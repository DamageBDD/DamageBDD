%% Nostr-first browser auth; callback is the only endpoint exempt from origin checks.
-module(nosternity_auth_http).
-export([trails/0, init/2, origin/0, allowed/1, token/1, session/1, reply/3,
         read_json/1, error_reply/2, cookie/2, no_store/1]).

trails() -> [trails:trail(P, ?MODULE, #{action => A}, #{}) || {P, A} <- [
    {"/api/nosternity/auth/options", options},
    {"/api/nosternity/auth/session", session},
    {"/api/nosternity/auth/logout", logout},
    {"/api/nosternity/auth/nostr/challenge", nostr_challenge},
    {"/api/nosternity/auth/nostr/verify", nostr_verify},
    {"/api/nosternity/auth/lightning/challenge", lightning_challenge},
    {"/api/nosternity/auth/lightning/callback", lightning_callback},
    {"/api/nosternity/auth/lightning/poll", lightning_poll},
    {"/api/nosternity/auth/damage", damage}]].

init(Req0, #{action := Action} = State) ->
    Req = no_store(Req0),
    try route(Action, Req) of Req1 -> {ok, Req1, State}
    catch _:_ -> {ok, error_reply(auth_unavailable, Req), State} end.
route(options, Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> reply(200, #{origin => origin(), primary => nostr,
            signup_enabled => nosternity_config:get(auth_signup_enabled),
            providers => [nostr, lightning, damage],
            session_ttl_seconds => nosternity_config:get(auth_session_ttl_seconds)}, Req);
        _ -> error_reply(method_not_allowed, Req)
    end;
route(lightning_callback, Req) -> callback(Req);
route(Action, Req) ->
    Method = case Action of session -> <<"GET">>; _ -> <<"POST">> end,
    case {cowboy_req:method(Req) =:= Method, allowed(Req)} of
        {false, _} -> error_reply(method_not_allowed, Req);
        {_, false} -> error_reply(origin_rejected, Req);
        {true, true} when Action =:= session ->
            case session(Req) of {ok, S} -> reply(200, public_session(S), Req); Error -> result(Error, Req) end;
        {true, true} when Action =:= logout ->
            case nosternity_auth:revoke(token(Req)) of
                ok -> reply(200, #{authenticated => false}, set_cookie(<<"nosternity_session">>, <<>>, 0, Req));
                Error -> result(Error, Req)
            end;
        {true, true} ->
            {Peer, _} = cowboy_req:peer(Req),
            case nosternity_auth:attempt(Peer) of
                ok -> case read_json(Req) of
                    {ok, Obj, Raw, Req1} -> dispatch(Action, Obj, Raw, Peer, Req1);
                    {error, Why, Req1} -> error_reply(Why, Req1)
                end;
                Error -> result(Error, Req)
            end
    end.

dispatch(Action, #{<<"intent">> := Intent} = Obj, _, Peer, Req0)
  when (Action =:= nostr_challenge orelse Action =:= lightning_challenge), map_size(Obj) =:= 1 ->
    {Binding, Req} = binding(Req0),
    Provider = case Action of nostr_challenge -> nostr; lightning_challenge -> lightning end,
    result(nosternity_auth:challenge(Provider, Intent, origin(), Binding, Peer), Req);
dispatch(nostr_verify, #{<<"challenge_id">> := Id}, Raw, _, Req) ->
    Event = decode_proof(cowboy_req:header(<<"authorization">>, Req)),
    finish(nosternity_auth:verify_nostr(Id, Event, Raw, origin(), cookie(<<"nosternity_binding">>, Req)), Req);
dispatch(lightning_poll, #{<<"challenge_id">> := Id} = Obj, _, _, Req) when map_size(Obj) =:= 1 ->
    case nosternity_auth:poll_lightning(Id, origin(), cookie(<<"nosternity_binding">>, Req)) of
        {ok, pending} -> reply(202, #{status => pending}, Req);
        Result -> finish(Result, Req)
    end;
dispatch(damage, #{<<"intent">> := Intent} = Obj, _, _, Req) when map_size(Obj) =:= 1 ->
    %% Resolve the actual DamageBDD browser cookie, never an address from JSON.
    case damage_browser_auth:lookup(cookie(<<"sessionid">>, Req)) of
        {ok, #{address := Address}} -> finish(nosternity_auth:damage(Address, Intent), Req);
        _ -> error_reply(damage_login_required, Req)
    end;
dispatch(_, _, _, _, Req) -> error_reply(invalid_request, Req).

callback(Req) ->
    {Peer, _} = cowboy_req:peer(Req),
    Result = try
        <<"GET">> = cowboy_req:method(Req),
        true = byte_size(cowboy_req:qs(Req)) =< 1024,
        ok = nosternity_auth:attempt({lightning_callback, Peer}),
        Pairs = cowboy_req:parse_qs(Req), Map = maps:from_list(Pairs),
        true = length(Pairs) =:= map_size(Map),
        #{<<"tag">> := <<"login">>, <<"k1">> := Id, <<"sig">> := Sig,
          <<"key">> := Key, <<"action">> := Action} = Map,
        5 = map_size(Map),
        nosternity_auth:verify_lightning(Id, Sig, Key, Action)
    catch _:_ -> {error, invalid_request} end,
    %% LUD-04 uses status OK/ERROR; callback never sets the browser's session cookie.
    case Result of
        ok -> reply(200, #{status => <<"OK">>}, Req);
        _ -> reply(200, #{status => <<"ERROR">>, reason => <<"Invalid, expired or used authentication challenge">>}, Req)
    end.

finish({ok, Token, S}, Req) ->
    case nosternity_auth:revoke(token(Req)) of
        ok -> reply(200, public_session(S), set_cookie(<<"nosternity_session">>, Token,
                nosternity_config:get(auth_session_ttl_seconds), Req));
        Error -> _ = nosternity_auth:revoke(Token), result(Error, Req)
    end;
finish(Result, Req) -> result(Result, Req).
public_session(S) -> S#{authenticated => true,
    capabilities => #{social_write => maps:get(provider, S) =:= nostr, damage_custody => false}}.
result({ok, Body}, Req) when is_map(Body) -> reply(200, Body, Req);
result({error, Why}, Req) -> error_reply(Why, Req).
session(Req) -> nosternity_auth:lookup(token(Req)).
token(Req) -> cookie(<<"nosternity_session">>, Req).
cookie(Name, Req) -> proplists:get_value(Name, cowboy_req:parse_cookies(Req), <<>>).
origin() -> damage_browser_auth_http:configured_origin(nosternity).
allowed(Req) ->
    Expected = origin(), Method = cowboy_req:method(Req),
    O = cowboy_req:header(<<"origin">>, Req),
    ((Method =:= <<"GET">> andalso O =:= undefined) orelse O =:= Expected) andalso
    cowboy_req:header(<<"x-nosternity-auth">>, Req) =:= <<"1">> andalso
    cowboy_req:header(<<"sec-fetch-site">>, Req) =/= <<"cross-site">>.
binding(Req) ->
    case cookie(<<"nosternity_binding">>, Req) of
        B when byte_size(B) =:= 64 -> {B, Req};
        _ -> B = nosternity_auth_proof:hex(crypto:strong_rand_bytes(32)),
             {B, set_cookie(<<"nosternity_binding">>, B, 600, Req)}
    end.
set_cookie(Name, Value, MaxAge, Req) ->
    %% Secure derives from the operator's canonical origin, never request headers.
    Secure = case origin() of <<"https://", _/binary>> -> true; _ -> false end,
    cowboy_req:set_resp_cookie(Name, Value, Req, #{path => <<"/">>, max_age => MaxAge,
        secure => Secure, http_only => true, same_site => strict}).
decode_proof(<<"Nostr ", Encoded/binary>>) when byte_size(Encoded) =< 8192 ->
    try jsx:decode(base64:decode(Encoded), [return_maps]) catch _:_ -> invalid end;
decode_proof(_) -> invalid.
read_json(Req) ->
    Header = cowboy_req:header(<<"content-type">>, Req, <<>>),
    [Type | _] = binary:split(Header, <<";">>),
    case string:lowercase(string:trim(Type)) of
        <<"application/json">> ->
            case cowboy_req:read_body(Req, #{length => 65536, period => 5000}) of
                {ok, Raw, Req1} when byte_size(Raw) =< 65536 ->
                    try jsx:decode(Raw, [return_maps]) of
                        M when is_map(M) -> {ok, M, Raw, Req1};
                        _ -> {error, invalid_request, Req1}
                    catch _:_ -> {error, invalid_json, Req1} end;
                {_, _, Req1} -> {error, body_too_large, Req1}
            end;
        _ -> {error, expected_json, Req}
    end.
error_reply(Why, Req) ->
    Code = case Why of
        unauthorized -> 401; invalid_proof -> 401; invalid_challenge -> 401;
        account_not_found -> 404; damage_login_required -> 401;
        origin_rejected -> 403; nostr_login_required -> 403;
        signup_unavailable -> 403; rate_limited -> 429;
        method_not_allowed -> 405; body_too_large -> 413; expected_json -> 415;
        search_unavailable -> 503; auth_unavailable -> 503; account_store_unavailable -> 503; session_capacity -> 503;
        _ -> 400
    end,
    reply(Code, #{error => Why}, Req).
no_store(Req) -> cowboy_req:set_resp_headers(#{<<"cache-control">> => <<"no-store">>,
    <<"referrer-policy">> => <<"no-referrer">>, <<"x-content-type-options">> => <<"nosniff">>}, Req).
reply(Code, Body, Req) -> cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json; charset=utf-8">>}, jsx:encode(Body), no_store(Req)).
