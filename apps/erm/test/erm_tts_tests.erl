-module(erm_tts_tests).
-include_lib("eunit/include/eunit.hrl").
chunks_test() ->
    ?assertEqual({ok, [<<"hello world">>]}, erm_tts:chunks(" hello\nworld ")),
    ?assertMatch({error, _}, erm_tts:chunks(<<255>>)),
    ?assertMatch({error, _}, erm_tts:chunks([0])),
    ?assertMatch({error, _}, erm_tts:chunks(lists:duplicate(1201, $a))),
    {ok, Parts} = erm_tts:chunks(lists:flatten(lists:duplicate(100, "word "))),
    ?assert(length(Parts) > 1),
    ?assert(lists:all(fun(P) -> byte_size(P) =< 240 end, Parts)).
response_test() ->
    ?assertEqual("Paused.", erm_tts:response(ok, "pause")),
    ?assertEqual(undefined, erm_tts:response({error, busy}, "play")),
    ?assertEqual(
        <<"hello">>, erm_tts:response({ok, #{action => answer, text => <<"hello">>}}, "ask")
    ).
lifecycle_test_() -> {timeout, 20, fun lifecycle/0}.
lifecycle() ->
    Root = os:getenv("ERM_TTS_TEST_DIR"),
    application:set_env(erm, whisper_trigger, [{length_ms, 10}, {keep_ms, 10}, {step_ms, 10}]),
    Opts = [
        {binary, Root ++ "/port"},
        {model, Root ++ "/model"},
        {config, Root ++ "/config"},
        {espeak_data, Root},
        {player, Root ++ "/player"},
        {echo_guard_ms, 30},
        {speech_timeout_ms, 1000},
        {startup_timeout_ms, 1000}
    ],
    {ok, Pid} = erm_tts:start_link(Opts),
    try
        wait(fun() -> maps:get(ready, erm_tts:status()) end, 200),
        ?assertEqual(ok, erm_tts:say("hello")),
        ?assert(erm_tts:suppressed()),
        ?assertEqual({error, busy}, erm_tts:say("again")),
        wait(fun() -> not maps:get(speaking, erm_tts:status()) end, 200),
        wait(fun() -> not erm_tts:suppressed() end, 200),
        %% EOF cancellation during inference must not wait for inference.
        ?assertEqual(ok, erm_tts:say("slow")),
        ?assertEqual(ok, erm_tts:cancel()),
        ?assertEqual(false, maps:get(ready, erm_tts:status())),
        Pid ! connect,
        wait(fun() -> maps:get(ready, erm_tts:status()) end, 200),
        ?assertEqual(ok, erm_tts:say("fail")),
        wait(fun() -> maps:get(last_error, erm_tts:status()) =/= undefined end, 200),
        Pid ! connect,
        wait(fun() -> maps:get(ready, erm_tts:status()) end, 200),
        %% Active player is killed with the worker on cancellation.
        file:delete(Root ++ "/player.pid"),
        ?assertEqual(ok, erm_tts:say("hello")),
        wait(fun() -> filelib:is_regular(Root ++ "/player.pid") end, 200),
        {ok, PlayerPid} = file:read_file(Root ++ "/player.pid"),
        ?assertEqual(ok, erm_tts:cancel()),
        wait(fun() -> not alive(binary_to_list(PlayerPid)) end, 200),
        Pid ! connect,
        wait(fun() -> maps:get(ready, erm_tts:status()) end, 200),
        ?assertEqual(ok, erm_tts:say("slow")),
        wait(fun() -> maps:get(last_error, erm_tts:status()) =:= timeout end, 200)
    after
        gen_server:stop(Pid),
        application:unset_env(erm, whisper_trigger),
        persistent_term:erase({erm_tts, suppress_until})
    end.
alive(Pid) ->
    case file:read_file("/proc/" ++ Pid ++ "/stat") of
        {ok, B} ->
            case binary:match(B, <<") Z ">>) of
                nomatch -> true;
                _ -> false
            end;
        _ ->
            false
    end.
wait(F, 0) ->
    ?assertEqual(true, F());
wait(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait(F, N - 1)
    end.
