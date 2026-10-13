-module(ecai_patch_worker_quality_tests).

-include_lib("eunit/include/eunit.hrl").

single_binary_patch_is_preserved_test() ->
    Patch = git_patch(),
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch(Patch)
    ).

single_element_patch_array_is_recovered_test() ->
    Patch = git_patch(),
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch([Patch])
    ).

line_array_patch_is_recovered_test() ->
    Lines = [
        <<"diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl">>,
        <<"--- a/apps/ecai/src/a.erl">>,
        <<"+++ b/apps/ecai/src/a.erl">>,
        <<"@@ -1 +1 @@">>,
        <<"-old">>,
        <<"+new">>
    ],
    {ok, Patch} =
        ecai_patch_worker:normalize_proposal_patch(Lines),
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)),
    ?assertMatch(<<"diff --git ", _/binary>>, Patch).

single_file_unified_diff_gets_git_header_test() ->
    Raw = <<
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    {ok, Patch} =
        ecai_patch_worker:normalize_proposal_patch(Raw),
    ?assertMatch(
        <<
            "diff --git a/apps/ecai/src/a.erl "
            "b/apps/ecai/src/a.erl\n",
            _/binary
        >>,
        Patch
    ),
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)).

arbitrary_patch_object_is_still_rejected_test() ->
    ?assertMatch(
        {error, {invalid_patch_type, map}},
        ecai_patch_worker:normalize_proposal_patch(
            #{<<"op">> => <<"replace">>}
        )
    ).

compact_verification_diagnostic_keeps_first_failure_test() ->
    Verification = #{
        status => failed,
        base_commit => <<"abc">>,
        steps => [
            #{
                step => worktree_add,
                result => #{ok => true, exit_status => 0}
            },
            #{
                step => patch_apply_check,
                result => #{
                    ok => false,
                    exit_status => 1,
                    output => <<"error: patch failed">>
                }
            },
            #{
                step => compile,
                result => #{
                    ok => false,
                    exit_status => 1,
                    output => <<"should not be selected">>
                }
            }
        ]
    },
    Compact =
        ecai_patch_worker:compact_verification_diagnostic(
            Verification
        ),
    ?assertEqual(failed, maps:get(status, Compact)),
    Failed = maps:get(failing_step, Compact),
    ?assertEqual(patch_apply_check, maps:get(step, Failed)),
    Result = maps:get(result, Failed),
    ?assertEqual(1, maps:get(exit_status, Result)),
    ?assertEqual(
        <<"error: patch failed">>,
        maps:get(output, Result)
    ).

git_patch() ->
    <<
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\n"
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>.
