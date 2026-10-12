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

propose_release_from_latest_rc_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v1.2.3"]),
        ok = commit(Repo, "prepare rc"),
        ok = git(Repo, ["tag", "v1.2.4-rc.1"]),
        {ok, Proposal} = ecai_release_candidate:propose_release(#{repo_root => Repo}),
        ?assertEqual(<<"v1.2.4">>, maps:get(tag, Proposal)),
        ?assertEqual(stable, maps:get(release_kind, Proposal)),
        ?assertEqual(<<"v1.2.4-rc.1">>, maps:get(base_tag, Proposal))
    end).

tag_release_candidate_creates_annotated_tag_test() ->
    with_repo(fun(Repo) ->
        {ok, Result} = ecai_release_candidate:tag_release_candidate(#{
            repo_root => Repo,
            require_learning_reference => false
        }),
        ?assertEqual(true, maps:get(created, Result)),
        ?assertEqual(rc, maps:get(release_kind, Result)),
        Tag = maps:get(tag, Result),
        {ok, Head0} = git_command(Repo, ["rev-parse", "HEAD"]),
        {ok, Tagged0} = git_command(Repo, ["rev-list", "-n", "1", binary_to_list(Tag)]),
        ?assertEqual(trim_bin(Head0), trim_bin(Tagged0)),
        {ok, Object} = git_command(Repo, ["cat-file", "-p", binary_to_list(Tag)]),
        ?assert(binary:match(Object, <<"ECAI learning provenance">>) =/= nomatch),
        ?assert(binary:match(Object, <<"ECAI-Learning-Reference: unavailable">>) =/= nomatch)
    end).

tag_release_finalizes_latest_rc_test() ->
    with_repo(fun(Repo) ->
        ok = git(Repo, ["tag", "v2.0.0-rc.1"]),
        {ok, Result} = ecai_release_candidate:tag_release(#{
            repo_root => Repo,
            require_learning_reference => false
        }),
        ?assertEqual(<<"v2.0.0">>, maps:get(tag, Result)),
        ?assertEqual(stable, maps:get(release_kind, Result)),
        {ok, Object} = git_command(Repo, ["cat-file", "-p", "v2.0.0"]),
        ?assert(binary:match(Object, <<"ECAI-Release-Kind: release">>) =/= nomatch)
    end).

non_head_tagging_is_rejected_to_protect_learning_binding_test() ->
    with_repo(fun(Repo) ->
        {ok, Old0} = git_command(Repo, ["rev-parse", "HEAD"]),
        Old = trim_bin(Old0),
        ok = commit(Repo, "new head"),
        ?assertMatch(
            {error, {learning_commit_mismatch, _}},
            ecai_release_candidate:tag_release_candidate(#{
                repo_root => Repo,
                commit => Old,
                require_learning_reference => false
            })
        )
    end).

explicit_release_version_test() ->
    with_repo(fun(Repo) ->
        {ok, Proposal} = ecai_release_candidate:propose_release(#{
            repo_root => Repo,
            version => <<"3.2.1">>
        }),
        ?assertEqual(<<"v3.2.1">>, maps:get(tag, Proposal)),
        ?assertEqual(explicit, maps:get(proposal_source, Proposal))
    end).

large_tag_annotation_uses_message_file_test() ->
    with_repo(fun(Repo) ->
        {ok, Head0} = git_command(Repo, ["rev-parse", "HEAD"]),
        Head = trim_bin(Head0),
        Annotation = binary:copy(<<"large-release-provenance\n">>, 10000),
        ok = ecai_release_candidate:create_annotated_tag(
            Repo,
            <<"v9.9.9-rc.1">>,
            Head,
            Annotation,
            #{}
        ),
        {ok, Object} = git_command(Repo, ["cat-file", "-p", "v9.9.9-rc.1"]),
        ?assert(binary:match(Object, <<"large-release-provenance">>) =/= nomatch)
    end).

learning_status_readiness_test() ->
    Ready = #{
        phase => idle,
        ready => true,
        inflight_count => 0,
        queued => 0,
        refresh_requested => false
    },
    ?assert(ecai_release_candidate:learning_status_ready(Ready)),
    ?assertNot(ecai_release_candidate:learning_status_ready(Ready#{phase => queued})),
    ?assertNot(ecai_release_candidate:learning_status_ready(Ready#{ready => false})),
    ?assertNot(ecai_release_candidate:learning_status_ready(Ready#{inflight_count => 1})),
    ?assertNot(ecai_release_candidate:learning_status_ready(Ready#{refresh_requested => true})).

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
    ok = git(Base, [
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "base"
    ]),
    try
        Fun(Base)
    after
        _ = file:del_dir_r(Base)
    end.

commit(Repo, Message) ->
    File = filename:join(Repo, "history.txt"),
    Existing =
        case file:read_file(File) of
            {ok, Bin} -> Bin;
            _ -> <<>>
        end,
    ok = file:write_file(
        File, <<Existing/binary, (unicode:characters_to_binary(Message))/binary, "\n">>
    ),
    ok = git(Repo, ["add", "."]),
    git(Repo, [
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", Message
    ]).

git(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, _Output} -> ok;
        {error, Reason} -> erlang:error({git_failed, Args, Reason})
    end.

git_command(Cwd, Args) ->
    case os:find_executable("git") of
        false ->
            {error, executable_not_found};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                binary, exit_status, stderr_to_stdout, {args, ["-C", Cwd | Args]}
            ]),
            collect_git(Port, <<>>)
    end.

trim_bin(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, Acc}}
    after 30000 ->
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, timeout}
    end.
