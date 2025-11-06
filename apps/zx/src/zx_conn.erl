%% @doc
%%% ZX Connector
%%%
%%% This module represents a connection to a Zomp server.
%%% Multiple connections can exist at a given time, but each one of these processes
%%% only represents a single connection at a time.
%%% @end

-module(zx_conn).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([subscribe/2, unsubscribe/2, request/3]).
-export([start/1, retire/1, stop/1]).
-export([start_link/1, init/2]).

-include("zx_logger.hrl").


%%% Interface

-spec subscribe(Conn, Package) -> ok
    when Conn    :: pid(),
         Package :: zx:package().

subscribe(Conn, Realm) ->
    Conn ! {subscribe, Realm},
    ok.


-spec unsubscribe(Conn, Package) -> ok
    when Conn    :: pid(),
         Package :: zx:package().

unsubscribe(Conn, Package) ->
    Conn ! {unsubscribe, Package},
    ok.


-spec request(Conn, ID, Action) -> ok
    when Conn   :: pid(),
         ID     :: zx_daemon:id(),
         Action :: zx_daemon:action().
%% @doc
%% Wraps any legal request.
%% Only to be called by zx_daemon.
%% Results must be returned with the ID via zx_daemon:result/2.

request(Conn, ID, Action) ->
    Conn ! {request, ID, Action},
    ok.


%%% Startup

-spec start(Target) -> Result
    when Target :: zx:host(),
         Result :: {ok, pid()}
                 | {error, Reason :: term()}.
%% @doc
%% Starts a connection to a given target Zomp node. This call itself should never fail,
%% but this process may fail to connect or crash immediately after spawning. Should
%% only be called by zx_daemon.

start(Target) ->
    zx_conn_sup:start_conn(Target).


-spec retire(Conn :: pid()) -> ok.

retire(Conn) ->
    Conn ! retire,
    ok.


-spec stop(Conn :: pid()) -> ok.
%% @doc
%% Signals the connection to disconnect and retire immediately.

stop(Conn) ->
    Conn ! stop,
    ok.


-spec start_link(Target) ->  Result
    when Target :: zx:host(),
         Result :: {ok, pid()}
                 | {error, Reason},
         Reason :: term().
%% @private
%% The supervisor's way of spawning a new connector.

start_link(Target) ->
    proc_lib:start_link(?MODULE, init, [self(), Target]).


-spec init(Parent, Target) -> no_return()
    when Parent :: pid(),
         Target :: zx:host().
%% @private
%% gen_server callback. For more information refer to the OTP documentation.

init(Parent, Target) ->
    Debug = sys:debug_options([]),
    ok = proc_lib:init_ack(Parent, {ok, self()}),
    connect(Parent, Debug, Target).



%%% Connection Procedure

-spec connect(Parent, Debug, Target) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         Target :: zx:host().

connect(Parent, Debug, {Host, Port}) ->
    Options = [{packet, 4}, {mode, binary}, {nodelay, true}, {active, once}],
    case gen_tcp:connect(Host, Port, Options, 5000) of
        {ok, Socket} ->
            confirm_service(Parent, Debug, Socket);
        {error, Error} ->
            HS = zx_net:host_string({Host, Port}),
            ok = log(warning, "Connection problem with ~ts: ~160tp", [HS, Error]),
            ok = zx_daemon:report(failed),
            terminate()
    end.


-spec confirm_service(Parent, Debug, Socket) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         Socket :: gen_tcp:socket().
%% @private
%% Confirm the zomp node can handle "LEAF 1:" and is accepting connections or try
%% another node.

confirm_service(Parent, Debug, Socket) ->
    Realms = zx_lib:list_realms(),
    Message = <<"ZOMP LEAF 1:", (term_to_binary(Realms))/binary>>,
    ok = gen_tcp:send(Socket, Message),
    receive
        {tcp, Socket, <<0:8, RealmsBin/binary>>} ->
            {ok, Available} = zx_lib:b_to_ts(RealmsBin),
            ok = zx_daemon:report({connected, Available}),
            loop(Parent, Debug, Socket);
        {tcp, Socket, <<1:8, HostsBin/binary>>} ->
            {ok, Hosts} = zx_lib:b_to_ts(HostsBin),
            ok = zx_daemon:report({redirect, Hosts}),
            ok = zx_net:disconnect(Socket),
            terminate();
        {tcp, Socket, <<2:8>>} ->
            ok = zx_daemon:report({use_version, no_version}),
            terminate();
        {tcp, Socket, <<2:8, Version:16>>} ->
            ok = zx_daemon:report({use_version, Version}),
            terminate();
        {tcp, Socket, <<3:8, Reason/utf8>>} ->
            ok = zx_daemon:report({no_service, Reason}),
            terminate();
        {tcp_closed, Socket} ->
            ok = zx_daemon:report(failed),
            terminate();
        retire ->
            ok = zx_net:disconnect(Socket),
            ok = zx_daemon:report(retired),
            terminate();
        stop ->
            ok = zx_net:disconnect(Socket),
            terminate();
        Other ->
            log(error, "Received: ~tp", [Other])
        after 5000 ->
            handle_timeout(Socket)
    end.



%%% Service Loop

-spec loop(Parent, Debug, Socket) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         Socket :: gen_tcp:socket().
%% @private
%% Service loop. Messages incoming from the connected Zomp node, the zx_daemon, and
%% OTP system messages all come here. This is the only catch-all receive loop, so
%% messages that occur in a specific state must not be accidentally received here out
%% of order or else whatever sequenced communication was happening will be corrupted.

loop(Parent, Debug, Socket) ->
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<1:1, 0:7>>} ->
            ok = pong(Socket),
            loop(Parent, Debug, Socket);
        {tcp, Socket, <<1:1, 1:7, SigSize:24, Sig:SigSize/binary, 9:8, Bin/binary>>} ->
            ok = handle_package_update(Sig, Bin),
            loop(Parent, Debug, Socket);
        {tcp, Socket, <<1:1, 2:7, Bin/binary>>} ->
            {ok, {Realm, Serial}} = zx_lib:b_to_ts(Bin),
            ok = zx_daemon:report({serial_update, Realm, Serial}),
            loop(Parent, Debug, Socket);
        {tcp, Socket, Unexpected} ->
            ok = log(warning, "Funky data from node: ~160tp", [Unexpected]),
            ok = zx_net:disconnect(Socket),
            terminate();
        {request, ID, Action} ->
            Result = dispatch(Socket, ID, Action),
            ok = zx_daemon:result(ID, Result),
            loop(Parent, Debug, Socket);
        {subscribe, Package} ->
            ok = do_subscribe(Socket, Package),
            loop(Parent, Debug, Socket);
        {unsubscribe, Package} ->
            ok = do_unsubscribe(Socket, Package),
            loop(Parent, Debug, Socket);
        {tcp_closed, Socket} ->
            ok = log(info, "Connection closed unexpectedly."),
            ok = zx_daemon:report(disconnected),
            terminate();
        retire ->
            ok = zx_net:disconnect(Socket),
            ok = zx_daemon:report(retired),
            terminate();
        stop ->
            ok = zx_net:disconnect(Socket),
            terminate();
        Unexpected ->
            ok = log(warning, "Unexpected message: ~160tp", [Unexpected]),
            loop(Parent, Debug, Socket)
    end.



%% TODO: Pull in missing key chains.
handle_package_update(Sig, Bin) ->
    Message = {_, _, _, KeyID, {Realm, Name} = PackageID} = zx_lib:b_to_ts(Bin),
    Package = {Realm, Name},
    {ok, Key} = zx_key:load(KeyID),
    case zx_key:verify(Bin, Sig, Key) of
        true ->
            zx_daemon:notify(Package, {update, PackageID});
        false ->
            ok = log(error, "Received an unverified update message: ~160tp", [Message]),
            terminate()
    end.


%%% Incoming Request Actions

-spec do_subscribe(gen_tcp:socket(), zx:package()) -> ok | no_return().

do_subscribe(Socket, Package) ->
    Reference = term_to_binary(Package),
    Message = <<0:1, 1:7, Reference/binary>>,
    ok = gen_tcp:send(Socket, Message),
    wait_ok(Socket).


-spec do_unsubscribe(gen_tcp:socket(), zx:package()) -> ok | no_return().

do_unsubscribe(Socket, Package) ->
    Reference = term_to_binary(Package),
    Message = <<0:1, 2:7, Reference/binary>>,
    ok = gen_tcp:send(Socket, Message),
    wait_ok(Socket).


-spec wait_ok(gen_tcp:socket()) -> ok | no_return().

wait_ok(Socket) ->
    receive
        {tcp, Socket, <<0:1, 0:7>>} -> ok
        after 5000                  -> handle_timeout(Socket)
    end.


dispatch(Socket, ID, Action) ->
    case Action of
        {list,        R}          -> send_query(Socket,  3,  R);
        {list,        R, N}       -> send_query(Socket,  4, {R, N});
        {list,        R, N, V}    -> send_query(Socket,  4, {R, N, V});
        {latest,      R, N}       -> send_query(Socket,  5, {R, N});
        {latest,      R, N, V}    -> send_query(Socket,  5, {R, N, V});
        {describe,    R, N, V}    -> send_query(Socket,  6, {R, N, V});
        {tags,        R, N}       -> send_query(Socket,  7, {R, N});
        {tags,        R, N, V}    -> send_query(Socket,  7, {R, N, V});
        {provides,    R, M}       -> send_query(Socket,  8, {R, M});
        {search,      R, String}  -> send_query(Socket,  9, {R, String});
        {list_deps,   R, N, V}    -> send_query(Socket, 10, {R, N, V});
        {list_sysops, R}          -> send_query(Socket, 11,  R);
        {fetch,       R, N, V, W} ->      fetch(Socket, ID, W, {R, N, V});
        {keychain,    R, K}       -> send_query(Socket, 13, {R, K});
        {list_type,   R, T}       -> send_query(Socket, 14, {R, T});
        Unexpected                ->
            Message = "Received unexpected request action. ID: ~tp, Action: ~200tp",
            log(warning, Message, [ID, Unexpected])
    end.


send_query(Socket, Command, Payload) ->
    TermBin = term_to_binary(Payload),
    Message = <<0:1, Command:7, TermBin/binary>>,
    ok = gen_tcp:send(Socket, Message),
    wait_query(Socket).


wait_query(Socket) ->
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<1:1, 0:7>>}             -> wait_pong(Socket);
        {tcp, Socket, <<0:1, 0:7>>}             -> ok;
        {tcp, Socket, <<0:1, 0:7, Bin/binary>>} -> zx_lib:b_to_ts(Bin);
        {tcp, Socket, Bin}                      -> {error, zx_net:err_in(Bin)}
        after 5000                              -> handle_timeout(Socket)
    end.


wait_pong(Socket) ->
    ok = pong(Socket),
    wait_query(Socket).


pong(Socket) ->
    gen_tcp:send(Socket, <<1:1, 0:7>>).


-spec fetch(Socket, ID, Watchers, PackageID) -> Result
    when Socket    :: gen_tcp:socket(),
         ID        :: zx_daemon:id(),
         Watchers  :: [pid()],
         PackageID :: zx:package_id(),
         Result    :: {done, binary()}
                    | {error, Reason :: term()}.
%% @private
%% Download a package to the local cache.

fetch(Socket, ID, Watchers, PackageID) ->
    PIDB = term_to_binary(PackageID),
    Message = <<0:1, 12:7, PIDB/binary>>,
    ok = gen_tcp:send(Socket, Message),
    case wait_hops(Socket, ID, PIDB) of
        ok ->
            {ok, Bin} = zx_net:rx(Socket, 5000, Watchers),
            {done, Bin};
        Error ->
            Error
    end.


wait_hops(Socket, ID, PIDB) ->
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<1:1, 3:7, 0:8, PIDB/binary>>} ->
            ok;
        {tcp, Socket, <<1:1, 3:7, Distance:8, PIDB/binary>>} ->
            ok = zx_daemon:result(ID, {hops, Distance}),
            wait_hops(Socket, ID, PIDB);
        {tcp, Socket, Bin} ->
            Reason = zx_net:err_in(Bin),
            {error, Reason}
        after 60000 ->
            handle_timeout(Socket)
    end.



%%% Terminal handlers

-spec handle_timeout(gen_tcp:socket()) -> no_return().

handle_timeout(Socket) ->
    ok = zx_daemon:report(timeout),
    ok = zx_net:disconnect(Socket),
    terminate().


-spec terminate() -> no_return().
%% @private
%% Convenience wrapper around the suicide call.
%% In the case that a more formal retirement procedure is required, consider notifying
%% the supervisor with `supervisor:terminate_child(zomp_client_sup, PID)' and writing
%% a proper system_terminate/2.

terminate() ->
    exit(normal).
