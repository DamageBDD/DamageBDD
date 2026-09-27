-module(ecai_learning_snapshot).

-export([build/0, build/1, write/0, write/1, path/0]).

-define(SCHEMA, 1).

build() -> build(#{}).

build(Opts) ->
    Data = ecai_learning_store:snapshot_data(),
    RepoRoot = repo_root(Opts),
    Git = git_info(RepoRoot),
    Ollama = ecai_ollama_client:defaults(),
    Core = #{
        schema_version => ?SCHEMA,
        git => Git,
        model => #{
            name => maps:get(model, Ollama),
            prompt_family => <<"ecai-code-learning-v1">>
        },
        applications => [damage, ecai, erm],
        learning => normalize_lists(Data)
    },
    SnapshotId = sha256_hex(term_to_binary(Core, [deterministic])),
    Core#{
        snapshot_id => SnapshotId,
        created_at => now_iso8601(),
        ollama_pool => safe_pool_status()
    }.

write() -> write(#{}).

write(Opts) ->
    Snapshot = build(Opts),
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            File = ecai_code_paths:log_file(Root, "codebase_learning.json"),
            Tmp = File ++ ".tmp",
            Encoded = jsx:encode(json_safe(Snapshot)),
            case file:write_file(Tmp, Encoded) of
                ok ->
                    case file:rename(Tmp, File) of
                        ok -> {ok, File, Snapshot};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

path() ->
    case ecai_code_paths:state_root() of
        {ok, Root} -> {ok, ecai_code_paths:log_file(Root, "codebase_learning.json")};
        {error, _} = Error -> Error
    end.

safe_pool_status() ->
    try ecai_ollama_pool:status() of
        Status -> Status
    catch
        Class:Reason -> #{available => false, error => to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

normalize_lists(Data) ->
    Data#{
        analyses => sort_by_module(maps:get(analyses, Data, [])),
        module_knowledge => sort_by_module(maps:get(module_knowledge, Data, [])),
        repairs => sort_repairs(maps:get(repairs, Data, []))
    }.

sort_by_module(List) ->
    lists:sort(fun(A, B) ->
        {maps:get(application, A, undefined), maps:get(module, A, undefined)} =<
        {maps:get(application, B, undefined), maps:get(module, B, undefined)}
    end, List).

sort_repairs(List) ->
    lists:sort(fun(A, B) ->
        {maps:get(fingerprint, A, <<>>), maps:get(finding_version, A, <<>>)} =<
        {maps:get(fingerprint, B, <<>>), maps:get(finding_version, B, <<>>)}
    end, List).

repo_root(Opts) ->
    Root0 = maps:get(repo_root, Opts,
        application:get_env(ecai, code_repo_root, ".")),
    filename:absname(path_to_list(Root0)).

git_info(RepoRoot) ->
    case filelib:is_dir(filename:join(RepoRoot, ".git")) of
        false -> #{repo_root => to_binary(RepoRoot), available => false};
        true ->
            Commit = command(RepoRoot, "git", ["rev-parse", "HEAD"]),
            Status = command(RepoRoot, "git", ["status", "--porcelain"]),
            #{
                repo_root => to_binary(RepoRoot),
                available => true,
                commit => command_value(Commit),
                dirty => command_value(Status) =/= <<>>,
                status => command_value(Status)
            }
    end.

command_value({ok, Bin}) -> trim(Bin);
command_value({error, Reason}) -> to_binary(io_lib:format("error:~p", [Reason])).

command(Cwd, ExeName, Args) ->
    case os:find_executable(ExeName) of
        false -> {error, {executable_not_found, ExeName}};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [binary, exit_status, stderr_to_stdout,
                {args, Args}, {cd, Cwd}]),
            collect_port(Port, <<>>, 30000)
    end.

collect_port(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, Acc}}
    after Timeout ->
        catch port_close(Port),
        {error, timeout}
    end.

trim(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(Tuple) when is_tuple(Tuple) -> [json_safe(V) || V <- tuple_to_list(Tuple)];
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(undefined) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Number) when is_number(Number) -> Number;
json_safe(Other) -> to_binary(Other).

json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_list(K) -> unicode:characters_to_binary(K);
json_key(K) -> to_binary(K).

sha256_hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
