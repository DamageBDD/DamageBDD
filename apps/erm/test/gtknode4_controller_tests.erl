%%%-------------------------------------------------------------------
%%% Transport-contract tests which exercise the real controller path with an
%%% Erlang process standing in for the C-node endpoint.
%%%-------------------------------------------------------------------
-module(gtknode4_controller_tests).

-include_lib("eunit/include/eunit.hrl").

controller_transport_test_() ->
    [
        {setup, fun setup/0, fun cleanup/1, fun(Data) ->
            fun() -> transport_call_is_correlated(Data) end
        end},
        {setup, fun setup/0, fun cleanup/1, fun(Data) ->
            fun() -> unsupported_protocol_is_rejected(Data) end
        end}
    ].

setup() ->
    cleanup_controller(),
    Endpoint = spawn(fun endpoint_loop/0),
    {ok, Controller} = gtknode4:start_link(#{endpoint => Endpoint}),
    unlink(Controller),
    Controller ! {gtknode4, hello, 1, Endpoint, #{backend => endpoint_stub}},
    ok = gtknode4:await_ready(1000),
    {Controller, Endpoint}.

cleanup({_Controller, Endpoint}) ->
    best_effort_stop(),
    Endpoint ! stop,
    cleanup_controller().

transport_call_is_correlated({_Controller, _Endpoint}) ->
    ?assertEqual({ok, <<"value">>}, gtknode4:call({echo, <<"value">>}, 1000)),
    Status = gtknode4:status(),
    ?assertEqual(0, maps:get(pending_calls, Status)),
    ?assertEqual(true, maps:get(ready, Status)).

unsupported_protocol_is_rejected({Controller, Endpoint}) ->
    ok = gtknode4:subscribe(self()),
    Controller ! {gtknode4, hello, 99, Endpoint, #{}},
    receive
        {gtknode4, status, disconnected,
            {unsupported_protocol, #{received := 99, supported := [1]}}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    Status = gtknode4:status(),
    ?assertEqual(false, maps:get(ready, Status)).

endpoint_loop() ->
    receive
        {gtknode4, call, Ref, {echo, Value}} ->
            whereis(gtknode4) ! {gtknode4, reply, Ref, {ok, Value}},
            endpoint_loop();
        {gtknode4, cast, _Command} ->
            endpoint_loop();
        stop ->
            ok;
        _Other ->
            endpoint_loop()
    end.

cleanup_controller() ->
    case whereis(gtknode4_sup) of
        undefined ->
            ok;
        SupPid ->
            exit(SupPid, kill),
            wait_name_stopped(gtknode4_sup, 100)
    end,
    case whereis(gtknode4) of
        undefined ->
            ok;
        Pid ->
            exit(Pid, kill),
            wait_stopped(100)
    end.

wait_stopped(0) ->
    ok;
wait_stopped(Attempts) ->
    case whereis(gtknode4) of
        undefined ->
            ok;
        _Pid ->
            timer:sleep(5),
            wait_stopped(Attempts - 1)
    end.

wait_name_stopped(_Name, 0) ->
    ok;
wait_name_stopped(Name, Attempts) ->
    case whereis(Name) of
        undefined ->
            ok;
        _Pid ->
            timer:sleep(5),
            wait_name_stopped(Name, Attempts - 1)
    end.

%% Test cleanup is intentionally idempotent: the controller may already have
%% terminated as part of the assertion under test.
best_effort_stop() ->
    try gtknode4:stop() of
        _ -> ok
    catch
        _:_ -> ok
    end.
