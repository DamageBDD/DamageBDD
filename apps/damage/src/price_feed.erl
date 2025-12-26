-module(price_feed).
-behaviour(gen_server).

%% API
-export([start_link/0, get_prices/0]).

-export([sats_to_damage/1]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

% 10 minutes in milliseconds
-define(INTERVAL, 10 * 60 * 1000).

-record(state, {
    %% keep existing (BTC/AUD) if you still want it
    price = undefined :: undefined | float(),
    btc_usdt = undefined :: undefined | float(),
    damage_usdt = undefined :: undefined | float(),
    updated_ms = 0 :: non_neg_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_prices() ->
    gen_server:call(?MODULE, get_price).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! fetch,
    {ok, #state{}}.

handle_info(fetch, State) ->
    NewState2 =
        case fetch_coinstore_prices() of
            {ok, #{btc_usdt := BTCUSDT, damage_usdt := DamageUSDT}} ->
                State#state{
                    btc_usdt = BTCUSDT,
                    damage_usdt = DamageUSDT,
                    updated_ms = erlang:system_time(millisecond)
                };
            {error, Reason2} ->
                ?LOG_WARNING("Failed to fetch Coinstore prices: ~p", [Reason2]),
                State
        end,

    erlang:send_after(?INTERVAL, self(), fetch),
    {noreply, NewState2};
handle_info(_, State) ->
    {noreply, State}.

handle_call(get_prices, _From, State) ->
    Reply =
        case {State#state.btc_usdt, State#state.damage_usdt} of
            {B, D} when is_float(B), is_float(D) ->
                {ok, #{btc_usdt => B, damage_usdt => D, updated_ms => State#state.updated_ms}};
            _ ->
                {error, not_ready}
        end,
    {reply, Reply, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec fetch_coinstore_prices() ->
    {ok, #{btc_usdt := float(), damage_usdt := float()}} | {error, term()}.
fetch_coinstore_prices() ->
    Host = "api.coinstore.com",
    %% Coinstore REST base is https://api.coinstore.com/api (docs)
    %% Endpoint: GET /v1/ticker/price (docs)
    %% We request only the two symbols we need: btcusdt, damageusdt
    Path = "/api/v1/ticker/price?symbol=btcusdt,damageusdt",
    {ok, ConnPid} = gun:open(Host, 443, #{transport => tls, tls_opts => [{verify, verify_none}]}),
    StreamRef = gun:get(ConnPid, Path, [{<<"accept">>, <<"application/json">>}]),
    Res =
        case gun:await(ConnPid, StreamRef, 600000) of
            {error, Error} ->
                {error, Error};
            {response, nofin, _Status, _Headers0} ->
                {ok, Body} = gun:await_body(ConnPid, StreamRef),
                decode_coinstore_price_body(Body)
        end,
    gun:close(ConnPid),
    Res.

decode_coinstore_price_body(Body) ->
    case catch jsx:decode(Body, [return_maps]) of
        #{<<"code">> := 0, <<"data">> := Data} when is_list(Data) ->
            %% Data items look like: #{<<"symbol">> := <<"btcusdt">>, <<"price">> := <<"400">>}
            case {find_price(<<"btcusdt">>, Data), find_price(<<"damageusdt">>, Data)} of
                {{ok, BTCUSDT}, {ok, DamageUSDT}} ->
                    {ok, #{btc_usdt => BTCUSDT, damage_usdt => DamageUSDT}};
                Other ->
                    {error, {missing_prices, Other}}
            end;
        Other ->
            {error, {bad_json, Other}}
    end.

find_price(Symbol, Items) ->
    case
        lists:filter(
            fun
                (#{<<"symbol">> := S}) when is_binary(S) -> S =:= Symbol;
                (_) -> false
            end,
            Items
        )
    of
        [#{<<"price">> := P0} | _] ->
            try
                {ok, binary_to_float(P0)}
            catch
                _:_ ->
                    %% sometimes price may come as integer string; still ok with float conversion via list
                    try
                        {ok, list_to_float(binary_to_list(P0))}
                    catch
                        _:_ -> {error, {bad_price, Symbol, P0}}
                    end
            end;
        [] ->
            {error, {not_found, Symbol}}
    end.
sats_to_damage(Sats) ->
    case get_prices() of
        {ok, #{btc_usdt := BTCUSDT, damage_usdt := DamageUSDT}} ->
            BTC = Sats / 1.0e8,
            USDT = BTC * BTCUSDT,
            Damage = USDT / DamageUSDT,
            round(Damage);
        _ ->
            %% fallback (optional)
            BTCUSDT = 112000,
            DamageUSDT = 0.0117,
            BTC = Sats / 1.0e8,
            USDT = BTC * BTCUSDT,
            Damage = USDT / DamageUSDT,
            round(Damage)
    end.
