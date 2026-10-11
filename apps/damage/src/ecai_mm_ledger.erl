%% Paper-trading accounting. All P&L in USDT, mark-to-market including fees.
-module(ecai_mm_ledger).
-export([new/1, mark/3, replace_quotes/2, paper_fill/3, public/1]).

new(Balances) ->
    #{balances => Balances, opening_equity => undefined,
      opening_btc => undefined, opening_damage => undefined,
      last_equity => undefined, peak_equity => undefined,
      max_drawdown_pct => 0.0, pnl_usdt => 0.0, pnl_pct => 0.0,
      btc_benchmark_pnl_usdt => 0.0, fees_usdt => 0.0,
      turnover_usdt => 0.0, fill_count => 0,
      quotes => [], fills => []}.

replace_quotes(L, Quotes) -> L#{quotes => Quotes}.

%% Paper fills must reference a *currently active* quote, can't overfill, and
%% must be funded. No artificial fills are manufactured from last price alone.
paper_fill(Ledger, Id, Qty) when is_binary(Id), is_number(Qty), Qty > 0 ->
    case [Q || Q <- maps:get(quotes, Ledger, []),
               maps:get(client_id, Q) =:= Id] of
        [Quote] -> apply_fill(Ledger, Quote, Qty);
        [] -> {error, unknown_or_expired_quote}
    end;
paper_fill(_, _, _) -> {error, invalid_fill}.

apply_fill(L, Q, Qty) ->
    Rem = maps:get(remaining_qty, Q),
    Price = maps:get(price, Q),
    FeeBps = maps:get(fee_bps, Q),
    Notional = Price * Qty,
    Fee = Notional * FeeBps / 10000.0,
    B = maps:get(balances, L),
    D = maps:get(damage, B), U = maps:get(usdt, B),
    Side = maps:get(side, Q),
    Sufficient = case Side of
        buy -> U + 1.0e-8 >= Notional + Fee;
        sell -> D + 1.0e-8 >= Qty
    end,
    if
        Qty > Rem + 1.0e-8 -> {error, overfill};
        not Sufficient -> {error, insufficient_paper_inventory};
        true ->
            NextBalances = case Side of
                buy -> B#{damage => D + Qty, usdt => U - Notional - Fee};
                sell -> B#{damage => D - Qty, usdt => U + Notional - Fee}
            end,
            UpdatedQuotes = [
                case maps:get(client_id, X) =:= maps:get(client_id, Q) of
                    true -> X#{remaining_qty => max(0.0, Rem - Qty)};
                    false -> X
                end
             || X <- maps:get(quotes, L)],
            NewQuotes = [X || X <- UpdatedQuotes, maps:get(remaining_qty, X) > 1.0e-8],
            Fill = #{side => Side, price => Price, qty => Qty,
                     fee_usdt => Fee, notional_usdt => Notional,
                     client_id => maps:get(client_id, Q),
                     ts_ms => erlang:system_time(millisecond)},
            Fills = lists:sublist([Fill | maps:get(fills, L)], 50),
            {ok, L#{balances => NextBalances, quotes => NewQuotes,
                    fees_usdt => maps:get(fees_usdt, L) + Fee,
                    turnover_usdt => maps:get(turnover_usdt, L) + Notional,
                    fill_count => maps:get(fill_count, L) + 1,
                    fills => Fills}, Fill}
    end.

mark(L, DamagePx, BtcPx) when DamagePx > 0.0, BtcPx > 0.0 ->
    B = maps:get(balances, L),
    Eq = maps:get(usdt, B) + maps:get(damage, B) * DamagePx,
    Start = case maps:get(opening_equity, L) of
        undefined -> Eq;
        X0 -> X0
    end,
    StartD = case maps:get(opening_damage, L) of
        undefined -> DamagePx;
        X1 -> X1
    end,
    StartB = case maps:get(opening_btc, L) of
        undefined -> BtcPx;
        X2 -> X2
    end,
    Peak = max(Eq, case maps:get(peak_equity, L) of undefined -> Eq; X3 -> X3 end),
    DD = case Peak > 0.0 of
        true -> 100.0 * (Peak - Eq) / Peak;
        false -> 0.0
    end,
    Pnl = Eq - Start,
    PnlPct = case Start > 0 of true -> 100.0 * Pnl / Start; false -> 0.0 end,
    BTCBench = Start * (BtcPx / StartB - 1.0),
    L#{opening_equity => Start, opening_damage => StartD,
       opening_btc => StartB, last_equity => Eq, peak_equity => Peak,
       pnl_usdt => Pnl, pnl_pct => PnlPct,
       btc_benchmark_pnl_usdt => BTCBench,
       max_drawdown_pct => max(maps:get(max_drawdown_pct, L), DD)}.

public(L) ->
    #{balances => maps:get(balances, L),
      opening_equity_usdt => as_json(maps:get(opening_equity, L, undefined)),
      equity_usdt => as_json(maps:get(last_equity, L, undefined)),
      pnl_usdt => maps:get(pnl_usdt, L),
      pnl_pct => maps:get(pnl_pct, L),
      btc_benchmark_pnl_usdt => maps:get(btc_benchmark_pnl_usdt, L),
      max_drawdown_pct => maps:get(max_drawdown_pct, L),
      fees_usdt => maps:get(fees_usdt, L),
      turnover_usdt => maps:get(turnover_usdt, L),
      fill_count => maps:get(fill_count, L),
      fills => lists:reverse(maps:get(fills, L))}.


as_json(undefined) -> null;
as_json(Value) -> Value.
