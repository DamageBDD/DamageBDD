-module(damage_gun).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    open/2,
    open/3,
    open/4,

    request/7,
    get/5,
    post/6,
    put/6,
    patch/6,
    delete/5,
    head/5,
    options/5,

    open_ws/3,
    open_ws/4,
    await_up/1,
    await_up/2,
    ws_upgrade/2,
    ws_upgrade/3,
    ws_send/3,
    ws_close/1,

    proxy/0,
    proxy_for_host/1,
    transport_for/3,
    tls_opts/1
]).

-type proxy_spec() :: none | direct | auto | {socks5, string() | binary(), inet:port_number()}.
-type method() :: get | post | put | patch | delete | head | options.

-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_HTTP_TIMEOUT, 30000).
-define(DEFAULT_WS_TIMEOUT, 15000).

%% ===================================================================
%% HTTP API
%% ===================================================================

-type request_opts() :: map().

-spec request(
    method(),
    string() | binary(),
    inet:port_number(),
    iodata(),
    [{binary() | string(), iodata()}],
    iodata() | undefined,
    request_opts()
) -> {ok, map()} | {error, term()}.
request(Method, Host0, Port, Path0, Headers0, Body0, Opts0) when
    is_atom(Method), is_integer(Port), is_map(Opts0)
->
    Host = normalize_open_host(Host0),
    Path = normalize_path(Path0),
    Headers = normalize_headers(Headers0),
    Timeout = maps:get(timeout, Opts0, ?DEFAULT_HTTP_TIMEOUT),
    Decode = maps:get(decode, Opts0, raw),
    Close = maps:get(close, Opts0, true),

    Transport = transport_for(Host, Port, Opts0),
    Proxy = proxy_policy(Host, maps:get(proxy, Opts0, auto)),
    GunOpts0 = maps:without([timeout, decode, close, proxy], Opts0),
    GunOpts = maps:put(transport, Transport, GunOpts0),

    case open(Host, Port, GunOpts, Proxy) of
        {ok, ConnPid} ->
            try
                case
                    await_up(ConnPid, maps:get(connect_timeout, Opts0, ?DEFAULT_CONNECT_TIMEOUT))
                of
                    {ok, _Protocol} ->
                        do_request(Method, ConnPid, Path, Headers, Body0, Timeout, Decode);
                    Error ->
                        Error
                end
            after
                case Close of
                    true -> catch gun:close(ConnPid);
                    false -> ok
                end
            end;
        Error ->
            Error
    end.
-spec get(string() | binary(), inet:port_number(), iodata(), list(), map()) ->
    {ok, map()} | {error, term()}.
get(Host, Port, Path, Headers, Opts) ->
    request(get, Host, Port, Path, Headers, <<>>, Opts).

post(Host, Port, Path, Headers, Body, Opts) ->
    request(post, Host, Port, Path, Headers, Body, Opts).

put(Host, Port, Path, Headers, Body, Opts) ->
    request(put, Host, Port, Path, Headers, Body, Opts).

patch(Host, Port, Path, Headers, Body, Opts) ->
    request(patch, Host, Port, Path, Headers, Body, Opts).

delete(Host, Port, Path, Headers, Opts) ->
    request(delete, Host, Port, Path, Headers, <<>>, Opts).

head(Host, Port, Path, Headers, Opts) ->
    request(head, Host, Port, Path, Headers, <<>>, Opts).

options(Host, Port, Path, Headers, Opts) ->
    request(options, Host, Port, Path, Headers, <<>>, Opts).

do_request(Method, ConnPid, Path, Headers, Body, Timeout, Decode) ->
    StreamRef =
        case Method of
            get -> gun:get(ConnPid, Path, Headers);
            delete -> gun:delete(ConnPid, Path, Headers);
            head -> gun:head(ConnPid, Path, Headers);
            options -> gun:options(ConnPid, Path, Headers);
            post -> gun:post(ConnPid, Path, Headers, normalize_body(Body));
            put -> gun:put(ConnPid, Path, Headers, normalize_body(Body));
            patch -> gun:patch(ConnPid, Path, Headers, normalize_body(Body))
        end,

    Reply = await_response(ConnPid, StreamRef, Timeout, Decode),
    catch gun:cancel(ConnPid, StreamRef),
    Reply.

await_response(ConnPid, StreamRef, Timeout, Decode) ->
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, fin, Status, RespHeaders} ->
            build_response(Status, RespHeaders, <<>>, Decode);
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(ConnPid, StreamRef, Timeout) of
                {ok, Body} ->
                    build_response(Status, RespHeaders, Body, Decode);
                Error ->
                    {error, {await_body_failed, Error}}
            end;
        {error, Reason} ->
            {error, {await_response_failed, Reason}};
        Other ->
            {error, {unexpected_response, Other}}
    end.

build_response(Status, Headers, Body, Decode) ->
    Base = #{status => Status, headers => Headers, body => Body},
    case Decode of
        none ->
            {ok, maps:remove(body, Base)};
        raw ->
            {ok, Base};
        json ->
            case decode_json_body(Body) of
                {ok, Json} ->
                    {ok, Base#{json => Json}};
                {error, Reason} ->
                    {error, Base#{error => Reason}}
            end
    end.

decode_json_body(<<>>) ->
    {ok, undefined};
decode_json_body(Body) ->
    try jsx:decode(Body, [return_maps, {labels, atom}]) of
        Json -> {ok, Json}
    catch
        _:Reason -> {error, {invalid_json, Reason}}
    end.

%% ===================================================================
%% Connection API
%% ===================================================================

-spec proxy() -> none | {socks5, string() | binary(), inet:port_number()}.
proxy() ->
    case application:get_env(damage, proxy) of
        {ok, none} -> none;
        {ok, false} -> none;
        {ok, {socks5, Host, Port}} when is_integer(Port) -> {socks5, Host, Port};
        {ok, {Host, Port}} when is_integer(Port) -> {socks5, Host, Port};
        _ -> none
    end.

-spec tls_opts(string() | binary()) -> list().
tls_opts(Host0) ->
    Host = normalize_open_host(Host0),
    [
        {verify, verify_peer},
        {depth, 4},
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ].

open(Host, Port) ->
    open(Host, Port, #{}).

open(Host, Port, Opts) ->
    open(Host, Port, Opts, proxy_for_host(Host)).

open(Host0, Port, Opts0, Proxy0) when is_integer(Port), is_map(Opts0) ->
    Host = normalize_open_host(Host0),
    Transport = transport_for(Host, Port, Opts0),
    Proxy = proxy_policy(Host, Proxy0),
    Opts1 = normalize_opts(Host, Transport, maps:put(transport, Transport, Opts0)),
    log_open(Host, Port, Transport, Proxy, Opts1),

    case Proxy of
        {socks5, ProxyHost0, ProxyPort} when is_integer(ProxyPort) ->
            ProxyHost = normalize_open_host(ProxyHost0),
            SocksOpts = socks_opts(Host, Port, Transport, Opts1),
            Opts = maps:merge(
                maps:without([transport, tls_opts, protocols], Opts1),
                #{transport => tcp, protocols => [{socks, SocksOpts}]}
            ),
            safe_gun_open(ProxyHost, ProxyPort, Opts);
        none ->
            safe_gun_open(Host, Port, Opts1);
        direct ->
            safe_gun_open(Host, Port, Opts1)
    end.

transport_for(_Host, _Port, #{transport := tcp}) -> tcp;
transport_for(_Host, _Port, #{transport := tls}) -> tls;
transport_for(_Host, _Port, #{transport := auto}) -> auto_transport(_Host, _Port);
transport_for(Host, Port, _Opts) -> auto_transport(Host, Port).

auto_transport(Host, Port) ->
    case {normalize_open_host(Host), Port} of
        {"localhost", _} -> tcp;
        {"127.0.0.1", _} -> tcp;
        {"::1", _} -> tcp;
        {_, 80} -> tcp;
        {_, 443} -> tls;
        {_, 8443} -> tls;
        _ -> tcp
    end.

-spec proxy_policy(string() | binary(), proxy_spec() | false | undefined) -> proxy_spec().
proxy_policy(Host, auto) -> proxy_for_host(Host);
proxy_policy(Host, undefined) -> proxy_for_host(Host);
proxy_policy(_Host, direct) -> none;
proxy_policy(_Host, none) -> none;
proxy_policy(_Host, false) -> none;
proxy_policy(_Host, {socks5, _, _} = Proxy) -> Proxy.

%% ===================================================================
%% WebSocket API
%% ===================================================================

open_ws(Host, Port, Path) ->
    open_ws(Host, Port, Path, #{}).

open_ws(Host0, Port, Path, Opts0) ->
    Host = normalize_open_host(Host0),
    Transport = transport_for(Host, Port, put_new(transport, tls, Opts0)),
    Headers = maps:get(headers, Opts0, maps:get(ws_headers, Opts0, [])),
    ConnectTimeout = maps:get(connect_timeout, Opts0, ?DEFAULT_CONNECT_TIMEOUT),
    Proxy = proxy_policy(Host, maps:get(proxy, Opts0, auto)),

    GunOpts0 =
        maps:without([headers, ws_headers, connect_timeout, proxy], Opts0),

    %% WebSocket upgrade must be HTTP/1.1, not HTTP/2.
    GunOpts1 = maps:put(protocols, [http], GunOpts0),

    Opts = normalize_opts(
        Host,
        Transport,
        maps:put(transport, Transport, GunOpts1)
    ),

    log_ws_open(Host, Port, Transport, Proxy, Headers, Opts),

    case open(Host, Port, Opts, Proxy) of
        {ok, ConnPid} ->
            case await_up(ConnPid, ConnectTimeout) of
                {ok, http} ->
                    case ws_upgrade(ConnPid, Path, Headers) of
                        {ok, StreamRef} ->
                            {ok, ConnPid, StreamRef};
                        Error ->
                            catch gun:close(ConnPid),
                            Error
                    end;
                {ok, Protocol} ->
                    catch gun:close(ConnPid),
                    {error, {invalid_ws_protocol, Protocol}};
                Error ->
                    catch gun:close(ConnPid),
                    Error
            end;
        Error ->
            Error
    end.

await_up(ConnPid) ->
    await_up(ConnPid, ?DEFAULT_CONNECT_TIMEOUT).

await_up(ConnPid, Timeout) ->
    case catch gun:await_up(ConnPid, Timeout) of
        {ok, _Protocol} = Ok ->
            %?LOG_DEBUG("gun connection up protocol=~p", [Protocol]),
            Ok;
        {error, Reason} ->
            {error, {await_up_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {await_up_exit, Reason}};
        Other ->
            {error, {await_up_failed, Other}}
    end.
normalize_ws_path(Path0) ->
    Path = normalize_path(Path0),
    case uri_string:parse(Path) of
        #{scheme := Scheme} when Scheme =:= "ws"; Scheme =:= "wss" ->
            error({invalid_ws_upgrade_path_full_url, Path});
        #{scheme := Scheme} when Scheme =:= <<"ws">>; Scheme =:= <<"wss">> ->
            error({invalid_ws_upgrade_path_full_url, Path});
        _ ->
            Path
    end.

sanitize_ws_headers(Headers) ->
    lists:filter(
        fun({K, _}) ->
            not lists:member(K, [
                <<"host">>,
                <<"connection">>,
                <<"upgrade">>,
                <<"sec-websocket-key">>,
                <<"sec-websocket-version">>
            ])
        end,
        Headers
    ).
ws_upgrade(ConnPid, Path) ->
    ws_upgrade(ConnPid, Path, []).

ws_upgrade(ConnPid, Path0, WsHeaders) ->
    Path = normalize_ws_path(Path0),
    SafeHeaders = sanitize_ws_headers(WsHeaders),
    ?LOG_INFO("WS upgrade ~p ~p", [Path, SafeHeaders]),
    StreamRef = gun:ws_upgrade(ConnPid, Path, SafeHeaders),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _RespHeaders} ->
            {ok, StreamRef};
        {gun_response, ConnPid, StreamRef, Fin, Status, RespHeaders} ->
            maybe_drain_http_body(ConnPid, StreamRef, Fin),
            ?LOG_ERROR(
                "WS upgrade failed status=~p resp_headers=~p sent_headers=~p",
                [Status, RespHeaders, SafeHeaders]
            ),
            {error, {upgrade_failed, Status, RespHeaders}};
        {gun_ws, ConnPid, StreamRef, close} ->
            {error, {ws_closed, close}};
        {gun_ws, ConnPid, StreamRef, {close, Code, Reason}} ->
            {error, {ws_closed, Code, Reason}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {ws_error, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams} ->
            {error, {gun_down, Reason}}
    after ?DEFAULT_WS_TIMEOUT ->
        {error, ws_upgrade_timeout}
    end.

ws_send(ConnPid, StreamRef, Frame) ->
    catch gun:ws_send(ConnPid, StreamRef, Frame).

ws_close(ConnPid) ->
    catch gun:close(ConnPid),
    ok.

%% ===================================================================
%% Proxy helpers
%% ===================================================================

-spec proxy_for_host(string() | binary()) -> proxy_spec().
proxy_for_host(Host0) ->
    Host = normalize_open_host(Host0),
    case should_bypass_proxy(Host) of
        true -> none;
        false -> proxy()
    end.

should_bypass_proxy(Host) ->
    Default = ["localhost", "127.0.0.1", "::1", ".local", ".lan"],
    Patterns =
        case application:get_env(damage, proxy_exclude) of
            {ok, Ps} when is_list(Ps) -> Ps ++ Default;
            _ -> Default
        end,
    lists:any(fun(P) -> match_host(Host, P) end, Patterns).

match_host(Host, Pattern0) ->
    Pattern = normalize_open_host(Pattern0),
    case Host =:= Pattern of
        true ->
            true;
        false ->
            case Pattern of
                "." ++ _ -> lists:suffix(Pattern, Host);
                _ -> string:find(Host, Pattern) =/= nomatch
            end
    end.

%% ===================================================================
%% Internal helpers
%% ===================================================================

normalize_opts(Host, auto, Opts0) ->
    normalize_opts(Host, transport_for(Host, maps:get(port, Opts0, 443), Opts0), Opts0);
normalize_opts(Host, tls, Opts0) ->
    TlsOpts0 = maps:get(tls_opts, Opts0, []),
    TlsOpts = merge_tls_opts(Host, TlsOpts0),
    Opts0#{transport => tls, tls_opts => TlsOpts};
normalize_opts(_Host, tcp, Opts0) ->
    Opts0#{transport => tcp}.

merge_tls_opts(Host, TlsOpts0) ->
    Verify = proplists:get_value(verify, TlsOpts0, verify_peer),
    Base =
        case Verify of
            verify_none -> [{verify, verify_none}];
            verify_peer -> tls_opts(Host)
        end,
    merge_proplist(Base, TlsOpts0).

merge_proplist(Default, Override) ->
    maps:to_list(maps:merge(maps:from_list(Default), maps:from_list(Override))).

socks_opts(Host, Port, tls, Opts) ->
    #{
        host => Host,
        port => Port,
        transport => tls,
        tls_opts => maps:get(tls_opts, Opts, tls_opts(Host))
    };
socks_opts(Host, Port, tcp, _Opts) ->
    #{host => Host, port => Port, transport => tcp}.

safe_gun_open(Host, Port, Opts) ->
    case catch gun:open(Host, Port, Opts) of
        {ok, _Pid} = Ok -> Ok;
        {'EXIT', {noproc, _} = Reason} -> {error, {gun_not_started, Reason}};
        {'EXIT', Reason} -> {error, {gun_open_exit, Reason}};
        Error -> Error
    end.

maybe_drain_http_body(_ConnPid, _StreamRef, fin) ->
    ok;
maybe_drain_http_body(ConnPid, StreamRef, nofin) ->
    _ = catch gun:await_body(ConnPid, StreamRef, 2000),
    ok;
maybe_drain_http_body(_, _, _) ->
    ok.

normalize_open_host(H) when is_list(H) -> H;
normalize_open_host(H) when is_binary(H) -> binary_to_list(H).

normalize_path(P) when is_binary(P) -> P;
normalize_path(P) when is_list(P) -> list_to_binary(P).

normalize_body(undefined) -> <<>>;
normalize_body(B) -> B.

normalize_headers([]) ->
    [];
normalize_headers(Headers) ->
    lists:map(
        fun
            ({K, V}) when is_binary(K) -> {K, V};
            ({K, V}) when is_list(K) -> {list_to_binary(string:lowercase(K)), V}
        end,
        Headers
    ).

log_open(Host, Port, Transport, Proxy, Opts) ->
    Verify =
        case maps:get(tls_opts, Opts, []) of
            TlsOpts when is_list(TlsOpts) ->
                proplists:get_value(verify, TlsOpts, undefined);
            _ ->
                undefined
        end,
    ?LOG_INFO(
        "Opening gun connection host=~p port=~p transport=~p proxy=~p tls_verify=~p",
        [Host, Port, Transport, redact_proxy(Proxy), Verify]
    ).

log_ws_open(Host, Port, Transport, Proxy, Headers0, Opts) ->
    Verify =
        case maps:get(tls_opts, Opts, []) of
            TlsOpts when is_list(TlsOpts) ->
                proplists:get_value(verify, TlsOpts, undefined);
            _ ->
                undefined
        end,
    ?LOG_INFO(
        "Opening WS connection host=~p port=~p transport=~p proxy=~p tls_verify=~p ws_headers=~p",
        [Host, Port, Transport, redact_proxy(Proxy), Verify, summarize_headers(Headers0)]
    ).

summarize_headers([]) ->
    [];
summarize_headers(Headers) when is_list(Headers) ->
    lists:map(fun summarize_header/1, Headers).

summarize_header({K, V}) ->
    Key = to_lower(K),
    case Key of
        <<"authorization">> -> {Key, <<"REDACTED">>};
        <<"cookie">> -> {Key, <<"REDACTED">>};
        <<"rune">> -> {Key, <<"REDACTED">>};
        <<"sec-websocket-key">> -> {Key, <<"REDACTED">>};
        <<"origin">> -> {Key, V};
        <<"host">> -> {Key, V};
        <<"user-agent">> -> {Key, truncate(to_binary(V), 60)};
        <<"accept">> -> {Key, V};
        _ -> {Key, truncate(to_binary(V), 40)}
    end.

to_lower(B) when is_binary(B) ->
    list_to_binary(string:lowercase(binary_to_list(B)));
to_lower(L) when is_list(L) ->
    list_to_binary(string:lowercase(L)).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(T) -> iolist_to_binary(io_lib:format("~p", [T])).

truncate(Bin, Max) when is_binary(Bin) ->
    case byte_size(Bin) =< Max of
        true ->
            Bin;
        false ->
            <<Prefix:Max/binary, _/binary>> = Bin,
            <<Prefix/binary, "...">>
    end.

redact_proxy(none) -> none;
redact_proxy(direct) -> none;
redact_proxy({socks5, Host, Port}) -> {socks5, normalize_open_host(Host), Port}.

put_new(Key, Val, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> maps:put(Key, Val, Map)
    end.
