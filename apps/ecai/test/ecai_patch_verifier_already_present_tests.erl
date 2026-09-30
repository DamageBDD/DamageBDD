-module(ecai_patch_verifier_already_present_tests).

-include_lib("eunit/include/eunit.hrl").

already_present_disposition_test() ->
    Steps = [
        #{step => patch_apply_check},
        #{step => patch_reverse_check},
        #{step => patch_already_present}
    ],
    ?assertEqual(
        already_present,
        ecai_patch_verifier:patchset_disposition(Steps)
    ).

applied_disposition_test() ->
    Steps = [
        #{step => patch_apply_check},
        #{step => patch_apply}
    ],
    ?assertEqual(
        applied,
        ecai_patch_verifier:patchset_disposition(Steps)
    ).

mixed_disposition_test() ->
    Steps = [
        #{step => patch_already_present},
        #{step => patch_apply}
    ],
    ?assertEqual(
        mixed,
        ecai_patch_verifier:patchset_disposition(Steps)
    ).

only_already_present_is_candidate_neutral_test() ->
    ?assert(
        ecai_patch_verifier:candidate_neutral_validation_failure(
            already_present
        )
    ),
    ?assertNot(
        ecai_patch_verifier:candidate_neutral_validation_failure(applied)
    ),
    ?assertNot(
        ecai_patch_verifier:candidate_neutral_validation_failure(mixed)
    ).

same_validation_failure_normalizes_worktree_path_test() ->
    Candidate = #{
        ok => false,
        exit_status => 1,
        executable => <<"rebar3">>,
        args => [<<"eunit">>],
        output => <<
            "apps/damage/test/foo_tests.erl:42: foo_tests:bar_test...*failed*\n",
            "  in function foo_tests:bar_test/0 (/tmp/repair-123/apps/damage/test/foo_tests.erl, line 42)\n",
            "Failed: 1.  Skipped: 0.  Passed: 10.\n"
        >>
    },
    Baseline = Candidate#{
        output => <<
            "apps/damage/test/foo_tests.erl:42: foo_tests:bar_test...*failed*\n",
            "  in function foo_tests:bar_test/0 (/tmp/baseline-456/apps/damage/test/foo_tests.erl, line 42)\n",
            "Failed: 1.  Skipped: 0.  Passed: 10.\n"
        >>
    },
    ?assert(
        ecai_patch_verifier:same_validation_failure(
            eunit,
            Candidate,
            "/tmp/repair-123",
            Baseline,
            "/tmp/baseline-456"
        )
    ).

different_validation_failure_is_not_neutral_test() ->
    Candidate = #{
        ok => false,
        exit_status => 1,
        executable => <<"rebar3">>,
        args => [<<"eunit">>],
        output => <<
            "apps/damage/test/foo_tests.erl:42: foo_tests:bar_test...*failed*\n",
            "Failed: 1.  Skipped: 0.  Passed: 10.\n"
        >>
    },
    Baseline = Candidate#{
        output => <<
            "apps/damage/test/other_tests.erl:17: other_tests:baz_test...*failed*\n",
            "Failed: 1.  Skipped: 0.  Passed: 10.\n"
        >>
    },
    ?assertNot(
        ecai_patch_verifier:same_validation_failure(
            eunit,
            Candidate,
            "/tmp/repair",
            Baseline,
            "/tmp/baseline"
        )
    ).

validation_failure_signature_tracks_paths_and_summary_test() ->
    Result = #{
        ok => false,
        exit_status => 1,
        executable => <<"rebar3">>,
        args => [<<"eunit">>],
        output => <<
            "apps/damage/src/abduco_worker.erl:12: error: example\n",
            "Failed: 2.  Skipped: 0.  Passed: 8.\n"
        >>
    },
    Signature = ecai_patch_verifier:validation_failure_signature(
        eunit, Result, "/tmp/repair"
    ),
    ?assertEqual(eunit, maps:get(phase, Signature)),
    ?assertEqual(1, maps:get(exit_status, Signature)),
    ?assertEqual(
        ["apps/damage/src/abduco_worker.erl"],
        maps:get(failure_paths, Signature)
    ),
    ?assert(length(maps:get(failure_markers, Signature)) >= 2).
