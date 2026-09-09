%% Existing ipfs dependency for data operations; explicit Kubo RPC for control.
%% No CLI or shell invocation. RPC credentials are never logged.
-module(damage_ipfs_backend).
-export([execute/2, decode_json/1]).

execute({add, What}, C) ->
    with_connection(fun(P, T) -> ipfs:add(P, What, T) end, C);
execute({get, Cid, Path}, C) ->
    with_connection(fun(P, T) -> ipfs:get(P, Cid, Path, T) end, C);
execute({cat, Cid}, C) ->
    limit_result(with_connection(fun(P, T) -> ipfs:cat(P, Cid, T) end, C), C);
execute({ls, Cid}, C) ->
    with_connection(fun(P, T) -> ipfs:ls(P, Cid, T) end, C);
%% Preserve the existing dependency's pin result shape for legacy callers.
execute({pin, Hashes}, C) ->
    with_connection(fun(P, T) -> ipfs:pin(P, Hashes, T) end, C);
execute({ensure_pin, Cid}, C) ->
    rpc("pin/add", [{"arg", Cid}, {"recursive", "true"}], C);
execute({unpin, Cid}, C) ->
    case rpc("pin/rm", [{"arg", Cid}, {"recursive", "true"}], C) of
        {error, {http_error, 500, Body}} = E ->
            case not_pinned(Body) of
                true -> {ok, already_unpinned};
                false -> E
            end;
        R ->
            R
    end;
execute({pin_check, Cid}, C) ->
    case rpc("pin/ls", [{"arg", Cid}, {"type", "recursive"}], C) of
        {ok, #{<<"Keys">> := Keys}} when is_map(Keys) ->
            case maps:get(Cid, Keys, undefined) of
                #{<<"Type">> := <<"recursive">>} -> {ok, true};
                _ -> {ok, false}
            end;
        {error, {http_error, 500, Body}} = E ->
            case not_pinned(Body) of
                true -> {ok, false};
                false -> E
            end;
        {ok, _} ->
            {error, invalid_pin_response};
        E ->
            E
    end;
execute({explicit_pin_check, Cid}, C) ->
    case rpc("pin/ls", [{"arg", Cid}, {"type", "all"}], C) of
        {ok, #{<<"Keys">> := Keys}} when is_map(Keys) ->
            case maps:get(Cid, Keys, undefined) of
                #{<<"Type">> := Type} when Type =:= <<"recursive">>; Type =:= <<"direct">> ->
                    {ok, true};
                _ ->
                    {ok, false}
            end;
        {error, {http_error, 500, Body}} = E ->
            case not_pinned(Body) of
                true -> {ok, false};
                false -> E
            end;
        {ok, _} ->
            {error, invalid_pin_response};
        E ->
            E
    end;
execute(version, C) ->
    rpc("version", [], C);
execute(identity, C) ->
    rpc("id", [], C);
execute(swarm_peers, C) ->
    rpc("swarm/peers", [], C);
execute({connect, Addr}, C) ->
    case rpc("swarm/connect", [{"arg", Addr}], C) of
        {error, {http_error, 500, Body}} = E ->
            Lower = string:lowercase(Body),
            case binary:match(Lower, <<"already connected">>) of
                nomatch -> E;
                _ -> {ok, already_connected}
            end;
        R ->
            R
    end;
execute(_, _) ->
    {error, unsupported_operation}.

with_connection(Fun, C) ->
    %% The supplied ipfs:start_link/1 contract only establishes host/port.
    %% Refuse HTTPS, auth and path prefixes instead of silently downgrading them.
    Api = uri_string:parse(maps:get(ipfs_api, C)),
    case {maps:get(scheme, Api), maps:get(path, Api, ""), maps:get(headers, C)} of
        {"http", Path, []} when Path =:= ""; Path =:= "/" ->
            case application:ensure_all_started(gun) of
                {ok, _} ->
                    Server = #{ip => maps:get(host, Api), port => maps:get(port, Api, 80)},
                    case ipfs:start_link(Server) of
                        {ok, Pid} when is_pid(Pid) ->
                            try
                                Fun(Pid, maps:get(request_timeout_ms, C))
                            after
                                %% Keep the ownership link until termination.
                                %% A normal stop cannot race a successful reply
                                %% with an abnormal linked-exit signal.
                                try
                                    gen_server:stop(Pid, normal, 1000)
                                catch
                                    exit:_ -> exit(Pid, kill)
                                end
                            end;
                        {error, _} = E ->
                            E;
                        _ ->
                            {error, invalid_start_response}
                    end;
                {error, _} ->
                    {error, gun_unavailable}
            end;
        _ ->
            {error, legacy_ipfs_transport_requires_plain_http}
    end.

rpc(Command, Args, C) ->
    case application:ensure_all_started(inets) of
        {ok, _} -> rpc_started(Command, Args, C);
        {error, _} -> {error, inets_unavailable}
    end.
rpc_started(Command, Args, C) ->
    Base = maps:get(ipfs_api, C),
    Query = uri_string:compose_query([{K, damage_ipfs_config:text(V)} || {K, V} <- Args]),
    Url =
        Base ++ "/api/v0/" ++ Command ++
            case Query of
                [] -> "";
                _ -> "?" ++ Query
            end,
    HttpOpts0 = [
        {timeout, maps:get(http_timeout_ms, C)},
        {connect_timeout, maps:get(connect_timeout_ms, C)},
        {autoredirect, false}
    ],
    case tls_options(Base) of
        {error, _} = Error ->
            Error;
        {ok, TLS} ->
            case
                httpc:request(
                    post,
                    {Url, maps:get(headers, C), "application/x-www-form-urlencoded", <<>>},
                    TLS ++ HttpOpts0,
                    [{body_format, binary}]
                )
            of
                {ok, {{_, Code, _}, _, Body}} ->
                    case byte_size(Body) =< maps:get(max_response_bytes, C) of
                        false -> {error, response_too_large};
                        true when Code =:= 200 -> decode_json(Body);
                        true -> {error, {http_error, Code, excerpt(Body)}}
                    end;
                {error, Reason} ->
                    {error, {transport, Reason}}
            end
    end.
tls_options("https://" ++ _) ->
    case application:ensure_all_started(ssl) of
        {ok, _} ->
            try
                {ok, [
                    {ssl, [
                        {verify, verify_peer},
                        {cacerts, public_key:cacerts_get()},
                        {customize_hostname_check, [
                            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                        ]}
                    ]}
                ]}
            catch
                _:_ -> {error, tls_ca_unavailable}
            end;
        _ ->
            {error, ssl_unavailable}
    end;
tls_options(_) ->
    {ok, []}.

decode_json(Bin) ->
    try
        Value =
            case code:ensure_loaded(json) of
                {module, json} ->
                    json:decode(Bin);
                _ ->
                    case code:ensure_loaded(jsx) of
                        {module, jsx} -> jsx:decode(Bin, [return_maps]);
                        _ -> jiffy:decode(Bin, [return_maps])
                    end
            end,
        {ok, Value}
    catch
        error:undef -> {error, json_decoder_unavailable};
        _:_ -> {error, invalid_json}
    end.
not_pinned(B) -> binary:match(string:lowercase(B), <<"not pinned">>) =/= nomatch.
excerpt(B) when byte_size(B) > 1024 -> binary:part(B, 0, 1024);
excerpt(B) -> B.
limit_result({ok, B}, C) when is_binary(B) ->
    case byte_size(B) =< maps:get(max_response_bytes, C) of
        true -> {ok, B};
        false -> {error, response_too_large}
    end;
limit_result(B, C) when is_binary(B) ->
    case limit_result({ok, B}, C) of
        {ok, B} -> B;
        E -> E
    end;
limit_result(R, _) ->
    R.
