-module(ecai_patch_proposal_tests).

-include_lib("eunit/include/eunit.hrl").

json_patch_array_is_rejected_test() ->
    JsonPatch = [
        #{
            <<"op">> => <<"replace">>,
            <<"path">> => <<"/knowledge/invariants/4">>,
            <<"value">> => <<"not a git diff">>
        }
    ],
    ?assertEqual(
        {error, {invalid_patch_type, list}},
        ecai_patch_worker:normalize_proposal_patch(JsonPatch)
    ).

json_patch_object_is_rejected_test() ->
    ?assertEqual(
        {error, {invalid_patch_type, map}},
        ecai_patch_worker:normalize_proposal_patch(
            #{<<"op">> => <<"replace">>}
        )
    ).

binary_git_diff_is_normalized_test() ->
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
    {ok, Patch} = ecai_patch_worker:normalize_proposal_patch(Raw),
    ?assertMatch(<<"diff --git ", _/binary>>, Patch),
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)).
