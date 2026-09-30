-module(ecai_git_worktree_tests).

-include_lib("eunit/include/eunit.hrl").

clean_tracked_only_by_default_test() ->
    with_repo(fun(Repo) ->
        Clean = path(Repo, "apps/ecai/src/clean.erl"),
        Dirty = path(Repo, "apps/ecai/src/dirty.erl"),
        Generated = path(
            Repo, "apps/damage/src/damage_build_info.erl"
        ),
        ok = file:write_file(Dirty, <<"dirty changed\n">>),
        ok = filelib:ensure_dir(Generated),
        ok = file:write_file(Generated, <<"generated\n">>),
        {ok, Included, Skipped} =
            ecai_git_worktree:filter_learning_files(
                Repo,
                [Clean, Dirty, Generated],
                #{}
            ),
        ?assertEqual([Clean], Included),
        ?assert(
            lists:any(
                fun
                    (#{path := <<"apps/ecai/src/dirty.erl">>,
                       reason := dirty_tracked}) ->
                        true;
                    (_) ->
                        false
                end,
                Skipped
            )
        ),
        ?assert(
            lists:any(
                fun
                    (#{
                        path :=
                            <<"apps/damage/src/damage_build_info.erl">>,
                        reason := untracked_or_generated
                    }) ->
                        true;
                    (_) ->
                        false
                end,
                Skipped
            )
        )
    end).

include_dirty_override_test() ->
    with_repo(fun(Repo) ->
        Dirty = path(Repo, "apps/ecai/src/dirty.erl"),
        Generated = path(
            Repo, "apps/damage/src/damage_build_info.erl"
        ),
        ok = file:write_file(Dirty, <<"dirty changed\n">>),
        ok = filelib:ensure_dir(Generated),
        ok = file:write_file(Generated, <<"generated\n">>),
        Files = [Dirty, Generated],
        ?assertEqual(
            {ok, Files, []},
            ecai_git_worktree:filter_learning_files(
                Repo,
                Files,
                #{include_dirty_files => true}
            )
        )
    end).

dirty_allowlist_test() ->
    with_repo(fun(Repo) ->
        Dirty = path(Repo, "apps/ecai/src/dirty.erl"),
        Generated = path(
            Repo, "apps/damage/src/damage_build_info.erl"
        ),
        ok = file:write_file(Dirty, <<"dirty changed\n">>),
        ok = filelib:ensure_dir(Generated),
        ok = file:write_file(Generated, <<"generated\n">>),
        {ok, Included, _Skipped} =
            ecai_git_worktree:filter_learning_files(
                Repo,
                [Dirty, Generated],
                #{
                    dirty_allowlist => [
                        "apps/damage/src/damage_build_info.erl"
                    ]
                }
            ),
        ?assertEqual([Generated], Included)
    end).

staged_change_is_dirty_test() ->
    with_repo(fun(Repo) ->
        Dirty = path(Repo, "apps/ecai/src/dirty.erl"),
        ok = file:write_file(Dirty, <<"staged changed\n">>),
        ok = git(Repo, ["add", "apps/ecai/src/dirty.erl"]),
        {ok, Included, Skipped} =
            ecai_git_worktree:filter_learning_files(
                Repo, [Dirty], #{}
            ),
        ?assertEqual([], Included),
        ?assertMatch(
            [#{reason := dirty_tracked}],
            Skipped
        )
    end).

with_repo(Fun) ->
    Repo = filename:join(
        "/tmp",
        "ecai_git_worktree_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ),
    Clean = path(Repo, "apps/ecai/src/clean.erl"),
    Dirty = path(Repo, "apps/ecai/src/dirty.erl"),
    ok = filelib:ensure_dir(Clean),
    ok = file:write_file(Clean, <<"clean\n">>),
    ok = file:write_file(Dirty, <<"dirty\n">>),
    ok = git(Repo, ["init", "-q"]),
    ok = git(
        Repo,
        ["config", "user.email", "ecai-test@example.invalid"]
    ),
    ok = git(
        Repo,
        ["config", "user.name", "ECAI Test"]
    ),
    ok = git(Repo, ["add", "."]),
    ok = git(
        Repo,
        [
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
            "commit", "-qm", "base"
        ]
    ),
    try
        Fun(Repo)
    after
        _ = file:del_dir_r(Repo)
    end.

path(Repo, Rel) ->
    filename:join(Repo, Rel).

git(Cwd, Args) ->
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
                    {args, ["-C", Cwd | Args]}
                ]
            ),
            case collect_git(Port, <<>>) of
                {ok, _} -> ok;
                {error, Reason} ->
                    erlang:error({git_failed, Args, Reason})
            end
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, Acc}}
    after 30000 ->
        try port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, timeout}
    end.
