-module(erm_dj_http_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

request(Scenario, Extra) ->
    flush(),
    application:set_env(erm,dj_http_test_report,self()),
    application:set_env(erm,dj_http_test_scenario,Scenario),
    erm_dj_http:get(<<"https://ektoplazm.com/source">>,maps:merge(#{max_bytes=>6,timeout=>1000},Extra)).
flush() -> receive _ -> flush() after 0 -> ok end.

normal_and_tls_test() ->
    ?assertEqual({ok,<<"abcdef">>},request(normal,#{})),
    receive {opened,"ektoplazm.com",443,#{transport:=tls,tls_opts:=TLS,protocols:=[http],retry:=0}} ->
        ?assertEqual(verify_peer,proplists:get_value(verify,TLS)),
        ?assertEqual("ektoplazm.com",proplists:get_value(server_name_indication,TLS)),
        ?assert(is_list(proplists:get_value(cacerts,TLS)))
    after 1000 -> ?assert(false) end.

actual_body_limit_test() ->
    ?assertEqual({error,size_limit_exceeded},request(body_limit,#{})),
    receive {chunk,4} -> ok after 1000 -> ?assert(false) end,
    receive {chunk,4} -> ok after 1000 -> ?assert(false) end,
    receive {chunk,_} -> ?assert(false) after 30 -> ok end.

length_and_encoding_test() ->
    ?assertEqual({error,size_limit_exceeded},request(declared_limit,#{})),
    ?assertEqual({error,unsupported_content_encoding},request(compressed,#{})),
    ?assertEqual({error,invalid_content_length},request(invalid_length,#{})).

status_test() -> ?assertEqual({error,{http_status,403}},request(status,#{})).
external_redirect_revalidated_test() ->
    ?assertEqual({error,untrusted_url},request(external_redirect,#{})).
redirect_budget_test() ->
    ?assertEqual({error,too_many_redirects},request(redirect_loop,#{})).
absolute_timeout_test() ->
    Start=erlang:monotonic_time(millisecond),
    ?assertEqual({error,timeout},request(stall,#{timeout=>100})),
    ?assert(erlang:monotonic_time(millisecond)-Start < 1000).
transport_failure_test() ->
    ?assertEqual({error,{transport,closed}},request(transport_error,#{})).

maximum_archive_budget_test() ->
    ?assertEqual({ok,<<"abcdef">>}, request(normal,#{max_bytes=>268435456})).

caller_shutdown_cancels_worker_test() ->
    flush(),
    application:set_env(erm,dj_http_test_report,self()),
    application:set_env(erm,dj_http_test_scenario,stall),
    {Caller, CallerMon}=spawn_monitor(fun()->
        erm_dj_http:get(<<"https://ektoplazm.com/source">>,#{timeout=>10000})
    end),
    Worker=receive {http_worker,W}->W after 1000->error(no_http_worker) end,
    WorkerMon=monitor(process,Worker),
    exit(Caller,kill),
    receive {'DOWN',CallerMon,process,Caller,killed}->ok after 1000->?assert(false) end,
    receive {'DOWN',WorkerMon,process,Worker,killed}->ok after 1000->?assert(false) end.

trapping_caller_mailbox_test() ->
    Old=process_flag(trap_exit,true),
    try
        ?assertEqual({ok,<<"abcdef">>},request(normal,#{})),
        receive {'EXIT',_,_}->?assert(false) after 30->ok end
    after process_flag(trap_exit,Old) end.
