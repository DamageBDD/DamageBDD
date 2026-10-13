-module(ecai_source_repository).

%% Canonical committed-source substrate for ECAI code intelligence.
%%
%% The developer checkout is only used as a Git object/ref source. Canonical
%% operations read immutable detached worktrees materialized under the Damage
%% state tree and keyed by commit SHA. Uncommitted developer bytes never enter
%% the authoritative learning/audit/repair path.
%%
%% A full learner refresh advances the cached canonical generation. Targeted
%% learning and vulnerability scans consume that already-pinned generation.

-export([
    refresh/0,
    refresh/1,
    current/0,
    current/1,
    status/0,
    status/1,
    base_for_commit/1,
    base_for_commit/2,
    module_source/2,
    module_source/3,
    module_source_at_commit/3,
    module_source_at_commit/4,
    application_modules/1,
    application_modules/2,
    application_modules_at_commit/2,
    application_modules_at_commit/3,
    inspect_module/2,
    inspect_module/3
]).

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(CACHE_NS, ecai_source_repository_cache).
-define(ALLOWED_APPS, [damage, ecai, erm]).

refresh() ->
    refresh(#{}).

refresh(Opts) when is_map(Opts) ->
    case repository_context(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Ctx} ->
            Lock = {{?MODULE, maps:get(mirror_root, Ctx)}, self()},
            case global:trans(Lock, fun() -> do_refresh(Ctx, Opts) end) of
                aborted ->
                    {error, source_repository_lock_aborted};
                Result ->
                    Result
            end
    end.

current() ->
    current(#{}).

current(Opts) when is_map(Opts) ->
    case repository_context(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Ctx} ->
            Key = cache_key(Ctx),
            case persistent_term:get(Key, undefined) of
                #{commit := _Commit, root := _Root} = Base ->
                    {ok, Base};
                undefined ->
                    refresh(Opts)
            end
    end.

status() ->
    status(#{}).

status(Opts) when is_map(Opts) ->
    case repository_context(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Ctx} ->
            SourceRoot = maps:get(source_root, Ctx),
            Current =
                case persistent_term:get(cache_key(Ctx), undefined) of
                    undefined -> undefined;
                    Value -> maps:without([refreshed_at_ms], Value)
                end,
            SourceHead =
                case source_head(SourceRoot, command_timeout(Opts)) of
                    {ok, Commit} -> Commit;
                    {error, _} -> undefined
                end,
            Dirty = developer_status(SourceRoot, command_timeout(Opts)),
            {ok, #{
                mode => source_mode(Opts),
                developer_overlay => developer_overlay(Opts),
                source_root => to_binary(SourceRoot),
                mirror_root => to_binary(maps:get(mirror_root, Ctx)),
                bases_root => to_binary(maps:get(bases_root, Ctx)),
                current => Current,
                source_head => SourceHead,
                developer_dirty => maps:get(dirty, Dirty, undefined),
                developer_status => maps:get(status, Dirty, <<>>)
            }}
    end.

base_for_commit(Commit) ->
    base_for_commit(Commit, #{}).

base_for_commit(Commit0, Opts) when is_map(Opts) ->
    Commit = to_binary(Commit0),
    case valid_commit_id(Commit) of
        false ->
            {error, {invalid_commit_id, Commit}};
        true ->
            case repository_context(Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Ctx} ->
                    Lock = {{?MODULE, maps:get(mirror_root, Ctx)}, self()},
                    case
                        global:trans(
                            Lock,
                            fun() -> ensure_commit_base(Ctx, Commit, Opts) end
                        )
                    of
                        aborted ->
                            {error, source_repository_lock_aborted};
                        Result ->
                            Result
                    end
            end
    end.

module_source(App, Module) ->
    module_source(App, Module, #{}).

module_source(App, Module, Opts) when
    is_atom(App), is_atom(Module), is_map(Opts)
->
    case allowed_app(App) of
        false ->
            {error, {unsupported_application, App}};
        true ->
            case current(Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Base} ->
                    read_module_from_base(App, Module, Base)
            end
    end.

module_source_at_commit(App, Module, Commit) ->
    module_source_at_commit(App, Module, Commit, #{}).

module_source_at_commit(App, Module, Commit, Opts) when
    is_atom(App), is_atom(Module), is_map(Opts)
->
    case allowed_app(App) of
        false ->
            {error, {unsupported_application, App}};
        true ->
            case base_for_commit(Commit, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Base} ->
                    read_module_from_base(App, Module, Base)
            end
    end.

application_modules(App) ->
    application_modules(App, #{}).

application_modules(App, Opts) when
    is_atom(App), is_map(Opts)
->
    case allowed_app(App) of
        false ->
            {error, {unsupported_application, App}};
        true ->
            case current(Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Base} ->
                    application_modules_from_base(App, Base)
            end
    end.

application_modules_at_commit(App, Commit) ->
    application_modules_at_commit(App, Commit, #{}).

application_modules_at_commit(App, Commit, Opts) when
    is_atom(App), is_map(Opts)
->
    case allowed_app(App) of
        false ->
            {error, {unsupported_application, App}};
        true ->
            case base_for_commit(Commit, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Base} ->
                    application_modules_from_base(App, Base)
            end
    end.

application_modules_from_base(App, Base) ->
    Root = path_to_list(maps:get(root, Base)),
    case ecai_code_analyser:repo_source_files(App, Root) of
        {error, _} = Error ->
            Error;
        {ok, Files} ->
            Modules = lists:usort([
                list_to_atom(filename:basename(Path, ".erl"))
             || Path <- Files,
                filename:extension(Path) =:= ".erl"
            ]),
            {ok, Modules}
    end.

inspect_module(App, Module) ->
    inspect_module(App, Module, #{}).

inspect_module(App, Module, Opts) when
    is_atom(App), is_atom(Module), is_map(Opts)
->
    case developer_overlay(Opts) of
        ignore_dirty ->
            {error, developer_overlay_disabled};
        inspect_only ->
            case repository_context(Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Ctx} ->
                    Root = maps:get(source_root, Ctx),
                    case first_existing_module_path(Root, App, Module) of
                        not_found ->
                            {error, {source_not_found, App, Module}};
                        {ok, RelPath, FullPath} ->
                            case file:read_file(FullPath) of
                                {error, Reason} ->
                                    {error, {cannot_read_developer_source, FullPath, Reason}};
                                {ok, Source} ->
                                    PathStatus = run_git(
                                        Root,
                                        ["status", "--porcelain", "--", RelPath],
                                        command_timeout(Opts)
                                    ),
                                    {ok, #{
                                        authoritative => false,
                                        origin => developer_worktree,
                                        application => App,
                                        module => Module,
                                        source_path => to_binary(RelPath),
                                        full_path => to_binary(FullPath),
                                        source_sha256 => sha256_hex(Source),
                                        source => Source,
                                        dirty => command_output(PathStatus) =/= <<>>
                                    }}
                            end
                    end
            end
    end.

%%====================================================================
%% Canonical generation
%%====================================================================

do_refresh(Ctx, Opts) ->
    SourceRoot = maps:get(source_root, Ctx),
    Timeout = command_timeout(Opts),
    case source_head(SourceRoot, Timeout) of
        {error, _} = Error ->
            Error;
        {ok, Commit} ->
            case ensure_mirror(Ctx, Opts) of
                {error, _} = Error ->
                    Error;
                ok ->
                    case ensure_commit_present(Ctx, Commit, Opts) of
                        {error, _} = Error ->
                            Error;
                        ok ->
                            case ensure_base(Ctx, Commit, Opts) of
                                {error, _} = Error ->
                                    Error;
                                {ok, Root} ->
                                    Dev = developer_status(SourceRoot, Timeout),
                                    Base = #{
                                        commit => Commit,
                                        root => to_binary(Root),
                                        mirror_root =>
                                            to_binary(maps:get(mirror_root, Ctx)),
                                        source_root => to_binary(SourceRoot),
                                        mode => source_mode(Opts),
                                        developer_overlay => developer_overlay(Opts),
                                        developer_dirty =>
                                            maps:get(dirty, Dev, undefined),
                                        refreshed_at => now_iso8601(),
                                        refreshed_at_ms =>
                                            erlang:system_time(millisecond)
                                    },
                                    persistent_term:put(cache_key(Ctx), Base),
                                    {ok, Base}
                            end
                    end
            end
    end.

ensure_commit_base(Ctx, Commit, Opts) ->
    case ensure_mirror(Ctx, Opts) of
        {error, _} = Error ->
            Error;
        ok ->
            case ensure_commit_present(Ctx, Commit, Opts) of
                {error, _} = Error ->
                    Error;
                ok ->
                    case ensure_base(Ctx, Commit, Opts) of
                        {error, _} = Error ->
                            Error;
                        {ok, Root} ->
                            {ok, #{
                                commit => Commit,
                                root => to_binary(Root),
                                mirror_root =>
                                    to_binary(maps:get(mirror_root, Ctx)),
                                source_root =>
                                    to_binary(maps:get(source_root, Ctx)),
                                mode => source_mode(Opts)
                            }}
                    end
            end
    end.

ensure_mirror(Ctx, Opts) ->
    Mirror = maps:get(mirror_root, Ctx),
    Source = maps:get(source_root, Ctx),
    Timeout = command_timeout(Opts),
    case mirror_available(Mirror) of
        false ->
            _ = remove_partial_path(Mirror),
            Parent = filename:dirname(Mirror),
            ok = ensure_dir(Parent),
            Clone = run_git_exe(
                Parent,
                ["clone", "--mirror", "--", Source, Mirror],
                Timeout
            ),
            case step_ok(Clone) of
                true -> ok;
                false -> {error, {cannot_clone_source_repository, Clone}}
            end;
        true ->
            _ = run_git_dir(
                Mirror,
                ["remote", "set-url", "origin", Source],
                Timeout
            ),
            Fetch = run_git_dir(
                Mirror,
                ["fetch", "--prune", "origin"],
                Timeout
            ),
            case step_ok(Fetch) of
                true -> ok;
                false -> {error, {cannot_refresh_source_repository, Fetch}}
            end
    end.

ensure_commit_present(Ctx, Commit, Opts) ->
    Mirror = maps:get(mirror_root, Ctx),
    Timeout = command_timeout(Opts),
    Object = binary_to_list(Commit) ++ "^{commit}",
    Check = run_git_dir(Mirror, ["cat-file", "-e", Object], Timeout),
    case step_ok(Check) of
        true ->
            ok;
        false ->
            Source = maps:get(source_root, Ctx),
            %% Fetch the exact object as well as normal refs. This keeps
            %% detached-HEAD development commits usable even before a branch
            %% or remote ref names them.
            Fetch = run_git_dir(
                Mirror,
                [
                    "fetch",
                    "--no-tags",
                    Source,
                    binary_to_list(Commit)
                ],
                Timeout
            ),
            case step_ok(Fetch) of
                false ->
                    {error, {cannot_fetch_canonical_commit, Commit, Fetch}};
                true ->
                    Check2 = run_git_dir(
                        Mirror, ["cat-file", "-e", Object], Timeout
                    ),
                    case step_ok(Check2) of
                        true -> ok;
                        false -> {error, {canonical_commit_missing, Commit, Check2}}
                    end
            end
    end.

ensure_base(Ctx, Commit, Opts) ->
    Bases = maps:get(bases_root, Ctx),
    Mirror = maps:get(mirror_root, Ctx),
    Root = filename:join(Bases, binary_to_list(Commit)),
    Timeout = command_timeout(Opts),
    ok = ensure_dir(Bases),
    case base_matches_commit(Root, Commit, Timeout) of
        true ->
            {ok, Root};
        false ->
            _ = run_git_dir(Mirror, ["worktree", "prune"], Timeout),
            _ = remove_partial_path(Root),
            Add = run_git_dir(
                Mirror,
                [
                    "worktree",
                    "add",
                    "--detach",
                    Root,
                    binary_to_list(Commit)
                ],
                Timeout
            ),
            case step_ok(Add) of
                true -> {ok, Root};
                false -> {error, {cannot_materialize_canonical_base, Commit, Root, Add}}
            end
    end.

base_matches_commit(Root, Commit, Timeout) ->
    case
        filelib:is_file(filename:join(Root, ".git")) orelse
            filelib:is_dir(filename:join(Root, ".git"))
    of
        false ->
            false;
        true ->
            case
                run_git(
                    Root,
                    ["rev-parse", "--verify", "HEAD^{commit}"],
                    Timeout
                )
            of
                #{ok := true, output := Output} ->
                    trim_binary(Output) =:= Commit;
                _ ->
                    false
            end
    end.

%%====================================================================
%% Source resolution
%%====================================================================

read_module_from_base(App, Module, Base) ->
    Root = path_to_list(maps:get(root, Base)),
    case first_existing_module_path(Root, App, Module) of
        not_found ->
            {error, {source_not_found, App, Module, maps:get(commit, Base, undefined)}};
        {ok, RelPath, FullPath} ->
            case file:read_file(FullPath) of
                {error, Reason} ->
                    {error, {cannot_read_canonical_source, FullPath, Reason}};
                {ok, Source} ->
                    {ok, #{
                        authoritative => true,
                        origin => canonical_repository,
                        application => App,
                        module => Module,
                        commit => maps:get(commit, Base),
                        root => maps:get(root, Base),
                        source_path => to_binary(RelPath),
                        full_path => to_binary(FullPath),
                        source_sha256 => sha256_hex(Source),
                        source => Source
                    }}
            end
    end.

first_existing_module_path(Root, App, Module) ->
    AppS = atom_to_list(App),
    ModuleS = atom_to_list(Module) ++ ".erl",
    Candidates = [
        filename:join(["apps", AppS, "src", ModuleS]),
        filename:join(["apps", AppS, "test", ModuleS]),
        filename:join(["apps", AppS, "tests", ModuleS])
    ],
    case first_existing_path(Root, Candidates) of
        not_found ->
            find_nested_module_path(Root, App, ModuleS);
        Found ->
            Found
    end.

find_nested_module_path(Root, App, ModuleFile) ->
    case ecai_code_analyser:repo_source_files(App, Root) of
        {ok, Files} ->
            case
                [
                    Path
                 || Path <- Files,
                    filename:basename(Path) =:= ModuleFile
                ]
            of
                [FullPath | _] ->
                    case repo_relative_path(Root, FullPath) of
                        {ok, RelPath} ->
                            {ok, RelPath, FullPath};
                        {error, _} ->
                            not_found
                    end;
                [] ->
                    not_found
            end;
        {error, _} ->
            not_found
    end.

repo_relative_path(Root0, Path0) ->
    Root = filename:split(filename:absname(path_to_list(Root0))),
    Path = filename:split(filename:absname(path_to_list(Path0))),
    case lists:prefix(Root, Path) andalso length(Path) > length(Root) of
        true ->
            {ok, filename:join(lists:nthtail(length(Root), Path))};
        false ->
            {error, source_outside_canonical_base}
    end.

first_existing_path(_Root, []) ->
    not_found;
first_existing_path(Root, [Rel | Rest]) ->
    Full = filename:join(Root, Rel),
    case filelib:is_regular(Full) of
        true -> {ok, Rel, Full};
        false -> first_existing_path(Root, Rest)
    end.

%%====================================================================
%% Repository context / config
%%====================================================================

repository_context(Opts) ->
    case ecai_code_paths:state_root(Opts) of
        {error, _} = Error ->
            Error;
        {ok, StateRoot} ->
            SourceRoot = filename:absname(
                path_to_list(
                    maps:get(
                        repo_root,
                        Opts,
                        application:get_env(ecai, code_repo_root, ".")
                    )
                )
            ),
            case repository_available(SourceRoot) of
                false ->
                    {error, {git_repository_not_found, SourceRoot}};
                true ->
                    SecurityRoot = ecai_code_paths:security_git_root(StateRoot),
                    Mirror = filename:join(SecurityRoot, "repository.git"),
                    Bases = filename:join(SecurityRoot, "bases"),
                    ok = ensure_dir(SecurityRoot),
                    ok = ensure_dir(Bases),
                    {ok, #{
                        state_root => StateRoot,
                        source_root => SourceRoot,
                        security_root => SecurityRoot,
                        mirror_root => Mirror,
                        bases_root => Bases
                    }}
            end
    end.

cache_key(Ctx) ->
    {
        ?CACHE_NS,
        maps:get(source_root, Ctx),
        maps:get(state_root, Ctx)
    }.

source_head(SourceRoot, Timeout) ->
    case
        run_git(
            SourceRoot,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            Timeout
        )
    of
        #{ok := true, output := Output} ->
            {ok, trim_binary(Output)};
        Result ->
            {error, {cannot_resolve_source_head, Result}}
    end.

developer_status(SourceRoot, Timeout) ->
    case run_git(SourceRoot, ["status", "--porcelain"], Timeout) of
        #{ok := true, output := Output} ->
            Status = trim_binary(Output),
            #{dirty => Status =/= <<>>, status => Status};
        Result ->
            #{
                dirty => undefined,
                status => <<>>,
                error => compact_result(Result)
            }
    end.

source_mode(Opts) ->
    case
        maps:get(
            source_mode,
            Opts,
            application:get_env(ecai, code_source_mode, committed)
        )
    of
        development -> development;
        <<"development">> -> development;
        "development" -> development;
        _ -> committed
    end.

developer_overlay(Opts) ->
    case
        maps:get(
            developer_overlay,
            Opts,
            application:get_env(
                ecai, code_dev_overlay, inspect_only
            )
        )
    of
        ignore_dirty -> ignore_dirty;
        <<"ignore_dirty">> -> ignore_dirty;
        "ignore_dirty" -> ignore_dirty;
        _ -> inspect_only
    end.

allowed_app(App) ->
    lists:member(App, ?ALLOWED_APPS).

valid_commit_id(Commit) when is_binary(Commit) ->
    case
        re:run(
            Commit,
            <<"^[0-9a-fA-F]{7,64}$">>,
            [{capture, none}]
        )
    of
        match -> true;
        nomatch -> false
    end;
valid_commit_id(_) ->
    false.

repository_available(Root) ->
    filelib:is_dir(filename:join(Root, ".git")) orelse
        filelib:is_file(filename:join(Root, ".git")).

mirror_available(Root) ->
    filelib:is_file(filename:join(Root, "HEAD")) andalso
        filelib:is_dir(filename:join(Root, "objects")).

remove_partial_path(Path) ->
    case filelib:is_dir(Path) of
        true ->
            file:del_dir_r(Path);
        false ->
            case filelib:is_file(Path) of
                true -> file:delete(Path);
                false -> ok
            end
    end.

ensure_dir(Dir) ->
    filelib:ensure_dir(filename:join(Dir, ".keep")).

command_timeout(Opts) ->
    case
        maps:get(
            command_timeout_ms,
            Opts,
            application:get_env(
                ecai, code_source_git_timeout_ms, ?DEFAULT_TIMEOUT_MS
            )
        )
    of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_TIMEOUT_MS
    end.

%%====================================================================
%% Git execution
%%====================================================================

run_git(Cwd, Args, Timeout) ->
    run_git_exe(Cwd, ["-C", Cwd | Args], Timeout).

run_git_dir(GitDir, Args, Timeout) ->
    Cwd = filename:dirname(GitDir),
    run_git_exe(Cwd, ["--git-dir", GitDir | Args], Timeout).

run_git_exe(Cwd, Args, Timeout) ->
    case os:find_executable("git") of
        false ->
            #{ok => false, error => git_not_found};
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, Args},
                    {cd, Cwd}
                ]
            ),
            collect_port(Port, <<>>, Timeout)
    end.

collect_port(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {exit_status, 0}} ->
            #{ok => true, output => Acc};
        {Port, {exit_status, Status}} ->
            #{ok => false, exit_status => Status, output => Acc}
    after Timeout ->
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        #{ok => false, error => timeout, output => Acc}
    end.

step_ok(#{ok := true}) -> true;
step_ok(_) -> false.

command_output(#{ok := true, output := Output}) ->
    trim_binary(Output);
command_output(_) ->
    <<>>.

compact_result(Result) when is_map(Result) ->
    maps:with([ok, exit_status, error, output], Result);
compact_result(Result) ->
    Result.

trim_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

sha256_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary(
        [
            io_lib:format("~2.16.0b", [Byte])
         || <<Byte>> <= crypto:hash(sha256, Bin)
        ]
    ).

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P);
path_to_list(P) when is_atom(P) -> atom_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
