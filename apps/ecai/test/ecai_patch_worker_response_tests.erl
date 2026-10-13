-module(ecai_patch_worker_response_tests).

-include_lib("eunit/include/eunit.hrl").

wrapped_diff_map_is_recovered_test() ->
    Patch = git_patch(),
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch(
            #{<<"diff">> => Patch}
        )
    ).

nested_content_diff_is_recovered_test() ->
    Patch = git_patch(),
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch(
            #{<<"result">> => #{<<"content">> => Patch}}
        )
    ).

structured_patch_array_without_diff_is_rejected_test() ->
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

wrapped_unified_diff_without_git_header_is_recovered_test() ->
    Raw = <<
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    {ok, Patch} = ecai_patch_worker:normalize_proposal_patch(
        #{<<"content">> => Raw}
    ),
    ?assertMatch(<<"diff --git ", _/binary>>, Patch),
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)).

failure_classes_are_stable_test() ->
    ?assertEqual(
        invalid_patch,
        ecai_patch_worker:failure_class({invalid_patch, empty_patch})
    ),
    ?assertEqual(
        verification_failed,
        ecai_patch_worker:failure_class(verification_failed)
    ),
    ?assertEqual(
        verification_failed,
        ecai_patch_worker:failure_class(
            {verification_error, compile_failed}
        )
    ),
    ?assertEqual(
        retry_exhausted,
        ecai_patch_worker:failure_class(
            {retry_exhausted, inference_timeout}
        )
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
