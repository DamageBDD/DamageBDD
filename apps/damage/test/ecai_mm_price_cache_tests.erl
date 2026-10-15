-module(ecai_mm_price_cache_tests).
-include_lib("eunit/include/eunit.hrl").

cache_reuses_original_timestamp_test() ->
    Count = atomics:new(1, []),
    Get = fun(Path) -> atomics:add(Count, 1, 1), response(Path) end,
    with_cache(Get, #{live_ttl_ms => 2000}, fun(_Dir, _O) ->
        {ok, First} = ecai_mm_feed:fetch(),
        {ok, Second} = ecai_mm_feed:fetch(),
        ?assertEqual(false, maps:get(cache_hit, First)),
        ?assertEqual(true, maps:get(cache_hit, Second)),
        ?assertEqual(maps:get(fetched_ms, First), maps:get(fetched_ms, Second)),
        ?assertEqual(2, atomics:get(Count, 1)),
        ?assertEqual(1, maps:get(hits, ecai_mm_price_cache:status()))
    end).

failed_request_never_returns_stale_book_test() ->
    Mode = atomics:new(2, []),
    Get = fun(Path) ->
        atomics:add(Mode, 2, 1),
        case atomics:get(Mode, 1) of
            0 -> response(Path);
            _ -> {error, tls_rejected}
        end
    end,
    with_cache(Get, #{live_ttl_ms => 0}, fun(_Dir, _O) ->
        {ok, Original} = ecai_mm_feed:fetch(),
        atomics:put(Mode, 1, 1),
        ?assertEqual({error, {depth_request, tls_rejected}}, ecai_mm_feed:fetch()),
        Calls = atomics:get(Mode, 2),
        ?assertEqual({error, {depth_request, tls_rejected}}, ecai_mm_feed:fetch()),
        ?assertEqual(Calls, atomics:get(Mode, 2)),
        #{latest := Last} = ecai_mm_price_cache:status(),
        ?assertEqual(maps:get(fetched_ms, Original), maps:get(fetched_ms, Last)),
        ?assertEqual(false, maps:get(execution_eligible, Last)),
        ?assertNot(maps:is_key(bid, Last))
    end).

cold_restart_does_not_make_saved_live_data_fresh_test() ->
    with_cache(fun response/1, #{}, fun(_Dir, Options) ->
        {ok, Original} = ecai_mm_feed:fetch(),
        gen_server:stop(ecai_mm_price_cache),
        {ok, _} = ecai_mm_price_cache:start_link(Options#{get_fun => fun(_) -> {error, offline} end}),
        ?assertMatch({error, _}, ecai_mm_feed:fetch()),
        #{latest := Last, hits := 0} = ecai_mm_price_cache:status(),
        ?assertEqual(maps:get(fetched_ms, Original), maps:get(fetched_ms, Last))
    end).

single_flight_keeps_reads_responsive_test_() -> {timeout, 10, fun single_flight/0}.
single_flight() ->
    Owner = self(),
    Get = fun(Path) -> Owner ! {request, self(), Path}, receive continue -> response(Path) end end,
    with_cache(Get, #{}, fun(_Dir, _O) ->
        spawn(fun() -> Owner ! {result, ecai_mm_feed:fetch()} end),
        Worker = receive {request, W, _} -> W after 1000 -> error(no_request) end,
        spawn(fun() -> Owner ! {result, ecai_mm_feed:fetch()} end),
        wait_until(fun() -> maps:get(coalesced, ecai_mm_price_cache:status()) =:= 1 end),
        %% Cache status and historical reads do not wait for network completion.
        ?assertMatch(#{live_inflight := true}, ecai_mm_price_cache:status()),
        ?assertMatch({ok, #{rows := []}}, ecai_mm_price_cache:history(<<"60min">>, 10)),
        Worker ! continue,
        receive {request, Worker, _} -> Worker ! continue after 1000 -> error(no_ticker) end,
        A = receive {result, {ok, V1}} -> V1 after 2000 -> error(no_first_result) end,
        B = receive {result, {ok, V2}} -> V2 after 2000 -> error(no_second_result) end,
        ?assertEqual(maps:get(fetched_ms, A), maps:get(fetched_ms, B))
    end).

history_backfill_persistence_and_idempotency_test_() -> {timeout, 15, fun history_backfill/0}.
history_backfill() ->
    with_cache(fun response/1, #{}, fun(_Dir, Options) ->
        ?assertMatch({ok, _}, ecai_mm_price_cache:backfill(#{period => <<"60min">>, size => 3})),
        wait_done(),
        {ok, #{rows := Rows, missing_intervals := 0}} = ecai_mm_price_cache:history(<<"60min">>, 20),
        ?assertEqual(2, length(Rows)),
        ?assertEqual(100.0, maps:get(damage_index, hd(Rows))),
        ?assertNot(maps:is_key(equity_usdt, hd(Rows))),
        ?assertMatch({ok, #{count := 2}}, ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 20)),
        ?assertMatch({ok, _}, ecai_mm_price_cache:backfill(#{period => <<"60min">>, size => 3})),
        wait_done(),
        ?assertMatch({ok, #{count := 2}}, ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 20)),
        gen_server:stop(ecai_mm_price_cache),
        %% Reading a warm archive must work with an offline provider, even with
        %% no paper engine running, and must not issue a fetch in the background.
        {ok, _} = ecai_mm_price_cache:start_link(Options#{get_fun => fun(_) -> error(unexpected_network) end}),
        ?assertMatch({ok, #{rows := Rows}}, ecai_mm_price_cache:history(<<"60min">>, 20)),
        ?assertEqual(undefined, whereis(ecai_mm))
    end).

pending_backfill_resumes_after_restart_test_() -> {timeout, 10, fun resume_backfill/0}.
resume_backfill() ->
    Owner = self(),
    Get = fun(Path) -> Owner ! {backfill_started, Path}, receive never -> response(Path) end end,
    with_cache(Get, #{}, fun(_Dir, Options) ->
        {ok, _} = ecai_mm_price_cache:backfill(#{symbol => <<"DAMAGEUSDT">>, period => <<"60min">>, size => 3}),
        receive {backfill_started, _} -> ok after 1000 -> error(no_backfill) end,
        ?assertMatch(#{queued := 1, history_inflight := true}, ecai_mm_price_cache:status()),
        gen_server:stop(ecai_mm_price_cache),
        {ok, _} = ecai_mm_price_cache:start_link(Options#{get_fun => fun response/1}),
        wait_done(),
        ?assertMatch({ok, #{count := 2}}, ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 20))
    end).

backfill_errors_preserve_good_archive_test_() -> {timeout, 12, fun failure_keeps_archive/0}.
failure_keeps_archive() ->
    Mode = atomics:new(1, []),
    Get = fun(Path) -> case atomics:get(Mode, 1) of 0 -> response(Path); _ -> {error, {http_status, 429}} end end,
    with_cache(Get, #{}, fun(_Dir, _O) ->
        {ok, _} = ecai_mm_price_cache:backfill(#{symbol => <<"DAMAGEUSDT">>, period => <<"60min">>, size => 3}),
        wait_done(), atomics:put(Mode, 1, 1),
        {ok, _} = ecai_mm_price_cache:backfill(#{symbol => <<"DAMAGEUSDT">>, period => <<"60min">>, size => 3}),
        wait_until(fun() ->
            case maps:get(series, ecai_mm_price_cache:status()) of
                [#{last_error := E}] -> E =/= null;
                _ -> false
            end
        end),
        ?assertMatch({ok, #{count := 2}}, ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 20)),
        #{jobs := [Job]} = ecai_mm_price_cache:status(),
        ?assert(maps:get(not_before_ms, Job) > erlang:system_time(millisecond))
    end).

invalid_queries_do_not_fetch_test() ->
    with_cache(fun(_) -> error(unexpected_network) end, #{}, fun(_Dir, _O) ->
        [?assertMatch({error, _}, ecai_mm_price_cache:backfill(R)) || R <-
            [#{url => <<"https://elsewhere.invalid">>}, #{period => <<"x">>}, #{size => 2001}, #{size => 0}]],
        ?assertMatch({error, _}, ecai_mm_price_cache:history(<<"60min">>, 2001)),
        ?assertMatch({error, _}, ecai_mm_price_cache:candles(<<"EVIL">>, <<"60min">>, 10)),
        ?assertMatch(#{queued := 0, live_inflight := false}, ecai_mm_price_cache:status())
    end).

larger_manual_backfill_is_not_lost_test_() -> {timeout, 12, fun upgraded_backfill/0}.
upgraded_backfill() ->
    Owner = self(),
    Get = fun(Path) -> Owner ! {history_request, self(), Path},
        receive continue -> response(Path) end end,
    with_cache(Get, #{}, fun(_Dir, _O) ->
        {ok, _} = ecai_mm_price_cache:backfill(#{symbol => <<"DAMAGEUSDT">>, period => <<"60min">>, size => 3}),
        First = receive {history_request, W1, P1} ->
            ?assertNotEqual(nomatch, string:find(P1, "size=3")), W1
        after 2000 -> error(no_first_request) end,
        {ok, _} = ecai_mm_price_cache:backfill(#{symbol => <<"DAMAGEUSDT">>, period => <<"60min">>, size => 2000}),
        ?assertMatch(#{jobs := [#{size := 2000, automatic := false}]}, ecai_mm_price_cache:status()),
        First ! continue,
        Second = receive {history_request, W2, P2} ->
            ?assertNotEqual(nomatch, string:find(P2, "size=2000")), W2
        after 3000 -> error(no_upgraded_request) end,
        Second ! continue,
        wait_done(),
        ?assertMatch({ok, #{count := 2, last_requested_size := 2000}},
            ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 10))
    end).

automatic_backfill_stops_when_disabled_test_() -> {timeout, 12, fun auto_disable/0}.
auto_disable() ->
    Owner = self(),
    Get = fun(Path) -> Owner ! {automatic_request, Path}, receive never -> response(Path) end end,
    with_cache(Get, #{history_auto_backfill => true, history_periods => [<<"60min">>]}, fun(_Dir, _O) ->
        application:set_env(ecai, market_maker_enabled, true),
        receive {automatic_request, _} -> ok after 2500 -> error(no_automatic_request) end,
        ?assertMatch(#{history_inflight := true}, ecai_mm_price_cache:status()),
        application:set_env(ecai, market_maker_history_auto_backfill, false),
        wait_until(fun() ->
            #{queued := N, history_inflight := Busy} = ecai_mm_price_cache:status(),
            N =:= 0 andalso Busy =:= false
        end),
        ?assertMatch({ok, #{rows := []}}, ecai_mm_price_cache:history(<<"60min">>, 10))
    end).

settings_bounds_test() ->
    ?assertEqual(ok, ecai_mm_price_cache:validate_settings(#{market_maker_price_cache_ttl_ms => 0})),
    ?assertEqual(ok, ecai_mm_price_cache:validate_settings(#{market_maker_history_bars => 2000})),
    [?assertMatch({error, _}, ecai_mm_price_cache:validate_settings(M)) || M <-
        [#{market_maker_history_bars => 2001}, #{market_maker_history_bars => 0},
         #{market_maker_price_cache_ttl_ms => -1}, #{market_maker_history_auto_backfill => <<"true">>},
         #{market_maker_history_refresh_ms => 59999}]].

engine_ignores_historical_inputs_and_cached_duplicate_ticks_test_() -> {timeout, 10, fun engine_safety/0}.
engine_safety() ->
    with_cache(fun response/1, #{live_ttl_ms => 2000}, fun(Dir, _O) ->
        {ok, _} = ecai_mm:start_link(#{state_dir => filename:join(Dir, "engine"), auto_poll => false,
            paper_balances => #{damage => 10000.0, usdt => 300.0}}),
        try
            ecai_mm:poll(),
            wait_until(fun() -> maps:get(fresh, ecai_mm:status()) end),
            Q = hd(ecai_mm:quotes()), Id = maps:get(client_id, Q),
            {ok, _} = ecai_mm:paper_fill(Id, 1.0),
            Before = ecai_mm:quotes(), Events = maps:get(events, ecai_mm:status()),
            ecai_mm:poll(),
            wait_until(fun() ->
                maps:get(hits, ecai_mm_price_cache:status()) >= 1 andalso
                maps:get(feed_request, sys:get_state(ecai_mm)) =:= undefined
            end),
            ?assertEqual(Before, ecai_mm:quotes()),
            ?assertEqual(Events, maps:get(events, ecai_mm:status())),
            ?assertEqual({error, historical_price_not_live_book}, ecai_mm:ingest(#{
                kind => historical_candle, bid => 0.0099, ask => 0.0101, btc_usdt => 90000.0})),
            ?assertEqual(Before, ecai_mm:quotes()),
            ?assertEqual(ok, ecai_mm:verify_audit())
        after gen_server:stop(ecai_mm) end
    end).

engine_status_remains_responsive_during_fetch_test_() -> {timeout, 10, fun responsive_engine/0}.
responsive_engine() ->
    Owner = self(), Get = fun(Path) -> Owner ! {blocked, self(), Path}, receive continue -> response(Path) end end,
    with_cache(Get, #{}, fun(Dir, _O) ->
        {ok, _} = ecai_mm:start_link(#{state_dir => filename:join(Dir, "engine"), auto_poll => false}),
        try
            ecai_mm:poll(), ecai_mm:poll(),
            Worker = receive {blocked, W, _} -> W after 1000 -> error(no_fetch) end,
            ?assertMatch(#{fresh := false}, ecai_mm:status()),
            ?assertEqual(ok, ecai_mm:pause()),
            Worker ! continue,
            receive {blocked, Worker, _} -> Worker ! continue after 1000 -> error(no_ticker) end,
            wait_until(fun() -> maps:get(fresh, ecai_mm:status()) end),
            ?assertMatch(#{paused := true, quotes := []}, ecai_mm:status())
        after gen_server:stop(ecai_mm) end
    end).

with_cache(Get, Extra, Fun) ->
    ?assertEqual(undefined, whereis(ecai_mm_price_cache)),
    Dir = filename:join("/tmp", "ecai-price-cache-" ++ os:getpid() ++ "-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    Options = maps:merge(#{state_dir => Dir, history_auto_backfill => false, get_fun => Get}, Extra),
    Keys = [market_maker_enabled | [maps:get(key, F) || F <- ecai_mm_price_cache:fields()]],
    Saved = [{K, application:get_env(ecai, K)} || K <- Keys],
    [application:unset_env(ecai, K) || K <- Keys],
    try
        {ok, _} = ecai_mm_price_cache:start_link(Options),
        Fun(Dir, Options)
    after
        case whereis(ecai_mm_price_cache) of undefined -> ok; P -> gen_server:stop(P) end,
        [case V of {ok, Value} -> application:set_env(ecai, K, Value);
                   undefined -> application:unset_env(ecai, K) end || {K, V} <- Saved],
        file:del_dir_r(Dir)
    end.

wait_done() -> wait_until(fun() -> maps:get(queued, ecai_mm_price_cache:status()) =:= 0 end).
wait_until(Fun) -> wait_until(Fun, erlang:monotonic_time(millisecond) + 7000).
wait_until(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(wait_timeout);
                false -> timer:sleep(10), wait_until(Fun, Deadline)
            end
    end.

%% Synthetic, closed candles used only in tests. Production never generates
%% candles from ticker snapshots or fills the gaps with these fixtures.
response(Path) ->
    case {lists:prefix("/v1/market/depth/", Path), lists:prefix("/v1/market/kline/", Path)} of
        {true, _} -> {ok, #{<<"code">> => 0, <<"data">> => #{
            <<"a">> => [[<<"0.0101">>, <<"1000">>]], <<"b">> => [[<<"0.0099">>, <<"1000">>]]}}};
        {false, true} ->
            Symbol = case string:find(Path, "DAMAGEUSDT") of nomatch -> <<"BTCUSDT">>; _ -> <<"DAMAGEUSDT">> end,
            Close = case Symbol of <<"BTCUSDT">> -> 95000.0; _ -> 0.01 end,
            %% Fixed fixture time: an hour boundary during EUnit cannot change history.
            Current = 1700002800,
            Items = [#{<<"interval">> => <<"hour_1">>, <<"startTime">> => T,
                       <<"endTime">> => T + 3599, <<"open">> => Close,
                       <<"high">> => Close, <<"low">> => Close, <<"close">> => Close,
                       <<"volume">> => 1, <<"amount">> => Close}
                     || T <- [Current - 10800, Current - 7200]],
            {ok, #{<<"code">> => 0, <<"data">> => #{<<"symbol">> => Symbol, <<"item">> => Items}}};
        _ -> {ok, #{<<"code">> => 0, <<"data">> => [
            #{<<"symbol">> => <<"damageusdt">>, <<"price">> => <<"0.01">>},
            #{<<"symbol">> => <<"btcusdt">>, <<"price">> => <<"95000">>}]}}
    end.
