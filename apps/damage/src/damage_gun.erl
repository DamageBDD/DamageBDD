-module(damage_gun).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    open/2,
    open/3,
    open/4,
    open_ws/3,
    open_ws/4,
    await_up/1,
    await_up/2,
    ws_upgrade/2,
    ws_upgrade/3,
    proxy/0,
    tls_opts/1
]).
-export([proxy_for_host/1]).

-type proxy_spec() :: none | {socks5, string() | binary(), inet:port_number()}.

-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_WS_TIMEOUT, 15000).

-spec proxy() -> proxy_spec().
proxy() ->
    case application:get_env(damage, proxy) of
        {ok, none} ->
            none;
        {ok, false} ->
            none;
        {ok, {socks5, Host, Port}} when is_integer(Port) ->
            {socks5, Host, Port};
        {ok, {Host, Port}} when is_integer(Port) ->
            {socks5, Host, Port};
        _ ->
            none
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

-spec open(string() | binary(), inet:port_number()) ->
    {ok, pid()} | {error, term()}.
open(Host, Port) ->
    open(Host, Port, #{}).
-spec open(string() | binary(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(Host, Port, Opts) ->
    open(Host, Port, Opts, proxy_for_host(Host)).

-spec open(string() | binary(), inet:port_number(), map(), proxy_spec()) ->
    {ok, pid()} | {error, term()}.
open(Host0, Port, Opts0, Proxy) when is_integer(Port), is_map(Opts0) ->
    Host = normalize_open_host(Host0),
    Transport = maps:get(transport, Opts0, tcp),
    Opts1 = normalize_opts(Host, Transport, Opts0),
    log_open(Host, Port, Transport, Proxy, Opts1),
    case Proxy of
        {socks5, ProxyHost0, ProxyPort} when is_integer(ProxyPort) ->
            ProxyHost = normalize_open_host(ProxyHost0),
            SocksOpts = socks_opts(Host, Port, Transport, Opts1),
            %% Important: the outer connection to 127.0.0.1:9050 is plain TCP.
            %% The SOCKS protocol then dials Host:Port and wraps that target side
            %% in TLS when Transport=tls. Never let gun default this connection to
            %% plain HTTP against the SOCKS port.
            Opts = maps:merge(
                maps:without([transport, tls_opts, protocols], Opts1),
                #{
                    transport => tcp,
                    protocols => [{socks, SocksOpts}]
                }
            ),
            safe_gun_open(ProxyHost, ProxyPort, Opts);
        none ->
            safe_gun_open(Host, Port, Opts1)
    end.

-spec open_ws(string() | binary(), inet:port_number(), iodata()) ->
    {ok, pid(), reference()} | {error, term()}.
open_ws(Host, Port, Path) ->
    open_ws(Host, Port, Path, #{}).

-spec open_ws(string() | binary(), inet:port_number(), iodata(), map()) ->
    {ok, pid(), reference()} | {error, term()}.
open_ws(Host0, Port, Path, Opts0) ->
    Host = normalize_open_host(Host0),
    Transport = maps:get(transport, Opts0, tls),

    Headers = maps:get(ws_headers, Opts0, []),
    ConnectTimeout = maps:get(connect_timeout, Opts0, ?DEFAULT_CONNECT_TIMEOUT),
    Proxy0 = maps:get(proxy, Opts0, proxy()),
    Proxy =
        case Proxy0 of
            auto -> proxy_for_host(Host);
            undefined -> proxy_for_host(Host);
            _ -> Proxy0
        end,
    log_ws_open(Host, Port, Transport, Proxy, Headers, Opts0),

    GunOpts0 = maps:without([ws_headers, connect_timeout, proxy], Opts0),
    Opts = normalize_opts(Host, Transport, maps:put(transport, Transport, GunOpts0)),

    case open(Host, Port, Opts, Proxy) of
        {ok, ConnPid} ->
            case await_up(ConnPid, ConnectTimeout) of
                {ok, _Protocol} ->
                    case ws_upgrade(ConnPid, Path, Headers) of
                        {ok, StreamRef} ->
                            {ok, ConnPid, StreamRef};
                        Error ->
                            catch gun:close(ConnPid),
                            Error
                    end;
                Error ->
                    catch gun:close(ConnPid),
                    Error
            end;
        Error ->
            Error
    end.

-spec await_up(pid()) -> {ok, term()} | {error, term()}.
await_up(ConnPid) ->
    await_up(ConnPid, ?DEFAULT_CONNECT_TIMEOUT).

-spec await_up(pid(), timeout()) -> {ok, term()} | {error, term()}.
await_up(ConnPid, Timeout) ->
    case catch gun:await_up(ConnPid, Timeout) of
        {ok, Protocol} = Ok ->
            ?LOG_DEBUG("gun connection up protocol=~p", [Protocol]),
            Ok;
        {error, Reason} ->
            {error, {await_up_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {await_up_exit, Reason}};
        Other ->
            {error, {await_up_failed, Other}}
    end.

-spec ws_upgrade(pid(), iodata()) -> {ok, reference()} | {error, term()}.
ws_upgrade(ConnPid, Path) ->
    ws_upgrade(ConnPid, Path, []).

-spec ws_upgrade(pid(), iodata(), [{binary(), iodata()}]) ->
    {ok, reference()} | {error, term()}.
ws_upgrade(ConnPid, Path0, Headers) ->
    Path = normalize_ws_path(Path0),
    StreamRef = gun:ws_upgrade(ConnPid, Path, Headers),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _RespHeaders} ->
            {ok, StreamRef};
        {gun_response, ConnPid, StreamRef, Fin, Status, RespHeaders} ->
            maybe_drain_http_body(ConnPid, StreamRef, Fin),
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
            verify_none ->
                [{verify, verify_none}];
            verify_peer ->
                tls_opts(Host)
        end,
    %% Caller supplied opts win, but the production defaults fill in SNI,
    %% hostname checking and CA roots when omitted.
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
    #{
        host => Host,
        port => Port,
        transport => tcp
    }.

normalize_open_host(H) when is_list(H) ->
    H;
normalize_open_host(H) when is_binary(H) ->
    binary_to_list(H).

normalize_ws_path(P) when is_binary(P) ->
    P;
normalize_ws_path(P) when is_list(P) ->
    list_to_binary(P).

safe_gun_open(Host, Port, Opts) ->
    case catch gun:open(Host, Port, Opts) of
        {ok, _Pid} = Ok ->
            Ok;
        {'EXIT', {noproc, _} = Reason} ->
            {error, {gun_not_started, Reason}};
        {'EXIT', Reason} ->
            {error, {gun_open_exit, Reason}};
        Error ->
            Error
    end.

maybe_drain_http_body(_ConnPid, _StreamRef, fin) ->
    ok;
maybe_drain_http_body(ConnPid, StreamRef, nofin) ->
    _ = catch gun:await_body(ConnPid, StreamRef, 2000),
    ok;
maybe_drain_http_body(_, _, _) ->
    ok.

log_open(Host, Port, Transport, Proxy, Opts) ->
    Verify =
        case maps:get(tls_opts, Opts, []) of
            TlsOpts when is_list(TlsOpts) ->
                proplists:get_value(verify, TlsOpts, undefined);
            _ ->
                undefined
        end,

    Headers0 = maps:get(ws_headers, Opts, []),
    Headers = summarize_headers(Headers0),

    ?LOG_INFO(
        "Opening gun connection host=~p port=~p transport=~p proxy=~p tls_verify=~p headers=~p",
        [Host, Port, Transport, redact_proxy(Proxy), Verify, Headers]
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
        [
            Host,
            Port,
            Transport,
            redact_proxy(Proxy),
            Verify,
            summarize_headers(Headers0)
        ]
    ).
summarize_headers([]) ->
    [];
summarize_headers(Headers) when is_list(Headers) ->
    lists:map(fun summarize_header/1, Headers).

summarize_header({K, V}) ->
    Key = to_lower(K),
    case Key of
        <<"authorization">> ->
            {Key, <<"REDACTED">>};
        <<"cookie">> ->
            {Key, <<"REDACTED">>};
        <<"sec-websocket-key">> ->
            {Key, <<"REDACTED">>};
        <<"origin">> ->
            {Key, V};
        <<"host">> ->
            {Key, V};
        <<"user-agent">> ->
            {Key, truncate(V, 60)};
        <<"accept">> ->
            {Key, V};
        _ ->
            {Key, truncate(V, 40)}
    end.

to_lower(B) when is_binary(B) ->
    list_to_binary(string:lowercase(binary_to_list(B)));
to_lower(L) when is_list(L) ->
    list_to_binary(string:lowercase(L)).

truncate(Bin, Max) when is_binary(Bin) ->
    case byte_size(Bin) =< Max of
        true ->
            Bin;
        false ->
            <<Prefix:Max/binary, _/binary>> = Bin,
            <<Prefix/binary, "...">>
    end.

redact_proxy(none) ->
    none;
redact_proxy({socks5, Host, Port}) ->
    {socks5, normalize_open_host(Host), Port}.
-spec proxy_for_host(string() | binary()) -> proxy_spec().
proxy_for_host(Host0) ->
    Host = normalize_open_host(Host0),
    case should_bypass_proxy(Host) of
        true -> none;
        false -> proxy()
    end.
should_bypass_proxy(Host) ->
    case application:get_env(damage, proxy_exclude) of
        {ok, Patterns} when is_list(Patterns) ->
            lists:any(fun(P) -> match_host(Host, P) end, Patterns);
        _ ->
            false
    end.

match_host(Host, Pattern0) ->
    Pattern = normalize_open_host(Pattern0),
    case Host =:= Pattern of
        true ->
            true;
        false ->
            case Pattern of
                "." ++ _ ->
                    lists:suffix(Pattern, Host);
                _ ->
                    string:find(Host, Pattern) =/= nomatch
            end
    end.
