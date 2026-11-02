%%% Coinstore closed OHLCV candles. Historical prices are NEVER order books.
%%% REST contract: https://coinstore-openapi.github.io/en/#get-k-line
-module(ecai_mm_candles).
-export([symbols/0, periods/0, period_ms/1, request_path/3, decode/4,
         merge/3, paired/3]).

symbols() -> [<<"DAMAGEUSDT">>, <<"BTCUSDT">>].
periods() -> [<<"1min">>, <<"5min">>, <<"15min">>, <<"30min">>, <<"60min">>,
              <<"4hour">>, <<"12hour">>, <<"1day">>, <<"1week">>].

period_ms(<<"1min">>) -> 60000;
period_ms(<<"5min">>) -> 300000;
period_ms(<<"15min">>) -> 900000;
period_ms(<<"30min">>) -> 1800000;
period_ms(<<"60min">>) -> 3600000;
period_ms(<<"4hour">>) -> 14400000;
period_ms(<<"12hour">>) -> 43200000;
period_ms(<<"1day">>) -> 86400000;
period_ms(<<"1week">>) -> 604800000.

request_path(Symbol, Period, Size) ->
    case lists:member(Symbol, symbols()) andalso lists:member(Period, periods())
        andalso is_integer(Size) andalso Size >= 1 andalso Size =< 2000 of
        true ->
            {ok, "/v1/market/kline/" ++ binary_to_list(Symbol) ++
                "?period=" ++ binary_to_list(Period) ++ "&size=" ++ integer_to_list(Size)};
        false -> {error, invalid_history_request}
    end.

%% startTime/endTime in the provider schema are SECONDS. Only candles whose
%% entire requested interval has elapsed (plus a 5s guard) enter the archive.
%% endTime is retained as provenance, not used to mark an open candle closed.
decode(#{<<"code">> := Code, <<"data">> := Data}, Symbol, Period, NowMs)
        when (Code =:= 0 orelse Code =:= <<"0">>), is_map(Data), is_integer(NowMs) ->
    try
        {ok, _} = request_path(Symbol, Period, 1),
        Symbol = maps:get(<<"symbol">>, Data),
        Items = maps:get(<<"item">>, Data),
        true = is_list(Items) andalso length(Items) =< 2000,
        Duration = period_ms(Period),
        Rows = [candle(Item, Symbol, Period, Duration, NowMs) || Item <- Items],
        Closed = [R || R <- Rows, maps:get(close_time_ms, R) + 5000 =< NowMs],
        %% Conflicting duplicates in one response are ambiguous; reject the
        %% batch instead of quietly choosing whichever row happened to arrive last.
        Unique = lists:foldl(fun(R, Acc) ->
            T = maps:get(ts_ms, R),
            case maps:find(T, Acc) of
                error -> Acc#{T => R};
                {ok, R} -> Acc;
                {ok, _} -> error(conflicting_candles)
            end
        end, #{}, Closed),
        {ok, sorted(maps:values(Unique))}
    catch
        _:_ -> {error, invalid_candle_response}
    end;
decode(#{<<"code">> := Code}, _Symbol, _Period, _Now) when Code =/= 0, Code =/= <<"0">> ->
    {error, {candle_api_error, Code}};
decode(_, _, _, _) -> {error, unexpected_candle_schema}.

candle(Row, Symbol, Period, Duration, Now) when is_map(Row) ->
    Start = maps:get(<<"startTime">>, Row),
    End = maps:get(<<"endTime">>, Row),
    true = is_integer(Start) andalso Start >= 946684800,
    true = is_integer(End) andalso End >= Start,
    Ts = Start * 1000,
    true = Ts =< Now andalso End * 1000 < Ts + Duration,
    true = lists:member(maps:get(<<"interval">>, Row), aliases(Period)),
    O = number(maps:get(<<"open">>, Row)),
    H = number(maps:get(<<"high">>, Row)),
    L = number(maps:get(<<"low">>, Row)),
    C = number(maps:get(<<"close">>, Row)),
    V = number(maps:get(<<"volume">>, Row)),
    A = number(maps:get(<<"amount">>, Row)),
    %% Numeric bounds also keep indexed ratios finite (no subnormal divide overflow).
    true = L >= 1.0e-100 andalso H >= L andalso O >= L andalso O =< H,
    true = C >= L andalso C =< H andalso V >= 0 andalso A >= 0,
    #{kind => historical_candle, source => <<"coinstore">>, symbol => Symbol,
      period => Period, ts_ms => Ts, close_time_ms => Ts + Duration,
      exchange_end_ms => End * 1000, fetched_ms => Now,
      open => O, high => H, low => L, close => C, volume => V, amount => A}.

number(V) when is_integer(V); is_float(V) ->
    true = V >= 0 andalso V =< 1.0e100,
    float(V);
number(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 128 ->
    L = binary_to_list(B),
    case string:to_float(L) of
        {V, []} -> number(V);
        _ -> case string:to_integer(L) of
            {V, []} -> number(V);
            _ -> error(invalid_candle_number)
        end
    end.

aliases(<<"1min">>) -> [<<"min_1">>, <<"1min">>, <<"1m">>];
aliases(<<"5min">>) -> [<<"min_5">>, <<"5min">>, <<"5m">>];
aliases(<<"15min">>) -> [<<"min_15">>, <<"15min">>, <<"15m">>];
aliases(<<"30min">>) -> [<<"min_30">>, <<"30min">>, <<"30m">>];
aliases(<<"60min">>) -> [<<"hour_1">>, <<"60min">>, <<"1h">>];
aliases(<<"4hour">>) -> [<<"hour_4">>, <<"4hour">>, <<"4h">>];
aliases(<<"12hour">>) -> [<<"hour_12">>, <<"12hour">>, <<"12h">>];
aliases(<<"1day">>) -> [<<"day_1">>, <<"1day">>, <<"1d">>];
aliases(<<"1week">>) -> [<<"week_1">>, <<"1week">>, <<"1w">>].

%% Re-fetching an overlapping window replaces revised candles idempotently.
%% Never discard retained older bars just because an upstream window is short.
merge(Old, New, Keep) when is_integer(Keep), Keep > 0 ->
    ByTime = lists:foldl(fun(R, M) -> M#{maps:get(ts_ms, R) => R} end, #{}, Old ++ New),
    latest(sorted(maps:values(ByTime)), Keep).

%% Compare close with close at the SAME timestamp, not a historical DAMAGE
%% close with today's BTC ticker. Missing intervals remain gaps. No P&L fields.
paired(Damage, Btc, Limit) when is_integer(Limit), Limit > 0 ->
    BTC = maps:from_list([{maps:get(ts_ms, R), R} || R <- Btc]),
    Rows = latest([#{ts_ms => maps:get(ts_ms, D),
                     damage_usdt => maps:get(close, D), btc_usdt => maps:get(close, B)}
        || D <- sorted(Damage), {ok, B} <- [maps:find(maps:get(ts_ms, D), BTC)]], Limit),
    case Rows of
        [] -> [];
        [First | _] ->
            D0 = maps:get(damage_usdt, First), B0 = maps:get(btc_usdt, First),
            [R#{damage_index => 100.0 * maps:get(damage_usdt, R) / D0,
                 btc_index => 100.0 * maps:get(btc_usdt, R) / B0} || R <- Rows]
    end.

sorted(Rows) -> lists:sort(fun(A, B) -> maps:get(ts_ms, A) < maps:get(ts_ms, B) end, Rows).
latest(Rows, Keep) -> lists:nthtail(max(0, length(Rows) - Keep), Rows).
