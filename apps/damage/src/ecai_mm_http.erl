%% Auth-gated, READ ONLY Cowboy 2+ JSON/dashboard handler.
%% The embedding DamageBDD router must pass a session-aware authorize fun.
%% Without that fun this handler DENIES ALL requests.
-module(ecai_mm_http).
-export([init/2]).

init(Req, Opts) ->
    case authorized(Req, Opts) of
        true ->
            serve(Req, Opts);
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
        <<"status">> ->
            json(ecai_mm:status(), Req, Opts);
        <<"quotes">> ->
            json(ecai_mm:quotes(), Req, Opts);
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
            json(ecai_mm:history(Limit), Req, Opts);
        dashboard ->
            serve_asset(<<"index.html">>, Req, Opts);
        asset ->
            serve_asset(cowboy_req:binding(asset, Req, <<>>), Req, Opts);
        _ ->
            respond(404, <<"text/plain">>, <<"Not found">>, Req, Opts)
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
