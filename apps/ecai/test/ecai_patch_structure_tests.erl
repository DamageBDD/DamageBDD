-module(ecai_patch_structure_tests).

-include_lib("eunit/include/eunit.hrl").

header_only_diff_is_rejected_test() ->
    Patch = <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "--- a/apps/damage/src/a.erl\n"
        "+++ b/apps/damage/src/a.erl\n"
    >>,
    ?assertEqual(
        {error, {missing_patch_hunk, 1}},
        ecai_patch_verifier:validate_patch(Patch)
    ).

missing_file_headers_are_rejected_test() ->
    Patch = <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertEqual(
        {error, {missing_patch_file_headers, 1}},
        ecai_patch_verifier:validate_patch(Patch)
    ).

invalid_hunk_header_is_rejected_test() ->
    Patch = <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "--- a/apps/damage/src/a.erl\n"
        "+++ b/apps/damage/src/a.erl\n"
        "@@ -x +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertEqual(
        {error, {invalid_patch_hunk_header, 1}},
        ecai_patch_verifier:validate_patch(Patch)
    ).

hunk_without_changes_is_rejected_test() ->
    Patch = <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "--- a/apps/damage/src/a.erl\n"
        "+++ b/apps/damage/src/a.erl\n"
        "@@ -1 +1 @@\n"
        " unchanged\n"
    >>,
    ?assertEqual(
        {error, {patch_hunk_without_changes, 1}},
        ecai_patch_verifier:validate_patch(Patch)
    ).

non_hex_index_object_id_is_rejected_test() ->
    Patch = <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "index a1b2c3d..e4f5g6h 100644\n"
        "--- a/apps/damage/src/a.erl\n"
        "+++ b/apps/damage/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertEqual(
        {error, {invalid_patch_index, 1}},
        ecai_patch_verifier:validate_patch(Patch)
    ).

valid_text_diff_is_accepted_test() ->
    ?assertEqual(
        ok,
        ecai_patch_verifier:validate_patch(valid_patch())
    ).

valid_new_file_diff_is_accepted_test() ->
    Patch = <<
        "diff --git a/apps/ecai/test/a_tests.erl b/apps/ecai/test/a_tests.erl\n"
        "new file mode 100644\n"
        "index 0000000..abcdef1\n"
        "--- /dev/null\n"
        "+++ b/apps/ecai/test/a_tests.erl\n"
        "@@ -0,0 +1 @@\n"
        "+-module(a_tests).\n"
    >>,
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)).

format_correction_gets_one_bounded_extra_attempt_test() ->
    Reason = {missing_patch_hunk, 1},
    ?assert(
        ecai_patch_worker:should_retry_invalid_patch(
            3, 3, Reason, #{}
        )
    ),
    ?assertNot(
        ecai_patch_worker:should_retry_invalid_patch(
            4, 3, Reason, #{}
        )
    ).

non_structural_invalid_patch_does_not_get_extra_attempt_test() ->
    ?assertNot(
        ecai_patch_worker:should_retry_invalid_patch(
            3, 3, {invalid_patch_type, map}, #{}
        )
    ).

format_extra_attempt_can_be_disabled_test() ->
    ?assertNot(
        ecai_patch_worker:should_retry_invalid_patch(
            3,
            3,
            {missing_patch_hunk, 1},
            #{format_extra_attempts => 0}
        )
    ).

valid_patch() ->
    <<
        "diff --git a/apps/damage/src/a.erl b/apps/damage/src/a.erl\n"
        "index a1b2c3d..e4f5a6b 100644\n"
        "--- a/apps/damage/src/a.erl\n"
        "+++ b/apps/damage/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>.
