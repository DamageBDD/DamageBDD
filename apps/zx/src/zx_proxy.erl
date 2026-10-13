%%% @doc
%%% ZX Proxy
%%%
%%% Abstraction to the local zx_daemon proxy.
%%% @end

-module(zx_proxy).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([subscribe/1, unsubscribe/1, request/1]).
-export([connect/1, disconnect/0]).
-export([start_link/0, init/1]).
-export([system_continue/3, system_terminate/4,
         system_get_state/1, system_replace_state/2]).

-include("zx_logger.hrl").

%%% Type and Record Definitions

-record(s, {socket = none :: none | gen_tcp:socket()}).

-type state() :: #s{}.


%%% Service Interface

-spec subscribe(zx:package()) -> ok.

subscribe(Realm) ->
    ?MODULE ! {subscribe, Realm},
    ok.


-spec unsubscribe(zx:package()) -> ok.

unsubscribe(Package) ->
    ?MODULE ! {unsubscribe, Package},
    ok.


-spec request(Action) -> Result
    when Action :: zx_daemon:action(),
         Result :: term()
                 | {error, Reason :: timeout | term()}.

request(Action) ->
    Proxy = whereis(?MODULE),
    Mon = monitor(process, Proxy),
    request(Proxy, Mon, Action).

request(Proxy, Mon, {fetch, R, N, V, Watchers}) ->
    Proxy ! {request, self(), Mon, {fetch, R, N, V}},
    progress(Proxy, Mon, Watchers);
request(Proxy, Mon, Action) ->
    Proxy ! {request, self(), Mon, Action},
    receive
        {result, Mon, Result} ->
            true = demonitor(Mon),
            Result;
        {'DOWN', Mon, process, Proxy, Info} ->
            {error, Info}
        after 5000 ->
            {error, timeout}
    end.

progress(Proxy, Mon, Watchers) ->
    receive
        Report when element(1, Report) =:= rx ->
            Notify = fun(Watcher) -> Watcher ! Report end,
            ok = lists:foreach(Notify, Watchers),
            progress(Proxy, Mon, Watchers);
        {result, Mon, Result} ->
            true = demonitor(Mon),
            Result;
        {'DOWN', Mon, process, Proxy, Info} ->
            {error, Info}
        after 5000 ->
            {error, timeout}
    end.


-spec connect(Port) -> Result
    when Port   :: inet:port_number(),
         Result :: ok.

connect(Port) ->
    ?MODULE ! {connect, self(), Port},
    receive
        {connect, Outcome} -> Outcome
        after 5000         -> error
    end.


-spec disconnect() -> ok.

disconnect() ->
    ?MODULE ! disconnect,
    ok.


-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason},
         Reason :: {already_started, pid()}
                 | {shutdown, term()}
                 | term().

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).


-spec init(Parent) -> no_return()
    when Parent :: pid().

init(Parent) ->
    Debug = sys:debug_options([]),
    Self = self(),
    true = register(?MODULE, Self),
    ok = proc_lib:init_ack(Parent, {ok, Self}),
    loop(Parent, Debug, #s{}).


-spec loop(Parent, Debug, State) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().

loop(Parent, Debug, State = #s{socket = Socket}) ->
    receive
        {request, From, Ref, Action} ->
            Result = dispatch(Socket, Action),
            From ! {result, Ref, Result},
            loop(Parent, Debug, State);
        {tcp, Socket, Bin} ->
            ok = handle_message(Bin),
            loop(Parent, Debug, State);
        {connect, From, Port} ->
            {Outcome, NewState} = connect(Port, State),
            From ! {connect, Outcome},
            loop(Parent, Debug, NewState);
        disconnect ->
            NewState = disconnect(State),
            loop(Parent, Debug, NewState);
        {tcp_closed, Socket} ->
            ok = log(info, "Socket closed."),
            NewState = State#s{socket = none},
            loop(Parent, Debug, NewState);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, State);
        Unexpected ->
            ok = io:format("~p Unexpected message: ~tp", [self(), Unexpected]),
            loop(Parent, Debug, State)
    end.


dispatch(Socket, Action) ->
    case Action of
        {list, R}             -> make_query(Socket,  3, R);
        {list, R, N}          -> make_query(Socket,  4, {R, N});
        {list, R, N, V}       -> make_query(Socket,  4, {R, N, V});
        {latest, R, N}        -> make_query(Socket,  5, {R, N});
        {latest, R, N, V}     -> make_query(Socket,  5, {R, N, V});
        {describe, R, N}      -> make_query(Socket,  6, {R, N});
        {describe, R, N, V}   -> make_query(Socket,  6, {R, N, V});
        {tags, R, N}          -> make_query(Socket,  7, {R, N});
        {tags, R, N, V}       -> make_query(Socket,  7, {R, N, V});
        {provides, R, M}      -> make_query(Socket,  8, {R, M});
        {search, R, String}   -> make_query(Socket,  9, {R, String});
        {list_deps, R, N, V}  -> make_query(Socket, 10, {R, N, V});
        {list_sysops, R}      -> make_query(Socket, 11, R);
%       {fetch, R, N, V}      -> fetch(Socket, {R, N, V});
        {fetch, R, N, V}      -> make_query(Socket, 12, {R, N, V});
        {keychain, R, K}      -> make_query(Socket, 13, {R, K});
        {install, R, N, V}    -> make_query(Socket, 14, {R, N, V});
        {build, R, N, V}      -> make_query(Socket, 15, {R, N, V});
        {list_mirrors}        -> make_query(Socket, 16, none);
        {add_mirror, Host}    -> make_query(Socket, 17, Host);
        {drop_mirror, Host}   -> make_query(Socket, 18, Host);
        {register_key, Data}  -> make_query(Socket, 19, Data);
        {get_key, KeyID}      -> make_query(Socket, 20, KeyID);
        {keybin, KeyID}       -> make_query(Socket, 21, KeyID);
        {find_keypair, KeyID} -> make_query(Socket, 22, KeyID);
        {have_key, Type, KID} -> make_query(Socket, 23, {Type, KID});
        {list_keys, R}        -> make_query(Socket, 24, R);
        {takeover, R}         -> make_query(Socket, 25, R);
        {abdicate, R}         -> make_query(Socket, 26, R);
        {drop_realm, R}       -> make_query(Socket, 27, R);
        {list_type, R, T}     -> make_query(Socket, 28, {R, T});
        Unexpected            ->
            Message = "Received unexpected request action. Action: ~200tp",
            ok = log(warning, Message, [Unexpected]),
            {error, bad_message}
    end.


make_query(Socket, Command, Payload) ->
    Message = pack(Command, Payload),
    ok = gen_tcp:send(Socket, Message),
    receive
        {tcp, Socket, <<0:8>>}             -> ok;
        {tcp, Socket, <<0:8, Bin/binary>>} -> zx_lib:b_to_t(Bin);
        {tcp, Socket, Bin}                 -> {error, zx_net:err_in(Bin)}
        after 5000                         -> {error, timeout}
    end.


pack(Command, none)    -> <<0:1, Command:7>>;
pack(Command, Payload) -> <<0:1, Command:7, (term_to_binary(Payload))/binary>>.


handle_message(<<1:1, 1:7, Bin/binary>>) ->
    {ok, {Channel, Message}} = zx_lib:b_to_ts(Bin),
    zx_daemon:notify(Channel, Message).


connect(Port, State = #s{socket = none}) ->
    Options =
        [inet6,
         {ip,        {0,0,0,0,0,0,0,1}},
         {active,    true},
         {mode,      binary},
         {keepalive, true},
         {reuseaddr, true},
         {packet,    4}],
    case gen_tcp:connect({0,0,0,0,0,0,0,1}, Port, Options) of
        {ok, Socket} ->
            {ok, State#s{socket = Socket}};
        {error, eafnosupport} ->
            AncientOptions =
                [inet,
                 {ip,        {127,0,0,1}},
                 {active,    true},
                 {mode,      binary},
                 {keepalive, true},
                 {reuseaddr, true},
                 {packet,    4}],
            case gen_tcp:connect({127,0,0,1}, Port, AncientOptions) of
                {ok, Socket} ->
                    {ok, State#s{socket = Socket}};
                {error, Reason} ->
                    ok = log(warning, "Connect to local proxy failed with ~tp.", [Reason]),
                    {error, State}
            end;
        {error, Reason} ->
            ok = log(warning, "Connect to local proxy failed with ~tp.", [Reason]),
            {error, State}
    end.


disconnect(State = #s{socket = none}) ->
    State;
disconnect(State = #s{socket = Socket}) ->
    ok = zx_net:disconnect(Socket),
    State#s{socket = none}.


%%% OTP System Message Handling

-spec system_continue(Parent, Debug, State) -> no_return()
    when Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().

system_continue(Parent, Debug, State) ->
    loop(Parent, Debug, State).


-spec system_terminate(Reason, Parent, Debug, State) -> no_return()
    when Reason :: term(),
         Parent :: pid(),
         Debug  :: [sys:dbg_opt()],
         State  :: state().

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).


-spec system_get_state(State) -> {ok, State}
    when State :: state().

system_get_state(State) -> {ok, State}.


-spec system_replace_state(StateFun, State) -> {ok, NewState, State}
    when StateFun :: fun(),
         State    :: state(),
         NewState :: term().

system_replace_state(StateFun, State) ->
    {ok, StateFun(State), State}.
