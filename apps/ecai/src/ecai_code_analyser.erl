-module(ecai_code_analyser).

-export([
    analyse/2,
    analyse_module/2,
    analyse_file/2,
    repo_source_files/2,
    module_source/1,
    application_modules/1
]).

-define(ALLOWED_APPS, [damage, ecai, erm]).

analyse(App, Module) ->
    analyse_module(App, Module).

analyse_module(App, Module) when is_atom(App), is_atom(Module) ->
    case lists:member(App, ?ALLOWED_APPS) of
        false -> {error, {unsupported_application, App}};
        true ->
            case module_source(Module) of
                {ok, SourceKind, SourceName, SourceBin, Forms} ->
                    build_analysis(App, Module, SourceKind, SourceName, SourceBin, Forms);
                {error, _} = Error -> Error
            end
    end.

analyse_file(App, Path0) when is_atom(App) ->
    Path = path_to_list(Path0),
    case lists:member(App, ?ALLOWED_APPS) of
        false -> {error, {unsupported_application, App}};
        true ->
            case file:read_file(Path) of
                {error, Reason} -> {error, {cannot_read_source, Path, Reason}};
                {ok, SourceBin0} ->
                    SourceBin = normalize_source(SourceBin0),
                    IncludeDirs = include_dirs(Path),
                    case epp:parse_file(Path, IncludeDirs, []) of
                        {ok, Forms} ->
                            case module_attribute(Forms) of
                                {ok, Module} ->
                                    build_analysis(App, Module, repo_source, Path, SourceBin, Forms);
                                not_found ->
                                    {error, {module_attribute_not_found, Path}}
                            end;
                        {error, Reason} ->
                            {error, {source_parse_failed, Path, Reason}}
                    end
            end
    end.

repo_source_files(App, RepoRoot0) when is_atom(App) ->
    case lists:member(App, ?ALLOWED_APPS) of
        false -> {error, {unsupported_application, App}};
        true ->
            RepoRoot = filename:absname(path_to_list(RepoRoot0)),
            AppRoot = filename:join([RepoRoot, "apps", atom_to_list(App)]),
            Dirs = [filename:join(AppRoot, D) || D <- ["src", "test", "tests"]],
            %% Each filename is a charlist. lists:flatten/1 would flatten the
            %% filenames themselves into integer character codes. Append only
            %% the outer list of per-directory file lists.
            Files = lists:usort(lists:append([erl_files_recursive(D) || D <- Dirs])),
            case Files of
                [] -> {error, {no_repo_sources, App, AppRoot}};
                _ -> {ok, Files}
            end
    end.

application_modules(App) when is_atom(App) ->
    case lists:member(App, ?ALLOWED_APPS) of
        false -> {error, {unsupported_application, App}};
        true ->
            case application:get_key(App, modules) of
                {ok, Modules} when is_list(Modules) -> {ok, lists:sort(Modules)};
                undefined -> {error, {application_not_loaded, App}};
                Other -> {error, {cannot_read_application_modules, App, Other}}
            end
    end.

module_source(Module) ->
    case code:which(Module) of
        non_existing -> {error, {module_not_loaded, Module}};
        preloaded -> {error, {preloaded_module_has_no_beam_path, Module}};
        BeamPath -> module_source_from_beam(Module, BeamPath)
    end.

module_source_from_beam(Module, BeamPath) ->
    case beam_lib:chunks(BeamPath, [compile_info, abstract_code]) of
        {ok, {Module, Chunks}} ->
            CompileInfo = proplists:get_value(compile_info, Chunks, []),
            Abstract = proplists:get_value(abstract_code, Chunks, no_abstract_code),
            Forms = abstract_forms(Abstract),
            case source_path(CompileInfo) of
                {ok, SourcePath} ->
                    case file:read_file(SourcePath) of
                        {ok, SourceBin} ->
                            {ok, source_file, SourcePath, normalize_source(SourceBin), Forms};
                        {error, _} ->
                            abstract_source(Module, BeamPath, Abstract)
                    end;
                not_found ->
                    abstract_source(Module, BeamPath, Abstract)
            end;
        {error, beam_lib, Reason} ->
            {error, {beam_read_failed, Module, BeamPath, Reason}};
        Other ->
            {error, {unexpected_beam_result, Module, BeamPath, Other}}
    end.

build_analysis(App, Module, SourceKind, SourceName, Source, Forms) ->
    Exports = exports(Forms),
    Functions = functions(Forms),
    Calls = remote_calls(Forms),
    LocalCalls = local_calls(Forms),
    Behaviours = behaviours(Forms),
    ConfigReads = config_calls(Forms, get),
    ConfigWrites = config_calls(Forms, set),
    Analysis0 = #{
        application => App,
        module => Module,
        source_kind => SourceKind,
        source_name => to_binary(SourceName),
        source_sha256 => sha256_hex(Source),
        source => Source,
        exports => Exports,
        functions => Functions,
        specs => specs(Forms),
        types => types(Forms),
        records => records(Forms),
        behaviours => Behaviours,
        includes => includes(Source),
        remote_calls => Calls,
        local_calls => LocalCalls,
        config_reads => ConfigReads,
        config_writes => ConfigWrites,
        sends_messages => has_message_send(Forms),
        uses_nif => uses_nif(Forms, Calls),
        security_boundaries => security_boundaries(Calls, Forms),
        test_module => is_test_module(Module, SourceName),
        analysed_at => now_iso8601()
    },
    AnalysisHash = sha256_hex(term_to_binary(maps:remove(source, Analysis0), [deterministic])),
    {ok, Analysis0#{analysis_sha256 => AnalysisHash}}.

module_attribute(Forms) ->
    case [M || {attribute, _, module, M} <- Forms, is_atom(M)] of
        [Module | _] -> {ok, Module};
        [] -> not_found
    end.

include_dirs(Path) ->
    SourceDir = filename:dirname(Path),
    AppRoot = filename:dirname(SourceDir),
    Candidates = [SourceDir, filename:join(AppRoot, "include")],
    [D || D <- Candidates, filelib:is_dir(D)].

erl_files_recursive(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            %% Do not use lists:flatten/1 here: Path is a charlist, and flatten
            %% would turn ["foo.erl"] into the integer characters of the path.
            lists:append([
                begin
                    Path = filename:join(Dir, Name),
                    case filelib:is_dir(Path) of
                        true -> erl_files_recursive(Path);
                        false ->
                            case filename:extension(Name) of
                                ".erl" -> [Path];
                                _ -> []
                            end
                    end
                end
             || Name <- Names, Name =/= ".", Name =/= ".."]);
        {error, _} -> []
    end.

source_path(CompileInfo) when is_list(CompileInfo) ->
    case proplists:get_value(source, CompileInfo, undefined) of
        undefined -> not_found;
        Source when is_binary(Source) -> {ok, binary_to_list(Source)};
        Source when is_list(Source) -> {ok, Source};
        _ -> not_found
    end;
source_path(_) -> not_found.

abstract_forms({raw_abstract_v1, Forms}) when is_list(Forms) -> Forms;
abstract_forms(_) -> [].

abstract_source(Module, BeamPath, {raw_abstract_v1, Forms}) when is_list(Forms) ->
    try
        Text = iolist_to_binary([erl_pp:form(Form) || Form <- Forms]),
        {ok, beam_abstract_code, BeamPath, Text, Forms}
    catch
        Class:Reason:Stack ->
            {error, {cannot_pretty_print_abstract_code, Module, Class, Reason, Stack}}
    end;
abstract_source(Module, BeamPath, no_abstract_code) ->
    {error, {source_unavailable_and_no_debug_info, Module, BeamPath}};
abstract_source(Module, BeamPath, Other) ->
    {error, {unsupported_abstract_code, Module, BeamPath, Other}}.

exports(Forms) ->
    uniq(lists:flatten([
        [{Name, Arity} || {Name, Arity} <- Values]
     || {attribute, _, export, Values} <- Forms,
        is_list(Values)
    ])).

functions(Forms) ->
    lists:sort([
        #{name => Name, arity => Arity, line => line_number(Line)}
     || {function, Line, Name, Arity, _Clauses} <- Forms
    ]).

behaviours(Forms) ->
    uniq([
        Behaviour
     || {attribute, _, Key, Behaviour} <- Forms,
        (Key =:= behaviour orelse Key =:= behavior),
        is_atom(Behaviour)
    ]).

specs(Forms) ->
    lists:sort([
        #{name => Name, arity => Arity, line => line_number(Line)}
     || {attribute, Line, spec, {{Name, Arity}, _Spec}} <- Forms
    ]).

types(Forms) ->
    lists:sort(lists:filtermap(
        fun
            ({attribute, Line, type, {Name, _Body, Vars}}) when is_atom(Name), is_list(Vars) ->
                {true, #{name => Name, arity => length(Vars), kind => type,
                         line => line_number(Line)}};
            ({attribute, Line, opaque, {Name, _Body, Vars}}) when is_atom(Name), is_list(Vars) ->
                {true, #{name => Name, arity => length(Vars), kind => opaque,
                         line => line_number(Line)}};
            (_) -> false
        end,
        Forms
    )).

records(Forms) ->
    lists:sort([
        #{name => Name, line => line_number(Line)}
     || {attribute, Line, record, {Name, _Fields}} <- Forms,
        is_atom(Name)
    ]).

includes(Source) ->
    Pattern = <<"-include(?:_lib)?\\s*\\(\\s*\\\"([^\\\"]+)\\\"\\s*\\)\\s*\\.">>,
    case re:run(Source, Pattern, [global, {capture, [1], binary}]) of
        {match, Matches} -> uniq([Path || [Path] <- Matches]);
        nomatch -> []
    end.

remote_calls(Forms) ->
    Calls = collect(Forms, fun remote_call_node/1),
    uniq(Calls).

remote_call_node({call, Line, {remote, _, {atom, _, Mod}, {atom, _, Fun}}, Args})
  when is_atom(Mod), is_atom(Fun), is_list(Args) ->
    {match, #{module => Mod, function => Fun, arity => length(Args), line => line_number(Line)}};
remote_call_node(_) -> nomatch.

local_calls(Forms) ->
    Calls = collect(Forms, fun local_call_node/1),
    uniq(Calls).

local_call_node({call, Line, {atom, _, Fun}, Args}) when is_atom(Fun), is_list(Args) ->
    {match, #{function => Fun, arity => length(Args), line => line_number(Line)}};
local_call_node(_) -> nomatch.

config_calls(Forms, get) ->
    uniq(collect(Forms, fun(Node) -> config_node(Node, get) end));
config_calls(Forms, set) ->
    uniq(collect(Forms, fun(Node) -> config_node(Node, set) end)).

config_node({call, Line, {remote, _, {atom, _, application}, {atom, _, Fun}}, Args}, Mode)
  when is_list(Args) ->
    IsGet = lists:member(Fun, [get_env, get_all_env]),
    IsSet = lists:member(Fun, [set_env, unset_env]),
    case ((Mode =:= get) andalso IsGet) orelse ((Mode =:= set) andalso IsSet) of
        true ->
            {match, #{function => Fun, arity => length(Args), line => line_number(Line),
                      application => config_application(Fun, Args), key => config_key(Fun, Args)}};
        false -> nomatch
    end;
config_node(_, _) -> nomatch.

config_application(get_env, [_Key]) -> undefined;
config_application(get_all_env, []) -> undefined;
config_application(_Fun, Args) -> literal_atom_arg(Args, 1).

config_key(get_all_env, _Args) -> undefined;
config_key(_Fun, Args) ->
    case Args of
        [_App, Key | _] -> literal_value(Key);
        [Key] -> literal_value(Key);
        _ -> undefined
    end.

literal_atom_arg(Args, N) ->
    case nth(N, Args) of
        {atom, _, A} -> A;
        _ -> undefined
    end.

literal_value({atom, _, A}) -> A;
literal_value({integer, _, I}) -> I;
literal_value({char, _, I}) -> I;
literal_value({string, _, S}) -> to_binary(S);
literal_value({bin, _, _}) -> <<"<binary-expression>">>;
literal_value(_) -> undefined.

has_message_send(Forms) ->
    collect(Forms, fun
        ({op, _Line, '!', _Left, _Right}) -> {match, true};
        (_) -> nomatch
    end) =/= [].

uses_nif(Forms, Calls) ->
    HasNifAttr = lists:any(fun
        ({attribute, _, nif, _}) -> true;
        (_) -> false
    end, Forms),
    HasLoadNif = lists:any(fun
        (#{module := erlang, function := load_nif}) -> true;
        (_) -> false
    end, Calls),
    HasNifAttr orelse HasLoadNif.

security_boundaries(Calls, Forms) ->
    Modules = [maps:get(module, C) || C <- Calls],
    Base0 = [],
    Base1 = add_boundary(filesystem, any_member(Modules, [file, filelib]), Base0),
    Base2 = add_boundary(network, any_member(Modules, [gen_tcp, gen_udp, ssl, httpc, gun, damage_gun]), Base1),
    Base3 = add_boundary(crypto, any_member(Modules, [crypto, public_key, ssl]), Base2),
    Base4 = add_boundary(process_execution,
        any_call(Calls, os, cmd) orelse any_call(Calls, erlang, open_port), Base3),
    Base5 = add_boundary(persistent_storage, any_member(Modules, [dets, mnesia, disk_log]), Base4),
    Base6 = add_boundary(shared_memory, any_member(Modules, [ets, persistent_term]), Base5),
    Base7 = add_boundary(code_loading, any_member(Modules, [code, beam_lib]), Base6),
    Base8 = add_boundary(message_passing, has_message_send(Forms), Base7),
    lists:sort(Base8).

add_boundary(Name, true, Acc) -> [Name | Acc];
add_boundary(_Name, false, Acc) -> Acc.

any_member(Values, Candidates) ->
    lists:any(fun(V) -> lists:member(V, Candidates) end, Values).

any_call(Calls, Mod, Fun) ->
    lists:any(fun
        (#{module := Mod0, function := Fun0}) when Mod0 =:= Mod, Fun0 =:= Fun -> true;
        (_) -> false
    end, Calls).

is_test_module(Module, SourceName0) ->
    Name = atom_to_list(Module),
    SourceName = path_to_list(SourceName0),
    lists:suffix("_test", Name) orelse
    lists:suffix("_tests", Name) orelse
    string:str(SourceName, "/test/") > 0 orelse
    string:str(SourceName, "/tests/") > 0.

collect(Term, Matcher) ->
    lists:reverse(collect_walk(Term, Matcher, [])).

collect_walk(Term, Matcher, Acc0) ->
    Acc1 = case Matcher(Term) of
        {match, Value} -> [Value | Acc0];
        nomatch -> Acc0
    end,
    case Term of
        Tuple when is_tuple(Tuple) ->
            lists:foldl(fun(Elem, Acc) -> collect_walk(Elem, Matcher, Acc) end,
                        Acc1, tuple_to_list(Tuple));
        List when is_list(List) ->
            lists:foldl(fun(Elem, Acc) -> collect_walk(Elem, Matcher, Acc) end,
                        Acc1, List);
        _ -> Acc1
    end.

nth(N, List) when N > 0 ->
    try lists:nth(N, List) catch error:function_clause -> undefined; error:badarg -> undefined end.

uniq(List) ->
    lists:usort(List).

line_number(Line) when is_integer(Line) -> Line;
line_number(Anno) ->
    try erl_anno:line(Anno) catch _:_ -> 0 end.

normalize_source(Bin) when is_binary(Bin) -> unicode:characters_to_binary(Bin);
normalize_source(IoData) -> unicode:characters_to_binary(IoData).

sha256_hex(Bin) -> hex(crypto:hash(sha256, Bin)).

hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
