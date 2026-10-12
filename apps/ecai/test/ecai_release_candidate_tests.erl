-module(ecai_release_candidate_tests).

-include_lib("eunit/include/eunit.hrl").

initial_release_candidate_test() ->
    with_repo(fun(Repo) ->
        {ok, Proposal} = ecai_release_candidate:propose(#{repo_root => Repo}),
        ?assertEqual(<<"v0.1.0-rc.1">>, maps:get(tag, Proposal)),
        ?assertEqual(initial, maps:get(proposal_source, Proposal))
    end).

stable_tag_starts_next_patch_rc_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v1.2.3"]),
        {ok, Proposal} = ecai_release_candidate:propose(#{repo_root => Repo}),
        ?assertEqual(<<"v1.2.4-rc.1">>, maps:get(tag, Proposal)),
        ?assertEqual(patch_bump, maps:get(proposal_source, Proposal)),
        ?assertEqual(<<"v1.2.3">>, maps:get(base_tag, Proposal))
    end).

existing_rc_increments_candidate_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v1.2.3"]),
        ok = commit(Repo, "rc one"),
        ok = git(Repo, ["tag", "v1.3.0-rc.1"]),
        ok = commit(Repo, "rc two"),
        ok = git(Repo, ["tag", "v1.3.0-rc.2"]),
        ok = commit(Repo, "next candidate delta"),
        {ok, Proposal} = ecai_release_candidate:propose(#{repo_root => Repo}),
        ?assertEqual(<<"v1.3.0-rc.3">>, maps:get(tag, Proposal)),
        ?assertEqual(existing_rc, maps:get(proposal_source, Proposal)),
        ?assertEqual(<<"v1.3.0-rc.2">>, maps:get(base_tag, Proposal))
    end).

release_branch_selects_version_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v1.9.8"]),
        ok = git(Repo, ["checkout", "-qb", "release/2.0.0"]),
        ok = commit(Repo, "prepare 2.0.0"),
        {ok, Proposal} = ecai_release_candidate:propose(#{repo_root => Repo}),
        ?assertEqual(<<"v2.0.0-rc.1">>, maps:get(tag, Proposal)),
        ?assertEqual(branch, maps:get(proposal_source, Proposal)),
        ?assertEqual(<<"v1.9.8">>, maps:get(base_tag, Proposal))
    end).

existing_prefix_is_preserved_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "2.4.1"]),
        {ok, Proposal} = ecai_release_candidate:propose(#{repo_root => Repo}),
        ?assertEqual(<<"2.4.2-rc.1">>, maps:get(tag, Proposal))
    end).

dirty_tree_rejected_test() ->
    with_repo(fun(Repo) ->
        ok = file:write_file(filename:join(Repo, "README.md"), <<"dirty\n">>),
        ?assertMatch(
            {error, {dirty_worktree, _}},
            ecai_release_candidate:propose(#{repo_root => Repo})
        )
    end).

current_tags_are_reported_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v0.9.0"]),
        ok = git(Repo, ["tag", "build-2026-10-12"]),
        {ok, Tags} = ecai_release_candidate:tags(#{repo_root => Repo}),
        ?assert(lists:member(<<"v0.9.0">>, maps:get(tags, Tags))),
        ?assert(lists:member(<<"build-2026-10-12">>, maps:get(tags, Tags))),
        ?assert(lists:member(<<"v0.9.0">>, maps:get(tags_at_head, Tags)))
    end).

with_repo(Fun) ->
    Base = filename:join(
        "/tmp",
        "ecai_release_candidate_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    ok = file:write_file(filename:join(Base, "README.md"), <<"base\n">>),
    ok = git(Base, ["init", "-q"]),
    ok = git(Base, ["config", "user.email", "ecai-test@example.invalid"]),
    ok = git(Base, ["config", "user.name", "ECAI Test"]),
    ok = git(Base, ["add", "."]),
    ok = git(Base, ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "base"]),
    try Fun(Base)
    after _ = file:del_dir_r(Base)
    end.

commit(Repo, Message) ->
    File = filename:join(Repo, "history.txt"),
    Existing = case file:read_file(File) of {ok, Bin} -> Bin; _ -> <<>> end,
    ok = file:write_file(File, <<Existing/binary, (unicode:characters_to_binary(Message))/binary, "\n">>),
    ok = git(Repo, ["add", "."]),
    git(Repo, ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", Message]).

git(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, _Output} -> ok;
        {error, Reason} -> erlang:error({git_failed, Args, Reason})
    end.

git_command(Cwd, Args) ->
    case os:find_executable("git") of
        false -> {error, executable_not_found};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [binary, exit_status, stderr_to_stdout, {args, ["-C", Cwd | Args]}]),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, Acc}}
    after 30000 ->
        try port_close(Port) catch _:_ -> ok end,
        {error, timeout}
    end.
