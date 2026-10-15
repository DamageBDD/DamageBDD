-module(ecai_mm_control_tests).
-include_lib("eunit/include/eunit.hrl").

opt_in_paper_worker_lifecycle_test_() ->
    {timeout, 45, fun lifecycle/0}.

lifecycle() ->
    %% Never interfere with a supervised node when EUnit runs in a live shell.
    case {whereis(damage_mm_sup), whereis(ecai_mm_control), whereis(ecai_mm)} of
        {undefined, undefined, undefined} -> isolated_lifecycle();
        _ -> ok
    end.

isolated_lifecycle() ->
    Dir = filename:join("/tmp", "ecai-mm-control-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    _ = file:del_dir_r(Dir),
    Keys = [market_maker_enabled, market_maker_levels, market_maker_poll_interval_ms],
    Previous = [{ecai, Key, application:get_env(ecai, Key)} || Key <- Keys] ++
        [{damage, ecai_market_maker, application:get_env(damage, ecai_market_maker)}],
    try
        ok = application:set_env(ecai, market_maker_enabled, false),
        ok = application:unset_env(ecai, market_maker_levels),
        ok = application:unset_env(ecai, market_maker_poll_interval_ms),
        ok = application:set_env(damage, ecai_market_maker,
            #{state_dir => Dir, auto_poll => false,
              paper_balances => #{damage => 5000.0, usdt => 100.0}}),
        {ok, Sup} = damage_mm_sup:start_link(),
        try
            {ok, Control} = ecai_mm_control:start_link(),
            try
                #{state := <<"disabled">>} = ecai_mm_control:sync(),
                ?assertEqual(undefined, whereis(ecai_mm)),
                ok = application:set_env(ecai, market_maker_enabled, true),
                #{state := <<"running">>, execution_enabled := false} = ecai_mm_control:sync(),
                ?assert(is_pid(whereis(ecai_mm))),
                ?assertEqual(paper, maps:get(mode, ecai_mm:status())),
                ok = application:set_env(ecai, market_maker_levels, 7),
                #{state := <<"running">>} = ecai_mm_control:sync(),
                ?assertEqual(7, maps:get(levels, maps:get(values, ecai_mm:config()))),
                ?assertEqual(1, maps:get(revision, ecai_mm:config())),
                %% Invalid env must fail closed; no old paper quotes may survive.
                ok = application:set_env(ecai, market_maker_poll_interval_ms, 250000),
                #{state := <<"error">>} = ecai_mm_control:sync(),
                ?assertEqual(undefined, whereis(ecai_mm)),
                ok = application:unset_env(ecai, market_maker_poll_interval_ms),
                #{state := <<"running">>} = ecai_mm_control:sync(),
                ?assertEqual(7, maps:get(levels, maps:get(values, ecai_mm:config()))),
                ok = application:set_env(ecai, market_maker_enabled, false),
                #{state := <<"disabled">>} = ecai_mm_control:sync(),
                ?assertEqual(undefined, whereis(ecai_mm))
            after gen_server:stop(Control) end
        after gen_server:stop(Sup) end
    after
        [restore(App, Key, Value) || {App, Key, Value} <- Previous],
        _ = file:del_dir_r(Dir)
    end.

restore(App, Key, {ok, Value}) -> application:set_env(App, Key, Value);
restore(App, Key, undefined) -> application:unset_env(App, Key).
