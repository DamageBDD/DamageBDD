-module(ecai_patch_worker_response_shape_tests).

-include_lib("eunit/include/eunit.hrl").

output_wrapped_diff_is_recovered_test() ->
    Patch = git_patch(),
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch(
            #{<<"output">> => Patch}
        )
    ).

changes_wrapped_diff_is_recovered_test() ->
    Patch = git_patch(),
    Proposal = #{
        <<"response">> => #{
            <<"changes">> => [
                #{<<"diff">> => Patch}
            ]
        }
    },
    ?assertEqual(
        {ok, Patch},
        ecai_patch_worker:normalize_proposal_patch(Proposal)
    ).

json_edit_map_remains_rejected_test() ->
    Proposal = #{
        <<"changes">> => [
            #{
                <<"path">> => <<"apps/ecai/src/a.erl">>,
                <<"replacement">> => <<"not a diff">>
            }
        ]
    },
    ?assertMatch(
        {error, {invalid_patch_type, map}},
        ecai_patch_worker:normalize_proposal_patch(Proposal)
    ).

proposal_shape_does_not_store_response_bodies_test() ->
    Proposal = #{
        <<"response">> => #{
            <<"changes">> => [
                #{
                    <<"content">> =>
                        <<"sensitive source body, not a diff">>
                }
            ]
        }
    },
    Shape = ecai_patch_worker:proposal_shape(Proposal),
    ?assertEqual(map, maps:get(response_type, Shape)),
    ?assertEqual(false, maps:get(patch_candidate_found, Shape)),
    ?assertEqual(false, maps:get(diff_binary_found, Shape)),
    ShapeBin = term_to_binary(Shape),
    ?assertEqual(
        nomatch,
        binary:match(ShapeBin, <<"sensitive source body">>)
    ).

proposal_shape_detects_nested_diff_test() ->
    Patch = git_patch(),
    Shape =
        ecai_patch_worker:proposal_shape(
            #{<<"files">> => [#{<<"output">> => Patch}]}
        ),
    ?assertEqual(true, maps:get(patch_candidate_found, Shape)),
    ?assertEqual(true, maps:get(diff_binary_found, Shape)).

git_patch() ->
    <<
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\n"
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>.
