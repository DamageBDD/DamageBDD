-module(damage_ecai_log_bridge_tests).

-include_lib("eunit/include/eunit.hrl").

level_ordering_test() ->
    ?assert(damage_ecai_log_bridge:level_at_least(error, warning)),
    ?assert(damage_ecai_log_bridge:level_at_least(emergency, error)),
    ?assertNot(damage_ecai_log_bridge:level_at_least(info, warning)),
    ?assert(damage_ecai_log_bridge:level_at_least(debug, all)),
    ?assertNot(damage_ecai_log_bridge:level_at_least(emergency, none)).

event_target_from_mfa_test() ->
    Meta = #{mfa => {damage_worker, handle_info, 2}},
    ?assertEqual(
        {ok, damage, damage_worker},
        damage_ecai_log_bridge:event_target(Meta, [damage, ecai, erm])
    ).

event_target_from_application_test() ->
    Meta = #{application => ecai, module => ecai_patch_worker},
    ?assertEqual(
        {ok, ecai, ecai_patch_worker},
        damage_ecai_log_bridge:event_target(Meta, [damage, ecai, erm])
    ).

unrelated_event_is_ignored_test() ->
    Meta = #{application => kernel, mfa => {supervisor, report_error, 5}},
    ?assertEqual(
        ignore,
        damage_ecai_log_bridge:event_target(Meta, [damage, ecai, erm])
    ).

redacts_credentials_test() ->
    Text = damage_ecai_log_bridge:redact(
        <<"password=hunter2 Authorization: Bearer abc.def nsec1qqqqqqqqqq api_key=xyz">>
    ),
    ?assertEqual(nomatch, binary:match(Text, <<"hunter2">>)),
    ?assertEqual(nomatch, binary:match(Text, <<"abc.def">>)),
    ?assertEqual(nomatch, binary:match(Text, <<"nsec1qqqq">>)),
    ?assertEqual(nomatch, binary:match(Text, <<"xyz">>)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"redacted">>)).

normalizes_and_caps_error_event_test() ->
    Event = #{
        level => error,
        msg => {string, <<"password=secret-value module failed">>},
        meta => #{
            application => damage,
            mfa => {damage_worker, handle_call, 3},
            time => 1700000000000000
        }
    },
    {ok, Normalized} = damage_ecai_log_bridge:normalize_event_for_test(
        Event,
        #{capture_level => warning, max_text_bytes => 32}
    ),
    ?assertEqual(damage, maps:get(application, Normalized)),
    ?assertEqual(damage_worker, maps:get(module, Normalized)),
    ?assertEqual(error, maps:get(level, Normalized)),
    Message = maps:get(message, Normalized),
    ?assert(byte_size(Message) =< 32),
    ?assertEqual(nomatch, binary:match(Message, <<"secret-value">>)).

redacts_and_bounds_free_text_metadata_test() ->
    Event = #{
        level => error,
        msg => {string, <<"failed">>},
        meta => #{
            application => damage,
            mfa => {damage_worker, handle_call, 3},
            request_id => <<"api_key=metadata-secret">>,
            trace_id => binary:copy(<<"t">>, 700)
        }
    },
    {ok, Normalized} = damage_ecai_log_bridge:normalize_event_for_test(
        Event,
        #{capture_level => warning}
    ),
    Metadata = maps:get(metadata, Normalized),
    RequestId = maps:get(request_id, Metadata),
    TraceId = maps:get(trace_id, Metadata),
    ?assertEqual(nomatch, binary:match(RequestId, <<"metadata-secret">>)),
    ?assertNotEqual(nomatch, binary:match(RequestId, <<"redacted">>)),
    ?assert(byte_size(TraceId) =< 512),
    ?assertEqual({damage_worker, handle_call, 3}, maps:get(mfa, Metadata)).

malformed_metadata_is_ignored_without_crashing_test() ->
    Event = #{
        level => error,
        msg => {string, <<"boom">>},
        meta => not_a_map
    },
    ?assertEqual(
        ignore,
        damage_ecai_log_bridge:normalize_event_for_test(
            Event,
            #{capture_level => warning}
        )
    ).

internal_modules_are_not_learning_targets_test() ->
    ?assertNot(damage_ecai_log_bridge:learning_eligible_module(ecai_health_monitor)),
    ?assertNot(damage_ecai_log_bridge:learning_eligible_module(ecai_log_learning)),
    ?assertNot(damage_ecai_log_bridge:learning_eligible_module(damage_ecai_log_bridge)),
    ?assert(damage_ecai_log_bridge:learning_eligible_module(damage_worker)).

logger_handler_forwards_without_formatting_test() ->
    Event = #{
        level => error,
        msg => {string, <<"boom">>},
        meta => #{application => damage}
    },
    ok = damage_ecai_logger_handler:log(
        Event,
        #{config => #{server => self(), max_queue => 10}}
    ),
    receive
        {damage_ecai_logger_event, Event} -> ok
    after 1000 ->
        ?assert(false)
    end.

logger_handler_drops_internal_events_test() ->
    Event = #{
        level => error,
        msg => {string, <<"health report">>},
        meta => #{application => ecai, damage_ecai_internal => true}
    },
    ok = damage_ecai_logger_handler:log(
        Event,
        #{config => #{server => self(), max_queue => 10}}
    ),
    receive
        {damage_ecai_logger_event, _} -> ?assert(false)
    after 20 ->
        ok
    end.
