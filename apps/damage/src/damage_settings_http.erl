%%%-------------------------------------------------------------------
%%% Node-admin-only node configuration routes, separate from account settings.
%%% Plain Cowboy handler (not cowboy_rest).
%%% Resolve authentication through damage_auth. Wallet-mode sessions never
%%% receive node_admin, even if their AE address is on the node-admin allowlist.
%%%-------------------------------------------------------------------
-module(damage_settings_http).

-export([init/2, trails/0]).

-define(JSON, #{
    <<"content-type">> => <<"application/json; charset=utf-8">>,
    <<"cache-control">> => <<"no-store">>,
    <<"x-content-type-options">> => <<"nosniff">>
}).

trails() ->
    AppRoutes = lists:flatmap(
        fun(App) ->
            Name = atom_to_list(App),
            [
                trails:trail(
                    "/dashboard/node/settings/" ++ Name,
                    ?MODULE,
                    #{action => page, app => App},
                    #{get => #{tags => ["Node administration"], produces => ["text/html"]}}
                ),
                trails:trail(
                    "/api/admin/settings/" ++ Name,
                    ?MODULE,
                    #{action => app, app => App},
                    #{
                        get => #{tags => ["Node administration"], produces => ["application/json"]},
                        post => #{tags => ["Node administration"], produces => ["application/json"]}
                    }
                )
            ]
        end,
        damage_settings_schema:apps()
    ),
    [
        trails:trail(
            "/dashboard/node/settings",
            ?MODULE,
            #{action => page, app => damage},
            #{get => #{tags => ["Node administration"], produces => ["text/html"]}}
        )
        | AppRoutes
    ] ++
        [
            trails:trail(
                "/api/admin/settings/status",
                ?MODULE,
                #{action => status},
                #{get => #{tags => ["Node administration"], produces => ["application/json"]}}
            ),
            trails:trail(
                "/api/admin/settings/reload",
                ?MODULE,
                #{action => reload},
                #{post => #{tags => ["Node administration"], produces => ["application/json"]}}
            )
        ].

init(Req0, Opts) ->
    Req =
        case authorize(Req0) of
            {ok, Req1} -> dispatch(Req1, Opts);
            {error, Req1} -> reply_json(403, #{error => <<"node_admin_required">>}, Req1)
        end,
    {ok, Req, Opts}.

authorize(Req) ->
    %% Do not derive elevated permissions from an account address alone.
    %% This must stay in sync with damage_tax_http's node-admin policy.
    try damage_auth:authenticate(Req, #{action => admin_settings}) of
        {ok, #{
            authenticated := true,
            node_admin := true,
            public_key := PublicKey
        }} ->
            case steps_utils:is_admin(PublicKey) of
                true -> {ok, Req};
                _ -> {error, Req}
            end;
        _ ->
            {error, Req}
    catch
        _:_ -> {error, Req}
    end.

dispatch(Req, #{action := page, app := App}) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> page(App, Req);
        _ -> method_not_allowed(<<"GET">>, Req)
    end;
dispatch(Req, #{action := app, app := App}) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case safe_call(fun() -> damage_settings:get(App) end) of
                {ok, Fields} -> reply_json(200, Fields, Req);
                {error, Reason} -> reply_error(503, Reason, Req)
            end;
        <<"POST">> ->
            with_mutation(Req, fun(Req1, Json) -> action(App, Json, Req1) end);
        _ ->
            method_not_allowed(<<"GET, POST">>, Req)
    end;
dispatch(Req, #{action := status}) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case safe_call(fun damage_settings:status/0) of
                {ok, Result} -> reply_json(200, Result, Req);
                {error, Reason} -> reply_error(503, Reason, Req)
            end;
        _ ->
            method_not_allowed(<<"GET">>, Req)
    end;
dispatch(Req, #{action := reload}) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            with_mutation(Req, fun(Req1, _Json) ->
                case safe_call(fun damage_settings:reload/0) of
                    {ok, Status} -> reply_json(200, Status, Req1);
                    {error, Why} -> reply_error(422, Why, Req1)
                end
            end);
        _ ->
            method_not_allowed(<<"POST">>, Req)
    end;
dispatch(Req, _) ->
    reply_json(404, #{error => <<"not_found">>}, Req).

with_mutation(Req0, Fun) ->
    %% A cross-site HTML form cannot set this custom header. No CORS headers
    %% are provided; JSON bodies and strict Origin checks add defence in depth.
    case csrf_check(Req0) of
        ok ->
            case cowboy_req:header(<<"content-type">>, Req0, <<>>) of
                <<"application/json", _/binary>> ->
                    case
                        cowboy_req:read_body(Req0, #{
                            length => 65536,
                            period => 5000,
                            timeout => 5000
                        })
                    of
                        {ok, Body, Req} ->
                            try jsx:decode(Body, [return_maps]) of
                                Json when is_map(Json), map_size(Json) =< 100 -> Fun(Req, Json);
                                _ -> reply_json(400, #{error => <<"invalid_json_object">>}, Req)
                            catch
                                _:_ -> reply_json(400, #{error => <<"invalid_json">>}, Req)
                            end;
                        {more, _Chunk, Req} ->
                            reply_json(413, #{error => <<"request_too_large">>}, Req)
                    end;
                _ ->
                    reply_json(415, #{error => <<"json_required">>}, Req0)
            end;
        {error, Why} ->
            reply_json(403, #{error => Why}, Req0)
    end.

csrf_check(Req) ->
    case cowboy_req:header(<<"x-damage-settings-action">>, Req) of
        <<"1">> -> origin_check(Req);
        _ -> {error, <<"admin_action_header_required">>}
    end.

origin_check(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            %% CLI requests use Bearer auth and need not send Origin, but must
            %% still supply the non-simple custom action header.
            ok;
        Origin ->
            try
                OriginParts = uri_string:parse(Origin),
                Host = cowboy_req:header(<<"host">>, Req, <<>>),
                OriginHost = maps:get(host, OriginParts),
                OriginPort = maps:get(port, OriginParts, undefined),
                Scheme = maps:get(scheme, OriginParts),
                HostOnly =
                    case binary:split(Host, <<":">>) of
                        [HeaderHostWithPort, _] -> HeaderHostWithPort;
                        [HeaderHost] -> HeaderHost
                    end,
                ReqPort =
                    case binary:split(Host, <<":">>) of
                        [_, HeaderPort] -> binary_to_integer(HeaderPort);
                        _ -> undefined
                    end,
                EffectivePort =
                    case {Scheme, OriginPort} of
                        {<<"https">>, undefined} -> 443;
                        {<<"http">>, undefined} -> 80;
                        {_, OriginExplicitPort} -> OriginExplicitPort
                    end,
                EffectiveReqPort =
                    case ReqPort of
                        undefined when Scheme =:= <<"https">> -> 443;
                        undefined -> 80;
                        ExplicitReqPort -> ExplicitReqPort
                    end,
                case
                    OriginHost =:= HostOnly andalso EffectivePort =:= EffectiveReqPort andalso
                        (Scheme =:= <<"https">> orelse Scheme =:= <<"http">>)
                of
                    true -> ok;
                    false -> {error, <<"cross_origin_request">>}
                end
            catch
                _:_ -> {error, <<"invalid_origin">>}
            end
    end.

action(
    App,
    #{
        <<"action">> := <<"save">>,
        <<"changes">> := Changes,
        <<"version">> := Version
    },
    Req
) ->
    mutation_reply(safe_call(fun() -> damage_settings:save(App, Changes, Version) end), Req);
action(
    App,
    #{
        <<"action">> := <<"reset">>,
        <<"keys">> := Names,
        <<"version">> := Version
    },
    Req
) ->
    mutation_reply(safe_call(fun() -> damage_settings:reset(App, Names, Version) end), Req);
action(_App, _Json, Req) ->
    reply_json(400, #{error => <<"invalid_settings_action">>}, Req).

mutation_reply({ok, Result}, Req) ->
    reply_json(200, Result, Req);
mutation_reply({error, {conflict, Version}}, Req) ->
    reply_json(409, #{error => <<"config_changed">>, version => Version}, Req);
mutation_reply({error, {invalid_value, Name, Why}}, Req) ->
    reply_json(
        422,
        #{
            error => <<"invalid_value">>,
            field => Name,
            reason => to_bin(Why)
        },
        Req
    );
mutation_reply({error, {not_editable, Name}}, Req) ->
    reply_json(422, #{error => <<"field_not_editable">>, field => Name}, Req);
mutation_reply({error, invalid_changes}, Req) ->
    reply_json(400, #{error => <<"invalid_changes">>}, Req);
mutation_reply({error, invalid_payload}, Req) ->
    reply_json(400, #{error => <<"invalid_payload">>}, Req);
mutation_reply({error, Why}, Req) ->
    reply_error(422, Why, Req).

page(App, Req) ->
    Priv = code:priv_dir(damage),
    File = filename:join([Priv, "static", "settings", "index.html"]),
    case file:read_file(File) of
        {ok, Template} ->
            Name = atom_to_binary(App, utf8),
            Html = binary:replace(Template, <<"__APP__">>, Name, [global]),
            Headers = #{
                <<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>,
                <<"x-content-type-options">> => <<"nosniff">>,
                <<"referrer-policy">> => <<"no-referrer">>,
                <<"content-security-policy">> =>
                    <<"default-src 'none'; script-src 'self'; style-src 'self'; ",
                        "connect-src 'self'; img-src 'self'; base-uri 'none'; ",
                        "frame-ancestors 'self'">>
            },
            cowboy_req:reply(200, Headers, Html, Req);
        {error, _} ->
            reply_json(503, #{error => <<"settings_template_missing">>}, Req)
    end.

safe_call(F) ->
    try F() of
        {ok, _} = Ok -> Ok;
        {error, _} = Error -> Error;
        _ -> {error, invalid_service_response}
    catch
        exit:{noproc, _} -> {error, settings_service_unavailable};
        exit:{timeout, _} -> {error, settings_service_timeout};
        _:_ -> {error, settings_service_failed}
    end.

method_not_allowed(Allow, Req) ->
    cowboy_req:reply(
        405,
        maps:merge(?JSON, #{<<"allow">> => Allow}),
        jsx:encode(#{error => <<"method_not_allowed">>}),
        Req
    ).

reply_error(Status, Why, Req) ->
    reply_json(Status, #{error => to_bin(Why)}, Req).

reply_json(Status, Json, Req) ->
    cowboy_req:reply(Status, ?JSON, jsx:encode(Json), Req).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
