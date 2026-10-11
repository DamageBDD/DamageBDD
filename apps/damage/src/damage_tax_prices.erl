%%% Historical AUD price witnesses. The exact HTTP response must be archived.
%%% CryptoCompare hourly OPEN avoids using trades later than the event.
%%% CoinGecko history is daily-resolution and explicitly requires manual review.
-module(damage_tax_prices).
-export([fetch/3, parse_cryptocompare/3, parse_coingecko/3,
         quote_key/1, valid_quote/2, aud_cents/2, provider_url/3]).

-define(CC_HOST, "min-api.cryptocompare.com").
-define(CG_HOST, "api.coingecko.com").
-define(MICRO, 1000000).

-spec quote_key(map()) -> {binary(), integer()}.
quote_key(E) ->
    {maps:get(<<"asset">>, E), (maps:get(<<"occurred_at">>, E) div 3600) * 3600}.

-spec fetch(cryptocompare | coingecko, binary(), pos_integer()) ->
    {ok, #{quote := map(), evidence_body := binary()}} | {error, term()}.
fetch(Provider, Asset, Ts) when is_binary(Asset), is_integer(Ts), Ts > 0 ->
    case provider_url(Provider, Asset, Ts) of
        {ok, {Host, Path}} ->
            Headers = auth_headers(Provider),
            case damage_gun:get(Host, 443, Path, Headers,
                    #{transport => tls, proxy => direct, timeout => 15000,
                      connect_timeout => 5000, close => true, decode => raw}) of
                {ok, #{status := 200, body := Body}} when byte_size(Body) =< 1048576 ->
                    Parsed = case Provider of
                        cryptocompare -> parse_cryptocompare(Body, Asset, Ts);
                        coingecko -> parse_coingecko(Body, Asset, Ts)
                    end,
                    case Parsed of
                        {ok, Quote} -> {ok, #{quote => Quote,
                                              evidence_body => Body}};
                        ParseError -> ParseError
                    end;
                {ok, #{status := Status}} -> {error, {price_http_status, Status}};
                {error, Why} -> {error, {price_provider_unavailable, Why}}
            end;
        UrlError -> UrlError
    end;
fetch(_, _, _) -> {error, invalid_quote_request}.

provider_url(cryptocompare, Asset, Ts) when is_integer(Ts), Ts > 0 ->
    case allowed_asset(Asset) of
        true ->
            Hour = (Ts div 3600) * 3600,
            Path = iolist_to_binary([
                <<"/data/v2/histohour?fsym=">>, Asset,
                <<"&tsym=AUD&limit=2&aggregate=1&e=CCCAGG&toTs=">>,
                integer_to_binary(Hour), <<"&tryConversion=true">>]),
            {ok, {?CC_HOST, Path}};
        false -> {error, unsupported_historical_asset}
    end;
provider_url(coingecko, Asset, Ts) when is_integer(Ts), Ts > 0 ->
    case coingecko_id(Asset) of
        undefined -> {error, unsupported_historical_asset};
        Id ->
            {{Year, Month, Day}, _} =
                calendar:gregorian_seconds_to_datetime(epoch() + Ts),
            Date = io_lib:format("~2..0B-~2..0B-~4..0B", [Day, Month, Year]),
            {ok, {?CG_HOST, iolist_to_binary([
                <<"/api/v3/coins/">>, Id, <<"/history?date=">>, Date,
                <<"&localization=false">>])}}
    end;
provider_url(_, _, _) -> {error, unknown_price_provider}.

allowed_asset(<<"BTC">>) -> true;
allowed_asset(<<"ETH">>) -> true;
allowed_asset(<<"AE">>) -> true;
allowed_asset(_) -> false.

coingecko_id(<<"BTC">>) -> <<"bitcoin">>;
coingecko_id(<<"ETH">>) -> <<"ethereum">>;
coingecko_id(<<"AE">>) -> <<"aeternity">>;
coingecko_id(_) -> undefined.

auth_headers(cryptocompare) ->
    Base = [{<<"accept">>, <<"application/json">>}],
    case application:get_env(damage, tax_cryptocompare_key, undefined) of
        K when is_binary(K), byte_size(K) > 0 ->
            [{<<"authorization">>, <<"Apikey ", K/binary>>} | Base];
        _ -> Base
    end;
auth_headers(coingecko) ->
    Base = [{<<"accept">>, <<"application/json">>}],
    case application:get_env(damage, tax_coingecko_demo_key, undefined) of
        K when is_binary(K), byte_size(K) > 0 ->
            [{<<"x-cg-demo-api-key">>, K} | Base];
        _ -> Base
    end.

-spec parse_cryptocompare(binary(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
parse_cryptocompare(Body, Asset, Ts) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        #{<<"Response">> := <<"Success">>,
          <<"Data">> := #{<<"Data">> := Candles}} = Json,
        TargetHour = (Ts div 3600) * 3600,
        [Candle] = [C || C <- Candles,
                         maps:get(<<"time">>, C, undefined) =:= TargetHour],
        PriceMicro = decimal_micro(maps:get(<<"open">>, Candle)),
        Conversion = normal_binary(maps:get(<<"conversionType">>, Candle, <<"unknown">>)),
        {ok, quote(Asset, TargetHour, PriceMicro, <<"cryptocompare">>,
                   <<"hour_open">>, Body,
                   #{<<"conversion_type">> => Conversion,
                     <<"review_required">> => Conversion =/= <<"direct">>,
                     <<"precision_seconds">> => 3600})}
    catch
        _:_ -> {error, invalid_cryptocompare_hourly_price}
    end.

-spec parse_coingecko(binary(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
parse_coingecko(Body, Asset, Ts) ->
    try
        Json = jsx:decode(Body, [return_maps]),
        #{<<"market_data">> := #{<<"current_price">> := #{<<"aud">> := Price}}} = Json,
        Midnight = (Ts div 86400) * 86400,
        PriceMicro = decimal_micro(Price),
        {ok, quote(Asset, Midnight, PriceMicro, <<"coingecko">>,
                   <<"daily_historical_snapshot">>, Body,
                   #{<<"conversion_type">> => <<"provider_aggregated">>,
                     <<"review_required">> => true,
                     <<"precision_seconds">> => 86400})}
    catch
        _:_ -> {error, invalid_coingecko_daily_price}
    end.

quote(Asset, At, PriceMicro, Provider, Method, Body, Extra) ->
    ProviderAtom = binary_to_existing_atom(Provider, utf8),
    {ok, {Host, Path}} = provider_url(ProviderAtom, Asset, At),
    RequestUrl = iolist_to_binary([<<"https://">>, Host, Path]),
    maps:merge(#{<<"asset">> => Asset, <<"currency">> => <<"AUD">>,
                 <<"at">> => At, <<"price_micro_aud">> => PriceMicro,
                 <<"provider">> => Provider, <<"method">> => Method,
                 <<"request_url">> => RequestUrl,
                 <<"body_sha256">> => damage_tax_canonical:sha256_hex(Body),
                 <<"observed_at">> => erlang:system_time(second)}, Extra).

%%% Strictly fixed-point after parsing exchange JSON floating point.
%%% Maximum six fractional AUD decimal places in the normalised quote.
decimal_micro(P) when is_integer(P), P > 0, P < 1000000000 -> P * ?MICRO;
decimal_micro(P) when is_float(P), P > 0.0, P < 1000000000.0 ->
    N = round(P * ?MICRO),
    case N > 0 of true -> N; false -> error(invalid_price) end;
decimal_micro(_) -> error(invalid_price).

-spec valid_quote(map(), map()) -> ok | {error, term()}.
valid_quote(Event, Quote) ->
    EventTs = maps:get(<<"occurred_at">>, Event),
    PriceAt = maps:get(<<"at">>, Quote, -1),
    Method = maps:get(<<"method">>, Quote, undefined),
    MatchesTime = case Method of
        <<"hour_open">> -> PriceAt =:= (EventTs div 3600) * 3600;
        <<"daily_historical_snapshot">> ->
            PriceAt =:= (EventTs div 86400) * 86400;
        _ -> false
    end,
    case {maps:get(<<"asset">>, Event) =:= maps:get(<<"asset">>, Quote, undefined),
          maps:get(<<"currency">>, Quote, undefined),
          maps:get(<<"price_micro_aud">>, Quote, 0), MatchesTime,
          maps:get(<<"body_sha256">>, Quote, undefined)} of
        {true, <<"AUD">>, Micro, true, SHA}
                when is_integer(Micro), Micro > 0, is_binary(SHA), byte_size(SHA) =:= 64 -> ok;
        _ -> {error, missing_or_mismatched_aud_evidence}
    end.

-spec aud_cents(map(), map()) -> {ok, non_neg_integer()} | {error, term()}.
aud_cents(Event, Quote) ->
    case valid_quote(Event, Quote) of
        ok ->
            Atomic = maps:get(<<"amount_atomic">>, Event),
            Scale = maps:get(<<"scale">>, Event),
            MicroAudPerUnit = maps:get(<<"price_micro_aud">>, Quote),
            %% integer half-up rounding to a whole Australian cent.
            Denominator = Scale * 10000,
            {ok, (Atomic * MicroAudPerUnit + Denominator div 2) div Denominator};
        Error -> Error
    end.

normal_binary(V) when is_binary(V) -> V;
normal_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
normal_binary(_) -> <<"unknown">>.
epoch() -> calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
