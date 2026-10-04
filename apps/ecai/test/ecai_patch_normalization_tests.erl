-module(ecai_patch_normalization_tests).

-include_lib("eunit/include/eunit.hrl").

fenced_crlf_patch_is_canonicalized_test() ->
    Raw = <<
        "```diff\r\n"
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\r\n"
        "--- a/apps/ecai/src/a.erl\r\n"
        "+++ b/apps/ecai/src/a.erl\r\n"
        "@@ -1 +1 @@\r\n"
        "-old\r\n"
        "+new\r\n"
        "```\r\n"
    >>,
    Normalized = ecai_patch_verifier:normalize_patch(Raw),
    ?assertMatch(<<"diff --git ", _/binary>>, Normalized),
    ?assertEqual(nomatch, binary:match(Normalized, <<"```">>)),
    ?assertEqual(nomatch, binary:match(Normalized, <<"\r">>)),
    ?assertEqual($\n, binary:last(Normalized)),
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Normalized)).

prose_before_diff_is_removed_test() ->
    Raw = <<
        "Here is the requested patch:\n"
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\n"
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    Normalized = ecai_patch_verifier:normalize_patch(Raw),
    ?assertMatch(<<"diff --git ", _/binary>>, Normalized),
    ?assertEqual(nomatch, binary:match(Normalized, <<"Here is">>)).

missing_git_diff_header_is_rejected_test() ->
    Patch = <<
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertEqual(
        {error, missing_git_diff_header},
        ecai_patch_verifier:validate_patch(Patch)
    ).
