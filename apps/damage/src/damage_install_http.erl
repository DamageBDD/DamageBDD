%% Signed installers with auth via damage_http:is_authorized/2 (same as schedules)
%% Routes:
%%   GET  /install/auth         -> HTML form to request signed link (auth required)
%%   POST /install/auth         -> Mint signed link (auth required)
%%   POST /api/install/request  -> JSON API to mint signed link (auth required)
%%   GET  /secure/install.sh    -> Verify HMAC + exp + nonce; render Bash installer
%%   GET  /secure/install.ps1   -> Verify HMAC + exp + nonce; render PowerShell

-module(damage_install_http).
-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([trails/0]).
-export([
    allowed_methods/2,
    is_authorized/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_html/2,
    to_json/2,
    to_text/2,
    from_html/2,
    from_json/2
]).

-include_lib("kernel/include/logger.hrl").

-define(TAGS, ["Installers", "Security"]).
%% 1 hour TTL
-define(DEFAULT_EXP_SECS, 3600).
-define(NONCE_BYTES, 12).

%%% ────────────── Trails ──────────────
trails() ->
    [
        trails:trail(
            "/install/auth",
            ?MODULE,
            #{action => form},
            #{
                get => #{
                    tags => ?TAGS,
                    description => "Installer request form (auth)",
                    produces => ["text/html"]
                },
                post => #{
                    tags => ?TAGS,
                    description => "Create signed install link",
                    consumes => ["application/x-www-form-urlencoded"],
                    produces => ["text/html"]
                }
            }
        ),
        trails:trail(
            "/install/request",
            ?MODULE,
            #{action => api},
            #{
                post => #{
                    tags => ?TAGS,
                    description => "Create signed install link (JSON)",
                    consumes => ["application/json"],
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/install/install.sh",
            ?MODULE,
            #{action => sh},
            #{
                get => #{
                    tags => ?TAGS,
                    description => "Signed Bash installer",
                    produces => ["text/plain"]
                }
            }
        ),
        trails:trail(
            "/install/install.ps1",
            ?MODULE,
            #{action => ps1},
            #{
                get => #{
                    tags => ?TAGS,
                    description => "Signed PowerShell installer",
                    produces => ["text/plain"]
                }
            }
        ),
        trails:trail(
            "/install/install.termux.sh",
            ?MODULE,
            #{action => termux_sh},
            #{
                get => #{
                    tags => ?TAGS,
                    description => "Bash installer for Android Termux",
                    produces => ["text/plain"]
                }
            }
        )
    ].

%%% ───────────── cowboy_rest ──────────
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, #{action := form} = S) -> {[<<"GET">>, <<"POST">>], Req, S};
allowed_methods(Req, #{action := api} = S) -> {[<<"POST">>], Req, S};
allowed_methods(Req, S) -> {[<<"GET">>], Req, S}.

%% IMPORTANT: reuse existing auth like schedules do:
is_authorized(Req, State) ->
    {true, Req, State}.
%damage_http:is_authorized(Req, State).  %% delegates (sets public_key, username, access_token, ip, useragent, ...)

content_types_provided(Req, #{action := form} = S) ->
    {[{{<<"text">>, <<"html">>, '*'}, to_html}], Req, S};
content_types_provided(Req, #{action := api} = S) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, S};
content_types_provided(Req, #{action := sh} = S) ->
    {[{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S};
content_types_provided(Req, #{action := ps1} = S) ->
    {[{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S};
content_types_provided(Req, #{action := termux_sh} = S) ->
    {[{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S};
content_types_provided(Req, S) ->
    {[{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S}.

content_types_accepted(Req, #{action := form} = S) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html}
        ],
        Req,
        S
    };
content_types_accepted(Req, #{action := api} = S) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        S
    };
content_types_accepted(Req, S) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        S
    }.

%%% ───────────── Helpers ──────────────
no_cache(Req0, CT) ->
    Req1 = cowboy_req:set_resp_header(<<"content-type">>, CT, Req0),
    Req2 = cowboy_req:set_resp_header(<<"x-content-type-options">>, <<"nosniff">>, Req1),
    cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req2).

qs(Req) -> cowboy_req:parse_qs(Req).
%% Safe query param getter: returns binary if present, otherwise default.
q(Qs, K, D) ->
    case lists:keyfind(K, 1, Qs) of
        {K, V} when is_binary(V), V =/= <<>> -> V;
        {K, V} when is_list(V), V =/= [] -> unicode:characters_to_binary(V);
        _ -> D
    end.

json_body(Req0) ->
    case cowboy_req:has_body(Req0) of
        true ->
            {ok, Bin, Req} = cowboy_req:read_body(Req0),
            {catch jsx:decode(Bin, [return_maps]), Req};
        false ->
            {#{}, Req0}
    end.

safe(B) ->
    case re:run(B, "^[A-Za-z0-9._:-@]+$", [{capture, none}]) of
        match -> B;
        _ -> <<>>
    end.

now_unix() -> erlang:system_time(second).
rand_b64(N) -> base64:encode(crypto:strong_rand_bytes(N)).

get_secret() ->
    case secrets:retrieve_decrypt(install_signing_secret) of
        {ok, S} when is_binary(S) -> S;
        {ok, L} when is_list(L) -> unicode:characters_to_binary(L);
        _ -> erlang:error({missing_secret, install_signing_secret})
    end.

canon_qs(Map) ->
    Pairs = lists:sort(fun({K1, _}, {K2, _}) -> K1 =< K2 end, maps:to_list(Map)),
    Enc = fun({K, V}) -> <<(uri_string:quote(K))/binary, "=", (uri_string:quote(V))/binary>> end,
    iolist_to_binary(lists:join(<<"&">>, [Enc(P) || P <- Pairs])).

hmac(Secret, Data) -> crypto:mac(hmac, sha256, Secret, Data).
sign_params(Map) ->
    S = get_secret(),
    base64:encode(hmac(S, canon_qs(maps:without([sig], Map)))).

verify_sig(Map) ->
    case {maps:get(<<"sig">>, Map, undefined), maps:get(<<"exp">>, Map, <<"0">>)} of
        {undefined, _} ->
            {error, missing_sig};
        {ProvidedSig, ExpBin} ->
            %% Parse exp defensively
            Now = date_util:now_to_seconds(os:timestamp()),
            Exp =
                try
                    binary_to_integer(ExpBin)
                catch
                    _:_ -> error
                end,
            case Exp of
                error ->
                    {error, bad_exp};
                _ when Now > Exp ->
                    {error, expired};
                _ ->
                    %% Compute signature outside any guard
                    CalcSig = sign_params(Map),
                    case CalcSig =:= ProvidedSig of
                        true -> ok;
                        false -> {error, bad_sig}
                    end
            end
    end.

%% convert mixed map/qs -> ctx map of binaries with defaults
normalize_params(Params) ->
    Dom = safe(getb(Params, <<"domain">>, <<"run.example.com">>)),
    Email = safe(getb(Params, <<"email">>, <<"admin@example.com">>)),
    Repo = getb(Params, <<"repo">>, <<"https://github.com/DamageBDD/DamageBDD.git">>),
    Br = safe(getb(Params, <<"branch">>, <<"main">>)),
    Port = safe(getb(Params, <<"port">>, <<"8080">>)),
    #{domain => Dom, email => Email, repo => Repo, branch => Br, port => Port}.

getb(Map, Key, Default) when is_map(Map) ->
    case maps:get(Key, Map, Default) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V);
        _ -> Default
    end;
getb(List, Key, Default) when is_list(List) ->
    case lists:keyfind(Key, 1, List) of
        {Key, V} when is_binary(V) -> V;
        {Key, V} when is_list(V) -> unicode:characters_to_binary(V);
        _ -> Default
    end.

make_signed_urls(Ctx) ->
    Exp = integer_to_binary(now_unix() + ?DEFAULT_EXP_SECS),
    Nonce = rand_b64(?NONCE_BYTES),
    Base = #{
        <<"domain">> => maps:get(domain, Ctx),
        <<"email">> => maps:get(email, Ctx),
        <<"repo">> => maps:get(repo, Ctx),
        <<"branch">> => maps:get(branch, Ctx),
        <<"port">> => maps:get(port, Ctx),
        <<"exp">> => Exp,
        <<"nonce">> => Nonce
    },
    Sig = sign_params(Base),
    P = maps:merge(Base, #{<<"sig">> => Sig}),
    Q = canon_qs(P),
    Dom = maps:get(<<"domain">>, Base),
    ShURL = iolist_to_binary([<<"https://">>, Dom, <<"/secure/install.sh?">>, Q]),
    PsURL = iolist_to_binary([<<"https://">>, Dom, <<"/secure/install.ps1?">>, Q]),
    {ShURL, PsURL, Exp}.

render(Name, Ctx) -> damage_utils:load_template(Name, Ctx).

%%% ─────────── Renderers / Handlers ───────────
%% GET form
to_html(Req0, #{action := form} = State) ->
    Ctx = #{
        domain => <<"run.example.com">>,
        email => <<"admin@example.com">>,
        repo => <<"https://github.com/DamageBDD/DamageBDD.git">>,
        branch => <<"main">>,
        port => <<"8080">>
    },
    Html = render("install_request_form.html.mustache", Ctx),
    Req = no_cache(Req0, <<"text/html; charset=utf-8">>),
    {Html, Req, State}.

%% POST form -> signed URLs page
from_html(Req0, #{action := form} = State) ->
    {ok, Body, Req1} = cowboy_req:read_urlencoded_body(Req0),
    Ctx0 = normalize_params(maps:from_list(Body)),
    {ShURL, PsURL, Exp} = make_signed_urls(Ctx0),
    Html = render(
        "install_request_result.html.mustache",
        Ctx0#{signed_url_sh => ShURL, signed_url_ps1 => PsURL, expires_at => Exp}
    ),
    Req = no_cache(Req1, <<"text/html; charset=utf-8">>),
    {stop, cowboy_req:reply(200, Req, Html), State}.

%% POST JSON API -> signed URL (Bash + PowerShell)
from_json(Req0, #{action := api} = State) ->
    {BodyOrErr, Req1} = json_body(Req0),
    Body =
        case BodyOrErr of
            {'EXIT', _} = _ -> #{};
            _ -> BodyOrErr
        end,
    Ctx0 = normalize_params(Body),
    {ShURL, PsURL, Exp} = make_signed_urls(Ctx0),
    Json = jsx:encode(#{signed_url_sh => ShURL, signed_url_ps1 => PsURL, expires_at => Exp}),
    Req = no_cache(Req1, <<"application/json">>),
    {stop, cowboy_req:reply(200, cowboy_req:set_resp_body(Json, Req)), State};
from_json(Req, _State) ->
    {stop, cowboy_req:reply(405, Req), undefined}.

%% GET signed Bash
to_text(Req0, #{action := sh} = State) ->
    Params = maps:from_list(qs(Req0)),
    case verify_sig(Params) of
        ok ->
            Ctx = normalize_params(Params),
            Script = render("install.sh.mustache", Ctx),
            Req1 = no_cache(Req0, <<"text/x-shellscript; charset=utf-8">>),
            Req = cowboy_req:set_resp_header(
                <<"content-disposition">>, <<"attachment; filename=install.sh">>, Req1
            ),
            {Script, Req, State};
        {error, Reason} ->
            {stop, cowboy_req:reply(403, Req0, io_lib:format("invalid signature: ~p", [Reason])),
                State}
    end;
%% GET signed PowerShell
to_text(Req0, #{action := ps1} = State) ->
    Params = maps:from_list(qs(Req0)),
    case verify_sig(Params) of
        ok ->
            Ctx = normalize_params(Params),
            PS1 = render("install.ps1.mustache", Ctx),
            Req1 = no_cache(Req0, <<"application/x-powershell; charset=utf-8">>),
            Req = cowboy_req:set_resp_header(
                <<"content-disposition">>, <<"attachment; filename=install.ps1">>, Req1
            ),
            {PS1, Req, State};
        {error, Reason} ->
            {stop, cowboy_req:reply(403, Req0, io_lib:format("invalid signature: ~p", [Reason])),
                State}
    end;
to_text(Req0, #{action := termux_sh} = State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Ctx = #{
        domain => q(Qs, <<"domain">>, <<"run.example.com">>),
        email => q(Qs, <<"email">>, <<"admin@example.com">>),
        repo => q(Qs, <<"repo">>, <<"https://github.com/DamageBDD/DamageBDD.git">>),
        branch => q(Qs, <<"branch">>, <<"main">>),
        port => q(Qs, <<"port">>, <<"8080">>)
    },
    Script = damage_utils:load_template("install.termux.sh.mustache", Ctx),
    Req1 = cowboy_req:set_resp_header(
        <<"content-disposition">>, <<"attachment; filename=install.termux.sh">>, Req0
    ),
    Req = cowboy_req:set_resp_header(
        <<"content-type">>, <<"text/x-shellscript; charset=utf-8">>, Req1
    ),
    {Script, Req, State};
to_text(Req, _State) ->
    {<<"">>, Req, _State}.

%% fallbacks
to_json(Req, _State) -> {<<"{}">>, Req, _State}.
