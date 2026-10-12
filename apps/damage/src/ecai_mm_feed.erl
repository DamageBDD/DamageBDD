%% Read-only public Coinstore feed. Reuses DamageBDD price_feed as a reference.
%% No API secret is required, and this module never submits orders.
-module(ecai_mm_feed).
-export([fetch/0, fetch/1, decode_depth/1, decode_prices/1, reference/1]).

-define(API, "https://api.coinstore.com/api").

fetch() -> fetch(fun https_get/1).

%% Injectable HTTP adapter: fun(Path) -> {ok, decoded_json_map} | {error,term()}.
%% Useful for replay, fuzzing and tests; the production adapter verifies TLS.
fetch(Get) when is_function(Get, 1) ->
    case
        {
            Get("/v1/market/depth/DAMAGEUSDT?depth=5"),
            Get("/v1/ticker/price?symbol=damageusdt,btcusdt")
        }
    of
        {{ok, Depth}, {ok, Prices}} ->
            case {decode_depth(Depth), decode_prices(Prices)} of
                {{ok, B}, {ok, P}} ->
                    Now = erlang:system_time(millisecond),
                    D = B#{
                        btc_usdt => maps:get(btc_usdt, P),
                        damage_last_usdt => maps:get(damage_usdt, P),
                        fetched_ms => Now,
                        source => <<"coinstore">>
                    },
                    {ok, D#{price_feed_reference => reference(maps:get(btc_usdt, P))}};
                {{error, E}, _} ->
                    {error, {depth, E}};
                {_, {error, E}} ->
                    {error, {ticker, E}}
            end;
        {{error, E}, _} ->
            {error, {depth_request, E}};
        {_, {error, E}} ->
            {error, {ticker_request, E}};
        _ ->
            {error, invalid_api_response}
    end.

%% A second, diagnostic source. The known DamageBDD function converts
%% one DAMAGE to satoshis; no invented price_feed API calls are made.
reference(BtcUSDT) ->
    try
        case code:ensure_loaded(price_feed) of
            {module, price_feed} ->
                case erlang:function_exported(price_feed, damage_to_sats, 1) of
                    true ->
                        Sats = price_feed:damage_to_sats(1),
                        case num(Sats) of
                            V when V > 0.0 -> V * BtcUSDT / 100000000.0;
                            _ -> null
                        end;
                    false ->
                        null
                end;
            _ ->
                null
        end
    catch
        _:_ -> null
    end.

decode_depth(#{<<"code">> := Code, <<"data">> := Data}) when
    (Code =:= 0 orelse Code =:= <<"0">>), is_map(Data)
->
    try
        Asks = [
            num(hd(Row))
         || Row <- maps:get(<<"a">>, Data),
            is_list(Row),
            length(Row) >= 2,
            num(lists:nth(2, Row)) > 0.0
        ],
        Bids = [
            num(hd(Row))
         || Row <- maps:get(<<"b">>, Data),
            is_list(Row),
            length(Row) >= 2,
            num(lists:nth(2, Row)) > 0.0
        ],
        A = lists:min(Asks),
        B = lists:max(Bids),
        true = A > B andalso B > 0.0,
        {ok, #{bid => B, ask => A}}
    catch
        _:_ -> {error, invalid_or_crossed_book}
    end;
decode_depth(_) ->
    {error, unexpected_depth_schema}.

decode_prices(#{<<"code">> := Code, <<"data">> := Rows}) when
    (Code =:= 0 orelse Code =:= <<"0">>), is_list(Rows)
->
    try
        M = lists:foldl(
            fun(Row, Acc) ->
                Key = string:lowercase(maps:get(<<"symbol">>, Row)),
                maps:put(Key, num(maps:get(<<"price">>, Row)), Acc)
            end,
            #{},
            Rows
        ),
        BTC = maps:get(<<"btcusdt">>, M),
        D = maps:get(<<"damageusdt">>, M),
        true = BTC > 0.0 andalso D > 0.0,
        {ok, #{btc_usdt => BTC, damage_usdt => D}}
    catch
        _:_ -> {error, missing_or_invalid_symbols}
    end;
decode_prices(_) ->
    {error, unexpected_ticker_schema}.

num(V) when is_integer(V) -> float(V);
num(V) when is_float(V) -> V;
num(V) when is_binary(V) -> num(binary_to_list(V));
num(V) when is_list(V) ->
    case string:to_float(V) of
        {F, []} ->
            F;
        _ ->
            case string:to_integer(V) of
                {I, []} -> float(I);
                _ -> erlang:error(invalid_numeric_field)
            end
    end.

https_get(Path) ->
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        %% Trust store supplied by OTP; deliberately NO verify_none.
        SslOpts = [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {server_name_indication, "api.coinstore.com"}
        ],
        Opts = [{timeout, 5000}, {connect_timeout, 3500}, {ssl, SslOpts}],
        case
            httpc:request(
                get,
                {?API ++ Path, [{"accept", "application/json"}]},
                Opts,
                [{body_format, binary}]
            )
        of
            {ok, {{_, 200, _}, _Headers, Body}} ->
                try
                    {ok, jsx:decode(Body, [return_maps])}
                catch
                    _:_ -> {error, invalid_json}
                end;
            {ok, {{_, Status, _}, _, _}} ->
                {error, {http_status, Status}};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        Class:Reason0 -> {error, {Class, Reason0}}
    end.
