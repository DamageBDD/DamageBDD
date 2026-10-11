%% Copyright (c) ECAI contributors. Apache-2.0.
%% Deterministic inventory-sensitive quotes, and P-256 state fingerprints.
%% An EC point is a cryptographic index/commitment, NOT a forecast or a proof
%% that the input market data was authentic.
-module(ecai_mm_curve).
-export([defaults/0, quotes/3, state_point/1, chain_event/2, hex/1]).

-define(P256_ORDER, 16#FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551).

defaults() ->
    #{symbol => <<"DAMAGEUSDT">>, levels => 4,
      tick_size => 0.00000001, lot_size => 1.0, min_qty => 1.0,
      min_notional => 5.0, max_order_notional => 35.0,
      max_side_notional => 150.0, base_half_spread_bps => 30.0,
      level_step_bps => 20.0, maker_fee_bps => 10.0,
      fee_buffer_bps => 4.0, volatility_weight => 0.75,
      max_skew_bps => 60.0, target_inventory_ratio => 0.50,
      max_inventory_ratio => 0.85}.

%% Book contains bid, ask, btc_usdt and volatility_bps. Balances are free
%% paper funds; orders are constrained by available assets, not 'budget' only.
quotes(Book, Balances, Config) when is_map(Book), is_map(Balances), is_map(Config) ->
    C = maps:merge(defaults(), Config),
    try
        Bid = numeric(maps:get(bid, Book)),
        Ask = numeric(maps:get(ask, Book)),
        BTC = numeric(maps:get(btc_usdt, Book)),
        Damage = numeric(maps:get(damage, Balances, 0.0)),
        Usdt = numeric(maps:get(usdt, Balances, 0.0)),
        Tick = numeric(maps:get(tick_size, C)),
        Lot = numeric(maps:get(lot_size, C)),
        MinQty = numeric(maps:get(min_qty, C)),
        MinNotional = numeric(maps:get(min_notional, C)),
        MaxOrder = numeric(maps:get(max_order_notional, C)),
        MaxSide = numeric(maps:get(max_side_notional, C)),
        Levels = maps:get(levels, C),
        true = is_integer(Levels) andalso Levels >= 1 andalso Levels =< 16,
        true = Bid > 0.0 andalso Ask > Bid andalso BTC > 0.0,
        true = Tick > 0.0 andalso Lot > 0.0 andalso MinQty >= 0.0,
        true = MinNotional >= 0.0 andalso MaxOrder >= MinNotional,
        true = MaxSide > 0.0 andalso Damage >= 0.0 andalso Usdt >= 0.0,
        Mid = (Bid + Ask) / 2.0,
        Equity = Usdt + Damage * Mid,
        Ratio = case Equity > 0 of true -> Damage * Mid / Equity; false -> 0.5 end,
        Target = numeric(maps:get(target_inventory_ratio, C)),
        MaxRatio = numeric(maps:get(max_inventory_ratio, C)),
        true = Target > 0.0 andalso Target < MaxRatio andalso MaxRatio < 1.0,
        Imbalance = clamp((Ratio - Target) / (MaxRatio - Target), -1.0, 1.0),
        SkewBps = Imbalance * numeric(maps:get(max_skew_bps, C)),
        Reservation = Mid * (1.0 - SkewBps / 10000.0),
        Vol = max(0.0, numeric(maps:get(volatility_bps, Book, 0.0))),
        Base = numeric(maps:get(base_half_spread_bps, C)),
        FeeFloor = numeric(maps:get(maker_fee_bps, C)) +
                   numeric(maps:get(fee_buffer_bps, C)),
        HalfBps = max(Base, FeeFloor) + Vol * numeric(maps:get(volatility_weight, C)),
        Step = numeric(maps:get(level_step_bps, C)),
        true = HalfBps > 0.0 andalso Step > 0.0,
        %% Post-only constraint: quotes must be strictly outside opposite top.
        %% Tick rounding is integer based; never quantize through the spread.
        Buys = make_side(buy, Levels, Reservation, HalfBps, Step, Bid, Ask,
                         Tick, Lot, MinQty, MinNotional, MaxOrder,
                         min(Usdt / (1.0 + numeric(maps:get(maker_fee_bps, C)) / 10000.0),
                             MaxSide), C),
        Sells = make_side(sell, Levels, Reservation, HalfBps, Step, Bid, Ask,
                          Tick, Lot, MinQty, MinNotional, MaxOrder,
                          min(Damage * Bid, MaxSide), C),
        {ok, #{quotes => Buys ++ Sells, mid => Mid,
               reservation => Reservation, inventory_ratio => Ratio,
               skew_bps => SkewBps, half_spread_bps => HalfBps}}
    catch
        _:_ -> {error, invalid_market_or_config}
    end;
quotes(_, _, _) -> {error, invalid_market_or_config}.

make_side(Side, Levels, R, Half, Step, Bid, Ask, Tick, Lot,
          MinQty, MinNotional, MaxOrder, Budget, C) ->
    make_side(Side, lists:seq(0, Levels - 1), R, Half, Step, Bid, Ask,
              Tick, Lot, MinQty, MinNotional, MaxOrder, Budget, C, []).

make_side(_, [], _, _, _, _, _, _, _, _, _, _, _, _, Acc) ->
    lists:reverse(Acc);
make_side(Side, [K | Rest], R, Half, Step, Bid, Ask, Tick, Lot,
          MinQty, MinNotional, MaxOrder, Remaining, C, Acc) ->
    Offset = (Half + K * Step) / 10000.0,
    Raw = case Side of buy -> R * (1.0 - Offset); sell -> R * (1.0 + Offset) end,
    %% Do not join/cross the opposite touch; keep at least one tick away.
    Px = case Side of
        buy -> min(tick_down(Raw, Tick), tick_down(Ask - Tick, Tick));
        sell -> max(tick_up(Raw, Tick), tick_up(Bid + Tick, Tick))
    end,
    Eligible = Px > 0.0 andalso (Side =/= buy orelse Px < Ask) andalso
               (Side =/= sell orelse Px > Bid),
    WantNotional = min(MaxOrder, Remaining),
    Qty = if Eligible -> lot_down(WantNotional / Px, Lot); true -> 0.0 end,
    CanPlace = Qty >= MinQty andalso Qty * Px >= MinNotional andalso
               Qty * Px =< Remaining + 1.0e-8,
    case CanPlace of
        false -> Acc0 = Acc, Left = Remaining;
        true ->
            Q = #{side => Side, level => K + 1, price => Px, qty => Qty,
                  symbol => maps:get(symbol, C)},
            Acc0 = [Q | Acc], Left = max(0.0, Remaining - Qty * Px)
    end,
    make_side(Side, Rest, R, Half, Step, Bid, Ask, Tick, Lot,
              MinQty, MinNotional, MaxOrder, Left, C, Acc0).

tick_down(X, Tick) -> erlang:floor(X / Tick + 1.0e-10) * Tick.
tick_up(X, Tick) -> erlang:ceil(X / Tick - 1.0e-10) * Tick.
lot_down(X, Lot) -> erlang:floor(X / Lot + 1.0e-10) * Lot.
clamp(V, A, B) -> max(A, min(B, V)).
numeric(V) when is_integer(V) -> float(V);
numeric(V) when is_float(V) -> V.

%% Canonical hashing independent of Erlang map insertion order. A P-256 point
%% is H(state)*G with a legal nonzero scalar. This is *not* a hiding commitment.
state_point(State) ->
    Hash = crypto:hash(sha256, term_to_binary(State, [deterministic])),
    <<N:256/unsigned-big>> = Hash,
    S = (N rem (?P256_ORDER - 1)) + 1,
    {Point, _Priv} = crypto:generate_key(ecdh, prime256v1, <<S:256/unsigned-big>>),
    Point.

chain_event(PrevHash, Event) when is_binary(PrevHash), byte_size(PrevHash) =:= 32 ->
    Payload = term_to_binary(Event, [deterministic]),
    Digest = crypto:hash(sha256, <<PrevHash/binary, Payload/binary>>),
    #{digest => Digest, digest_hex => hex(Digest),
      curve => <<"P-256">>, state_point_hex => hex(state_point({PrevHash, Event}))}.

hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [X]) || <<X>> <= Bin]).
