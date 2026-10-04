-module(ecai_source_repository_tests).

-include_lib("eunit/include/eunit.hrl").

dirty_worktree_does_not_change_canonical_generation_test() ->
    with_repo(
        fun(Repo, StateRoot) ->
            Opts = #{
                repo_root => Repo,
                state_root => StateRoot
            },
            {ok, Base1} = ecai_source_repository:refresh(Opts),
            {ok, Source1} =
                ecai_source_repository:module_source(
                    ecai, sample, Opts
                ),
            ?assertEqual(
                <<"-module(sample).\nvalue() -> one.\n">>,
                maps:get(source, Source1)
            ),

            DevFile = filename:join(
                [Repo, "apps", "ecai", "src", "sample.erl"]
            ),
            ok = file:write_file(
                DevFile,
                <<"-module(sample).\nvalue() -> dirty.\n">>
            ),

            {ok, Source2} =
                ecai_source_repository:module_source(
                    ecai, sample, Opts
                ),
            ?assertEqual(
                maps:get(commit, Base1),
                maps:get(commit, Source2)
            ),
            ?assertEqual(
                <<"-module(sample).\nvalue() -> one.\n">>,
                maps:get(source, Source2)
            ),

            {ok, Dev} =
                ecai_source_repository:inspect_module(
                    ecai, sample, Opts
                ),
            ?assertEqual(false, maps:get(authoritative, Dev)),
            ?assertEqual(true, maps:get(dirty, Dev)),
            ?assertEqual(
                <<"-module(sample).\nvalue() -> dirty.\n">>,
                maps:get(source, Dev)
            )
        end
    ).

new_commit_creates_new_immutable_generation_test() ->
    with_repo(
        fun(Repo, StateRoot) ->
            Opts = #{
                repo_root => Repo,
                state_root => StateRoot
            },
            {ok, Base1} = ecai_source_repository:refresh(Opts),
            Root1 = path_to_list(maps:get(root, Base1)),
            File1 = filename:join(
                [Root1, "apps", "ecai", "src", "sample.erl"]
            ),
            {ok, OldBytes} = file:read_file(File1),

            DevFile = filename:join(
                [Repo, "apps", "ecai", "src", "sample.erl"]
            ),
            ok = file:write_file(
                DevFile,
                <<"-module(sample).\nvalue() -> two.\n">>
            ),
            ok = git(Repo, ["add", "."]),
            ok = git(Repo, ["commit", "-qm", "two"]),

            {ok, Base2} = ecai_source_repository:refresh(Opts),
            ?assertNotEqual(
                maps:get(commit, Base1),
                maps:get(commit, Base2)
            ),
            ?assertNotEqual(
                maps:get(root, Base1),
                maps:get(root, Base2)
            ),

            %% The previous generation remains immutable and readable.
            ?assertEqual({ok, OldBytes}, file:read_file(File1)),

            {ok, Source2} =
                ecai_source_repository:module_source(
                    ecai, sample, Opts
                ),
            ?assertEqual(
                <<"-module(sample).\nvalue() -> two.\n">>,
                maps:get(source, Source2)
            )
        end
    ).

with_repo(Fun) ->
    N = integer_to_list(
        erlang:unique_integer([positive, monotonic])
    ),
    Root = filename:join("/tmp", "ecai_source_repo_" ++ N),
    Repo = filename:join(Root, "dev"),
    StateRoot = filename:join(Root, "state"),
    Source = filename:join(
        [Repo, "apps", "ecai", "src", "sample.erl"]
    ),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(
        Source,
        <<"-module(sample).\nvalue() -> one.\n">>
    ),
    ok = git(Repo, ["init", "-q"]),
    ok = git(Repo, ["config", "--local", "user.email", "ecai@example.invalid"]),
    ok = git(Repo, ["config", "--local", "user.name", "ECAI"]),
    %% Synthetic test repositories must not inherit workstation signing policy.
    ok = git(Repo, ["config", "--local", "commit.gpgSign", "false"]),
    ok = git(Repo, ["config", "--local", "tag.gpgSign", "false"]),
    ok = git(Repo, ["add", "."]),
    ok = git(Repo, ["commit", "-qm", "one"]),
    try
        Fun(Repo, StateRoot)
    after
        _ = file:del_dir_r(Root)
    end.

git(Repo, Args) ->
    case os:find_executable("git") of
        false ->
            erlang:error(git_not_found);
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", Repo | Args]},
                    {cd, Repo}
                ]
            ),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            erlang:error({git_failed, Status, Acc})
    after 30000 ->
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        erlang:error(git_timeout)
    end.

path_to_list(B) when is_binary(B) -> binary_to_list(B);
path_to_list(L) when is_list(L) -> L.
