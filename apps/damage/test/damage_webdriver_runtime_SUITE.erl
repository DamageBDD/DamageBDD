%% Opt-in real erlexec/process/HTTP tests. No browsers, network downloads or wallets.
-module(damage_webdriver_runtime_SUITE).
-include_lib("stdlib/include/assert.hrl").
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1,
    startup_and_stop/1, child_crash_recovery/1, occupied_port_is_not_adopted/1,
    admission_and_restart_guard/1, uncertain_session_recycles_service/1]).
suite() -> [{timetrap,{minutes,3}}].
all() -> [startup_and_stop, child_crash_recovery, occupied_port_is_not_adopted,
    admission_and_restart_guard, uncertain_session_recycles_service].
init_per_suite(C) ->
    case os:getenv("DAMAGE_WEBDRIVER_RUNTIME_TEST") of
        "1" ->
            false = lists:keymember(damage, 1, application:which_applications()),
            undefined = whereis(damage_webdriver_sup),
            lists:foreach(fun(A) -> {ok,_} = application:ensure_all_started(A) end,
                [ssl,inets,erlexec]),
            [{saved_runtime,application:get_env(damage,webdriver_runtime)}|C];
        _ -> {skip,set_DAMAGE_WEBDRIVER_RUNTIME_TEST_to_1_and_run_as_non_root}
    end.
end_per_suite(C) ->
    case proplists:get_value(saved_runtime,C) of
        {ok,V} -> application:set_env(damage,webdriver_runtime,V);
        _ -> application:unset_env(damage,webdriver_runtime)
    end.
with_runtime(C, Port, Fun) ->
    Root = filename:join(proplists:get_value(priv_dir,C),
        "webdriver-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Script = filename:join(proplists:get_value(data_dir,C),"fake_fixture.py"),
    application:set_env(damage,webdriver_runtime,[
        {enabled,true},{data_dir,Root},{bootstrap,false},{offline,true},
        {bootstrap_timeout_ms,10000},{ready_timeout_ms,5000},
        {health_interval_ms,200},{restart_delay_ms,200},{max_restart_delay_ms,400},
        {max_failures,2},{fixture,[{enabled,true},{port,Port},{script,Script}]}]),
    {ok,Sup} = damage_webdriver_sup:start_link(), unlink(Sup),
    try Fun(Sup)
    after
        case is_process_alive(Sup) of
            true -> gen_server:stop(Sup,shutdown,45000);
            false -> ok
        end
    end.
port() ->
    {ok,S} = gen_tcp:listen(0,[{ip,{127,0,0,1}},{active,false}]),
    {ok,{_,P}} = inet:sockname(S), gen_tcp:close(S), P.
ready() ->
    case damage_webdriver_runtime:await(fixture,15000) of
        {ok,C} -> C;
        Error -> ct:fail({runtime_not_ready_run_as_non_root_check_private_logs,Error})
    end.
eventually(Fun) -> eventually(Fun, erlang:monotonic_time(millisecond)+15000).
eventually(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(100), eventually(Fun,Deadline);
                false -> ct:fail(runtime_condition_timeout)
            end
    end.
startup_and_stop(C) -> with_runtime(C,port(),fun(Sup) ->
    _ = ready(),
    ?assertMatch(#{phase := ready,active_sessions := 0},damage_webdriver_runtime:status(fixture)),
    ?assertMatch(#{phase := disabled},damage_webdriver_runtime:status(chromedriver)),
    gen_server:stop(Sup,shutdown,45000),
    ?assertEqual(undefined,whereis(damage_webdriver_fixture))
end).
child_crash_recovery(C) -> with_runtime(C,port(),fun(_) ->
    #{generation := Before} = ready(),
    #{os_pid := OsPid} = damage_webdriver_runtime:status(fixture),
    ok = exec:kill(OsPid,9),
    eventually(fun() ->
        case damage_webdriver_runtime:await(fixture,200) of
            {ok,#{generation := After}} -> After =/= Before;
            _ -> false
        end
    end)
end).
occupied_port_is_not_adopted(C) ->
    {ok,Listener} = gen_tcp:listen(0,[{ip,{127,0,0,1}},{active,false}]),
    {ok,{_,Port}} = inet:sockname(Listener),
    try with_runtime(C,Port,fun(_) ->
        eventually(fun() ->
            case damage_webdriver_runtime:status(fixture) of
                #{phase := failed,last_error := webdriver_port_in_use} -> true;
                _ -> false
            end
        end),
        ?assertMatch({ok,{_,Port}},inet:sockname(Listener))
    end) after gen_tcp:close(Listener) end.
admission_and_restart_guard(C) -> with_runtime(C,port(),fun(_) ->
    #{pid := Service,generation := Gen} = ready(),
    ?assertEqual({ok,Service},damage_webdriver_runtime:claim(fixture,{Service,Gen})),
    ?assertEqual({error,webdriver_capacity_exhausted},damage_webdriver_runtime:claim(fixture,{Service,Gen})),
    ?assertEqual({error,webdriver_sessions_active},damage_webdriver_runtime:restart(fixture)),
    ok = gen_server:call(Service,{release,Gen}),
    ?assertEqual(ok,damage_webdriver_runtime:restart(fixture)),
    #{generation := New} = ready(), ?assertNotEqual(Gen,New)
end).
uncertain_session_recycles_service(C) -> with_runtime(C,port(),fun(_) ->
    #{pid := Service,generation := Gen} = ready(),
    {ok,Service} = damage_webdriver_runtime:claim(fixture,{Service,Gen}),
    gen_server:cast(Service,{invalidate,self(),Gen}),
    eventually(fun() ->
        case damage_webdriver_runtime:await(fixture,200) of
            {ok,#{generation := New}} -> New =/= Gen;
            _ -> false
        end
    end),
    receive {webdriver_backend_lost,Service} -> ok after 1000 -> ct:fail(missing_session_invalidation) end,
    ?assertMatch(#{active_sessions := 0},damage_webdriver_runtime:status(fixture))
end).
