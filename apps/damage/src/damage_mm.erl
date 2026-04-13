-module(damage_mm).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([where/1, stop/1]).
-export([
    start/0,
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    get_mid_price/2,
    place_order/4,
    fetch_public_book/1,
    fetch_active_orders/1,
    start_ws_ticker/0,
    print_orderbook/1,
    round_up/2
]).
-export([setup_ladders/1]).
-export([get_all_tickers/0]).

-define(HOST, "api.coinstore.com").
-define(PORT, 443).
-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(COIN_WS, "ws.coinstore.com").
-define(COIN_PATH, "/s/ws").

%% IMPORTANT:
%% These should be verified against the actual Coinstore API docs in your env.
%% The point here is to separate PUBLIC DEPTH from PRIVATE ACTIVE ORDERS.
-define(DEFAULT_PUBLIC_DEPTH_PATH, "/api/v1/market/depth").
-define(DEFAULT_ACTIVE_ORDERS_PATH, "/api/v2/trade/order/active").
-define(DEFAULT_PLACE_ORDER_PATH, "/api/trade/order/place").
-define(DEFAULT_CANCEL_BATCH_PATH, "/api/trade/order/cancelBatch").

-define(TICK, 0.0001).
-define(MIN_QTY, 100).
-define(BASE_QTY, 200).

-record(state, {
    symbol :: string(),
    rules :: map(),
    gun_pid,
    stream_ref,
    damage_rate_usdt :: float(),
    public_depth_path :: string(),
    active_orders_path :: string(),
    place_order_path :: string(),
    cancel_batch_path :: string()
}).

start_link(Args) ->
    gen_server:start_link({local, reg_name(Args)}, ?MODULE, Args, []).

reg_name(Args) ->
    Sym = proplists:get_value(symbol, Args, "DAMAGEUSDT"),
    {damage_mm, Sym}.

where(Symbol) when is_list(Symbol) ->
    gproc:whereis_name({n, l, {damage_mm, Symbol}}).

stop(Symbol) when is_list(Symbol) ->
    mm_sup:del(Symbol).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(Args) ->
    Symbol = proplists:get_value(symbol, Args, "DAMAGEUSDT"),
    Rules0 = proplists:get_value(
        rules,
        Args,
        #{
            price_precision => 4,
            min_qty => 100.0,
            %% 1.00%
            max_inside_spread_bp => 100,
            %% ±2.00%
            depth_band_bp => 200
        }
    ),
    Rules = normalize_rules(Rules0),

    PublicDepthPath = proplists:get_value(public_depth_path, Args, ?DEFAULT_PUBLIC_DEPTH_PATH),
    ActiveOrdersPath = proplists:get_value(active_orders_path, Args, ?DEFAULT_ACTIVE_ORDERS_PATH),
    PlaceOrderPath = proplists:get_value(place_order_path, Args, ?DEFAULT_PLACE_ORDER_PATH),
    CancelBatchPath = proplists:get_value(cancel_batch_path, Args, ?DEFAULT_CANCEL_BATCH_PATH),

    ok = gproc:reg({n, l, {damage_mm, Symbol}}),
    ?LOG_INFO("Starting DAMAGE MM for ~s with rules ~p", [Symbol, Rules]),

    {ok, ConnPid} = gun:open(?COIN_WS, 443, #{transport => tls, tls_opts => [{verify, verify_none}]}),
    {ok, _Protocols} = gun:await_up(ConnPid),
    Stream = gun:ws_upgrade(ConnPid, ?COIN_PATH, []),
    ?LOG_DEBUG("damage_mm websocket upgrade successful ~p", [Stream]),

    SubscribeMsg = jsx:encode(#{
        op => <<"subscribe">>,
        args => [#{channel => <<"ticker">>, symbol => list_to_binary(Symbol)}]
    }),
    gun:ws_send(ConnPid, Stream, {text, SubscribeMsg}),

    erlang:send_after(10_000, self(), rebalance),

    {ok, #state{
        gun_pid = ConnPid,
        stream_ref = Stream,
        damage_rate_usdt = 0.0,
        symbol = Symbol,
        rules = Rules,
        public_depth_path = PublicDepthPath,
        active_orders_path = ActiveOrdersPath,
        place_order_path = PlaceOrderPath,
        cancel_batch_path = CancelBatchPath
    }}.

handle_info(
    rebalance,
    State = #state{
        symbol = Symbol,
        rules = Rules
    }
) ->
    ?LOG_DEBUG("damage_mm got rebalance ~p", [State]),
    case get_mid_price(Symbol, Rules) of
        {ok, #{mid := Mid0, best_bid := BestBid, best_ask := BestAsk} = MidInfo} when Mid0 > 0 ->
            LTR = ltr_from_server(),
            Mid1 = apply_ltr_bias(Mid0, LTR),
            Mid = round_tick(Mid1),

            StepBP0 = mm_params:get_intraday_param("STEP_BP", Symbol, 30),
            Levels0 = mm_params:get_intraday_param("LEVELS", Symbol, 8),
            QtySlope0 = mm_params:get_intraday_param("QTY_SLOPE", Symbol, 1.12),
            Budget0 = mm_params:get_intraday_param("BUDGET", Symbol, 500.0),
            RefreshMs0 = mm_params:get_intraday_param("REFRESH_MS", Symbol, 10_000),

            {LevelsBuy, LevelsSell, QtySlopeBuy, QtySlopeSell, BudgetBuy, BudgetSell, RefreshMs} =
                ltr_mm_profile(LTR, Levels0, QtySlope0, Budget0, RefreshMs0),

            ok = cancel_own_ladders(State),

            MaxInsideSpreadBP = maps:get(max_inside_spread_bp, Rules, 100),
            BuyRef = min(Mid, BestBid),
            SellRef = max(Mid, BestAsk),

            BuyStepBP = clamp_step_bp(StepBP0, MaxInsideSpreadBP, LevelsBuy),
            SellStepBP = clamp_step_bp(StepBP0, MaxInsideSpreadBP, LevelsSell),

            BuyL0 = gen_ladder(buy, BuyRef, BuyStepBP, LevelsBuy, QtySlopeBuy),
            SellL0 = gen_ladder(sell, SellRef, SellStepBP, LevelsSell, QtySlopeSell),

            SafeBuy = ensure_non_crossing_buys(BuyL0, BestBid, BestAsk),
            SafeSell = ensure_non_crossing_sells(SellL0, BestBid, BestAsk),

            {PlacedB, CostB} = place_capped(buy, Symbol, SafeBuy, BudgetBuy),
            {PlacedS, CostS} = place_capped(sell, Symbol, SafeSell, BudgetSell),

            DepthBandBP = maps:get(depth_band_bp, Rules, 200),
            BuyDepth = quoted_depth_in_band(buy, Mid, PlacedB, DepthBandBP),
            SellDepth = quoted_depth_in_band(sell, Mid, PlacedS, DepthBandBP),
            SpreadBP = spread_bp(BestBid, BestAsk),

            ?LOG_INFO(
                "Rebalanced @ ~p (LTR=~p) spread_bp=~p; buys ~p (~p USDT depth_in_~pbp=~p), "
                "sells ~p (~p USDT depth_in_~pbp=~p), budget {buy=~p,sell=~p}, refresh=~p ms, mid_info=~p",
                [
                    Mid,
                    LTR,
                    SpreadBP,
                    length(PlacedB),
                    CostB,
                    DepthBandBP,
                    BuyDepth,
                    length(PlacedS),
                    CostS,
                    DepthBandBP,
                    SellDepth,
                    BudgetBuy,
                    BudgetSell,
                    RefreshMs,
                    MidInfo
                ]
            ),
            erlang:send_after(RefreshMs, self(), rebalance),
            {noreply, State};
        Other ->
            ?LOG_WARNING("Skip rebalance, no public mid: ~p", [Other]),
            RefreshMs = mm_params:get_intraday_param("REFRESH_MS", Symbol, 10_000),
            erlang:send_after(RefreshMs, self(), rebalance),
            {noreply, State}
    end;
handle_info(run_strategy, State = #state{symbol = Symbol, rules = Rules}) ->
    case get_mid_price(Symbol, Rules) of
        {ok, #{mid := Mid}} ->
            Qty = 1000,
            Spread = 0.002,
            Bid = Mid - Spread,
            Ask = Mid + Spread,
            place_order(buy, Symbol, round_up(Bid, 4), Qty),
            place_order(sell, Symbol, round_up(Ask, 4), Qty);
        {error, Reason} ->
            io:format("Failed to get mid price: ~p~n", [Reason])
    end,
    {noreply, State};
handle_info({gun_ws, _Conn, _Stream, {text, Msg}}, State = #state{damage_rate_usdt = _Old}) ->
    case safe_decode_json(Msg) of
        #{<<"channel">> := <<"ticker">>, <<"data">> := Data} ->
            case maps:get(<<"lastPrice">>, Data, undefined) of
                undefined ->
                    {noreply, State};
                PriceBin ->
                    Price = to_num(PriceBin),
                    DamageRate = Price / 0.01,
                    {noreply, State#state{damage_rate_usdt = DamageRate}}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({gun_up, _, _}, State) ->
    {noreply, State};
handle_info({gun_down, _Stream, http2, normal, []}, State) ->
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("damage_mm unhandled handle_info ~p ~p", [Info, State]),
    {noreply, State}.

handle_call({convert, Sats}, _From, State = #state{damage_rate_usdt = Rate}) ->
    BTC = Sats / 1.0e8,
    Damage = BTC * Rate,
    {reply, Damage, State};
handle_call(get_rate, _From, State = #state{damage_rate_usdt = Rate}) ->
    {reply, Rate, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(stop, State = #state{gun_pid = Conn, stream_ref = Stream}) ->
    gun:ws_send(Conn, Stream, close),
    {stop, normal, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

normalize_rules(Rules) when is_map(Rules) ->
    Rules;
normalize_rules(Rules) when is_list(Rules) ->
    maps:from_list(Rules).

%% PUBLIC MID MUST COME FROM PUBLIC DEPTH, NOT ACTIVE ACCOUNT ORDERS.
get_mid_price(Symbol, #{price_precision := PricePrecision, min_qty := MinQty}) ->
    case fetch_public_book(Symbol) of
        {ok, #{asks := Asks0, bids := Bids0}} ->
            Asks = [{P, Q} || {P, Q} <- Asks0, Q >= MinQty],
            Bids = [{P, Q} || {P, Q} <- Bids0, Q >= MinQty],
            case {Asks, Bids} of
                {[{BestAsk, _} | _], [{BestBid, _} | _]} when
                    BestAsk > 0, BestBid > 0, BestAsk >= BestBid
                ->
                    Mid0 = (BestAsk + BestBid) / 2,
                    {ok, #{
                        mid => round_up(Mid0, PricePrecision),
                        best_bid => BestBid,
                        best_ask => BestAsk,
                        spread_bp => spread_bp(BestBid, BestAsk),
                        symbol => Symbol
                    }};
                _ ->
                    {error, no_liquidity}
            end;
        Error ->
            Error
    end.

fetch_public_book(Symbol) ->
    Path = build_public_depth_path(Symbol),
    public_get_json(Path).

fetch_active_orders(Symbol) ->
    Params = "?symbol=" ++ uri_string:quote(Symbol),
    {_Expires, _SignatureHex, Headers} = get_sign(""),
    Path = ?DEFAULT_ACTIVE_ORDERS_PATH ++ Params,
    auth_get_json(Path, Headers).

print_orderbook(Symbol) ->
    case fetch_public_book(Symbol) of
        {ok, Book} ->
            ?LOG_INFO("Public orderbook : ~p", [Book]),
            Book;
        Error ->
            ?LOG_INFO("Orderbook error: ~p", [Error]),
            Error
    end.

build_public_depth_path(Symbol) ->
    ?DEFAULT_PUBLIC_DEPTH_PATH ++ "?symbol=" ++ uri_string:quote(Symbol).

public_get_json(Path) ->
    with_conn(
        fun(ConnPid) ->
            StreamRef = gun:get(ConnPid, Path, #{}),
            case await_json(ConnPid, StreamRef) of
                {ok, Json} ->
                    normalize_public_book(Json);
                Error ->
                    Error
            end
        end
    ).

auth_get_json(Path, Headers) ->
    with_conn(
        fun(ConnPid) ->
            StreamRef = gun:get(ConnPid, Path, Headers),
            await_json(ConnPid, StreamRef)
        end
    ).

with_conn(Fun) ->
    {ok, ConnPid} = gun:open(?HOST, ?PORT, #{tls_opts => [{verify, verify_none}]}),
    try
        {ok, _Protocol} = gun:await_up(ConnPid),
        Fun(ConnPid)
    after
        catch gun:close(ConnPid)
    end.

await_json(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, Status, _Headers} ->
            {error, {empty_response, Status}};
        {response, nofin, Status, _Headers} ->
            case gun:await_body(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
                {ok, Body} ->
                    {ok, safe_decode_json(Body)};
                Error ->
                    {error, {body_error, Status, Error}}
            end;
        Other ->
            {error, {unexpected_http, Other}}
    end.

safe_decode_json(Body) when is_binary(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Decoded ->
            Decoded
    catch
        _:_ ->
            #{raw => Body}
    end;
safe_decode_json(Other) ->
    Other.

normalize_public_book(#{<<"data">> := Data}) ->
    normalize_public_book(Data);
normalize_public_book(#{<<"asks">> := Asks0, <<"bids">> := Bids0}) ->
    {ok, #{
        asks => sort_asks(normalize_levels(Asks0)),
        bids => sort_bids(normalize_levels(Bids0))
    }};
normalize_public_book(#{<<"a">> := Asks0, <<"b">> := Bids0}) ->
    {ok, #{
        asks => sort_asks(normalize_levels(Asks0)),
        bids => sort_bids(normalize_levels(Bids0))
    }};
normalize_public_book(Other) ->
    {error, {unknown_public_book_shape, Other}}.

normalize_levels(Levels) when is_list(Levels) ->
    lists:filtermap(
        fun(Level) ->
            case normalize_level(Level) of
                {ok, PQ} -> {true, PQ};
                error -> false
            end
        end,
        Levels
    );
normalize_levels(_) ->
    [].

normalize_level([P0, Q0 | _]) ->
    {ok, {to_num(P0), to_num(Q0)}};
normalize_level(#{<<"price">> := P0, <<"qty">> := Q0}) ->
    {ok, {to_num(P0), to_num(Q0)}};
normalize_level(#{<<"ordPrice">> := P0, <<"leavesQty">> := Q0}) ->
    {ok, {to_num(P0), to_num(Q0)}};
normalize_level(_) ->
    error.

sort_asks(Levels) ->
    lists:sort(fun({P1, _}, {P2, _}) -> P1 =< P2 end, Levels).

sort_bids(Levels) ->
    lists:sort(fun({P1, _}, {P2, _}) -> P1 >= P2 end, Levels).

to_num(N) when is_integer(N) -> N * 1.0;
to_num(N) when is_float(N) -> N;
to_num(Bin) when is_binary(Bin) ->
    Str = binary_to_list(Bin),
    case string:to_float(Str) of
        {error, no_float} ->
            case string:to_integer(Str) of
                {I, _} -> I * 1.0;
                _ -> 0.0
            end;
        {F, _} ->
            F
    end;
to_num(List) when is_list(List) ->
    to_num(list_to_binary(List));
to_num(_) ->
    0.0.

round_up(Price, Prec) ->
    Factor = math:pow(10, Prec),
    erlang:ceil(Price * Factor) / Factor.

spread_bp(Bid, Ask) when Bid > 0, Ask > 0, Ask >= Bid ->
    ((Ask - Bid) / ((Ask + Bid) / 2.0)) * 10000.0;
spread_bp(_, _) ->
    999999.0.

gen_ladder(Side, Mid, StepBP, Levels, QtySlope) ->
    Sign =
        case Side of
            buy -> -1;
            sell -> 1
        end,
    lists:map(
        fun(K) ->
            P0 = Mid * (1.0 + Sign * (StepBP * K) / 10000.0),
            P =
                case Side of
                    buy -> floor_tick(P0);
                    sell -> ceil_tick(P0)
                end,
            Qty0 = ?BASE_QTY * math:pow(QtySlope, K - 1),
            Qty = max(?MIN_QTY, round(Qty0)),
            {P, Qty}
        end,
        lists:seq(1, max(1, Levels))
    ).

clamp_step_bp(StepBP, MaxInsideSpreadBP, Levels) when Levels > 0 ->
    min(StepBP, max(1, MaxInsideSpreadBP div Levels));
clamp_step_bp(StepBP, _MaxInsideSpreadBP, _Levels) ->
    StepBP.

ensure_non_crossing_buys(Levels, _BestBid, BestAsk) ->
    [{floor_tick(min(P, BestAsk - ?TICK)), Q} || {P, Q} <- Levels, P < BestAsk].

ensure_non_crossing_sells(Levels, BestBid, _BestAsk) ->
    [{ceil_tick(max(P, BestBid + ?TICK)), Q} || {P, Q} <- Levels, P > BestBid].

place_capped(Side, Symbol, Levels, BudgetUSDT) ->
    place_capped(Side, Symbol, Levels, BudgetUSDT, 0.0, []).

place_capped(_Side, _Symbol, [], _Budget, Spent, Acc) ->
    {lists:reverse(Acc), Spent};
place_capped(Side, Symbol, [{P, Q} | T], Budget, Spent, Acc) ->
    Notional = P * Q,
    case Spent + Notional =< Budget of
        true ->
            _ = place_order(Side, Symbol, P, Q),
            place_capped(Side, Symbol, T, Budget, Spent + Notional, [{P, Q} | Acc]);
        false ->
            {lists:reverse(Acc), Spent}
    end.

quoted_depth_in_band(Side, Mid, Levels, BandBP) ->
    Limit =
        case Side of
            buy -> Mid * (1.0 - BandBP / 10000.0);
            sell -> Mid * (1.0 + BandBP / 10000.0)
        end,
    lists:sum(
        [
            P * Q
         || {P, Q} <- Levels,
            case Side of
                buy -> P >= Limit andalso P =< Mid;
                sell -> P =< Limit andalso P >= Mid
            end
        ]
    ).

place_order(Side, Symbol, Price0, Qty) ->
    Price = round_up(Price0, 4),
    Timestamp = integer_to_binary(os:system_time(millisecond)),
    SideStr = string:to_upper(atom_to_list(Side)),
    BodyMap = #{
        <<"symbol">> => list_to_binary(Symbol),
        <<"side">> => list_to_binary(SideStr),
        <<"ordType">> => <<"LIMIT">>,
        <<"ordQty">> => Qty,
        <<"ordPrice">> => Price,
        <<"timestamp">> => Timestamp
    },
    BodyJSON = jsx:encode(BodyMap),
    {_Expires, _SignatureHex, Headers} = get_sign(BodyMap),
    with_conn(
        fun(ConnPid) ->
            ?LOG_INFO("Place order ~p", [BodyJSON]),
            StreamRef = gun:post(ConnPid, ?DEFAULT_PLACE_ORDER_PATH, Headers, BodyJSON),
            case await_json(ConnPid, StreamRef) of
                {ok, Response} ->
                    ?LOG_DEBUG("Got order response for ~p ~p ~p ~p", [Side, Price, Qty, Response]),
                    Response;
                Error ->
                    ?LOG_WARNING("Place order failed ~p", [Error]),
                    Error
            end
        end
    ).

get_sign(Params) when is_map(Params) ->
    prepare_signature(jsx:encode(Params));
get_sign(Params) when is_list(Params) ->
    prepare_signature(Params).

prepare_signature(Payload0) ->
    Expires = erlang:system_time(millisecond),
    ExpiresKey = integer_to_binary(Expires div 30000),
    {ok, SecretKey} = secrets:retrieve_decrypt(coinstore_api_secret),
    HmacKey = crypto:mac(hmac, sha256, SecretKey, ExpiresKey),
    HexKey = list_to_binary([io_lib:format("~2.16.0b", [B]) || B <- binary:bin_to_list(HmacKey)]),

    SignatureBin = crypto:mac(hmac, sha256, HexKey, Payload0),
    SignatureHex = list_to_binary([
        io_lib:format("~2.16.0b", [B])
     || B <- binary:bin_to_list(SignatureBin)
    ]),
    {ok, ApiKey} = secrets:retrieve_decrypt(coinstore_api_key),
    Headers = #{
        <<"X-CS-APIKEY">> => ApiKey,
        <<"X-CS-EXPIRES">> => integer_to_binary(Expires),
        <<"X-CS-SIGN">> => SignatureHex,
        <<"content-type">> => <<"application/json">>
    },
    {Expires, SignatureHex, Headers}.

start_ws_ticker() ->
    {ok, ConnPid} = gun:open("stream.coinstore.com", 443, #{transport => tls}),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:ws_upgrade(ConnPid, "/market"),
    receive
        {gun_upgrade, ConnPid, StreamRef, [_, _]} ->
            io:format("WebSocket connected for ticker~n"),
            Sub = jsx:encode(#{
                method => <<"SUBSCRIBE">>,
                params => [<<"DAMAGEUSDT@ticker">>],
                id => 1
            }),
            gun:ws_send(ConnPid, {text, Sub}),
            loop_ws_ticker(ConnPid, StreamRef)
    end.

loop_ws_ticker(ConnPid, StreamRef) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case safe_decode_json(Msg) of
                #{<<"c">> := Price} ->
                    io:format("Live Ticker: ~p~n", [Price]);
                Other ->
                    io:format("WS Event: ~p~n", [Other])
            end,
            loop_ws_ticker(ConnPid, StreamRef);
        Other ->
            io:format("WS Event: ~p~n", [Other]),
            loop_ws_ticker(ConnPid, StreamRef)
    end.

setup_ladders(Symbol) ->
    {ok, {damage_mm, Pid, worker, []}} = supervisor:which_child(damage_sup, damage_mm),
    Pid ! rebalance,
    RefreshMs = mm_params:get_intraday_param("REFRESH_MS", Symbol, 10_000),
    erlang:send_after(RefreshMs, self(), rebalance),
    ok.

get_all_tickers() ->
    Path = "/v1/market/tickers",
    public_get_json(Path).

round_tick(X) -> float(trunc(X / ?TICK) * ?TICK).
floor_tick(X) -> float(trunc(X / ?TICK) * ?TICK).
ceil_tick(X) ->
    case X / ?TICK of
        V when V =:= trunc(V) -> float(V * ?TICK);
        V -> float((trunc(V) + 1) * ?TICK)
    end.

ltr_from_server() ->
    try
        liquidity_ltr_server:get_ltr()
    catch
        _:_ -> undefined
    end.

apply_ltr_bias(Mid0, undefined) ->
    Mid0;
apply_ltr_bias(Mid0, LTR) when is_number(LTR) ->
    Mult =
        case LTR of
            V when V < 30 -> 1.08;
            V when V < 50 -> 1.04;
            V when V < 70 -> 1.00;
            V when V < 85 -> 0.97;
            _ -> 0.94
        end,
    Mid0 * Mult.

ltr_mm_profile(undefined, Levels0, QtySlope0, Budget0, Refresh0) ->
    {Levels0, Levels0, QtySlope0, QtySlope0, Budget0 / 2, Budget0 / 2, Refresh0};
ltr_mm_profile(LTR, Levels0, QtySlope0, Budget0, Refresh0) when is_number(LTR) ->
    case LTR of
        V when V < 30 ->
            {
                trunc(Levels0 * 1.3),
                trunc(Levels0 * 0.7),
                QtySlope0 * 1.10,
                max(1.0, QtySlope0 * 0.95),
                Budget0 * 0.70,
                Budget0 * 0.30,
                max(2_000, Refresh0 div 2)
            };
        V when V < 50 ->
            {
                trunc(Levels0 * 1.15),
                trunc(Levels0 * 0.9),
                QtySlope0 * 1.05,
                QtySlope0,
                Budget0 * 0.60,
                Budget0 * 0.40,
                max(3_000, Refresh0 * 3 div 4)
            };
        V when V < 70 ->
            {Levels0, Levels0, QtySlope0, QtySlope0, Budget0 / 2, Budget0 / 2, Refresh0};
        V when V < 85 ->
            {
                trunc(Levels0 * 0.9),
                trunc(Levels0 * 1.15),
                QtySlope0,
                QtySlope0 * 1.05,
                Budget0 * 0.40,
                Budget0 * 0.60,
                Refresh0
            };
        _ ->
            {
                trunc(Levels0 * 0.7),
                trunc(Levels0 * 1.3),
                max(1.0, QtySlope0 * 0.95),
                QtySlope0 * 1.10,
                Budget0 * 0.30,
                Budget0 * 0.70,
                Refresh0
            }
    end.

cancel_own_ladders(State = #state{symbol = Symbol}) ->
    case fetch_active_orders(Symbol) of
        {ok, #{<<"data">> := Orders}} when is_list(Orders) ->
            OrderIds = [maps:get(<<"ordId">>, O) || O <- Orders, maps:is_key(<<"ordId">>, O)],
            cancel_orders_batch(State, Symbol, OrderIds);
        {ok, Orders} when is_list(Orders) ->
            OrderIds = [maps:get(<<"ordId">>, O) || O <- Orders, maps:is_key(<<"ordId">>, O)],
            cancel_orders_batch(State, Symbol, OrderIds);
        _ ->
            ok
    end.

cancel_orders_batch(_State, _Symbol, []) ->
    ok;
cancel_orders_batch(#state{cancel_batch_path = Path}, Symbol, OrderIds) ->
    BodyMap = #{
        <<"symbol">> => list_to_binary(Symbol),
        <<"orderIds">> => OrderIds
    },
    BodyJSON = jsx:encode(BodyMap),
    {_Expires, _SignatureHex, Headers} = get_sign(BodyMap),
    with_conn(
        fun(ConnPid) ->
            ?LOG_INFO("Cancel batch orders for ~s: ~p", [Symbol, OrderIds]),
            StreamRef = gun:post(ConnPid, Path, Headers, BodyJSON),
            case await_json(ConnPid, StreamRef) of
                {ok, _Resp} ->
                    ok;
                Error ->
                    ?LOG_WARNING("cancelBatch failed: ~p", [Error]),
                    ok
            end
        end
    ).
