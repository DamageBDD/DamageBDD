-module(ecai_patch_verifier_integrity_tests).

-include_lib("eunit/include/eunit.hrl").

stable_candidate_state_is_accepted_test() ->
    with_repo(fun(Repo, PatchFile) ->
        ok = file:write_file(
            filename:join(
                Repo, "apps/ecai/src/sample.erl"
            ),
            <<"changed\n">>
        ),
        {ok, Before} = snapshot(Repo, PatchFile),
        {ok, After} = snapshot(Repo, PatchFile),
        ?assertEqual(
            [],
            maps:get(unexpected_paths, Before)
        ),
        ?assertEqual(
            ok,
            ecai_patch_verifier:compare_integrity_snapshots(
                Before, After
            )
        )
    end).

extra_tracked_mutation_is_rejected_test() ->
    with_repo(fun(Repo, PatchFile) ->
        Sample = filename:join(
            Repo, "apps/ecai/src/sample.erl"
        ),
        ok = file:write_file(Sample, <<"changed\n">>),
        {ok, Before} = snapshot(Repo, PatchFile),
        ok = file:write_file(
            filename:join(Repo, "rebar.lock"),
            <<"changed lock\n">>
        ),
        {ok, After} = snapshot(Repo, PatchFile),
        ?assertEqual(
            [<<"rebar.lock">>],
            maps:get(unexpected_paths, After)
        ),
        ?assertMatch(
            {error, #{
                reason :=
                    repository_mutated_during_validation,
                unexpected_paths := [<<"rebar.lock">>]
            }},
            ecai_patch_verifier:compare_integrity_snapshots(
                Before, After
            )
        )
    end).

candidate_file_mutation_is_rejected_test() ->
    with_repo(fun(Repo, PatchFile) ->
        Sample = filename:join(
            Repo, "apps/ecai/src/sample.erl"
        ),
        ok = file:write_file(Sample, <<"changed\n">>),
        {ok, Before} = snapshot(Repo, PatchFile),
        ok = file:write_file(
            Sample, <<"changed again\n">>
        ),
        {ok, After} = snapshot(Repo, PatchFile),
        ?assertEqual(
            [],
            maps:get(unexpected_paths, After)
        ),
        ?assertMatch(
            {error, #{
                reason :=
                    repository_mutated_during_validation,
                modified_paths :=
                    [<<"apps/ecai/src/sample.erl">>]
            }},
            ecai_patch_verifier:compare_integrity_snapshots(
                Before, After
            )
        )
    end).

extra_untracked_file_is_rejected_test() ->
    with_repo(fun(Repo, PatchFile) ->
        Sample = filename:join(
            Repo, "apps/ecai/src/sample.erl"
        ),
        ok = file:write_file(Sample, <<"changed\n">>),
        {ok, Before} = snapshot(Repo, PatchFile),
        ok = file:write_file(
            filename:join(Repo, "rebar3.crashdump"),
            <<"crash\n">>
        ),
        {ok, After} = snapshot(Repo, PatchFile),
        ?assert(
            lists:member(
                <<"rebar3.crashdump">>,
                maps:get(unexpected_paths, After)
            )
        ),
        ?assertMatch(
            {error, #{
                reason :=
                    repository_mutated_during_validation
            }},
            ecai_patch_verifier:compare_integrity_snapshots(
                Before, After
            )
        )
    end).

snapshot(Repo, PatchFile) ->
    ecai_patch_verifier:capture_integrity_snapshot(
        Repo, [PatchFile], 30000
    ).

with_repo(Fun) ->
    Base = filename:join(
        "/tmp",
        "ecai_verifier_integrity_" ++
            integer_to_list(
                erlang:unique_integer(
                    [positive, monotonic]
                )
            )
    ),
    Sample = filename:join(
        Base, "apps/ecai/src/sample.erl"
    ),
    PatchFile = filename:join(
        Base, "candidate.patch"
    ),
    ok = filelib:ensure_dir(Sample),
    ok = file:write_file(Sample, <<"base\n">>),
    ok = file:write_file(
        filename:join(Base, "rebar.lock"),
        <<"base lock\n">>
    ),
    ok = file:write_file(
        PatchFile,
        candidate_patch()
    ),
    ok = git(Base, ["init", "-q"]),
    ok = git(
        Base,
        [
            "config",
            "user.email",
            "ecai-test@example.invalid"
        ]
    ),
    ok = git(
        Base,
        ["config", "user.name", "ECAI Test"]
    ),
    ok = git(Base, ["add", "."]),
    ok = git(
        Base,
        [
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "commit",
            "-qm",
            "base"
        ]
    ),
    try
        Fun(Base, PatchFile)
    after
        _ = file:del_dir_r(Base)
    end.

candidate_patch() ->
    <<
        "diff --git a/apps/ecai/src/sample.erl "
        "b/apps/ecai/src/sample.erl\n"
        "--- a/apps/ecai/src/sample.erl\n"
        "+++ b/apps/ecai/src/sample.erl\n"
        "@@ -1 +1 @@\n"
        "-base\n"
        "+changed\n"
    >>.

git(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, _Output} ->
            ok;
        {error, Reason} ->
            erlang:error(
                {git_failed, Args, Reason}
            )
    end.

git_command(Cwd, Args) ->
    case os:find_executable("git") of
        false ->
            {error, executable_not_found};
        Exe ->
            Port = open_port(
                {spawn_executable, Exe},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", Cwd | Args]}
                ]
            ),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_git(
                Port, <<Acc/binary, Data/binary>>
            );
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {
                exit_status, Status, Acc
            }}
    after 30000 ->
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, timeout}
    end.
