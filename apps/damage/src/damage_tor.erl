%%%-------------------------------------------------------------------
%%% damage_tor.erl
%%%
%%% Small Tor ControlPort client for DamageBDD.
%%%
%%% Responsibilities:
%%% - read Tor ControlPort config from application env
%%% - authenticate using password, cookie file, or bare AUTHENTICATE
%%% - GETINFO address/version/circuit-status/orconn-status/etc.
%%% - SETCONF / RESETCONF selected Tor options
%%% - SIGNAL NEWNYM / CLEARDNSCACHE / RELOAD / ACTIVE / DORMANT / HEARTBEAT
%%% - ADD_ONION / DEL_ONION for ephemeral node onion addresses
%%% - configure Damage HTTP transport to use Tor SOCKS through damage_gun
%%%
%%% Keep this module admin/internal only. Do not expose SETCONF or ADD_ONION
%%% directly to untrusted BDD users.
%%%-------------------------------------------------------------------

-module(damage_tor).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    info/0,
    node_address/0,
    onion_address/0,
    external_address/0,

    getinfo/1,
    getinfo_many/1,
    getconf/1,
    setconf/1,
    resetconf/1,

    signal/1,
    newnym/0,
    clear_dns_cache/0,
    reload/0,

    map_address/2,
    address_mappings/0,

    add_onion/2,
    add_onion/3,
    del_onion/1,

    socks_proxy/0,
    apply_socks_proxy/0,
    disable_socks_proxy/0
]).

-define(DEFAULT_CONTROL_HOST, "127.0.0.1").
-define(DEFAULT_CONTROL_PORT, 9051).
-define(DEFAULT_SOCKS_HOST, "127.0.0.1").
-define(DEFAULT_SOCKS_PORT, 9050).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_HIDDEN_SERVICE_HOSTNAME_FILE, "/var/lib/damage/tor/hostname").

%%====================================================================
%% Public API
%%====================================================================

info() ->
    Keys = [
        <<"version">>,
        <<"address">>,
        <<"address/v4">>,
        <<"address/v6">>,
        <<"fingerprint">>,
        <<"circuit-status">>,
        <<"orconn-status">>,
        <<"entry-guards">>,
        <<"config-file">>
    ],
    case getinfo_many(Keys) of
        {ok, Info0} ->
            {ok, Info0#{
                onion_address => onion_address(),
                socks_proxy => socks_proxy(),
                damage_proxy => damage_gun:proxy()
            }};
        Error ->
            Error
    end.

node_address() ->
    onion_address().

onion_address() ->
    File = to_host(
        env(
            tor_hidden_service_hostname_file,
            ?DEFAULT_HIDDEN_SERVICE_HOSTNAME_FILE
        )
    ),
    case file:read_file(File) of
        {ok, Hostname0} ->
            validate_onion_hostname(strip_crlf(Hostname0));
        {error, Reason} ->
            {error, {tor_onion_hostname_read_failed, File, Reason}}
    end.
external_address() ->
    case getinfo(<<"address">>) of
        {ok, Address} ->
            {ok, Address};
        {error, _} = Error ->
            Error
    end.

getinfo(Key0) ->
    Key = to_bin(Key0),
    case getinfo_many([Key]) of
        {ok, Map} ->
            case maps:find(Key, Map) of
                {ok, Value} -> {ok, Value};
                error -> {error, {missing_getinfo_key, Key, Map}}
            end;
        Error ->
            Error
    end.

getinfo_many(Keys0) when is_list(Keys0) ->
    Keys = [to_bin(K) || K <- Keys0],
    with_control(fun(Sock) ->
        case command(Sock, [<<"GETINFO ">>, join_sp(Keys)]) of
            {ok, Lines} ->
                {ok, parse_250_map(Lines)};
            Error ->
                Error
        end
    end).

getconf(Key0) ->
    Key = to_bin(Key0),
    with_control(fun(Sock) ->
        case command(Sock, [<<"GETCONF ">>, Key]) of
            {ok, Lines} ->
                {ok, parse_250_map(Lines)};
            Error ->
                Error
        end
    end).

setconf(Pairs0) when is_map(Pairs0) ->
    setconf(maps:to_list(Pairs0));
setconf(Pairs0) when is_list(Pairs0) ->
    Args = [conf_arg(K, V) || {K, V} <- Pairs0],
    with_control(fun(Sock) ->
        expect_ok(command(Sock, [<<"SETCONF ">>, join_sp(Args)]))
    end).

resetconf(Keys0) when is_list(Keys0) ->
    Keys = [to_bin(K) || K <- Keys0],
    with_control(fun(Sock) ->
        expect_ok(command(Sock, [<<"RESETCONF ">>, join_sp(Keys)]))
    end);
resetconf(Key0) ->
    resetconf([Key0]).

signal(Signal0) ->
    Signal = uppercase_bin(Signal0),
    case allowed_signal(Signal) of
        true ->
            with_control(fun(Sock) ->
                expect_ok(command(Sock, [<<"SIGNAL ">>, Signal]))
            end);
        false ->
            {error, {unsafe_or_unknown_signal, Signal}}
    end.

newnym() ->
    signal(<<"NEWNYM">>).

clear_dns_cache() ->
    signal(<<"CLEARDNSCACHE">>).

reload() ->
    signal(<<"RELOAD">>).

map_address(From0, To0) ->
    From = to_bin(From0),
    To = to_bin(To0),
    with_control(fun(Sock) ->
        case command(Sock, [<<"MAPADDRESS ">>, From, <<"=">>, To]) of
            {ok, Lines} -> {ok, parse_250_map(Lines)};
            Error -> Error
        end
    end).

address_mappings() ->
    getinfo(<<"address-mappings/control">>).

%% Create an ephemeral onion service.
%%
%% Example:
%%   damage_tor:add_onion(80, "127.0.0.1:8080").
%%
%% Default flags:
%% - DiscardPK: Tor will not return the onion private key.
%% - Detach: service is not tied to this control connection.
%%
%% For a persistent service controlled by your app, pass a stored key:
%%   add_onion(80, "127.0.0.1:8080", #{key => <<"ED25519-V3:...">>, flags => [<<"Detach">>]}).
add_onion(VirtPort, Target) ->
    add_onion(VirtPort, Target, #{}).

add_onion(VirtPort0, Target0, Opts0) when is_map(Opts0) ->
    VirtPort = to_int(VirtPort0, 0),
    Key = maps:get(key, Opts0, <<"NEW:BEST">>),
    Flags = maps:get(flags, Opts0, [<<"DiscardPK">>, <<"Detach">>]),
    PortSpec = onion_port_spec(VirtPort, Target0),
    Cmd = [
        <<"ADD_ONION ">>,
        to_bin(Key),
        onion_flags_arg(Flags),
        <<" Port=">>,
        PortSpec
    ],
    with_control(fun(Sock) ->
        case command(Sock, Cmd) of
            {ok, Lines} ->
                Reply = parse_250_map(Lines),
                case maps:find(<<"ServiceID">>, Reply) of
                    {ok, ServiceId} ->
                        {ok, Reply#{
                            service_id => ServiceId,
                            onion => <<ServiceId/binary, ".onion">>
                        }};
                    error ->
                        {ok, Reply}
                end;
            Error ->
                Error
        end
    end).

del_onion(ServiceId0) ->
    ServiceId = strip_onion_suffix(to_bin(ServiceId0)),
    with_control(fun(Sock) ->
        expect_ok(command(Sock, [<<"DEL_ONION ">>, ServiceId]))
    end).

socks_proxy() ->
    Host = env(tor_socks_host, ?DEFAULT_SOCKS_HOST),
    Port = to_int(env(tor_socks_port, ?DEFAULT_SOCKS_PORT), ?DEFAULT_SOCKS_PORT),
    {socks5, Host, Port}.

apply_socks_proxy() ->
    application:set_env(damage, proxy, socks_proxy()).

disable_socks_proxy() ->
    application:set_env(damage, proxy, none).

%%====================================================================
%% Control connection
%%====================================================================

with_control(Fun) when is_function(Fun, 1) ->
    case connect_control() of
        {ok, Sock} ->
            try
                case authenticate(Sock) of
                    ok ->
                        Fun(Sock);
                    Error ->
                        Error
                end
            after
                safe_close(Sock)
            end;
        Error ->
            Error
    end.

connect_control() ->
    Host = to_host(env(tor_control_host, ?DEFAULT_CONTROL_HOST)),
    Port = to_int(env(tor_control_port, ?DEFAULT_CONTROL_PORT), ?DEFAULT_CONTROL_PORT),
    Timeout = timeout(),
    Opts = [binary, {packet, line}, {active, false}],
    case gen_tcp:connect(Host, Port, Opts, Timeout) of
        {ok, _Sock} = Ok ->
            Ok;
        {error, Reason} ->
            {error, {tor_control_connect_failed, Host, Port, Reason}}
    end.

authenticate(Sock) ->
    case auth_arg() of
        {error, _} = Error ->
            Error;
        <<>> ->
            expect_ok(command(Sock, <<"AUTHENTICATE">>));
        Arg ->
            expect_ok(command(Sock, [<<"AUTHENTICATE ">>, Arg]))
    end.

auth_arg() ->
    case env(tor_control_password, undefined) of
        undefined ->
            auth_cookie_or_empty();
        <<>> ->
            <<>>;
        "" ->
            <<>>;
        Password ->
            quote_value(Password)
    end.

auth_cookie_or_empty() ->
    case env(tor_control_cookie_file, undefined) of
        undefined ->
            <<>>;
        File0 ->
            File = to_host(File0),
            case file:read_file(File) of
                {ok, Cookie} ->
                    binary:encode_hex(Cookie);
                {error, Reason} ->
                    {error, {tor_cookie_read_failed, File, Reason}}
            end
    end.

command(Sock, IoData) ->
    Wire = iolist_to_binary([IoData, <<"\r\n">>]),
    case gen_tcp:send(Sock, Wire) of
        ok ->
            recv_reply(Sock, [], timeout());
        {error, Reason} ->
            {error, {tor_control_send_failed, Reason}}
    end.

recv_reply(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Line0} ->
            Line = strip_crlf(Line0),
            Acc1 = [Line | Acc],
            case reply_done(Line) of
                true ->
                    {ok, lists:reverse(Acc1)};
                false ->
                    case error_reply(Line) of
                        true ->
                            {error, {tor_control_error, Line, lists:reverse(Acc)}};
                        false ->
                            recv_reply(Sock, Acc1, Timeout)
                    end
            end;
        {error, Reason} ->
            {error, {tor_control_recv_failed, Reason, lists:reverse(Acc)}}
    end.

reply_done(<<"250 OK">>) ->
    true;
reply_done(<<"250 ", Rest/binary>>) ->
    Rest =/= <<"OK">>;
reply_done(_) ->
    false.

error_reply(<<A, B, C, _/binary>>) when
    A >= $4,
    A =< $5,
    B >= $0,
    B =< $9,
    C >= $0,
    C =< $9
->
    true;
error_reply(_) ->
    false.

expect_ok({ok, _Lines}) ->
    ok;
expect_ok(Error) ->
    Error.

safe_close(Sock) ->
    try
        gen_tcp:close(Sock)
    catch
        _Class:_Reason ->
            ok
    end.

%%====================================================================
%% Parsers
%%====================================================================

parse_250_map(Lines) ->
    parse_250_map(Lines, #{}).

parse_250_map([], Acc) ->
    Acc;
parse_250_map([<<"250 OK">> | Rest], Acc) ->
    parse_250_map(Rest, Acc);
parse_250_map([<<"250-", KV/binary>> | Rest], Acc) ->
    {Key, Value} = split_kv(KV),
    parse_250_map(Rest, maps:put(Key, Value, Acc));
parse_250_map([<<"250 ", KV/binary>> | Rest], Acc) ->
    {Key, Value} = split_kv(KV),
    parse_250_map(Rest, maps:put(Key, Value, Acc));
parse_250_map([<<"250+", KV/binary>> | Rest], Acc) ->
    {Key, _Value0} = split_kv(KV),
    {Block, Rest1} = take_data_block(Rest, []),
    parse_250_map(Rest1, maps:put(Key, join_lf(Block), Acc));
parse_250_map([_Other | Rest], Acc) ->
    parse_250_map(Rest, Acc).

take_data_block([], Acc) ->
    {lists:reverse(Acc), []};
take_data_block([<<".">> | Rest], Acc) ->
    {lists:reverse(Acc), Rest};
take_data_block([Line | Rest], Acc) ->
    take_data_block(Rest, [Line | Acc]).

split_kv(KV) ->
    case binary:split(KV, <<"=">>) of
        [Key, Value] -> {Key, Value};
        [Key] -> {Key, <<>>}
    end.

join_lf([]) ->
    <<>>;
join_lf(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

strip_crlf(Bin) ->
    strip_suffix(strip_suffix(Bin, <<"\n">>), <<"\r">>).

strip_suffix(Bin, Suffix) ->
    N = byte_size(Bin),
    M = byte_size(Suffix),
    case N >= M of
        true ->
            PrefixLen = N - M,
            case Bin of
                <<Prefix:PrefixLen/binary, Suffix:M/binary>> ->
                    Prefix;
                _ ->
                    Bin
            end;
        false ->
            Bin
    end.

validate_onion_hostname(<<ServiceId:56/binary, ".onion">> = Hostname) ->
    case valid_v3_service_id(ServiceId) of
        true -> {ok, Hostname};
        false -> {error, {invalid_onion_hostname, Hostname}}
    end;
validate_onion_hostname(Hostname) ->
    {error, {invalid_onion_hostname, Hostname}}.

valid_v3_service_id(ServiceId) ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse (C >= $2 andalso C =< $7)
        end,
        binary_to_list(ServiceId)
    ).

%%====================================================================
%% Command formatting
%%====================================================================

conf_arg(Key0, undefined) ->
    to_bin(Key0);
conf_arg(Key0, Value0) ->
    [to_bin(Key0), <<"=">>, quote_value(Value0)].

quote_value(Value0) ->
    Value = to_bin(Value0),
    [$", escape_quoted(Value, []), $"].

escape_quoted(<<>>, Acc) ->
    lists:reverse(Acc);
escape_quoted(<<$", Rest/binary>>, Acc) ->
    escape_quoted(Rest, [<<"\\\"">> | Acc]);
escape_quoted(<<$\\, Rest/binary>>, Acc) ->
    escape_quoted(Rest, [<<"\\\\">> | Acc]);
escape_quoted(<<$\r, Rest/binary>>, Acc) ->
    escape_quoted(Rest, Acc);
escape_quoted(<<$\n, Rest/binary>>, Acc) ->
    escape_quoted(Rest, Acc);
escape_quoted(<<C, Rest/binary>>, Acc) ->
    escape_quoted(Rest, [<<C>> | Acc]).

join_sp(Parts) ->
    iolist_to_binary(lists:join(<<" ">>, Parts)).

join_comma(Parts) ->
    iolist_to_binary(lists:join(<<",">>, [to_bin(P) || P <- Parts])).

onion_flags_arg([]) ->
    <<>>;
onion_flags_arg(Flags) when is_list(Flags) ->
    [<<" Flags=">>, join_comma(Flags)].

onion_port_spec(VirtPort, undefined) ->
    integer_to_binary(VirtPort);
onion_port_spec(VirtPort, <<>>) ->
    integer_to_binary(VirtPort);
onion_port_spec(VirtPort, "") ->
    integer_to_binary(VirtPort);
onion_port_spec(VirtPort, Target0) ->
    [integer_to_binary(VirtPort), <<",">>, to_bin(Target0)].

strip_onion_suffix(ServiceId0) ->
    case binary:split(ServiceId0, <<".onion">>) of
        [ServiceId, <<>>] -> ServiceId;
        _ -> ServiceId0
    end.

allowed_signal(<<"NEWNYM">>) -> true;
allowed_signal(<<"CLEARDNSCACHE">>) -> true;
allowed_signal(<<"RELOAD">>) -> true;
allowed_signal(<<"HEARTBEAT">>) -> true;
allowed_signal(<<"ACTIVE">>) -> true;
allowed_signal(<<"DORMANT">>) -> true;
allowed_signal(_) -> false.

uppercase_bin(V) ->
    list_to_binary(string:uppercase(binary_to_list(to_bin(V)))).

%%====================================================================
%% Env / coercion helpers
%%====================================================================

env(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, Value} -> Value;
        undefined -> Default;
        _ -> Default
    end.

timeout() ->
    to_int(env(tor_control_timeout, ?DEFAULT_TIMEOUT), ?DEFAULT_TIMEOUT).

to_int(V, _Default) when is_integer(V) ->
    V;
to_int(V, Default) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _Class:_Reason ->
            Default
    end;
to_int(V, Default) when is_list(V) ->
    try
        list_to_integer(V)
    catch
        _Class:_Reason ->
            Default
    end;
to_int(_, Default) ->
    Default.

to_host(V) when is_binary(V) ->
    binary_to_list(V);
to_host(V) when is_list(V) ->
    V;
to_host(V) when is_atom(V) ->
    atom_to_list(V).

to_bin(V) when is_binary(V) ->
    V;
to_bin(V) when is_list(V) ->
    unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) ->
    integer_to_binary(V);
to_bin(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).
