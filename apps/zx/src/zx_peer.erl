%%% @doc
%%% ZX Peer
%%%
%%% A process that handles connections from local ZX instances.
%%% These act as client processes within the local node, shuttling requests from
%%% other nodes to the zx_daemon, and receiving return responses and passing them
%%% back over the local socket.
%%% @end

-module(zx_peer).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([notify/3, takeover/2]).
-export([start/1]).
-export([start_link/1, init/2]).
-export([system_continue/3, system_terminate/4,
         system_get_state/1, system_replace_state/2]).

-include("zx_logger.hrl").

%%% Type and Record Definitions

-record(s, {socket = none :: none | gen_tcp:socket()}).

-type state() :: #s{}.


%%% Service Interface

-spec notify(Pid, Channel, Message) -> ok
    when Pid     :: pid(),
         Channel :: term(),
         Message :: term().

notify(Pid, Channel, Message) ->
    Pid ! {z_sub, Channel, Message},
    ok.


-spec takeover(Pid, ID) -> ok | timeout
    when Pid :: pid(),
         ID  :: zx_daemon:id().

takeover(Pid, ID) ->
    Ref = make_ref(),
    Pid ! {takeover, Ref, ID},
    receive
        {Ref, ok}  -> ok
        after 1000 -> timeout
    end.


-spec start(ListenSocket) -> Result
    when ListenSocket :: gen_tcp:socket(),
         Result       :: {ok, pid()}
                       | {error, Reason},
         Reason       :: {already_started, pid()}
                       | {shutdown, term()}
                       | term().

start(ListenSocket) ->
    zx_peer_sup:start_acceptor(ListenSocket).


-spec start_link(ListenSocket) -> Result
    when ListenSocket :: gen_tcp:socket(),
         Result       :: {ok, pid()}
                       | {error, Reason},
         Reason       :: {already_started, pid()}
                       | {shutdown, term()}
                       | term().

start_link(ListenSocket) ->
    proc_lib:start_link(?MODULE, init, [self(), ListenSocket]).


-spec init(Parent, ListenSocket) -> no_return()
    when Parent       :: pid(),
         ListenSocket :: gen_tcp:socket().

init(Parent, ListenSocket) ->
    Debug = sys:debug_options([]),
    ok = proc_lib:init_ack(Parent, {ok, self()}),
    listen(Parent, Debug, ListenSocket).


-spec listen(Parent, Debug, ListenSocket) -> no_return()
    when Parent       :: pid(),
         Debug        :: [sys:dbg_opt()],
         ListenSocket :: gen_tcp:socket().
%% @private
%% This function waits for a TCP connection. The owner of the socket is still
%% the zx_peer_man (so it can close it on a call to zx_peer_man:ignore/0),
%% but the only one calling gen_tcp:accept/1 on it is this process. Closing the socket
%% is one way a manager process can gracefully unblock child workers that are blocking
%% on a network accept.
%%
%% Once it makes a TCP connection it will call start/1 to spawn its successor.

listen(Parent, Debug, ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            {ok, _} = start(ListenSocket),
            State = #s{socket = Socket},
            loop(Parent, Debug, State);
        {error, closed} ->
            exit(normal)
     end.


-spec loop(Parent, Debug, State) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().

loop(Parent, Debug, State = #s{socket = Socket}) ->
    receive
        {tcp, Socket, Bin} ->
            Result = handle_message(Bin),
            ok = gen_tcp:send(Socket, Result),
            loop(Parent, Debug, State);
        {result, ID, Result} ->
            Bin = term_to_binary({ID, Result}),
            Message = <<0:8, Bin/binary>>,
            ok = gen_tcp:send(Socket, Message),
            loop(Parent, Debug, State);
        {z_sub, Channel, Message} ->
            Bin = term_to_binary({Channel, Message}),
            Message = <<1:1, 1:7, Bin/binary>>,
            ok = gen_tcp:send(Socket, Message),
            loop(Parent, Debug, State);
        {takeover, Ref, ID} ->
            ok = gen_tcp:send(Socket, <<1:1, 1:7, ID:32>>),
            zx_peer_man ! {Ref, ok},
            loop(Parent, Debug, State);
        {new_proxy, Port} ->
            Message = <<2:8, Port:16>>,
            ok = gen_tcp:send(Socket, Message),
            ok = zx_net:disconnect(Socket),
            exit(normal);
        {tcp_closed, Socket} ->
            exit(normal);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, State);
        Unexpected ->
            ok = log(warning, "~p Unexpected message: ~tp", [self(), Unexpected]),
            loop(Parent, Debug, State)
    end.


handle_message(<<Command:8, Bin/binary>>) ->
    Payload = binary_to_term(Bin, [safe]),
    Result =
        case Command of
             1 -> zx_daemon:subscribe(Payload);
             2 -> zx_daemon:unsubscribe(Payload);
             3 -> deferred(fun list/1, Payload);
             4 -> deferred(fun list/1, Payload);
             5 -> deferred(fun zx_daemon:latest/1, Payload);
             6 -> deferred(fun zx_daemon:describe/1, Payload);
             7 -> deferred(fun zx_daemon:tags/1, Payload);
             8 -> deferred(fun provides/1, Payload);
             9 -> deferred(fun zx_daemon:search/1, Payload);
            10 -> deferred(fun zx_daemon:list_deps/1, Payload);
            11 -> deferred(fun zx_daemon:list_sysops/1, Payload);
            12 -> deferred(fun zx_daemon:fetch/1, Payload);
            13 -> zx_daemon:keychain(Payload);
            14 -> zx_daemon:install(Payload);
            15 -> zx_daemon:build(Payload);
            16 -> zx_daemon:list_mirrors();
            17 -> zx_daemon:add_mirror(Payload);
            18 -> zx_daemon:drop_mirror(Payload);
            19 -> register_key(Payload);
            20 -> get_key(Payload);
            21 -> keybin(Payload);
            22 -> zx_daemon:find_keypair(Payload);
            23 -> have_key(Payload);
            24 -> list_keys(Payload);
            25 -> zx_daemon:takeover(Payload);
            26 -> zx_daemon:abdicate(Payload);
            27 -> zx_daemon:drop_realm(Payload);
            28 -> deferred(fun zx_daemon:list_type/1, Payload)
        end,
    pack(Result).


deferred(Query, Payload) ->
    {ok, ID} = Query(Payload),
    receive
        {result, ID, Result} -> Result
        after 5000           -> {error, timeout}
    end.


pack(ok)              -> <<0:8>>;
pack({ok, Result})    -> <<0:8, (term_to_binary(Result))/binary>>;
pack({error, Reason}) -> zx_net:err_ex(Reason);
pack(done)            -> <<0:8>>.


list({R, N, V})      -> zx_daemon:list(R, N, V);
list({R, N})         -> zx_daemon:list(R, N);
list(R)              -> zx_daemon:list(R).

provides({R, M})     -> zx_daemon:provides(R, M).

register_key({O, D}) -> zx_daemon:register_key(O, D).

get_key({T, K})      -> zx_daemon:get_key(T, K).

keybin({T, K})       -> zx_daemon:keybin(T, K).

have_key({T, K})     -> zx_daemon:have_key(T, K).

list_keys({T, O})    -> zx_daemon:list_keys(T, O).


%%% OTP System Message Handling

-spec system_continue(Parent, Debug, State) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().
%% @private
%% The function called by the OTP internal functions after a system message has been
%% handled. If the worker process has several possible states this is one place
%% resumption of a specific state can be specified and dispatched.

system_continue(Parent, Debug, State) ->
    loop(Parent, Debug, State).


-spec system_terminate(Reason, Parent, Debug, State) -> no_return()
    when Reason :: term(),
         Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().
%% @private
%% Called by the OTP inner bits to allow the process to terminate gracefully.
%% Exactly when and if this is callback gets called is specified in the docs:
%% See: http://erlang.org/doc/design_principles/spec_proc.html#msg

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).



-spec system_get_state(State) -> {ok, State}
    when State :: state().
%% @private
%% This function allows the runtime (or anything else) to inspect the running state
%% of the worker process at any arbitrary time.

system_get_state(State) -> {ok, State}.


-spec system_replace_state(StateFun, State) -> {ok, NewState, State}
    when StateFun :: fun(),
         State    :: state(),
         NewState :: term().
%% @private
%% This function allows the system to update the process state in-place. This is most
%% useful for state transitions between code types, like when performing a hot update
%% (very cool, but sort of hard) or hot patching a running system (living on the edge!).

system_replace_state(StateFun, State) ->
    {ok, StateFun(State), State}.
