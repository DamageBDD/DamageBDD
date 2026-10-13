-module(ecai_repair_feedback_tests).

-include_lib("eunit/include/eunit.hrl").

finding_from_incident_test() ->
    Incident = #{
        status => learned,
        fingerprint => <<"incident-123">>,
        application => damage,
        module => damage_worker,
        level => error,
        source_sha256 => <<"abc">>,
        learned_at => <<"2026-10-07T05:00:00Z">>,
        learning => #{
            summary => <<"worker crashes when state is missing">>,
            failure_mode => <<"badmatch">>,
            observed_evidence => [<<"badmatch at handle_call/3">>],
            likely_causes => [<<"missing state key">>],
            resolution_instructions => [<<"guard the missing-key path">>],
            verification => [<<"run focused EUnit">>],
            code_learning_notes => [<<"preserve existing success path">>],
            confidence => high
        }
    },
    {ok, damage, damage_worker, Finding, Meta} =
        ecai_repair_feedback:finding_from_incident(Incident),
    ?assertEqual(<<"high">>, maps:get(<<"severity">>, Finding)),
    ?assertEqual(<<"runtime_log_feedback">>, maps:get(<<"issue_key">>, Finding)),
    ?assert(byte_size(maps:get(<<"fingerprint">>, Finding)) =:= 64),
    ?assertEqual(runtime_log_learning, maps:get(source, Meta)),
    ?assertEqual(<<"abc">>, maps:get(source_sha256, Meta)).

missing_target_is_skipped_test() ->
    ?assertMatch(
        {skip, missing_target},
        ecai_repair_feedback:finding_from_incident(#{learning => #{}})
    ).
