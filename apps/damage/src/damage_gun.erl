-module(damage_gun).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    open/3,
    open/4,
    proxy/0
]).

-type gun_transport() :: tcp | tls.
-type proxy_spec() :: none | {socks5, string() | binary(), inet:port_number()}.

-spec proxy() -> proxy_spec().
proxy() ->
    case application:get_env(damage, proxy) of
        {ok, {socks5, Host, Port}} ->
            {socks5, Host, Port};
        {ok, {Host, Port}} ->
            {socks5, Host, Port};
        _ ->
            none
    end.

-spec open(string() | binary(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
open(Host, Port, Opts) ->
    open(Host, Port, Opts, proxy()).

-spec open(string() | binary(), inet:port_number(), map(), proxy_spec()) ->
    {ok, pid()} | {error, term()}.
open(Host0, Port, Opts0, Proxy) when is_integer(Port), is_map(Opts0) ->
    ?LOG_INFO("Opening safe gun connection ~p ~p ~p", [Host0, Port, Opts0]),
    Host = normalize_open_host(Host0),
    Transport = maps:get(transport, Opts0, tcp),
    case Proxy of
        {socks5, ProxyHost0, ProxyPort} ->
            ProxyHost = normalize_open_host(ProxyHost0),
            SocksOpts0 = #{
                host => Host,
                port => Port,
                transport => Transport
            },
            SocksOpts =
                case Transport of
                    tls ->
                        maps:put(
                            tls_opts,
                            maps:get(tls_opts, Opts0, [{verify, verify_none}]),
                            SocksOpts0
                        );
                    tcp ->
                        SocksOpts0
                end,
            Opts = maps:merge(
                maps:without([transport, tls_opts, protocols], Opts0),
                #{
                    transport => tcp,
                    protocols => [{socks, SocksOpts}]
                }
            ),
            safe_gun_open(ProxyHost, ProxyPort, Opts);
        none ->
            safe_gun_open(Host, Port, Opts0)
    end.

normalize_open_host(H) when is_list(H) ->
    H;
normalize_open_host(H) when is_binary(H) ->
    binary_to_list(H).

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
