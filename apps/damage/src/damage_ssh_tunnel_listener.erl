-module(damage_ssh_tunnel_listener).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-behaviour(ssh_server_channel).

-record(state, {n, id, cm}).

-export([init/2]).
-export([content_types_provided/2]).
-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2]).
-export([start_link/0]).
-export([to_html/2]).
-export([to_json/2]).
-export(
    [from_json/2, allowed_methods/2, from_html/2, from_yaml/2, is_authorized/2]
).
-export([content_types_accepted/2]).
-export([trails/0]).

-define(TRAILS_TAG, ["SSH Tunnel Management"]).

connect_func(User, PeerAddr, Method) ->
    ?LOG_DEBUG("user connecte ~p ~p ~p", [User, PeerAddr, Method]),
    ok.

trails() ->
    [
        trails:trail(
            "/accounts/ssh_tunnel_keys",
            damage_ssh_tunnel_listener,
            #{action => create},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to create an account on this DamageBDD server.",
                        produces => ["text/html"]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            %{{<<"text">>, <<"plain">>, '*'}, to_text},
            {{<<"text">>, <<"html">>, '*'}, to_html}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_html(Req, #{action := create} = State) ->
    Body = <<"Not implemented">>,
    {Body, Req, State}.

to_json(Req, #{action := balance} = State) ->
    Body = <<"Not implemented">>,
    {Body, Req, State}.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    list_to_binary(Value);
to_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8).

normalize_key(Key) ->
    string:trim(to_binary(Key)).

key_from_data(#{<<"key">> := Key}) ->
    Key;
key_from_data(#{key := Key}) ->
    Key;
key_from_data(#{<<"ssh_key">> := Key}) ->
    Key;
key_from_data(#{ssh_key := Key}) ->
    Key;
key_from_data(Key) ->
    Key.

ensure_trailing_newline(<<>>) ->
    <<>>;
ensure_trailing_newline(Bin) when is_binary(Bin) ->
    case binary:last(Bin) of
        $\n -> Bin;
        _ -> <<Bin/binary, $\n>>
    end.

authorized_keys_path() ->
    Home = os:getenv("HOME", "/var/lib/damage/"),
    UserDir = normalize_path(app_env(user_dir, filename:join(Home, "ssh/tunnel/user"))),
    ensure_dir(UserDir),
    filename:join(UserDir, "authorized_keys").

write_ssh_public_key(Data) ->
    Key = normalize_key(key_from_data(Data)),
    case Key of
        <<>> ->
            {400, #{status => <<"failed">>, message => <<"SSH public key is empty">>}};
        _ ->
            FilePath = authorized_keys_path(),
            case file:write_file(FilePath, ensure_trailing_newline(Key), [append, raw]) of
                ok ->
                    {201, #{status => <<"ok">>, message => <<"SSH public key stored">>}};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to write SSH public key to ~s: ~p", [FilePath, Reason]),
                    {500, #{status => <<"failed">>, message => Reason}}
            end
    end.

remove_ssh_key(Data) ->
    Key = normalize_key(key_from_data(Data)),
    FilePath = authorized_keys_path(),
    case file:read_file(FilePath) of
        {ok, File} ->
            Lines = [Line || Line <- binary:split(File, <<"\n">>, [global]), Line =/= <<>>],
            NewLines = [Line || Line <- Lines, Line =/= Key],
            NewContents =
                case NewLines of
                    [] -> <<>>;
                    _ -> <<(iolist_to_binary(lists:join(<<"\n">>, NewLines)))/binary, $\n>>
                end,
            case file:write_file(FilePath, NewContents) of
                ok ->
                    {200, #{status => <<"ok">>, message => <<"SSH public key removed">>}};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to rewrite authorized_keys in ~s: ~p", [FilePath, Reason]),
                    {500, #{status => <<"failed">>, message => Reason}}
            end;
        {error, enoent} ->
            {404, #{status => <<"failed">>, message => <<"No authorized_keys file exists">>}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to read authorized_keys from ~s: ~p", [FilePath, Reason]),
            {500, #{status => <<"failed">>, message => Reason}}
    end.

do_post_action(ssh_key, Data) -> write_ssh_public_key(Data);
do_post_action(create, Data) -> write_ssh_public_key(Data).

from_html(Req = #{method := <<"DELETE">>}, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} = remove_ssh_key(Data),
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(jsx:encode(Response0), Req)
        ),
        State
    };
from_html(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    FormData = maps:from_list(cow_qs:parse_qs(Data)),
    {Status0, Response0} = do_post_action(Action, FormData),
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(jsx:encode(Response0), Req)
        ),
        State
    }.

from_json(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} =
        case catch jsx:decode(Data, [return_maps]) of
            badarg ->
                {400, #{status => <<"failed">>, message => <<"Json decode error.">>}};
            {'EXIT', {badarg, _}} ->
                {400, #{status => <<"failed">>, message => <<"Json decode error.">>}};
            Data0 ->
                do_post_action(Action, Data0)
        end,
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(jsx:encode(Response0), Req)
        ),
        State
    }.

from_yaml(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    Result = do_post_action(Action, Data),
    YamlResult = damage_utils:safe_yaml(Result),
    Resp = cowboy_req:set_resp_body(YamlResult, Req),
    {stop, cowboy_req:reply(201, Resp), State}.
legacy_app_env(Key, Default) ->
    case application:get_env(damage_ssh_tunnel_listener, Key) of
        {ok, Value} -> Value;
        undefined -> Default
    end.

app_env(Key, Default) ->
    case application:get_env(damage, ssh_tunnel) of
        {ok, SSHConfig} when is_list(SSHConfig) ->
            proplists:get_value(Key, SSHConfig, legacy_app_env(Key, Default));
        _ ->
            legacy_app_env(Key, Default)
    end.

ensure_dirs(Dirs) ->
    lists:foreach(fun ensure_dir/1, Dirs).

normalize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
normalize_path(Path) when is_list(Path) ->
    Path.

ensure_dir(D0) ->
    D = normalize_path(D0),
    %% ensure_dir expects a *file* path; we append "x" to create the directory tree for D
    case filelib:ensure_dir(filename:join(D, "x")) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(
                "Cannot create directory ~s (~p). Set damage ssh_tunnel system_dir/user_dir to writable paths or pre-create them.",
                [D, Reason]
            ),
            ok
    end.

normalize_port({ok, Port}) ->
    normalize_port(Port);
normalize_port(0) ->
    ?LOG_WARNING("damage_ssh_tunnel_listener port 0 requested; using fixed loopback port 2223 instead", []),
    2223;
normalize_port(Port) when is_integer(Port), Port > 0, Port =< 65535 ->
    Port;
normalize_port(Port) when is_binary(Port) ->
    normalize_port(binary_to_list(Port));
normalize_port(Port) when is_list(Port) ->
    normalize_port(list_to_integer(Port)).

normalize_ip({ok, Ip}) ->
    normalize_ip(Ip);
normalize_ip(loopback) ->
    loopback;
normalize_ip(any) ->
    any;
normalize_ip({_, _, _, _} = Ip) ->
    Ip;
normalize_ip({_, _, _, _, _, _, _, _} = Ip) ->
    Ip;
normalize_ip(Ip) when is_binary(Ip) ->
    normalize_ip(binary_to_list(Ip));
normalize_ip("loopback") ->
    loopback;
normalize_ip("any") ->
    any;
normalize_ip(Ip) when is_list(Ip) ->
    case inet:parse_address(Ip) of
        {ok, ParsedIp} -> ParsedIp;
        {error, _} -> Ip
    end.

host_key_files(SystemDir) ->
    [
        filename:join(SystemDir, "ssh_host_ed25519_key"),
        filename:join(SystemDir, "ssh_host_rsa_key"),
        filename:join(SystemDir, "ssh_host_ecdsa_key"),
        filename:join(SystemDir, "ssh_host_dsa_key")
    ].

ensure_host_key_hint(SystemDir) ->
    case lists:any(fun filelib:is_regular/1, host_key_files(SystemDir)) of
        true ->
            ok;
        false ->
            ?LOG_WARNING(
                "No SSH host key found in ~s. Generate one before enabling damage_ssh_tunnel_listener, for example: ssh-keygen -t ed25519 -N '' -f ~s",
                [SystemDir, filename:join(SystemDir, "ssh_host_ed25519_key")]
            ),
            ok
    end.

ssh_daemon_options(SystemDir, UserDir) ->
    [
        {system_dir, SystemDir},
        {user_dir, UserDir},
        {subsystems, [{"damage_ssh_tunnel", {damage_ssh_tunnel_listener, [0]}}]},
        {shell, disabled},
        {tcpip_tunnel_out, true},
        {tcpip_tunnel_in, true},
        {exec, disabled},
        {connectfun, fun connect_func/3},
        {id_string, random},
        {hello_timeout, app_env(hello_timeout, 5000)},
        {negotiation_timeout, app_env(negotiation_timeout, 30000)},
        {max_sessions, app_env(max_sessions, 16)},
        {parallel_login, false}
    ].

start_link() ->
    case app_env(enabled, true) of
        false ->
            ?LOG_INFO("damage_ssh_tunnel_listener disabled by config", []),
            ignore;
        _ ->
            start_ssh_daemon()
    end.

start_ssh_daemon() ->
    Home = os:getenv("HOME", "/var/lib/damage/"),
    SystemDir = normalize_path(app_env(system_dir, filename:join(Home, "ssh/tunnel/system"))),
    UserDir = normalize_path(app_env(user_dir, filename:join(Home, "ssh/tunnel/user"))),
    Port = normalize_port(app_env(port, 2223)),
    Ip = normalize_ip(app_env(ip, {127, 0, 0, 1})),
    ensure_dirs([SystemDir, UserDir]),
    ensure_host_key_hint(SystemDir),

    case ssh:daemon(Ip, Port, ssh_daemon_options(SystemDir, UserDir)) of
        {ok, SSHPid} ->
            DaemonInfo = ssh:daemon_info(SSHPid),
            ?LOG_INFO("damage_ssh_tunnel_listener daemon started ip=~p port=~p info=~p", [Ip, Port, DaemonInfo]),
            {ok, SSHPid};
        {error, Reason} = Error ->
            ?LOG_ERROR(
                "Failed to start damage_ssh_tunnel_listener daemon ip=~p port=~p system_dir=~s user_dir=~s reason=~p",
                [Ip, Port, SystemDir, UserDir, Reason]
            ),
            Error
    end.

init([N]) ->
    ?LOG_DEBUG("starting ssh_server_channel ~p ", [N]),
    {ok, #state{n = N}}.

%% Function to find a free port in a given range
%% Arguments: Start port and End port
%% Returns: A free port within the range or 'undefined' if no port is available

find_free_port(StartPort, EndPort) ->
    case lists:seq(StartPort, EndPort) of
        [] -> undefined;
        Ports -> find_free_port_helper(Ports)
    end.

%% Helper function to find a free port

find_free_port_helper([Port | T]) ->
    case gen_tcp:listen(Port, [binary, {active, false}]) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            {ok, Port};
        {error, _} ->
            find_free_port_helper(T)
    end;
find_free_port_helper([]) ->
    undefined.

handle_msg({ssh_channel_up, ChannelId, ConnectionRef}, State) ->
    ?LOG_DEBUG("starting tunnel ~p ~p", [ConnectionRef, State]),
    StartPort = normalize_port(app_env(tunnel_start_port, 8888)),
    EndPort = normalize_port(app_env(tunnel_end_port, 9000)),
    TargetHost = normalize_path(app_env(tunnel_target_host, "localhost")),
    TargetPort = normalize_port(app_env(tunnel_target_port, 8888)),
    case find_free_port(StartPort, EndPort) of
        undefined ->
            ?LOG_ERROR("No free tunnel port available in range ~p..~p", [StartPort, EndPort]),
            {stop, ChannelId, State};
        {ok, ListenPort} ->
            ?LOG_INFO("Starting SSH tunnel listen_port=~p target=~s:~p", [
                ListenPort, TargetHost, TargetPort
            ]),
            case
                ssh:tcpip_tunnel_from_server(
                    ConnectionRef,
                    "localhost",
                    ListenPort,
                    TargetHost,
                    TargetPort
                )
            of
                {ok, _TrueListenPort} ->
                    {ok, State#state{id = ChannelId, cm = ConnectionRef}};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to start SSH tunnel: ~p", [Reason]),
                    {stop, ChannelId, State}
            end
    end.

handle_ssh_msg({ssh_cm, CM, {data, ChannelId, 0, Data}}, #state{n = N} = State) ->
    M = N - size(Data),
    case M > 0 of
        true ->
            ssh_connection:send(CM, ChannelId, Data),
            {ok, State#state{n = M}};
        false ->
            <<SendData:N/binary, _/binary>> = Data,
            ssh_connection:send(CM, ChannelId, SendData),
            ssh_connection:send_eof(CM, ChannelId),
            {stop, ChannelId, State}
    end;
handle_ssh_msg({ssh_cm, _ConnectionManager, {data, _ChannelId, 1, Data}}, State) ->
    ?LOG_DEBUG("ssh_cm ~p~n", [binary_to_list(Data)]),
    {ok, State};
handle_ssh_msg({ssh_cm, _ConnectionManager, {eof, _ChannelId}}, State) ->
    {ok, State};
handle_ssh_msg({ssh_cm, _, {signal, _, _}}, State) ->
    %% Ignore signals according to RFC 4254 section 6.9.
    {ok, State};
handle_ssh_msg({ssh_cm, _, {exit_signal, ChannelId, _, _Error, _}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, _, {exit_status, ChannelId, _Status}}, State) ->
    {stop, ChannelId, State}.

terminate(_Reason, _State) -> ok.
