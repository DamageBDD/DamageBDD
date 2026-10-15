%% Auth-gated, READ ONLY Cowboy 2+ JSON/dashboard handler.
%% The embedding DamageBDD router must pass a session-aware authorize fun.
%% Without that fun this handler DENIES ALL requests.
-module(ecai_mm_http).
-export([init/2, trails/0]).

%% All endpoints are GET-only and share the node-admin auth policy used by
%% /api/admin/settings/ecai. No mutating market execution API is mounted.
trails() ->
    Auth = fun damage_settings_http:node_admin/1,
    [
        trails:trail("/ecai/market-maker", ?MODULE,
            #{resource => dashboard, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["text/html"]}}),
        trails:trail("/ecai/market-maker/:asset", ?MODULE,
            #{resource => asset, authorize => Auth},
            #{get => #{tags => ["Node administration"]}}),
        trails:trail("/api/ecai/mm/status", ?MODULE,
            #{resource => <<"status">>, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["application/json"]}}),
        trails:trail("/api/ecai/mm/quotes", ?MODULE,
            #{resource => <<"quotes">>, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["application/json"]}}),
        trails:trail("/api/ecai/mm/price-cache", ?MODULE,
            #{resource => <<"price-cache">>, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["application/json"]}}),
        trails:trail("/api/ecai/mm/prices", ?MODULE,
            #{resource => <<"prices">>, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["application/json"]}}),
        trails:trail("/api/ecai/mm/history", ?MODULE,
            #{resource => <<"history">>, authorize => Auth},
            #{get => #{tags => ["Node administration"], produces => ["application/json"]}})
    ].

init(Req, Opts) ->
    case authorized(Req, Opts) of
        true ->
            case cowboy_req:method(Req) of
                <<"GET">> -> serve(Req, Opts);
                _ -> respond(405, <<"text/plain">>, <<"Method not allowed">>, Req, Opts)
            end;
        false ->
            respond(
                403,
                <<"text/plain; charset=utf-8">>,
                <<"Forbidden">>,
                Req,
                Opts
            )
    end.

authorized(Req, Opts) ->
    case maps:get(authorize, Opts, undefined) of
        Auth when is_function(Auth, 1) ->
            try
                Auth(Req) =:= true
            catch
                _:_ -> false
            end;
        _ ->
            false
    end.

serve(Req, Opts) ->
    Resource = maps:get(
        resource,
        Opts,
        cowboy_req:binding(resource, Req, <<"status">>)
    ),
    case Resource of
        <<"price-cache">> ->
            json(ecai_mm_price_cache:status(), Req, Opts);
        <<"prices">> ->
            prices_json(Req, Opts);
        <<"status">> ->
            live_json(fun ecai_mm:status/0, Req, Opts);
        <<"quotes">> ->
            live_json(fun ecai_mm:quotes/0, Req, Opts);
        <<"history">> ->
            Params = cowboy_req:parse_qs(Req),
            Limit =
                try
                    max(
                        1,
                        min(
                            2000,
                            binary_to_integer(
                                proplists:get_value(<<"limit">>, Params, <<"500">>)
                            )
                        )
                    )
                catch
                    _:_ -> 500
                end,
            live_json(fun() -> ecai_mm:history(Limit) end, Req, Opts);
        dashboard ->
            serve_asset(<<"index.html">>, Req, Opts);
        asset ->
            serve_asset(cowboy_req:binding(asset, Req, <<>>), Req, Opts);
        _ ->
            respond(404, <<"text/plain">>, <<"Not found">>, Req, Opts)
    end.

prices_json(Req, Opts) ->
    Params = cowboy_req:parse_qs(Req),
    Period = proplists:get_value(<<"period">>, Params, <<"60min">>),
    Symbol = proplists:get_value(<<"symbol">>, Params, undefined),
    Limit = try binary_to_integer(proplists:get_value(<<"limit">>, Params, <<"1000">>))
            catch _:_ -> invalid end,
    try
        Result = case Symbol of
            undefined -> ecai_mm_price_cache:history(Period, Limit);
            _ -> ecai_mm_price_cache:candles(Symbol, Period, Limit)
        end,
        case Result of
            {ok, Data} -> json(Data, Req, Opts);
            {error, _} -> respond(400, <<"application/json">>,
                <<"{\"error\":\"invalid_history_request\"}">>, Req, Opts)
        end
    catch exit:_ ->
        respond(503, <<"application/json">>,
            <<"{\"error\":\"price_cache_unavailable\"}">>, Req, Opts)
    end.

live_json(Fun, Req, Opts) ->
    case whereis(ecai_mm) of
        undefined ->
            respond(503, <<"application/json; charset=utf-8">>,
                <<"{\"error\":\"market_maker_disabled_or_unavailable\"}">>, Req, Opts);
        _ ->
            try json(Fun(), Req, Opts)
            catch _:_ ->
                respond(503, <<"application/json; charset=utf-8">>,
                    <<"{\"error\":\"market_maker_unavailable\"}">>, Req, Opts)
            end
    end.

json(Data, Req, Opts) ->
    try
        respond(
            200,
            <<"application/json; charset=utf-8">>,
            jsx:encode(Data),
            Req,
            Opts
        )
    catch
        _:_ ->
            respond(
                500,
                <<"text/plain">>,
                <<"Serialization failed">>,
                Req,
                Opts
            )
    end.

serve_asset(Name, Req, Opts) ->
    Type =
        case Name of
            <<"index.html">> -> <<"text/html; charset=utf-8">>;
            <<"app.js">> -> <<"text/javascript; charset=utf-8">>;
            <<"styles.css">> -> <<"text/css; charset=utf-8">>;
            _ -> forbidden
        end,
    case Type of
        forbidden ->
            respond(404, <<"text/plain">>, <<"Not found">>, Req, Opts);
        _ ->
            case code:priv_dir(damage) of
                {error, _} ->
                    respond(
                        503,
                        <<"text/plain">>,
                        <<"Asset directory unavailable">>,
                        Req,
                        Opts
                    );
                Priv ->
                    File = filename:join([
                        Priv,
                        "ui",
                        "ecai-market-maker",
                        binary_to_list(Name)
                    ]),
                    case file:read_file(File) of
                        {ok, Body} -> respond(200, Type, Body, Req, Opts);
                        _ -> respond(404, <<"text/plain">>, <<"Not found">>, Req, Opts)
                    end
            end
    end.

respond(Status, CType, Body, Req, Opts) ->
    Headers = #{
        <<"content-type">> => CType,
        <<"cache-control">> => <<"no-store">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"content-security-policy">> =>
            <<
                "default-src 'self'; script-src 'self'; style-src 'self'; "
                "connect-src 'self'; img-src 'self' data:; object-src 'none'; "
                "base-uri 'none'; frame-ancestors 'self'"
            >>
    },
    NewReq = cowboy_req:reply(Status, Headers, Body, Req),
    {ok, NewReq, Opts}.
