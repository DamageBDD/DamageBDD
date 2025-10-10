%% -*- erlang -*-
%% steps_namecheap_ddns.erl
%% Emulate ddclient for Namecheap Dynamic DNS using gun,
%% loading the DDNS password from secrets (encrypted at rest).
%% Author: Steven Joseph <steven@stevenjoseph.in>
%% License: Apache-2.0

-module(steps_namecheap_ddns).

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

-define(NC_HOST, "dynamicdns.park-your-domain.com").
-define(NC_BASE_URL, "https://" ++ ?NC_HOST).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/xml,text/xml,application/json,text/plain"},
    {<<"user-agent">>, "damagebdd/1.0"}
]).

%% ======================
%% Helpers
%% ======================

-spec ensure_nc_base(map()) -> map().
ensure_nc_base(Context0) ->
    Context1 = maps:put(base_url, ?NC_BASE_URL, Context0),
    Context2 = maps:put(host, ?NC_HOST, Context1),
    maps:put(port, 443, Context2).

-spec set_nc_cfg(map(), binary(), binary()) -> map().
set_nc_cfg(Context, Domain, Host) ->
    NC = #{domain => Domain, host => Host},
    maps:put(namecheap_ddns, NC, Context).

-spec secret_key(map()) -> atom().
secret_key(Context) ->
    maps:get(nc_secret_key, Context, namecheap_ddns_password).

-spec get_nc_password(map()) -> {ok, binary()} | {error, term()}.
get_nc_password(Context) ->
    case secrets:retrieve_decrypt(secret_key(Context)) of
        {ok, Value} when is_binary(Value) ->
            {ok, Value};
        {ok, Value} ->
            {ok, unicode:characters_to_binary(io_lib:format("~p", [Value]))};
        error ->
            {error, missing_secret}
    end.

-spec compose_update_path(map(), binary(), binary() | undefined) -> string().
compose_update_path(#{domain := Domain, host := Host}, Password, IP) ->
    QBase = io_lib:format(
              "/update?host=~s&domain=~s&password=~s",
              [binary_to_list(Host), binary_to_list(Domain), binary_to_list(Password)]
            ),
    case IP of
        undefined -> lists:flatten(QBase);
        _         -> lists:flatten([QBase, "&ip=", binary_to_list(IP)])
    end.

-spec text_body(map()) -> binary().
text_body(Context) ->
    case maps:get(response, Context, undefined) of
        [{status_code, _}, _Headers, {body, Body}] -> Body;
        _ -> <<>>
    end.

-spec contains(binary(), binary()) -> boolean().
contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> false;
        _ -> true
    end.

%% Simple public IP detect (plain text)
-spec detect_public_ip(list(), map()) -> {ok, binary()} | {error, term()}.
detect_public_ip(Config, Context0) ->
    C1 = maps:put(base_url, "https://api.ipify.org", Context0),
    C2 = maps:put(host, "api.ipify.org", C1),
    C  = maps:put(port, 443, C2),
    Headers = ?DEFAULT_HEADERS,
    CResp = steps_http:gun_get(Config, C, "/", Headers),
    Body = text_body(CResp),
    case Body of
        <<>> -> {error, no_body};
        _ -> {ok, list_to_binary(string:trim(binary_to_list(Body)))}
    end.

%% ======================
%% Steps
%% ======================

%% Configure domain + host (password is fetched from secrets)
step(_Config, Context, <<"Given">>, _N,
     ["I configure Namecheap DDNS for domain", Domain, "host", Host], _Body) ->
    set_nc_cfg(Context, list_to_binary(Domain), list_to_binary(Host));

%% Optional: override the secret name/key (default: namecheap_ddns_password)
step(_Config, Context, <<"Given">>, _N,
     ["I set Namecheap DDNS secret key to", SecretName], _Body) ->
    maps:put(nc_secret_key, list_to_atom(SecretName), Context);

%% Individual setters
step(_Config, Context, <<"Given">>, _N,
     ["I set Namecheap DDNS domain to", Domain], _Body) ->
    NC0 = maps:get(namecheap_ddns, Context, #{}),
    NC  = NC0#{domain => list_to_binary(Domain)},
    maps:put(namecheap_ddns, NC, Context);

step(_Config, Context, <<"Given">>, _N,
     ["I set Namecheap DDNS host to", Host], _Body) ->
    NC0 = maps:get(namecheap_ddns, Context, #{}),
    NC  = NC0#{host => list_to_binary(Host)},
    maps:put(namecheap_ddns, NC, Context);

%% Update with explicit IP (uses password from secrets)
step(Config, Context0, <<"When">>, _N,
     ["I update Namecheap DDNS with IP", IP], _Body) ->
    Context = ensure_nc_base(Context0),
    case {maps:get(namecheap_ddns, Context, undefined), get_nc_password(Context)} of
        {undefined, _} ->
            maps:put(fail, <<"Namecheap DDNS not configured">>, Context);
        {_, {error, missing_secret}} ->
            maps:put(fail, <<"Missing or locked secret for Namecheap DDNS">>, Context);
        {NC, {ok, Password}} ->
            Path = compose_update_path(NC, Password, list_to_binary(IP)),
            Headers = ?DEFAULT_HEADERS,
            steps_http:gun_get(Config, Context, Path, Headers)
    end;

%% Update with detected public IP (uses password from secrets)
step(Config, Context0, <<"When">>, _N,
     ["I update Namecheap DDNS with detected IP"], _Body) ->
    Context = ensure_nc_base(Context0),
    case {maps:get(namecheap_ddns, Context, undefined), get_nc_password(Context)} of
        {undefined, _} ->
            maps:put(fail, <<"Namecheap DDNS not configured">>, Context);
        {_, {error, missing_secret}} ->
            maps:put(fail, <<"Missing or locked secret for Namecheap DDNS">>, Context);
        {NC, {ok, Password}} ->
            case detect_public_ip(Config, Context) of
                {ok, IP} ->
                    Path = compose_update_path(NC, Password, IP),
                    Headers = ?DEFAULT_HEADERS,
                    steps_http:gun_get(Config, Context, Path, Headers);
                {error, Reason} ->
                    maps:put(fail, io_lib:format("Failed to detect public IP: ~p", [Reason]), Context)
            end
    end;

%% Assert success
step(_Config, Context, <<"Then">>, _N,
     ["the Namecheap DDNS update should succeed"], _Body) ->
    Body = text_body(Context),
    case contains(Body, <<"<ErrCount>0</ErrCount>">>) of
        true  -> Context;
        false ->
            ?LOG_INFO("Namecheap DDNS response (unexpected): ~s", [Body]),
            maps:put(fail, <<"Namecheap DDNS update did not report success">>, Context)
    end;

%% Assert echoed IP
step(_Config, Context, <<"Then">>, _N,
     ["the Namecheap response IP must be", ExpectIP], _Body) ->
    Body = text_body(Context),
    Expect = list_to_binary(ExpectIP),
    case contains(Body, <<"<IP>", Expect/binary, "</IP>">>) of
        true  -> Context;
        false -> maps:put(fail, <<"Expected IP not found in Namecheap response">>, Context)
    end;

%% Store echoed IP
step(_Config, Context, <<"Then">>, _N,
     ["I store the Namecheap response IP in", VarName], _Body) ->
    Body = text_body(Context),
    case re:run(Body, "<IP>([^<]+)</IP>", [{capture, [1], binary}]) of
        {match, [IP]} ->
            Var = list_to_atom(VarName),
            maps:put(Var, binary_to_list(IP), Context);
        nomatch ->
            maps:put(fail, <<"Could not extract <IP> from Namecheap response">>, Context)
    end.

