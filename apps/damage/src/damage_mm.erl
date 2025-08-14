-module(damage_mm).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([
    start/0,
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    get_mid_price/0,
    place_order/3,
    fetch_order_book/1,
    start_ws_ticker/0,
    print_orderbook/0,
    round_up/2
]).
-export([setup_ladders/0]).
-export([get_all_tickers/0]).

-define(HOST, "api.coinstore.com").
-define(PORT, 443).
-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(COIN_WS, "ws.coinstore.com").
-define(COIN_PATH, "/s/ws").
-define(SYMBOL, <<"BTCUSDT">>).

%% ---- params you can tune ----------------------------------

%% exchange price tick
-define(TICK, 0.0001).
%% exchange min order size (adjust!)
-define(MIN_QTY, 100).
%% levels each side
-define(LEVELS, 10).
%% 40 bps (=0.40%) between levels
-define(STEP_BP, 40).
%% size of 1st level
-define(BASE_QTY, 200).
%% grows by 12% each level out
-define(QTY_SLOPE, 1.12).
%% max notional per refresh (buy+sells)
-define(USDT_BUDGET, 1500.0).
%% rebalance every 60s
-define(REFRESH_MS, 60_000).
%% -----------------------------------------------------------

-record(state, {
    gun_pid,
    stream_ref,
    %% float
    damage_rate_usdt
}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    io:format("Starting DAMAGE market maker...~n"),
    %self() ! run_strategy,
    {ok, ConnPid} = gun:open(?COIN_WS, 443, #{transport => tls, tls_opts => [{verify, verify_none}]}),
    {ok, _Protocols} = gun:await_up(ConnPid),
    Stream = gun:ws_upgrade(ConnPid, ?COIN_PATH, []),
    ?LOG_DEBUG("damage_mm websocket upgrade successfull ~p", [Stream]),
    %% Subscribe JSON; check Coinstore docs for exact format
    SubscribeMsg = jsx:encode(#{
        op => <<"subscribe">>, args => [#{channel => <<"ticker">>, symbol => ?SYMBOL}]
    }),
    gun:ws_send(ConnPid, Stream, {text, SubscribeMsg}),
    State = #state{gun_pid = ConnPid, stream_ref = Stream, damage_rate_usdt = 0.0},
    {ok, State}.

handle_info(rebalance, State) ->
    ?LOG_DEBUG("damage_mm got rebalance ~p", [State]),
    case get_mid_price() of
        {ok, Mid0} when Mid0 > 0 ->
            Mid = round_tick(Mid0),
            BuyL = gen_ladder(buy, Mid),
            SellL = gen_ladder(sell, Mid),

            %% (optional) add a tiny guard so we never cross the book
            SafeBuy = [{min(P, Mid * 0.999), Q} || {P, Q} <- BuyL],
            SafeSell = [{max(P, Mid * 1.001), Q} || {P, Q} <- SellL],

            {PlacedB, CostB} = place_capped(buy, SafeBuy, ?USDT_BUDGET / 2),
            {PlacedS, CostS} = place_capped(sell, SafeSell, ?USDT_BUDGET / 2),
            ?LOG_INFO(
                "Rebalanced @ ~p; buys ~p (~p USDT), sells ~p (~p USDT)",
                [Mid, length(PlacedB), CostB, length(PlacedS), CostS]
            );
        Other ->
            ?LOG_INFO("Skip rebalance, no mid: ~p", [Other])
    end,
    erlang:send_after(?REFRESH_MS, self(), rebalance),
    {noreply, State};
handle_info(run_strategy, State) ->
    case get_mid_price() of
        {ok, Mid} ->
            Qty = 1000,
            Spread = 0.002,
            Bid = Mid - Spread,
            Ask = Mid + Spread,
            place_order(buy, round_up(Bid, 4), Qty),
            place_order(sell, round_up(Ask, 4), Qty);
        {error, Reason} ->
            io:format("Failed to get mid price: ~p~n", [Reason])
    end,
    {noreply, State};
handle_info({gun_ws, _Conn, _Stream, {text, Msg}}, State = #state{damage_rate_usdt = _Old}) ->
    case jsx:decode(Msg, [return_maps]) of
        #{<<"channel">> := <<"ticker">>, <<"data">> := Data} ->
            case maps:get(<<"lastPrice">>, Data, undefined) of
                undefined ->
                    {noreply, State};
                PriceBin ->
                    Price = list_to_float(binary_to_list(PriceBin)),
                    DamageRate = Price / 0.01,
                    {noreply, State#state{damage_rate_usdt = DamageRate}}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({gun_up, _, _}, State) ->
    {noreply, State};
handle_info({gun_down, _Stream, http2, normal, []}, State) ->
    %% Could trigger reconnect logic here
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("unhandled handle_info ~p ~p", [Info, State]),
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
%% Expect application env like:
%% {market_rules, #{
%%     <<"DAMAGEUSDT">> => #{price_precision => 4, min_qty => 100.0}
%% }}.

get_mid_price() ->
    Symbol = "DAMAGEUSDT",
    {PricePrec, MinQty} = get_rules(Symbol),
    case fetch_order_book(Symbol) of
        {ok, Orders} when is_list(Orders) ->
            %% filter by available quantity
            Asks = [
                to_num(maps:get(<<"ordPrice">>, O))
             || O <- Orders,
                maps:get(<<"side">>, O, <<>>) =:= <<"SELL">>,
                to_num(maps:get(<<"leavesQty">>, O, <<"0">>)) >= MinQty
            ],
            Bids = [
                to_num(maps:get(<<"ordPrice">>, O))
             || O <- Orders,
                maps:get(<<"side">>, O, <<>>) =:= <<"BUY">>,
                to_num(maps:get(<<"leavesQty">>, O, <<"0">>)) >= MinQty
            ],
            case {Asks, Bids} of
                {[_ | _], [_ | _]} ->
                    BestAsk = lists:min(Asks),
                    BestBid = lists:max(Bids),
                    Mid0 = (BestAsk + BestBid) / 2,
                    %% avoid 3105
                    {ok, round_up(Mid0, PricePrec)};
                _ ->
                    {error, no_liquidity}
            end;
        Error ->
            Error
    end.

%% ---------- helpers ----------

get_rules(Symbol) ->
    case application:get_env(damage, market_rules) of
        {ok, Rules} ->
            MR = maps:get(list_to_binary(Symbol), Rules, #{}),
            Prec = maps:get(price_precision, MR, 4),
            MinQ = maps:get(min_qty, MR, 1.0),
            {Prec, MinQ};
        _ ->
            %% sane defaults; override via app env
            {4, 100.0}
    end.

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
    end.

fetch_order_book(Symbol) ->
    _Params = "?symbol=" ++ Symbol,
    {_Expires, _SignatureHex, Headers} = get_sign(""),
    Path = "/api/v2/trade/order/active",
    ?LOG_INFO("path ~p", [Path]),
    {ok, ConnPid} = gun:open(?HOST, ?PORT, #{tls_opts => [{verify, verify_none}]}),
    {ok, _Protocol} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, Path, Headers),
    Response =
        case gun:await(ConnPid, StreamRef) of
            {response, fin, _Status, _Headers0} ->
                no_data;
            {response, nofin, _Status, _Headers0} ->
                {ok, Body} = gun:await_body(ConnPid, StreamRef),
                Body
        end,
    #{<<"code">> := 0, <<"data">> := Data} =
        jsx:decode(Response, [return_maps]),

    {ok, Data}.
round_up(Price, Prec) ->
    Factor = math:pow(10, Prec),
    erlang:ceil(Price * Factor) / Factor.

place_order(Side, Price0, Qty) ->
    Price = round_up(Price0, 4),
    Timestamp = integer_to_binary(os:system_time(millisecond)),
    SideStr = string:to_upper(atom_to_list(Side)),
    BodyMap = #{
        <<"symbol">> => <<"DAMAGEUSDT">>,
        <<"side">> => list_to_binary(SideStr),
        <<"ordType">> => <<"LIMIT">>,
        <<"ordQty">> => Qty,
        <<"ordPrice">> => Price,
        <<"timestamp">> => Timestamp
    },
    BodyJSON = jsx:encode(BodyMap),
    {_Expires, _SignatureHex, Headers} = get_sign(BodyMap),
    {ok, ConnPid} = gun:open(?HOST, ?PORT, #{tls_opts => [{verify, verify_none}]}),
    {ok, _Protocol} = gun:await_up(ConnPid),
    ?LOG_INFO("Place order ~p", [BodyJSON]),
    StreamRef = gun:post(ConnPid, "/api/trade/order/place", Headers, BodyJSON),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
            {response, fin, Status, _RespHeaders} ->
                ?LOG_DEBUG("Got fin ~p", [Status]),
                no_data;
            {response, nofin, _Status, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            Default ->
                ?LOG_DEBUG("Got unknown ~p ", [Default])
        end,
    ?LOG_DEBUG("Got order response for ~p ~p ~p ~p", [Side, Price, Qty, Response]),
    jsx:decode(Response, [return_maps, {labels, atom}]).

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

    ?LOG_INFO("Sign payload ~p", [Payload0]),
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
    ?LOG_INFO("Signature ~p Header ~p", [SignatureHex, Headers]),
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
            case jsx:decode(Msg, [return_maps]) of
                {ok, Map} ->
                    Price = maps:get(<<"c">>, Map, <<"n/a">>),
                    io:format("Live Ticker: ~p~n", [Price]);
                _ ->
                    ok
            end,
            loop_ws_ticker(ConnPid, StreamRef);
        Other ->
            io:format("WS Event: ~p~n", [Other]),
            loop_ws_ticker(ConnPid, StreamRef)
    end.
print_orderbook() ->
    case fetch_order_book("DAMAGEUSDT") of
        #{
            <<"code">> := 0,
            <<"data">> := Orders
        } ->
            ?LOG_INFO("Orderbook : ~p", [jsx:encode(Orders)]);
        Error ->
            ?LOG_INFO("Orderbook error: ~p", [Error]),
            Error
    end.
setup_ladders() ->
    %% kick off periodic rebalancing
    {ok, {damage_mm, Pid, worker, []}} = supervisor:which_child(damage_sup, damage_mm),
    Pid ! rebalance,
    erlang:send_after(?REFRESH_MS, self(), rebalance),
    ok.

get_all_tickers() ->
    Path = "/v1/market/tickers",
    {ok, ConnPid} = gun:open(?HOST, ?PORT, #{tls_opts => [{verify, verify_none}]}),
    {ok, _Protocol} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, Path, #{}),
    Response =
        case gun:await(ConnPid, StreamRef) of
            {response, nofin, _Status, _Headers} ->
                {ok, Body} = gun:await_body(ConnPid, StreamRef),
                jsx:decode(Body, [return_maps]);
            {response, fin, _Status, _Headers} ->
                no_data
        end,
    gun:close(ConnPid),
    Response.
%% ------- ladder generation --------------------------------

gen_ladder(Side, Mid) ->
    Sign =
        case Side of
            buy -> -1;
            sell -> 1
        end,
    lists:map(
        fun(K) ->
            %% price step in bps from mid
            P0 = Mid * (1.0 + Sign * (?STEP_BP * K) / 10000.0),
            P =
                (case Side of
                    %% be conservative on buys
                    buy -> floor_tick(P0);
                    sell -> ceil_tick(P0)
                end),
            Qty0 = ?BASE_QTY * math:pow(?QTY_SLOPE, K - 1),
            Qty = max(?MIN_QTY, round(Qty0)),
            {P, Qty}
        end,
        lists:seq(1, ?LEVELS)
    ).

place_capped(Side, Levels, BudgetUSDT) ->
    place_capped(Side, Levels, BudgetUSDT, 0.0, []).

place_capped(_Side, [], _Budget, Spent, Acc) ->
    {lists:reverse(Acc), Spent};
place_capped(Side, [{P, Q} | T], Budget, Spent, Acc) ->
    Notional = P * Q,
    case Spent + Notional =< Budget of
        true ->
            _ = place_order(Side, P, Q),
            place_capped(Side, T, Budget, Spent + Notional, [{P, Q} | Acc]);
        false ->
            {lists:reverse(Acc), Spent}
    end.

%% ------- tick helpers -------------------------------------
round_tick(X) -> float(trunc(X / ?TICK) * ?TICK).
floor_tick(X) ->
    float((trunc(X / ?TICK)) * ?TICK).
ceil_tick(X) ->
    case X / ?TICK of
        V when V =:= trunc(V) -> float(V * ?TICK);
        V -> float((trunc(V) + 1) * ?TICK)
    end.
