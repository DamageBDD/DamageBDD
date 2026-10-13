-module(ecai_patch_manager_source_identity_tests).

-include_lib("eunit/include/eunit.hrl").

matching_report_and_analysis_source_test() ->
    Hash = <<"abc123">>,
    ?assertEqual(
        true,
        ecai_patch_manager:analysis_matches_report_source(
            Hash,
            #{source_sha256 => Hash}
        )
    ).

mismatched_report_and_analysis_source_test() ->
    ?assertEqual(
        false,
        ecai_patch_manager:analysis_matches_report_source(
            <<"report">>,
            #{source_sha256 => <<"analysis">>}
        )
    ).

legacy_report_without_hash_remains_compatible_test() ->
    ?assertEqual(
        true,
        ecai_patch_manager:analysis_matches_report_source(
            undefined,
            #{source_sha256 => <<"analysis">>}
        )
    ).

missing_analysis_hash_does_not_match_identified_report_test() ->
    ?assertEqual(
        false,
        ecai_patch_manager:analysis_matches_report_source(
            <<"report">>,
            #{}
        )
    ).
