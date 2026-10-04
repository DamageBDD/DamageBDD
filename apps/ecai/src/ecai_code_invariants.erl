-module(ecai_code_invariants).

%% Deterministic extraction of code facts used to constrain model-generated repairs.
-export([
    build/2,
    build/3,
    file/1,
    file/2,
    problem_files/1
]).

-define(DEFAULT_MAX_FILES, 16).
-define(DEFAULT_MAX_SOURCE_BYTES, 32768).

-spec build(file:filename_all(), map()) -> {ok, map()} | {error, term()}.
build(Repo, Problem) ->
    build(Repo, Problem, #{}).

-spec build(file:filename_all(), map(), map()) -> {ok, map()} | {error, term()}.
build(Repo0, Problem, Opts) when is_map(Problem), is_map(Opts) ->
    Repo = filename:absname(to_list(Repo0)),
    MaxFiles = maps:get(max_files, Opts, ?DEFAULT_MAX_FILES),
    RequestedTargets = lists:usort(problem_files(Problem)),
    Relevant = lists:usort(maps:get(relevant_files, Opts, [])),
    TargetFiles0 = resolve_files(Repo, RequestedTargets),
    TargetFiles =
        case TargetFiles0 of
            [] -> lists:sublist(resolve_files(Repo, Relevant), MaxFiles);
            _ -> lists:sublist(TargetFiles0, MaxFiles)
        end,
    SeedFiles = lists:usort(TargetFiles ++ resolve_files(Repo, Relevant)),
    InitialFiles =
        case SeedFiles of
            [] -> lists:sublist(discover_erlang_files(Repo), MaxFiles);
            _ -> SeedFiles
        end,
    FileOpts = #{max_source_bytes => maps:get(max_source_bytes, Opts, ?DEFAULT_MAX_SOURCE_BYTES)},
    InitialFacts = facts(Repo, InitialFiles, FileOpts),
    Files = repair_closure(Repo, InitialFiles, InitialFacts, MaxFiles),
    Facts = facts(Repo, Files, FileOpts),
    Manifest = maps:from_list([{maps:get(path, Fact), Fact} || Fact <- Facts]),
    TargetRelative0 = [ecai_repair_git:relative(Repo, Path) || Path <- TargetFiles],
    TargetRelative =
        case TargetRelative0 of
            [] -> [ecai_repair_git:relative(Repo, Path) || Path <- InitialFiles];
            _ -> TargetRelative0
        end,
    Head = value_or_undefined(ecai_repair_git:head(Repo)),
    Branch = value_or_undefined(ecai_repair_git:branch(Repo)),
    {ok, #{
        repo_state => #{
            path => unicode:characters_to_binary(Repo),
            head => Head,
            branch => Branch
        },
        target_files => lists:sort(lists:usort(TargetRelative)),
        context_files => lists:sort(maps:keys(Manifest)),
        source_manifest => Manifest,
        relation_hints => relation_hints(Facts),
        extracted_invariants => extracted_invariants(Facts)
    }};
build(_Repo, _Problem, _Opts) ->
    {error, invalid_arguments}.

-spec file(file:filename_all()) -> {ok, map()} | {error, term()}.
file(Path) -> file(Path, #{}).

-spec file(file:filename_all(), map()) -> {ok, map()} | {error, term()}.
file(Path0, Opts) ->
    Path = to_list(Path0),
    MaxBytes = maps:get(max_source_bytes, Opts, ?DEFAULT_MAX_SOURCE_BYTES),
    case file:read_file(Path) of
        {ok, Source} ->
            Hash = hex(crypto:hash(sha256, Source)),
            FormsResult = epp:parse_file(Path, [], []),
            Parsed =
                case FormsResult of
                    {ok, Forms} -> parse_forms(Forms);
                    {error, Reason} -> #{parse_error => Reason}
                end,
            Rel = maps:get(relative_path, Opts, unicode:characters_to_binary(Path)),
            {ok, Parsed#{
                path => Rel,
                sha256 => Hash,
                size => byte_size(Source),
                source_excerpt => truncate(Source, MaxBytes)
            }};
        {error, Reason} ->
            {error, {read_failed, Path0, Reason}}
    end.

-spec problem_files(map()) -> [file:filename_all()].
problem_files(Problem) when is_map(Problem) ->
    lists:usort(collect_paths(Problem, 0));
problem_files(_) ->
    [].

parse_forms(Forms) ->
    Module = first([M || {attribute, _, module, M} <- Forms], undefined),
    Exports = lists:usort(lists:append([Es || {attribute, _, export, Es} <- Forms])),
    ExportTypes = lists:usort(lists:append([Es || {attribute, _, export_type, Es} <- Forms])),
    Behaviours = lists:usort(
        [B || {attribute, _, behaviour, B} <- Forms] ++
            [B || {attribute, _, behavior, B} <- Forms]
    ),
    Specs = lists:usort([
        {Name, Arity}
     || {attribute, _, spec, Spec} <- Forms,
        {Name, Arity} <- [spec_name_arity(Spec)],
        Name =/= undefined
    ]),
    Callbacks = lists:usort([
        {Name, Arity}
     || {attribute, _, callback, Spec} <- Forms,
        {Name, Arity} <- [spec_name_arity(Spec)],
        Name =/= undefined
    ]),
    Functions = lists:sort([
        #{name => Name, arity => Arity, clauses => length(Clauses), line => Line}
     || {function, Line, Name, Arity, Clauses} <- Forms
    ]),
    Calls = lists:usort(lists:append([calls(Form) || Form <- Forms])),
    #{
        module => Module,
        exports => Exports,
        export_types => ExportTypes,
        behaviours => Behaviours,
        specs => Specs,
        callbacks => Callbacks,
        functions => Functions,
        calls => Calls
    }.

spec_name_arity({{Name, Arity}, _}) when is_atom(Name), is_integer(Arity) -> {Name, Arity};
spec_name_arity({{_Module, Name, Arity}, _}) when is_atom(Name), is_integer(Arity) -> {Name, Arity};
spec_name_arity(_) -> {undefined, undefined}.

calls(Term) ->
    lists:usort(calls(Term, [])).

calls({call, _, {atom, _, Name}, Args} = Term, Acc) ->
    walk_children(Term, [#{kind => local, function => Name, arity => length(Args)} | Acc]);
calls({call, _, {remote, _, {atom, _, Mod}, {atom, _, Name}}, Args} = Term, Acc) ->
    walk_children(Term, [
        #{kind => remote, module => Mod, function => Name, arity => length(Args)} | Acc
    ]);
calls(Term, Acc) when is_tuple(Term) ->
    walk_children(Term, Acc);
calls(Term, Acc) when is_list(Term) ->
    lists:foldl(fun(Item, A) -> calls(Item, A) end, Acc, Term);
calls(_Term, Acc) ->
    Acc.

walk_children(Term, Acc) ->
    lists:foldl(fun(Item, A) -> calls(Item, A) end, Acc, tuple_to_list(Term)).

facts(Repo, Files, FileOpts) ->
    [
        Fact
     || Path <- Files,
        {ok, Fact} <- [
            file(Path, FileOpts#{
                relative_path => ecai_repair_git:relative(Repo, Path)
            })
        ]
    ].

repair_closure(Repo, InitialFiles, InitialFacts, MaxFiles) ->
    All = discover_erlang_files(Repo),
    Modules = lists:usort([
        atom_to_binary(Module, utf8)
     || Fact <- InitialFacts,
        Module <- [maps:get(module, Fact, undefined)],
        is_atom(Module),
        Module =/= undefined
    ]),
    Callees = lists:usort([
        atom_to_binary(Module, utf8)
     || Fact <- InitialFacts,
        Call <- maps:get(calls, Fact, []),
        maps:get(kind, Call, undefined) =:= remote,
        Module <- [maps:get(module, Call, undefined)],
        is_atom(Module)
    ]),
    ModuleFiles = [
        Path
     || Path <- All,
        lists:member(module_name_from_path(Path), Callees)
    ],
    Referencing = [
        Path
     || Path <- All,
        not lists:member(Path, InitialFiles),
        references_any_module(Path, Modules)
    ],
    Tests = [
        Path
     || Path <- Referencing,
        is_test_file(Path)
    ],
    Callers = [Path || Path <- Referencing, not is_test_file(Path)],
    Ordered =
        lists:usort(InitialFiles) ++
            subtract(lists:usort(Tests), InitialFiles) ++
            subtract(lists:usort(ModuleFiles), InitialFiles ++ Tests) ++
            subtract(lists:usort(Callers), InitialFiles ++ Tests ++ ModuleFiles),
    lists:sublist(dedupe(Ordered), MaxFiles).

module_name_from_path(Path) ->
    unicode:characters_to_binary(filename:basename(Path, filename:extension(Path))).

references_any_module(_Path, []) ->
    false;
references_any_module(Path, Modules) ->
    case file:read_file(Path) of
        {ok, Source} ->
            lists:any(
                fun(Module) ->
                    binary:match(Source, <<Module/binary, ":">>) =/= nomatch orelse
                        binary:match(Source, <<"-behaviour(", Module/binary>>) =/= nomatch orelse
                        binary:match(Source, <<"-behavior(", Module/binary>>) =/= nomatch
                end,
                Modules
            );
        _ ->
            false
    end.

is_test_file(Path) ->
    Base = filename:basename(Path),
    lists:suffix("_tests.erl", Base) orelse
        lists:suffix("_test.erl", Base) orelse
        lists:suffix("_SUITE.erl", Base) orelse
        lists:member("test", filename:split(Path)).

subtract(Values, Existing) -> [V || V <- Values, not lists:member(V, Existing)].

dedupe(Values) -> dedupe(Values, #{}, []).

dedupe([Value | Rest], Seen, Acc) ->
    case maps:is_key(Value, Seen) of
        true -> dedupe(Rest, Seen, Acc);
        false -> dedupe(Rest, Seen#{Value => true}, [Value | Acc])
    end;
dedupe([], _Seen, Acc) ->
    lists:reverse(Acc).

resolve_files(Repo, Paths) ->
    lists:usort([
        Full
     || P <- flatten_paths(Paths),
        {ok, Full} <- [ecai_repair_git:safe_join(Repo, P)],
        filelib:is_regular(Full)
    ]).

discover_erlang_files(Repo) ->
    lists:sort(
        filelib:fold_files(
            Repo,
            ".*\\.(erl|hrl)$",
            true,
            fun(Path, Acc) -> [Path | Acc] end,
            []
        )
    ).

collect_paths(_Map, Depth) when Depth > 5 -> [];
collect_paths(Map, Depth) when is_map(Map) ->
    Keys = [file, files, path, paths, target_file, target_files, allowed_files, permitted_files],
    Direct = lists:append([flatten_paths(maps:get(K, Map, [])) || K <- Keys]),
    NestedKeys = [target, source, context, failure, diagnostic, repair, metadata],
    Nested = lists:append([
        collect_paths(maps:get(K, Map, #{}), Depth + 1)
     || K <- NestedKeys,
        maps:is_key(K, Map)
    ]),
    Direct ++ Nested;
collect_paths(List, Depth) when is_list(List) ->
    case is_charlist(List) of
        true -> [List];
        false -> lists:append([collect_paths(V, Depth + 1) || V <- List])
    end;
collect_paths(_Other, _Depth) ->
    [].

flatten_paths(Bin) when is_binary(Bin) -> [Bin];
flatten_paths(List) when is_list(List) ->
    case is_charlist(List) of
        true -> [List];
        false -> lists:append([flatten_paths(V) || V <- List])
    end;
flatten_paths(_) ->
    [].

relation_hints(Facts) ->
    lists:sort(
        lists:append([
            [
                #{from => maps:get(module, Fact, undefined), relation => calls, to => Call}
             || Call <- maps:get(calls, Fact, [])
            ]
         || Fact <- Facts
        ])
    ).

extracted_invariants(Facts) ->
    lists:sort(
        lists:append([
            [
                #{
                    kind => public_exports,
                    path => maps:get(path, F),
                    expected => maps:get(exports, F, [])
                },
                #{
                    kind => behaviours,
                    path => maps:get(path, F),
                    expected => maps:get(behaviours, F, [])
                },
                #{
                    kind => callbacks,
                    path => maps:get(path, F),
                    expected => maps:get(callbacks, F, [])
                }
            ]
         || F <- Facts
        ])
    ).

value_or_undefined({ok, Value}) -> Value;
value_or_undefined(_) -> undefined.

first([Value | _], _Default) -> Value;
first([], Default) -> Default.

truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) ->
    <<(binary:part(Bin, 0, Max))/binary, "\n%% [ECAI source excerpt truncated]\n">>.

is_charlist([]) -> false;
is_charlist(List) when is_list(List) -> lists:all(fun is_integer/1, List);
is_charlist(_) -> false.

hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
