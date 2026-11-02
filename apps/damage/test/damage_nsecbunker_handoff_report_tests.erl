-module(damage_nsecbunker_handoff_report_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise the real controller/report path. JSX treats three-element tuples
%% as timestamps, so a URI error tuple used to turn all health/setup fields
%% into an uninformative badarith report.
health_report_retains_checks_and_redacted_relays_test() ->
    Dir = filename:join("/tmp", "bunker-report-test-" ++
        integer_to_list(erlang:unique_integer([positive]))),
    Previous = application:get_env(damage, nsecbunker),
    Relays = [
        "wss://relay.example",
        <<"wss://user:DO_NOT_EXPOSE@relay.example:8443/private?token=HIDDEN#fragment">>,
        #{url => <<"wss://another.example/socket">>},
        <<"not-a-uri">>,
        <<"wss://relay.example:invalid">>
    ],
    application:set_env(damage, nsecbunker,
        #{enabled => false, state_dir => Dir, relays => Relays}),
    try
        {ok, Pid} = damage_nsecbunker_handoff:start_link(),
        try
            Status = wait_for_report(200),
            Health = maps:get(health, Status),
            ?assertMatch([_ | _], maps:get(checks, Health)),
            ?assertEqual(failed, maps:get(status, Health)),
            ?assertNotEqual(badarith, maps:get(reason, Health, undefined)),
            Setup = maps:get(setup, Health),
            ?assertEqual([
                <<"wss://relay.example">>,
                <<"wss://relay.example:8443">>,
                <<"wss://another.example">>,
                <<"invalid_relay">>,
                <<"invalid_relay">>
            ], maps:get(relays, Setup)),
            Bytes = damage_nsecbunker_handoff:canonical(Health),
            ?assertEqual(nomatch, binary:match(Bytes, <<"DO_NOT_EXPOSE">>)),
            ?assertEqual(nomatch, binary:match(Bytes, <<"HIDDEN">>)),
            Decoded = jsx:decode(Bytes, [return_maps]),
            ?assertMatch([_ | _], maps:get(<<"checks">>, Decoded)),
            ?assert(maps:is_key(<<"setup">>, Decoded))
        after
            gen_server:stop(Pid)
        end
    after
        case Previous of
            {ok, Value} -> application:set_env(damage, nsecbunker, Value);
            undefined -> application:unset_env(damage, nsecbunker)
        end,
        file:del_dir_r(Dir)
    end.

wait_for_report(0) -> error(controller_timeout);
wait_for_report(Attempts) ->
    Status = damage_nsecbunker_handoff:status(),
    case maps:get(busy, Status) of
        false -> Status;
        true -> receive after 10 -> wait_for_report(Attempts - 1) end
    end.
