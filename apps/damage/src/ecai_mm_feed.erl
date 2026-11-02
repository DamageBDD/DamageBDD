%% Read-only public Coinstore feed. Reuses DamageBDD price_feed as a reference.
%% No API secret is required, and this module never submits orders.
-module(ecai_mm_feed).
-export([fetch/0, fetch/1, fetch_live/0, fetch_candles/3, fetch_candles/4,
         decode_depth/1, decode_prices/1, reference/1]).

-ifdef(TEST).
-export([tls_options/1]).
-endif.

-define(API, "https://api.coinstore.com/api").

%% Only fall back to direct networking when the optional cache is not running.
%% Cache errors are NOT bypassed, and stale stored books never return {ok, Book}.
fetch() ->
    case whereis(ecai_mm_price_cache) of
        undefined -> fetch_live();
        _ ->
            try ecai_mm_price_cache:fetch()
            catch exit:Why -> {error, {price_cache_unavailable, Why}} end
    end.
fetch_live() -> fetch(fun https_get/1).

fetch_candles(Symbol, Period, Size) ->
    fetch_candles(Symbol, Period, Size, fun https_get/1).
fetch_candles(Symbol, Period, Size, Get) when is_function(Get, 1) ->
    case ecai_mm_candles:request_path(Symbol, Period, Size) of
        {ok, Path} ->
            %% Use request-start time conservatively: candles that were open
            %% at request time do not become closed merely because HTTP was slow.
            Started = erlang:system_time(millisecond),
            case Get(Path) of
                {ok, JSON} -> ecai_mm_candles:decode(JSON, Symbol, Period, Started);
                {error, Why} -> {error, {candle_request, Why}};
                _ -> {error, invalid_candle_api_response}
            end;
        Error -> Error
    end;
fetch_candles(_, _, _, _) -> {error, invalid_history_request}.

%% Injectable HTTP adapter: fun(Path) -> {ok, decoded_json_map} | {error,term()}.
%% Useful for replay, fuzzing and tests; the production adapter verifies TLS.
fetch(Get) when is_function(Get, 1) ->
    %% The oldest component bounds freshness. Never stamp a slow depth/ticker
    %% pair (or an old cache entry) with a brand-new receipt timestamp.
    Started = erlang:system_time(millisecond),
    case
        {
            Get("/v1/market/depth/DAMAGEUSDT?depth=5"),
            Get("/v1/ticker/price?symbol=damageusdt,btcusdt")
        }
    of
        {{ok, Depth}, {ok, Prices}} ->
            case {decode_depth(Depth), decode_prices(Prices)} of
                {{ok, B}, {ok, P}} ->
                    D = B#{
                        btc_usdt => maps:get(btc_usdt, P),
                        damage_last_usdt => maps:get(damage_usdt, P),
                        fetched_ms => Started,
                        kind => live_order_book,
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

%% Use HTTPS hostname rules so a SAN such as *.coinstore.com can match
%% api.coinstore.com. OTP's generic DNS-ID matcher does not allow this
%% wildcard by default. Keep chain verification, OS trust roots and SNI;
%% never override bad_cert with a permissive verify_fun or fail_callback.
%% The CA list is an argument only to make the policy testable offline.
tls_options(CACerts) ->
    [
        {verify, verify_peer},
        {cacerts, CACerts},
        {server_name_indication, "api.coinstore.com"},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%% One bounded/deadline-limited request, same verified TLS policy for live
%% books and backfills. Do not follow redirects to an unreviewed data source.
https_get(Path) ->
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        SslOpts = tls_options(public_key:cacerts_get()),
        Opts = [{timeout, 5000}, {connect_timeout, 3500}, {autoredirect, false}, {ssl, SslOpts}],
        case httpc:request(get,
            {?API ++ Path, [{"accept", "application/json"}, {"accept-encoding", "identity"}]},
            Opts, [{sync, false}, {stream, {self, once}}]) of
            {ok, Id} ->
                Deadline = erlang:monotonic_time(millisecond) + 6000,
                try receive_json(Id, undefined, [], 0, Deadline)
                after httpc:cancel_request(Id) end;
            {error, Why} -> {error, Why}
        end
    catch C:R -> {error, {C, R}} end.

receive_json(Id, Handler, Acc, Bytes, Deadline) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {http, {Id, stream_start, Headers, Pid}} ->
            case response_headers_ok(Headers) of
                true ->
                    httpc:stream_next(Pid), receive_json(Id, Pid, Acc, Bytes, Deadline);
                false -> {error, invalid_or_oversized_http_response}
            end;
        {http, {Id, stream, Chunk}} when is_binary(Chunk) ->
            NewBytes = Bytes + byte_size(Chunk),
            case NewBytes =< 4 * 1024 * 1024 of
                true ->
                    httpc:stream_next(Handler),
                    receive_json(Id, Handler, [Chunk | Acc], NewBytes, Deadline);
                false -> {error, http_response_too_large}
            end;
        {http, {Id, stream_end, _Headers}} ->
            decode_json_body(iolist_to_binary(lists:reverse(Acc)));
        {http, {Id, {{_, 200, _}, _Headers, Body}}} -> decode_json_body(iolist_to_binary(Body));
        {http, {Id, {{_, Status, _}, _Headers, _Body}}} -> {error, {http_status, Status}};
        {http, {Id, {error, Why}}} -> {error, Why}
    after Wait -> {error, http_request_timeout}
    end.

response_headers_ok(Headers) ->
    try
        Len = proplists:get_value("content-length", Headers, "0"),
        Size = list_to_integer(Len),
        Size >= 0 andalso Size =< 4 * 1024 * 1024 andalso
        proplists:get_value("content-encoding", Headers, "identity") =:= "identity" andalso
        proplists:get_value("content-range", Headers, undefined) =:= undefined
    catch _:_ -> false end.

decode_json_body(Body) when byte_size(Body) =< 4 * 1024 * 1024 ->
    try {ok, jsx:decode(Body, [return_maps])}
    catch _:_ -> {error, invalid_json} end;
decode_json_body(_) -> {error, http_response_too_large}.
