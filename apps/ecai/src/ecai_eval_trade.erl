%% Bounded, deterministic, single-decision top-of-book PAPER replay.
%% No wallets, exchange connections, live orders, or claims of tradable alpha.
-module(ecai_eval_trade).
-export([validate/1, public_context/1, grade/2]).

validate(M) ->
    Keys = [<<"symbol">>, <<"as_of_ms">>, <<"latency_ms">>, <<"fee_bps">>,
            <<"slippage_bps">>, <<"initial_cash_minor">>, <<"initial_position">>,
            <<"max_position">>, <<"max_order_quantity">>, <<"max_order_notional_minor">>,
            <<"allow_short">>, <<"tape">>],
    ecai_eval_util:keys(M, Keys),
    ecai_eval_util:text(maps:get(<<"symbol">>, M), 32),
    T = ecai_eval_util:integer(maps:get(<<"as_of_ms">>, M), 0, 9007199254740991),
    lists:foreach(fun(K) -> ecai_eval_util:integer(maps:get(K, M), 0, 10000) end,
                  [<<"fee_bps">>, <<"slippage_bps">>]),
    ecai_eval_util:integer(maps:get(<<"latency_ms">>, M), 1, 86400000),
    lists:foreach(fun(K) -> ecai_eval_util:integer(maps:get(K, M), 1, 1000000000) end,
                  [<<"initial_cash_minor">>, <<"max_order_notional_minor">>]),
    lists:foreach(fun(K) -> ecai_eval_util:integer(maps:get(K, M), 1, 10000) end,
                  [<<"max_position">>, <<"max_order_quantity">>]),
    Pos = ecai_eval_util:integer(maps:get(<<"initial_position">>, M), -10000, 10000),
    Short = maps:get(<<"allow_short">>, M),
    ecai_eval_util:require(is_boolean(Short), invalid_boolean),
    ecai_eval_util:require(abs(Pos) =< maps:get(<<"max_position">>, M), invalid_initial_position),
    ecai_eval_util:require(Short orelse Pos >= 0, short_position_forbidden),
    Tape = maps:get(<<"tape">>, M),
    ecai_eval_util:require(is_list(Tape) andalso length(Tape) >= 2 andalso length(Tape) =< 4096,
                           invalid_tape),
    lists:foreach(fun tick/1, Tape),
    Ts = [maps:get(<<"time_ms">>, X) || X <- Tape],
    ecai_eval_util:require(Ts =:= lists:usort(Ts), unordered_or_duplicate_ticks),
    ecai_eval_util:require(hd(Ts) =< T andalso lists:last(Ts) >= T + maps:get(<<"latency_ms">>, M),
                           missing_as_of_or_future_tick),
    ecai_eval_util:require(equity(maps:get(<<"initial_cash_minor">>, M), Pos,
                                   last_visible(M)) > 0, nonpositive_initial_equity), M.
tick(X) ->
    ecai_eval_util:keys(X, [<<"time_ms">>, <<"bid_minor">>, <<"ask_minor">>]),
    ecai_eval_util:integer(maps:get(<<"time_ms">>, X), 0, 9007199254740991),
    B = ecai_eval_util:integer(maps:get(<<"bid_minor">>, X), 1, 1000000000),
    A = ecai_eval_util:integer(maps:get(<<"ask_minor">>, X), 1, 1000000000),
    ecai_eval_util:require(B =< A, crossed_book).
last_visible(M) ->
    lists:last([X || X <- maps:get(<<"tape">>, M),
                      maps:get(<<"time_ms">>, X) =< maps:get(<<"as_of_ms">>, M)]).
public_context(M) ->
    (maps:without([<<"tape">>], M))#{<<"book">> => last_visible(M),
        <<"output_contract">> => <<"JSON: symbol, decision_time_ms equal to as_of_ms, action hold/buy/sell. For buy/sell include positive integer quantity and limit_price_minor. Units are fixture units; no live trading.">>}.

grade(M, Output) ->
    try
        Action = validate_order(M, Output),
        Result = replay(M, Action),
        #{<<"status">> => <<"pass">>, <<"reason">> => <<"paper_risk_contract_satisfied">>,
          <<"metrics">> => Result}
    catch
        throw:{eval_error, Why} -> #{<<"status">> => <<"fail">>, <<"reason">> => ecai_eval_util:bin(Why)};
        error:{badkey, _} -> #{<<"status">> => <<"fail">>, <<"reason">> => <<"missing_order_field">>};
        error:badarg -> #{<<"status">> => <<"fail">>, <<"reason">> => <<"invalid_order">>}
    end.
validate_order(M, O) ->
    ecai_eval_util:keys(O, [<<"symbol">>, <<"decision_time_ms">>, <<"action">>,
                           <<"quantity">>, <<"limit_price_minor">>]),
    ecai_eval_util:require(maps:get(<<"symbol">>, O) =:= maps:get(<<"symbol">>, M), wrong_symbol),
    ecai_eval_util:require(maps:get(<<"decision_time_ms">>, O) =:= maps:get(<<"as_of_ms">>, M),
                           invalid_decision_time),
    Side = ecai_eval_util:enum(maps:get(<<"action">>, O), [<<"hold">>, <<"buy">>, <<"sell">>]),
    case Side of
        <<"hold">> ->
            ecai_eval_util:require(not maps:is_key(<<"quantity">>, O) andalso
                                   not maps:is_key(<<"limit_price_minor">>, O), invalid_hold_order),
            #{side => hold, quantity => 0, limit => 0};
        _ ->
            Q = ecai_eval_util:integer(maps:get(<<"quantity">>, O), 1,
                                        maps:get(<<"max_order_quantity">>, M)),
            Price = ecai_eval_util:integer(maps:get(<<"limit_price_minor">>, O), 1, 1000000000),
            Signed = case Side of <<"buy">> -> Q; <<"sell">> -> -Q end,
            Pos = maps:get(<<"initial_position">>, M) + Signed,
            ecai_eval_util:require(abs(Pos) =< maps:get(<<"max_position">>, M), position_limit),
            ecai_eval_util:require(maps:get(<<"allow_short">>, M) orelse Pos >= 0, short_sale_forbidden),
            ecai_eval_util:require(Q * Price =< maps:get(<<"max_order_notional_minor">>, M), notional_limit),
            #{side => Side, quantity => Signed, limit => Price}
    end.
replay(M, Order) ->
    Tape = maps:get(<<"tape">>, M), AsOf = maps:get(<<"as_of_ms">>, M),
    Future = [X || X <- Tape, maps:get(<<"time_ms">>, X) > AsOf],
    Cash0 = maps:get(<<"initial_cash_minor">>, M), Pos0 = maps:get(<<"initial_position">>, M),
    E0 = equity(Cash0, Pos0, last_visible(M)),
    Initial = #{cash => Cash0, position => Pos0, filled => false, fill => null,
                fees => 0, slippage => 0, peak => E0, drawdown_bps => 0},
    Final = lists:foldl(fun(Tick, State) ->
        S = maybe_fill(M, Order, Tick, State),
        mark(S, equity(maps:get(cash, S), maps:get(position, S), Tick))
    end, Initial, Future),
    Last = lists:last(Future),
    {Liquidation, CloseFee, CloseSlip} = liquidation(M, maps:get(position, Final), Last),
    E1 = maps:get(cash, Final) + Liquidation,
    Closed = mark(Final, E1),
    {HoldLiquidation, _, _} = liquidation(M, Pos0, Last),
    HoldE1 = Cash0 + HoldLiquidation,
    #{<<"simulator">> => <<"single-decision-top-of-book/v1">>, <<"paper_only">> => true,
      <<"filled">> => maps:get(filled, Final), <<"fill">> => maps:get(fill, Final),
      <<"initial_equity_minor">> => E0, <<"terminal_equity_minor">> => E1,
      <<"net_pnl_minor">> => E1 - E0, <<"hold_net_pnl_minor">> => HoldE1 - E0,
      <<"excess_vs_hold_minor">> => E1 - HoldE1,
      <<"net_return_bps">> => ((E1 - E0) * 10000) div E0,
      <<"max_drawdown_bps">> => maps:get(drawdown_bps, Closed),
      <<"fees_minor">> => maps:get(fees, Final) + CloseFee,
      <<"slippage_minor">> => maps:get(slippage, Final) + CloseSlip,
      <<"terminal_liquidation_assumed">> => true}.
maybe_fill(_M, #{side := hold}, _Tick, S) -> S;
maybe_fill(_M, _O, _Tick, #{filled := true} = S) -> S;
maybe_fill(M, #{quantity := Q, limit := Limit}, T, S) ->
    Ready = maps:get(<<"time_ms">>, T) >= maps:get(<<"as_of_ms">>, M) + maps:get(<<"latency_ms">>, M),
    {Price, Raw} = execution_price(M, Q, T),
    Crosses = case Q > 0 of true -> Price =< Limit; false -> Price >= Limit end,
    case Ready andalso Crosses of
        false -> S;
        true ->
            Notional = abs(Q) * Price, Fee = fee(M, Notional),
            ecai_eval_util:require(Notional =< maps:get(<<"max_order_notional_minor">>, M), fill_notional_limit),
            Cash = maps:get(cash, S) - Q * Price - Fee,
            ecai_eval_util:require(Cash >= 0, insufficient_paper_cash),
            S#{filled => true, cash => Cash, position => maps:get(position, S) + Q,
               fees => Fee, slippage => abs(Q) * abs(Price - Raw),
               fill => #{<<"time_ms">> => maps:get(<<"time_ms">>, T),
                         <<"signed_quantity">> => Q, <<"price_minor">> => Price}}
    end.
execution_price(M, Q, T) when Q > 0 ->
    A = maps:get(<<"ask_minor">>, T),
    {A + ceil_div(A * maps:get(<<"slippage_bps">>, M), 10000), A};
execution_price(M, _Q, T) ->
    B = maps:get(<<"bid_minor">>, T),
    {max(0, B - ceil_div(B * maps:get(<<"slippage_bps">>, M), 10000)), B}.
liquidation(_M, 0, _T) -> {0, 0, 0};
liquidation(M, Position, T) ->
    {P, Raw} = execution_price(M, -Position, T),
    F = fee(M, abs(Position) * P),
    {Position * P - F, F, abs(Position) * abs(P - Raw)}.
fee(M, N) -> ceil_div(N * maps:get(<<"fee_bps">>, M), 10000).
ceil_div(N, D) -> (N + D - 1) div D.
equity(C, P, T) -> C + P * ((maps:get(<<"bid_minor">>, T) + maps:get(<<"ask_minor">>, T)) div 2).
mark(S, E) ->
    Peak = max(maps:get(peak, S), E),
    DD = ((Peak - E) * 10000) div max(1, Peak),
    S#{peak => Peak, drawdown_bps => max(maps:get(drawdown_bps, S), DD)}.
