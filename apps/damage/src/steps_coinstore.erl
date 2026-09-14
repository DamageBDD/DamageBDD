%%%-------------------------------------------------------------------
%%% DamageBDD Coinstore REST API steps.
%%%
%%% - Keeps API credentials in DamageBDD secrets; secret values are never
%%%   written to Context.
%%% - Implements Coinstore's two-stage HMAC-SHA256 authentication exactly:
%%%     key  = hex(HMAC-SHA256(secret, floor(expires_ms / 30000)))
%%%     sign = hex(HMAC-SHA256(key-as-ASCII-hex, query ++ body))
%%% - Preserves raw query/body bytes for signed generic requests because
%%%   Coinstore signs parameters in request order (no sorting).
%%% - Stores HTTP responses in the same Context shape as steps_http.erl so
%%%   the existing HTTP JSON/status assertions can be reused.
%%% - Mutating trading/withdrawal/transfer endpoints fail closed unless the
%%%   feature explicitly enables the corresponding capability.
%%%-------------------------------------------------------------------
-module(steps_coinstore).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([step/6, step_dry/6]).
-export([sign/3]).

-define(DEFAULT_BASE_URL, <<"https://api.coinstore.com/api">>).
-define(DEFAULT_API_KEY_SECRET, coinstore_api_key).
-define(DEFAULT_SECRET_KEY_SECRET, coinstore_secret_key).
-define(DEFAULT_TIMEOUT, 30000).

%% ------------------------------------------------------------------
%% Step patterns
%% ------------------------------------------------------------------

-define(S_USE_API, ["I use Coinstore API"]).
-define(S_USE_API_AT, ["I use Coinstore API at", BaseUrl]).
-define(S_USE_SECRETS, [
    "I use Coinstore credentials from API key secret",
    ApiKeySecret,
    "and secret key secret",
    SecretKeySecret
]).
-define(S_ALLOW_TRADING, ["I allow Coinstore trading"]).
-define(S_ALLOW_WITHDRAWALS, ["I allow Coinstore withdrawals"]).
-define(S_ALLOW_TRANSFERS, ["I allow Coinstore transfers"]).

-define(S_BALANCES, ["I get my Coinstore spot balances"]).
-define(S_DEPOSIT_ADDRESS, [
    "I get my Coinstore deposit address for currency", Currency, "on chain", Chain
]).
-define(S_DEPOSIT_HISTORY, ["I get my Coinstore deposit history"]).
-define(S_WITHDRAWAL_HISTORY, ["I get my Coinstore withdrawal history"]).
-define(S_WITHDRAW, ["I withdraw from Coinstore"]).
-define(S_CANCEL_WITHDRAWAL, ["I cancel a Coinstore withdrawal"]).

-define(S_CURRENT_ORDERS, ["I get my Coinstore current orders"]).
-define(S_CURRENT_ORDERS_QUERY, ["I get my Coinstore current orders with query", Query]).
-define(S_LATEST_TRADES_QUERY, ["I get my latest Coinstore trades with query", Query]).
-define(S_ORDER_QUERY, ["I get Coinstore order information with query", Query]).
-define(S_CREATE_ORDER, ["I create a Coinstore order"]).
-define(S_CANCEL_ORDER, ["I cancel a Coinstore order"]).
-define(S_BATCH_ORDERS, ["I create Coinstore batch orders"]).
-define(S_BATCH_CANCEL_ORDER_IDS, ["I cancel Coinstore orders by order ids"]).
-define(S_BATCH_CANCEL_CLIENT_IDS, ["I cancel Coinstore orders by client order ids"]).

-define(S_TICKERS, ["I get Coinstore market tickers"]).
-define(S_DEPTH, ["I get Coinstore market depth for", Symbol, "with depth", Depth]).

-define(S_SIGNED_GET, ["I make a signed Coinstore GET request to", Path]).
-define(S_SIGNED_GET_QUERY, [
    "I make a signed Coinstore GET request to", Path, "with query", Query
]).
-define(S_SIGNED_POST, ["I make a signed Coinstore POST request to", Path]).
-define(S_SIGNED_POST_QUERY, [
    "I make a signed Coinstore POST request to", Path, "with query", Query
]).
-define(S_PUBLIC_GET, ["I make a public Coinstore GET request to", Path]).
-define(S_PUBLIC_GET_QUERY, [
    "I make a public Coinstore GET request to", Path, "with query", Query
]).
-define(S_PUBLIC_POST, ["I make a public Coinstore POST request to", Path]).

-define(S_SUCCESS, ["the Coinstore response should succeed"]).

%% ------------------------------------------------------------------
%% Dry-run clauses: keep these exact so this module does not claim steps
%% belonging to other step modules during DamageBDD dry runs.
%% ------------------------------------------------------------------

step_dry(Config, Context, Keyword, LineNo, ?S_USE_API = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_USE_API_AT = Args, Body) ->
    _ = BaseUrl,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_USE_SECRETS = Args, Body) ->
    _ = {ApiKeySecret, SecretKeySecret},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_ALLOW_TRADING = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_ALLOW_WITHDRAWALS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_ALLOW_TRANSFERS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_BALANCES = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_DEPOSIT_ADDRESS = Args, Body) ->
    _ = {Currency, Chain},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_DEPOSIT_HISTORY = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_WITHDRAWAL_HISTORY = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_WITHDRAW = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_CANCEL_WITHDRAWAL = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_CURRENT_ORDERS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_CURRENT_ORDERS_QUERY = Args, Body) ->
    _ = Query,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_LATEST_TRADES_QUERY = Args, Body) ->
    _ = Query,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_ORDER_QUERY = Args, Body) ->
    _ = Query,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_CREATE_ORDER = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_CANCEL_ORDER = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_BATCH_ORDERS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_BATCH_CANCEL_ORDER_IDS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_BATCH_CANCEL_CLIENT_IDS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_TICKERS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_DEPTH = Args, Body) ->
    _ = {Symbol, Depth},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_SIGNED_GET = Args, Body) ->
    _ = Path,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_SIGNED_GET_QUERY = Args, Body) ->
    _ = {Path, Query},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_SIGNED_POST = Args, Body) ->
    _ = Path,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_SIGNED_POST_QUERY = Args, Body) ->
    _ = {Path, Query},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_PUBLIC_GET = Args, Body) ->
    _ = Path,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_PUBLIC_GET_QUERY = Args, Body) ->
    _ = {Path, Query},
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_PUBLIC_POST = Args, Body) ->
    _ = Path,
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?S_SUCCESS = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

%% ------------------------------------------------------------------
%% Configuration steps
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_USE_API, _Body) ->
    Context#{
        coinstore_base_url => ?DEFAULT_BASE_URL,
        coinstore_api_key_secret => ?DEFAULT_API_KEY_SECRET,
        coinstore_secret_key_secret => ?DEFAULT_SECRET_KEY_SECRET
    };
step(_Config, Context, _Keyword, _N, ?S_USE_API_AT, _Body) ->
    Context#{coinstore_base_url => to_bin(BaseUrl)};
step(_Config, Context, _Keyword, _N, ?S_USE_SECRETS, _Body) ->
    %% Store secret *names* only. Credential values are fetched just-in-time.
    Context#{
        coinstore_api_key_secret => to_bin(ApiKeySecret),
        coinstore_secret_key_secret => to_bin(SecretKeySecret)
    };
step(_Config, Context, _Keyword, _N, ?S_ALLOW_TRADING, _Body) ->
    Context#{coinstore_allow_trading => true};
step(_Config, Context, _Keyword, _N, ?S_ALLOW_WITHDRAWALS, _Body) ->
    Context#{coinstore_allow_withdrawals => true};
step(_Config, Context, _Keyword, _N, ?S_ALLOW_TRANSFERS, _Body) ->
    Context#{coinstore_allow_transfers => true};
%% ------------------------------------------------------------------
%% Account/funding convenience steps
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_BALANCES, _Body) ->
    signed_request(post, <<"/spot/accountList">>, <<>>, <<"{}">>, Context);
step(_Config, Context, _Keyword, _N, ?S_DEPOSIT_ADDRESS, _Body) ->
    Body = jsx:encode(#{
        <<"currencyCode">> => to_bin(Currency),
        <<"chain">> => to_bin(Chain)
    }),
    signed_request(post, <<"/fi/v3/asset/deposit/do">>, <<>>, Body, Context);
step(_Config, Context, _Keyword, _N, ?S_DEPOSIT_HISTORY, Body0) ->
    signed_request(
        post,
        <<"/fi/v3/asset/deposit/record/list">>,
        <<>>,
        post_body(Body0),
        Context
    );
step(_Config, Context, _Keyword, _N, ?S_WITHDRAWAL_HISTORY, Body0) ->
    signed_request(
        post,
        <<"/fi/v3/asset/withdraw/record/list">>,
        <<>>,
        post_body(Body0),
        Context
    );
step(_Config, Context, _Keyword, _N, ?S_WITHDRAW, Body0) ->
    signed_request(post, <<"/fi/v3/asset/doWithdraw">>, <<>>, post_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_CANCEL_WITHDRAWAL, Body0) ->
    signed_request(post, <<"/fi/v3/asset/cancelWithdraw">>, <<>>, post_body(Body0), Context);
%% ------------------------------------------------------------------
%% Order convenience steps
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_CURRENT_ORDERS, _Body) ->
    signed_request(get, <<"/api/v2/trade/order/active">>, <<>>, <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_CURRENT_ORDERS_QUERY, _Body) ->
    signed_request(get, <<"/api/v2/trade/order/active">>, query_bin(Query), <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_LATEST_TRADES_QUERY, _Body) ->
    signed_request(get, <<"/trade/match/accountMatches">>, query_bin(Query), <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_ORDER_QUERY, _Body) ->
    signed_request(get, <<"/api/v2/trade/order/orderInfo">>, query_bin(Query), <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_CREATE_ORDER, Body0) ->
    signed_request(post, <<"/trade/order/place">>, <<>>, order_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_CANCEL_ORDER, Body0) ->
    signed_request(post, <<"/trade/order/cancel">>, <<>>, post_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_BATCH_ORDERS, Body0) ->
    signed_request(post, <<"/trade/order/placeBatch">>, <<>>, order_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_BATCH_CANCEL_ORDER_IDS, Body0) ->
    signed_request(post, <<"/trade/order/cancelBatch">>, <<>>, post_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_BATCH_CANCEL_CLIENT_IDS, Body0) ->
    signed_request(
        post,
        <<"/trade/order/cancelBatchByClOrdId">>,
        <<>>,
        post_body(Body0),
        Context
    );
%% ------------------------------------------------------------------
%% Public market convenience steps
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_TICKERS, _Body) ->
    public_request(get, <<"/v1/market/tickers">>, <<>>, <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_DEPTH, _Body) ->
    Query = uri_string:compose_query([{<<"depth">>, to_bin(Depth)}]),
    Path = <<"/v1/market/depth/", (to_bin(Symbol))/binary>>,
    public_request(get, Path, to_bin(Query), <<>>, Context);
%% ------------------------------------------------------------------
%% Generic API steps. These are useful for new Coinstore endpoints without
%% adding another Erlang clause. Query/body are signed exactly as supplied.
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_SIGNED_GET, _Body) ->
    signed_request(get, Path, <<>>, <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_SIGNED_GET_QUERY, _Body) ->
    signed_request(get, Path, query_bin(Query), <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_SIGNED_POST, Body0) ->
    signed_request(post, Path, <<>>, post_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_SIGNED_POST_QUERY, Body0) ->
    signed_request(post, Path, query_bin(Query), post_body(Body0), Context);
step(_Config, Context, _Keyword, _N, ?S_PUBLIC_GET, _Body) ->
    public_request(get, Path, <<>>, <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_PUBLIC_GET_QUERY, _Body) ->
    public_request(get, Path, query_bin(Query), <<>>, Context);
step(_Config, Context, _Keyword, _N, ?S_PUBLIC_POST, Body0) ->
    public_request(post, Path, <<>>, post_body(Body0), Context);
%% ------------------------------------------------------------------
%% Coinstore-specific assertion
%% ------------------------------------------------------------------

step(_Config, Context, _Keyword, _N, ?S_SUCCESS, _Body) ->
    assert_success(Context).

%% ------------------------------------------------------------------
%% HTTP/auth implementation
%% ------------------------------------------------------------------

signed_request(Method, Path0, Query0, Body, Context0) ->
    Context = ensure_defaults(Context0),
    case endpoint(Context, Path0, Query0) of
        {ok, Ep = #{path := FullPath}} ->
            case mutation_allowed(FullPath, Context) of
                ok ->
                    case credentials(Context) of
                        {ok, ApiKey, SecretKey} ->
                            Expires = erlang:system_time(millisecond),
                            Query = query_bin(Query0),
                            Payload = <<Query/binary, Body/binary>>,
                            Signature = sign(SecretKey, Expires, Payload),
                            Headers = auth_headers(ApiKey, Expires, Signature),
                            request(Method, Ep, Headers, Body, Context);
                        {error, Why} ->
                            fail(Context, "Coinstore credential lookup failed: ~p", [Why])
                    end;
                {error, Why} ->
                    fail(Context, "Coinstore mutation is disabled: ~p", [Why])
            end;
        {error, Why} ->
            fail(Context, "Invalid Coinstore endpoint: ~p", [Why])
    end.

public_request(Method, Path0, Query0, Body, Context0) ->
    Context = ensure_defaults(Context0),
    case endpoint(Context, Path0, Query0) of
        {ok, Ep = #{path := FullPath}} ->
            case mutation_allowed(FullPath, Context) of
                ok -> request(Method, Ep, public_headers(), Body, Context);
                {error, Why} -> fail(Context, "Coinstore mutation is disabled: ~p", [Why])
            end;
        {error, Why} ->
            fail(Context, "Invalid Coinstore endpoint: ~p", [Why])
    end.

request(
    Method,
    #{host := Host, port := Port, transport := Transport, request_path := ReqPath},
    Headers,
    Body,
    Context
) ->
    Opts0 = #{
        transport => Transport,
        %% Coinstore API keys are commonly IP-bound; direct preserves the
        %% node's egress IP instead of unexpectedly applying DamageBDD's proxy.
        proxy => direct,
        protocols => [http],
        connect_timeout => ?DEFAULT_TIMEOUT,
        timeout => ?DEFAULT_TIMEOUT,
        close => true,
        decode => raw
    },
    Opts =
        case Transport of
            tls -> Opts0#{tls_opts => damage_gun:tls_opts(Host)};
            tcp -> Opts0
        end,
    ?LOG_INFO("Coinstore request method=~p host=~p path=~p", [Method, Host, ReqPath]),
    Result =
        case Method of
            get -> damage_gun:get(Host, Port, ReqPath, Headers, Opts);
            post -> damage_gun:post(Host, Port, ReqPath, Headers, Body, Opts)
        end,
    case Result of
        {ok, #{status := Status, headers := RespHeaders, body := RespBody}} ->
            store_response(Status, RespHeaders, RespBody, Context);
        {ok, #{status := Status, headers := RespHeaders}} ->
            store_response(Status, RespHeaders, <<>>, Context);
        {error, Why} ->
            fail(Context, "Coinstore HTTP request failed: ~p", [Why])
    end.

%% Public helper, useful for focused EUnit/CT tests.
-spec sign(binary() | list(), integer(), binary() | list()) -> binary().
sign(SecretKey0, ExpiresMs, Payload0) when is_integer(ExpiresMs) ->
    SecretKey = to_bin(SecretKey0),
    Payload = to_bin(Payload0),
    TimeBucket = integer_to_binary(ExpiresMs div 30000),
    FirstMac = crypto:mac(hmac, sha256, SecretKey, TimeBucket),
    HexKey = lower_hex(FirstMac),
    lower_hex(crypto:mac(hmac, sha256, HexKey, Payload)).

auth_headers(ApiKey, Expires, Signature) ->
    [
        {<<"x-cs-apikey">>, ApiKey},
        {<<"x-cs-sign">>, Signature},
        {<<"x-cs-expires">>, integer_to_binary(Expires)},
        {<<"exch-language">>, <<"en_US">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"user-agent">>, <<"damagebdd/1.0">>}
    ].

public_headers() ->
    [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"user-agent">>, <<"damagebdd/1.0">>}
    ].

store_response(Status, Headers, Body, Context0) ->
    Response = [
        {status_code, Status},
        {headers, Headers},
        {body, Body}
    ],
    Context1 = Context0#{response => Response, coinstore_http_status => Status},
    case decode_json(Body) of
        {ok, Json} -> Context1#{coinstore_json => Json};
        {error, _} -> maps:remove(coinstore_json, Context1)
    end.

assert_success(Context) ->
    case maps:get(response, Context, undefined) of
        [{status_code, Status}, _Headers, {body, Body}] when Status >= 200, Status < 300 ->
            case decode_json(Body) of
                {ok, Json} ->
                    case maps:get(<<"code">>, Json, undefined) of
                        0 ->
                            Context;
                        <<"0">> ->
                            Context;
                        undefined ->
                            fail(Context, "Coinstore response has no code field: ~p", [Json]);
                        Code ->
                            Msg = first_defined([
                                maps:get(<<"message">>, Json, undefined),
                                maps:get(<<"msg">>, Json, undefined),
                                <<>>
                            ]),
                            fail(Context, "Coinstore API returned code ~p: ~p", [Code, Msg])
                    end;
                {error, Why} ->
                    fail(Context, "Coinstore response is not valid JSON: ~p", [Why])
            end;
        [{status_code, Status}, _Headers, {body, Body}] ->
            fail(Context, "Coinstore HTTP status ~p: ~p", [Status, Body]);
        Other ->
            fail(Context, "Coinstore response missing or invalid: ~p", [Other])
    end.

%% ------------------------------------------------------------------
%% Endpoint and mutation policy
%% ------------------------------------------------------------------

endpoint(Context, Path0, Query0) ->
    Base = maps:get(coinstore_base_url, Context, ?DEFAULT_BASE_URL),
    case uri_string:parse(to_list(Base)) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            Scheme = to_list(Scheme0),
            Host = to_list(Host0),
            case transport(Scheme) of
                {ok, Transport} ->
                    Port = maps:get(port, Parsed, default_port(Transport)),
                    BasePath = to_bin(maps:get(path, Parsed, <<"/api">>)),
                    case normalize_request_path(BasePath, Path0) of
                        {ok, Path} ->
                            Query = query_bin(Query0),
                            ReqPath = with_query(Path, Query),
                            {ok, #{
                                host => Host,
                                port => Port,
                                transport => Transport,
                                path => Path,
                                request_path => ReqPath
                            }};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Other ->
            {error, {bad_base_url, Base, Other}}
    end.

normalize_request_path(BasePath0, Path0) ->
    BasePath = strip_trailing_slash(ensure_leading_slash(to_bin(BasePath0))),
    Path = ensure_leading_slash(to_bin(Path0)),
    case contains_scheme(Path) orelse binary:match(Path, <<"?">>) =/= nomatch of
        true ->
            {error, path_must_not_be_full_url_or_contain_query};
        false ->
            case Path of
                <<"/api", _/binary>> -> {ok, Path};
                _ -> {ok, <<BasePath/binary, Path/binary>>}
            end
    end.

mutation_allowed(Path, Context) ->
    case mutation_class(Path) of
        read_only -> ok;
        trading -> require_capability(coinstore_allow_trading, trading, Context);
        withdrawals -> require_capability(coinstore_allow_withdrawals, withdrawals, Context);
        transfers -> require_capability(coinstore_allow_transfers, transfers, Context)
    end.

mutation_class(Path) ->
    case binary:match(Path, <<"/trade/order/place">>) of
        {_, _} ->
            trading;
        nomatch ->
            case binary:match(Path, <<"/trade/order/cancel">>) of
                {_, _} ->
                    trading;
                nomatch ->
                    case binary:match(Path, <<"/fi/v3/asset/doWithdraw">>) of
                        {_, _} ->
                            withdrawals;
                        nomatch ->
                            case binary:match(Path, <<"/fi/v3/asset/cancelWithdraw">>) of
                                {_, _} ->
                                    withdrawals;
                                nomatch ->
                                    case binary:match(Path, <<"/v1/future/transfer">>) of
                                        {_, _} -> transfers;
                                        nomatch -> read_only
                                    end
                            end
                    end
            end
    end.

require_capability(Key, Name, Context) ->
    case maps:get(Key, Context, false) of
        true -> ok;
        false -> {error, {explicit_enable_required, Name}}
    end.

%% ------------------------------------------------------------------
%% Credential helpers
%% ------------------------------------------------------------------

credentials(Context) ->
    ApiName = maps:get(coinstore_api_key_secret, Context, ?DEFAULT_API_KEY_SECRET),
    SecretName = maps:get(coinstore_secret_key_secret, Context, ?DEFAULT_SECRET_KEY_SECRET),
    case {read_secret(ApiName), read_secret(SecretName)} of
        {{ok, ApiKey}, {ok, SecretKey}} -> {ok, to_bin(ApiKey), to_bin(SecretKey)};
        {{error, Why}, _} -> {error, {api_key_secret, ApiName, Why}};
        {_, {error, Why}} -> {error, {secret_key_secret, SecretName, Why}}
    end.

read_secret(Name0) ->
    Name = to_bin(Name0),
    Candidates =
        case existing_atom(Name) of
            {ok, Atom} -> [Atom, Name];
            error -> [Name]
        end,
    read_secret_candidates(Candidates).

read_secret_candidates([Key | Rest]) ->
    case secrets:retrieve_decrypt(Key) of
        {ok, Value} -> {ok, Value};
        _ -> read_secret_candidates(Rest)
    end;
read_secret_candidates([]) ->
    {error, not_found}.

existing_atom(Bin) ->
    try
        {ok, binary_to_existing_atom(Bin, utf8)}
    catch
        _:_ -> error
    end.

ensure_defaults(Context) ->
    Context#{
        coinstore_base_url => maps:get(coinstore_base_url, Context, ?DEFAULT_BASE_URL),
        coinstore_api_key_secret => maps:get(
            coinstore_api_key_secret, Context, ?DEFAULT_API_KEY_SECRET
        ),
        coinstore_secret_key_secret => maps:get(
            coinstore_secret_key_secret, Context, ?DEFAULT_SECRET_KEY_SECRET
        )
    }.

%% ------------------------------------------------------------------
%% Small helpers
%% ------------------------------------------------------------------

post_body(undefined) -> <<"{}">>;
post_body(<<>>) -> <<"{}">>;
post_body([]) -> <<"{}">>;
post_body(Body) -> to_bin(Body).

%% Coinstore documents timestamp as required for order placement. Convenience
%% order steps add it when omitted; the generic signed POST step never rewrites
%% a body, so it remains suitable for exact signature fixtures.
order_body(Body0) ->
    Body = post_body(Body0),
    try jsx:decode(Body, [return_maps]) of
        Json when is_map(Json) ->
            case maps:is_key(<<"timestamp">>, Json) of
                true -> Body;
                false -> jsx:encode(Json#{<<"timestamp">> => erlang:system_time(millisecond)})
            end;
        _ ->
            Body
    catch
        _:_ -> Body
    end.

query_bin(undefined) ->
    <<>>;
query_bin(<<>>) ->
    <<>>;
query_bin([]) ->
    <<>>;
query_bin(Query0) ->
    Query = to_bin(Query0),
    case Query of
        <<"?", Rest/binary>> -> Rest;
        _ -> Query
    end.

with_query(Path, <<>>) -> Path;
with_query(Path, Query) -> <<Path/binary, "?", Query/binary>>.

decode_json(<<>>) ->
    {error, empty_body};
decode_json(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Json when is_map(Json) -> {ok, Json};
        Other -> {error, {not_object, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

transport("https") -> {ok, tls};
transport("http") -> {ok, tcp};
transport(Other) -> {error, {unsupported_scheme, Other}}.

default_port(tls) -> 443;
default_port(tcp) -> 80.

contains_scheme(Bin) ->
    binary:match(Bin, <<"://">>) =/= nomatch.

ensure_leading_slash(<<"/", _/binary>> = B) -> B;
ensure_leading_slash(<<>>) -> <<"/">>;
ensure_leading_slash(B) -> <<"/", B/binary>>.

strip_trailing_slash(<<"/">>) ->
    <<>>;
strip_trailing_slash(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end;
strip_trailing_slash(Bin) ->
    Bin.

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([null | Rest]) -> first_defined(Rest);
first_defined([H | _]) -> H;
first_defined([]) -> undefined.

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

fail(Context, Fmt, Args) ->
    Message = iolist_to_binary(io_lib:format(Fmt, Args)),
    ?LOG_WARNING("~s", [Message]),
    maps:put(fail, Message, Context).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(Other) -> lists:flatten(io_lib:format("~p", [Other])).
-ifdef(TEST).

sign_known_answer_test() ->
    ?assertEqual(
        <<"4c4944b6957d4f5c833b3022e43da1f5773f2891a7ed004ee57644b376a76d8b">>,
        sign(<<"your secret_key">>, 1629291143107, <<"currencyCode=ETH">>)
    ).

default_endpoint_test() ->
    Context = ensure_defaults(#{}),
    ?assertMatch(
        {ok, #{request_path := <<"/api/trade/order/active?symbol=BTCUSDT">>}},
        endpoint(Context, <<"/trade/order/active">>, <<"symbol=BTCUSDT">>)
    ).

mutation_policy_test() ->
    ?assertEqual(trading, mutation_class(<<"/api/trade/order/placeBatch">>)),
    ?assertEqual(withdrawals, mutation_class(<<"/api/fi/v3/asset/doWithdraw">>)),
    ?assertEqual(read_only, mutation_class(<<"/api/v2/trade/order/active">>)).
-endif.
