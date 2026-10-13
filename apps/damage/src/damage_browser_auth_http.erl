%% Same-origin browser authentication API. Deliberately separate from ae1 API tokens.
-module(damage_browser_auth_http).
-export([trails/0, trails/1, init/2, configured_origin/0, configured_origin/1, origin/1]).
-ifdef(TEST).
-export([request_origin_allowed/5]).
-endif.

trails() -> trails(damage).

%% App is a trusted router option, never supplied by the browser. Each listener
%% has one exact configured origin; do not allow both origins on either listener.
trails(App) when App =:= damage; App =:= ecai; App =:= nosternity ->
    [
        trails:trail(
            Path,
            ?MODULE,
            #{action => Action, browser_auth_app => App},
            #{Method => #{tags => ["Browser authentication"], produces => ["application/json"]}}
        )
     || {Path, Action, Method} <- [
            {"/accounts/auth/options", options, get},
            {"/accounts/session", session, get},
            {"/accounts/login", login, post},
            {"/accounts/signup", signup, post},
            {"/accounts/recovery", recovery, post},
            {"/accounts/wallet/challenge", challenge, post},
            {"/accounts/wallet/verify", verify, post},
            {"/accounts/session/logout", logout, post}
        ]
    ].

init(Req, #{action := Action} = State) ->
    try handle(Action, Req, configured_origin(maps:get(browser_auth_app, State, damage))) of
        Req1 -> {ok, Req1, State}
    catch
        error:ecai_browser_auth_origin_missing ->
            {ok,
                reply(
                    503,
                    #{
                        status => <<"error">>,
                        error => <<"auth_origin_not_configured">>,
                        message =>
                            <<"Configure ecai.browser_auth_origin with this dashboard's exact public HTTPS origin.">>
                    },
                    Req
                ),
                State};
        _:_ ->
            {ok,
                reply(
                    503,
                    #{
                        status => <<"error">>,
                        error => <<"auth_unavailable">>,
                        message =>
                            <<"Authentication is unavailable. Retry without changing your wallet or password.">>
                    },
                    Req
                ),
                State}
    end.

handle(options, Req, Origin) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            reply(
                200,
                #{
                    status => <<"ok">>,
                    origin => Origin,
                    network_id => maps:get(network_id, damage_browser_auth:options())
                },
                Req
            );
        _ ->
            reply(405, #{error => <<"method_not_allowed">>}, Req)
    end;
handle(Action, Req, Origin) ->
    Expected =
        case Action of
            session -> <<"GET">>;
            _ -> <<"POST">>
        end,
    case {cowboy_req:method(Req) =:= Expected, same_origin(Req, Expected, Origin)} of
        {false, _} ->
            reply(405, #{error => <<"method_not_allowed">>}, Req);
        {_, false} ->
            reply(
                403,
                #{
                    error => <<"origin_rejected">>,
                    message => <<"Open the configured DamageBDD origin and try again.">>
                },
                Req
            );
        {true, true} when Action =:= session -> session(Req);
        {true, true} when Action =:= logout ->
            case damage_browser_auth:revoke(token(Req)) of
                ok ->
                    reply(200, #{status => <<"ok">>}, damage_access_token:clear_access_cookie(Req));
                {error, Why} ->
                    auth_error(Why, Req)
            end;
        {true, true} ->
            {Peer, _Port} = cowboy_req:peer(Req),
            case damage_browser_auth:attempt(Peer) of
                ok -> read(Action, Peer, Req, Origin);
                {error, Why} -> auth_error(Why, Req)
            end
    end.

same_origin(Req, Method, Expected) ->
    request_origin_allowed(
        Expected,
        Method,
        cowboy_req:header(<<"origin">>, Req),
        cowboy_req:header(<<"x-damage-auth">>, Req),
        cowboy_req:header(<<"sec-fetch-site">>, Req)
    ).
request_origin_allowed(Expected, Method, Origin, AuthHeader, FetchSite) ->
    ValidOrigin =
        case Origin of
            undefined -> Method =:= <<"GET">>;
            _ -> Origin =:= Expected
        end,
    ValidOrigin andalso AuthHeader =:= <<"1">> andalso FetchSite =/= <<"cross-site">>.
configured_origin(nosternity) ->
    case application:get_env(nosternity, browser_auth_origin) of
        {ok, Value} -> origin(Value);
        undefined -> error(nosternity_browser_auth_origin_missing)
    end;
configured_origin(ecai) ->
    case application:get_env(ecai, browser_auth_origin) of
        {ok, Value} -> origin(Value);
        undefined -> error(ecai_browser_auth_origin_missing)
    end;
configured_origin(damage) ->
    configured_origin().
configured_origin() ->
    C = application:get_env(damage, browser_auth, []),
    origin(proplists:get_value(origin, C, application:get_env(damage, api_url, ""))).
origin(Value) ->
    case uri_string:parse(unicode:characters_to_binary(Value)) of
        #{scheme := Scheme, host := Host} = P when Scheme =:= <<"https">>; Scheme =:= <<"http">> ->
            false = maps:is_key(userinfo, P),
            true = byte_size(Host) > 0,
            Port = maps:get(
                port,
                P,
                case Scheme of
                    <<"https">> -> 443;
                    _ -> 80
                end
            ),
            AllowedHttp =
                Scheme =:= <<"https">> orelse
                    lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>]),
            true = AllowedHttp,
            HostText =
                case binary:match(Host, <<":">>) of
                    nomatch -> Host;
                    _ -> <<"[", Host/binary, "]">>
                end,
            Suffix =
                case {Scheme, Port} of
                    {<<"https">>, 443} -> <<>>;
                    {<<"http">>, 80} -> <<>>;
                    _ -> <<":", (integer_to_binary(Port))/binary>>
                end,
            <<Scheme/binary, "://", HostText/binary, Suffix/binary>>;
        _ ->
            error(invalid_browser_auth_origin)
    end.

read(Action, Peer, Req0, Origin) ->
    case cowboy_req:read_body(Req0, #{length => 8192, period => 5000}) of
        {ok, Data, Req} when byte_size(Data) =< 8192 ->
            Json =
                try
                    jsx:decode(Data, [return_maps])
                catch
                    _:_ -> invalid
                end,
            case is_map(Json) of
                true -> dispatch(Action, Json, Peer, Req, Origin);
                false -> reply(400, #{error => <<"invalid_json">>}, Req)
            end;
        {_, _, Req} ->
            reply(413, #{error => <<"request_too_large">>}, Req)
    end.

dispatch(login, #{<<"username">> := Email0, <<"password">> := Password}, _, Req, _Origin) when
    is_binary(Email0), byte_size(Email0) =< 254, is_binary(Password), byte_size(Password) =< 1024
->
    Email = string:trim(Email0),
    case damage_accounts:check_credentials(Email, Password) of
        {ok, Account, _PrivateKey} ->
            finish(damage_browser_auth:issue(Account, custodial, Email), Req);
        _ ->
            reply(
                401,
                #{status => <<"failed">>, message => <<"Email or password is incorrect.">>},
                Req
            )
    end;
dispatch(signup, #{<<"email">> := E}, _, Req, _Origin) when is_binary(E), byte_size(E) =< 254 ->
    {Code, Body} = damage_accounts:browser_action(create, #{email => string:trim(E)}),
    reply(Code, Body, Req);
dispatch(recovery, #{<<"email">> := E}, _, Req, _Origin) when is_binary(E), byte_size(E) =< 254 ->
    {Code, Body} = damage_accounts:browser_action(reset_password, #{email => string:trim(E)}),
    reply(Code, Body, Req);
dispatch(challenge, #{<<"address">> := Address}, Peer, Req0, Origin) ->
    {Binding, Req} = binding_cookie(Req0),
    case damage_browser_auth:challenge(Address, Origin, Binding, Peer) of
        {ok, C} -> reply(200, C#{status => <<"ok">>}, Req);
        {error, Why} -> auth_error(Why, Req)
    end;
dispatch(verify, #{<<"challenge_id">> := Id, <<"signature">> := Signature}, _, Req, Origin) ->
    Binding = cookie(<<"damage_auth_binding">>, Req),
    finish(damage_browser_auth:verify(Id, Signature, Origin, Binding), Req);
dispatch(_, _, _, Req, _Origin) ->
    reply(400, #{error => <<"invalid_request">>}, Req).

session(Req) ->
    Token = token(Req),
    case damage_browser_auth:lookup(Token) of
        {ok, S} -> reply(200, session_body(Token, S), Req);
        {error, auth_unavailable} -> auth_error(auth_unavailable, Req);
        _ -> reply(401, #{authenticated => false, error => <<"session_expired">>}, Req)
    end.
finish({ok, Token, S}, Req0) ->
    %% Rotate the previous browser session only after the new identity is verified.
    case damage_browser_auth:revoke(token(Req0)) of
        ok ->
            Req = damage_access_token:set_access_cookie(Req0, Token),
            reply(200, session_body(Token, S), Req);
        {error, Why} ->
            _ = damage_browser_auth:revoke(Token),
            auth_error(Why, Req0)
    end;
finish({error, Why}, Req) ->
    auth_error(Why, Req).
session_body(Token, S) ->
    Mode = maps:get(mode, S),
    (maps:remove(email, S))#{
        status => <<"ok">>,
        authenticated => true,
        access_token => Token,
        email =>
            case maps:get(email, S, undefined) of
                undefined -> null;
                Email -> Email
            end,
        capabilities => damage_wallet_policy:capabilities(Mode)
    }.
token(Req) ->
    case damage_access_token:get_access_token(Req) of
        {access_token, <<"ds1.", _/binary>> = Token} -> Token;
        _ -> <<>>
    end.
cookie(Name, Req) -> proplists:get_value(Name, cowboy_req:parse_cookies(Req), <<>>).
binding_cookie(Req) ->
    case cookie(<<"damage_auth_binding">>, Req) of
        B when byte_size(B) =:= 64 -> {B, Req};
        _ ->
            B = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(32))),
            Secure = application:get_env(damage, cookie_secure, true),
            {B,
                cowboy_req:set_resp_cookie(
                    <<"damage_auth_binding">>,
                    B,
                    Req,
                    #{
                        path => <<"/">>,
                        http_only => true,
                        same_site => lax,
                        secure => Secure,
                        max_age => 600
                    }
                )}
    end.
auth_error(Why, Req) ->
    {Code, Message} =
        case Why of
            rate_limited ->
                {429, <<"Too many attempts. Wait a minute and retry.">>};
            invalid_signature ->
                {401, <<"The wallet signature could not be verified. Start a new sign-in.">>};
            invalid_challenge ->
                {401, <<"This sign-in request expired or was already used. Connect again.">>};
            _ ->
                {503, <<"Authentication is unavailable. Please retry.">>}
        end,
    reply(Code, #{status => <<"failed">>, error => Why, message => Message}, Req).
reply(Code, Body, Req) ->
    cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"pragma">> => <<"no-cache">>,
            <<"referrer-policy">> => <<"no-referrer">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(Body),
        Req
    ).
