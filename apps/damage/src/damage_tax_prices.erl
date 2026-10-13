%%% Historical fiat price witnesses. Exact provider bodies must be archived.
%%% CryptoCompare hourly OPEN avoids using trades later than the event.
%%% CoinGecko daily history is approximate and always requires review.
%%% All fiat conversions use integer fixed-point arithmetic; AUD v1 APIs stay.
-module(damage_tax_prices).
-export([
    fetch/3, fetch/4,
    parse_cryptocompare/3, parse_cryptocompare/4,
    parse_coingecko/3, parse_coingecko/4,
    quote_key/1, quote_key/2,
    valid_quote/2, valid_quote/3,
    aud_cents/2,
    fiat_minor/3,
    provider_url/3, provider_url/4
]).

-define(CC_HOST, "min-api.cryptocompare.com").
-define(CG_HOST, "api.coingecko.com").
-define(MICRO, 1000000).

quote_key(Event) -> quote_key(Event, <<"AUD">>).
quote_key(Event, Currency) ->
    Asset = maps:get(<<"asset">>, Event),
    Hour = (maps:get(<<"occurred_at">>, Event) div 3600) * 3600,
    case Currency of
        <<"AUD">> -> {Asset, Hour};
        _ -> {Asset, Hour, Currency}
    end.

fetch(Provider, Asset, Ts) -> fetch(Provider, Asset, Ts, <<"AUD">>).
fetch(Provider, Asset, Ts, Currency) when is_binary(Asset), is_integer(Ts), Ts > 0 ->
    case provider_url(Provider, Asset, Ts, Currency) of
        {ok, {Host, Path}} ->
            case
                damage_gun:get(
                    Host,
                    443,
                    Path,
                    auth_headers(Provider),
                    #{
                        transport => tls,
                        proxy => direct,
                        timeout => 15000,
                        connect_timeout => 5000,
                        close => true,
                        decode => raw
                    }
                )
            of
                {ok, #{status := 200, body := Body}} when byte_size(Body) =< 1048576 ->
                    Parsed =
                        case Provider of
                            cryptocompare -> parse_cryptocompare(Body, Asset, Ts, Currency);
                            coingecko -> parse_coingecko(Body, Asset, Ts, Currency)
                        end,
                    case Parsed of
                        {ok, Quote} -> {ok, #{quote => Quote, evidence_body => Body}};
                        ParseError -> ParseError
                    end;
                {ok, #{status := Status}} ->
                    {error, {price_http_status, Status}};
                {error, Why} ->
                    {error, {price_provider_unavailable, Why}}
            end;
        UrlError ->
            UrlError
    end;
fetch(_, _, _, _) ->
    {error, invalid_quote_request}.

provider_url(Provider, Asset, Ts) -> provider_url(Provider, Asset, Ts, <<"AUD">>).
provider_url(cryptocompare, Asset, Ts, Currency) when is_integer(Ts), Ts > 0 ->
    case allowed_asset(Asset) andalso allowed_currency(Currency) of
        true ->
            Hour = (Ts div 3600) * 3600,
            Path = iolist_to_binary([
                <<"/data/v2/histohour?fsym=">>,
                Asset,
                <<"&tsym=">>,
                Currency,
                <<"&limit=2&aggregate=1&e=CCCAGG&toTs=">>,
                integer_to_binary(Hour),
                <<"&tryConversion=true">>
            ]),
            {ok, {?CC_HOST, Path}};
        false ->
            {error, unsupported_historical_asset_or_currency}
    end;
provider_url(coingecko, Asset, Ts, Currency) when is_integer(Ts), Ts > 0 ->
    case {coingecko_id(Asset), allowed_currency(Currency)} of
        {undefined, _} ->
            {error, unsupported_historical_asset};
        {_, false} ->
            {error, unsupported_historical_currency};
        {Id, true} ->
            {{Year, Month, Day}, _} = calendar:gregorian_seconds_to_datetime(epoch() + Ts),
            Date = io_lib:format("~2..0B-~2..0B-~4..0B", [Day, Month, Year]),
            {ok,
                {?CG_HOST,
                    iolist_to_binary([
                        <<"/api/v3/coins/">>,
                        Id,
                        <<"/history?date=">>,
                        Date,
                        <<"&localization=false">>
                    ])}}
    end;
provider_url(_, _, _, _) ->
    {error, unknown_price_provider}.

allowed_currency(Currency) ->
    lists:any(
        fun(#{<<"currency">> := V}) -> V =:= Currency end,
        damage_tax_regions:all()
    ).
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
        _ ->
            Base
    end;
auth_headers(coingecko) ->
    Base = [{<<"accept">>, <<"application/json">>}],
    case application:get_env(damage, tax_coingecko_demo_key, undefined) of
        K when is_binary(K), byte_size(K) > 0 ->
            [{<<"x-cg-demo-api-key">>, K} | Base];
        _ ->
            Base
    end.

parse_cryptocompare(Body, Asset, Ts) ->
    parse_cryptocompare(Body, Asset, Ts, <<"AUD">>).
parse_cryptocompare(Body, Asset, Ts, Currency) ->
    try
        true = allowed_currency(Currency),
        Json = jsx:decode(Body, [return_maps]),
        #{
            <<"Response">> := <<"Success">>,
            <<"Data">> := #{<<"Data">> := Candles}
        } = Json,
        Hour = (Ts div 3600) * 3600,
        [Candle] = [C || C <- Candles, maps:get(<<"time">>, C, undefined) =:= Hour],
        PriceMicro = decimal_micro(maps:get(<<"open">>, Candle)),
        Conversion = normal_binary(maps:get(<<"conversionType">>, Candle, <<"unknown">>)),
        {ok,
            quote(
                Asset,
                Hour,
                PriceMicro,
                Currency,
                <<"cryptocompare">>,
                <<"hour_open">>,
                Body,
                #{
                    <<"conversion_type">> => Conversion,
                    <<"review_required">> => Conversion =/= <<"direct">>,
                    <<"precision_seconds">> => 3600
                }
            )}
    catch
        _:_ -> {error, invalid_cryptocompare_hourly_price}
    end.

parse_coingecko(Body, Asset, Ts) -> parse_coingecko(Body, Asset, Ts, <<"AUD">>).
parse_coingecko(Body, Asset, Ts, Currency) ->
    try
        true = allowed_currency(Currency),
        Json = jsx:decode(Body, [return_maps]),
        #{<<"market_data">> := #{<<"current_price">> := Prices}} = Json,
        PriceMicro = decimal_micro(maps:get(lower_ascii(Currency), Prices)),
        Midnight = (Ts div 86400) * 86400,
        {ok,
            quote(
                Asset,
                Midnight,
                PriceMicro,
                Currency,
                <<"coingecko">>,
                <<"daily_historical_snapshot">>,
                Body,
                #{
                    <<"conversion_type">> => <<"provider_aggregated">>,
                    <<"review_required">> => true,
                    <<"precision_seconds">> => 86400
                }
            )}
    catch
        _:_ -> {error, invalid_coingecko_daily_price}
    end.

quote(Asset, At, PriceMicro, Currency, Provider, Method, Body, Extra) ->
    ProviderAtom = binary_to_existing_atom(Provider, utf8),
    {ok, {Host, Path}} = provider_url(ProviderAtom, Asset, At, Currency),
    Base = #{
        <<"asset">> => Asset,
        <<"currency">> => Currency,
        <<"at">> => At,
        <<"price_micro_fiat">> => PriceMicro,
        <<"provider">> => Provider,
        <<"method">> => Method,
        <<"request_url">> => iolist_to_binary([<<"https://">>, Host, Path]),
        <<"body_sha256">> => damage_tax_canonical:sha256_hex(Body),
        <<"observed_at">> => erlang:system_time(second)
    },
    Legacy =
        case Currency of
            <<"AUD">> -> Base#{<<"price_micro_aud">> => PriceMicro};
            _ -> Base
        end,
    maps:merge(Legacy, Extra).

decimal_micro(P) when is_integer(P), P > 0, P < 1000000000 -> P * ?MICRO;
decimal_micro(P) when is_float(P), P > 0.0, P < 1000000000.0 ->
    N = round(P * ?MICRO),
    case N > 0 of
        true -> N;
        false -> error(invalid_price)
    end;
decimal_micro(_) ->
    error(invalid_price).

valid_quote(Event, Quote) -> valid_quote(Event, Quote, <<"AUD">>).
valid_quote(Event, Quote, Currency) when is_map(Event), is_map(Quote) ->
    Ts = maps:get(<<"occurred_at">>, Event),
    At = maps:get(<<"at">>, Quote, -1),
    MatchesTime =
        case maps:get(<<"method">>, Quote, undefined) of
            <<"hour_open">> -> At =:= (Ts div 3600) * 3600;
            <<"daily_historical_snapshot">> -> At =:= (Ts div 86400) * 86400;
            _ -> false
        end,
    Price = micro_price(Quote, Currency),
    case
        {
            maps:get(<<"asset">>, Event) =:= maps:get(<<"asset">>, Quote, undefined),
            maps:get(<<"currency">>, Quote, undefined),
            Price,
            MatchesTime,
            maps:get(<<"body_sha256">>, Quote, undefined)
        }
    of
        {true, Currency, Micro, true, SHA} when
            is_integer(Micro), Micro > 0, is_binary(SHA), byte_size(SHA) =:= 64
        ->
            ok;
        _ ->
            {error, missing_or_mismatched_fiat_evidence}
    end;
valid_quote(_, _, _) ->
    {error, missing_or_mismatched_fiat_evidence}.

micro_price(Q, <<"AUD">>) ->
    maps:get(<<"price_micro_fiat">>, Q, maps:get(<<"price_micro_aud">>, Q, 0));
micro_price(Q, _Currency) ->
    maps:get(<<"price_micro_fiat">>, Q, 0).

aud_cents(Event, Quote) -> fiat_minor(Event, Quote, <<"AUD">>).
-spec fiat_minor(map(), map(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
fiat_minor(Event, Quote, Currency) ->
    case valid_quote(Event, Quote, Currency) of
        ok ->
            Atomic = maps:get(<<"amount_atomic">>, Event),
            Scale = maps:get(<<"scale">>, Event),
            PriceMicro = micro_price(Quote, Currency),
            MinorFactor =
                case Currency of
                    <<"JPY">> -> 1;
                    _ -> 100
                end,
            Denominator = Scale * ?MICRO,
            {ok, (Atomic * PriceMicro * MinorFactor + Denominator div 2) div Denominator};
        Error ->
            Error
    end.

normal_binary(V) when is_binary(V) -> V;
normal_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
normal_binary(_) -> <<"unknown">>.
lower_ascii(Bin) -> list_to_binary(string:lowercase(binary_to_list(Bin))).
epoch() -> calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
