-module(ecai_mm_candles_tests).
-include_lib("eunit/include/eunit.hrl").

-define(S, <<"DAMAGEUSDT">>).
-define(P, <<"60min">>).
-define(T, 1700000000).

row(T, Close) ->
    #{<<"interval">> => <<"hour_1">>, <<"startTime">> => T,
      <<"endTime">> => T + 3599, <<"open">> => <<"0.01">>,
      <<"high">> => <<"0.03">>, <<"low">> => <<"0.005">>,
      <<"close">> => Close, <<"volume">> => <<"2000">>, <<"amount">> => <<"20">>}.
json(Rows) -> #{<<"code">> => 0, <<"data">> => #{<<"symbol">> => ?S, <<"item">> => Rows}}.
now_ms() -> (?T + 10800) * 1000 + 5000.
decode(Rows) -> ecai_mm_candles:decode(json(Rows), ?S, ?P, now_ms()).

request_allowlist_test() ->
    ?assertEqual({ok, "/v1/market/kline/DAMAGEUSDT?period=60min&size=720"},
        ecai_mm_candles:request_path(?S, ?P, 720)),
    [?assertMatch({error, _}, ecai_mm_candles:request_path(S, P, N)) || {S, P, N} <-
        [{<<"../secret">>, ?P, 2}, {?S, <<"1hour">>, 2}, {?S, ?P, 0},
         {?S, ?P, 2001}, {?S, ?P, 2.0}, {?S, ?P, <<"2">>}]],
    ?assertEqual(9, length(ecai_mm_candles:periods())).

seconds_sorted_and_deduplicated_test() ->
    R = row(?T, <<"0.01">>),
    {ok, [A, B]} = decode([row(?T + 3600, <<"0.02">>), R, R]),
    ?assertEqual(?T * 1000, maps:get(ts_ms, A)),
    ?assertEqual((?T + 3600) * 1000, maps:get(close_time_ms, A)),
    ?assertEqual(historical_candle, maps:get(kind, A)),
    ?assertEqual(0.02, maps:get(close, B)),
    ?assertNot(maps:is_key(bid, A)), ?assertNot(maps:is_key(ask, A)).

open_candles_not_archived_test() ->
    %% Fetching a candle again does not move its historical timestamp to now.
    {ok, [A]} = ecai_mm_candles:decode(
        json([row(?T, <<"0.01">>), row(?T + 3600, <<"0.02">>)]),
        ?S, ?P, (?T + 4000) * 1000),
    ?assertEqual(?T * 1000, maps:get(ts_ms, A)),
    ?assertEqual({ok, []}, ecai_mm_candles:decode(json([row(?T, <<"0.01">>)]),
        ?S, ?P, (?T + 3600) * 1000)).

malformed_data_rejected_test() ->
    Base = row(?T, <<"0.01">>),
    Patches = [#{<<"close">> => <<"0.04">>}, #{<<"low">> => 0},
        #{<<"low">> => 1.0e-200}, #{<<"high">> => 1.0e101},
        #{<<"volume">> => -1}, #{<<"amount">> => <<"NaN">>},
        #{<<"open">> => <<"1e999">>}, #{<<"interval">> => <<"day_1">>},
        #{<<"startTime">> => ?T * 1000}, #{<<"endTime">> => ?T - 1}],
    [?assertMatch({error, _}, decode([maps:merge(Base, Patch)])) || Patch <- Patches],
    ?assertMatch({error, _}, decode([Base, row(?T, <<"0.02">>)])),
    ?assertMatch({error, _}, decode(lists:duplicate(2001, Base))),
    ?assertMatch({error, _}, ecai_mm_candles:decode(json([Base]), <<"BTCUSDT">>, ?P, now_ms())),
    ?assertMatch({error, _}, ecai_mm_candles:decode(#{<<"code">> => 3011}, ?S, ?P, now_ms())),
    ?assertMatch({error, _}, ecai_mm_candles:decode(#{}, ?S, ?P, now_ms())).

merge_revisions_retention_and_shared_timestamps_test() ->
    {ok, Old} = decode([row(?T, <<"0.01">>), row(?T + 3600, <<"0.01">>)]),
    {ok, New} = decode([row(?T + 3600, <<"0.02">>), row(?T + 7200, <<"0.03">>)]),
    All = ecai_mm_candles:merge(Old, New, 3),
    ?assertEqual(3, length(All)),
    ?assertEqual(All, ecai_mm_candles:merge(All, New, 3)),
    ?assertEqual(2, length(ecai_mm_candles:merge(All, [], 2))),
    %% Missing BTC rows are NOT carried forward; only shared times survive.
    BTC = [(hd(All))#{close => 50000.0}, (lists:last(All))#{close => 60000.0}],
    [A, B] = ecai_mm_candles:paired(All, BTC, 20),
    ?assertEqual(100.0, maps:get(damage_index, A)),
    ?assertEqual(300.0, maps:get(damage_index, B)),
    ?assertEqual(120.0, maps:get(btc_index, B)),
    ?assertNot(maps:is_key(equity_usdt, A)), ?assertNot(maps:is_key(pnl_usdt, A)),
    ?assertEqual([], ecai_mm_candles:paired(All, [], 20)).
