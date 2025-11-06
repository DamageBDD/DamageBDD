%%% @doc
%%% ZX Peer Manager
%%%
%%% Manages the peer connection aggregation subsystem for ZX.
%%% When ZX nodes need to connec to to get data from upstream Zomp nodes they proxy
%%% their connections through whatever ZX nodes is already providing this service
%%% locally. In addition to aggregating network resource usage, ZX also aggregates
%%% it also sequentializes (and effectively atomizes) local disk operations.
%%% @end

-module(zx_peer_man).
-vsn("0.14.0").
-behavior(gen_server).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([listen/0, ignore/0, retire/1]).
-export([enroll/0, broadcast/2]).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include("zx_logger.hrl").

%%% Type and Record Definitions


-record(s, {listener  = none  :: none | gen_tcp:socket(),
            secondary = none :: none | pid(),
            peers     = []    :: [{reference(), pid()}]}).


-type state()   :: #s{}.



%%% Service Interface


-spec listen() -> Result
    when Result  :: {ok, inet:port_number()}
                  | error.
%% @doc
%% Tell the service to start listening. The port number selection here is left up
%% to the host OS, so when it is determined then the number will be returned to the
%% caller (should always be zx_daemon calling). There shouldn't be any reasons why
%% this call should fail, so zx_daemon is expecting it to always succeed and errors
%% are not specified.

listen() ->
    gen_server:call(?MODULE, listen).


-spec ignore() -> ok.
%% @doc
%% Tell the service to stop listening.
%% It is not an error to call this function when the service is not listening.

ignore() ->
    gen_server:cast(?MODULE, ignore).


-spec retire(ID) -> ok | no_peers
    when ID :: integer().

retire(ID) ->
    gen_server:call(?MODULE, {retire, ID}).


-spec enroll() -> ok.
%% @private
%% zx_peer processes have to enroll themselves so that the zx_peer_man can monitor them
%% and know which one has been alive the longest. In the event that this node retires
%% or goes down it will need to designate a successor. Because there is no guarantee
%% that any of the code being executed by ZX is reliable (and may be calling halt(N)
%% or any other hard shutdown functions or breaks), successor designation occurs
%% pre-emptively and not just on shutdown.

enroll() ->
    gen_server:cast(?MODULE, {enroll, self()}).


-spec broadcast(Channel, Message) -> ok
    when Channel :: term(),
         Message :: term().

broadcast(Channel, Message) ->
    gen_server:cast(?MODULE, {broadcast, Channel, Message}).


%%% Startup Functions


-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason :: term()}.
%% @private
%% This should only ever be called by zx_peers (the service-level supervisor).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, none, []).


-spec init(none) -> {ok, state()}.
%% @private
%% Called by the supervisor process to give the process a chance to perform any
%% preparatory work necessary for proper function.

init(none) ->
    State = #s{},
    {ok, State}.



%%% gen_server Message Handling Callbacks


-spec handle_call(Message, From, State) -> Result
    when Message  :: term(),
         From     :: {pid(), reference()},
         State    :: state(),
         Result   :: {reply, Response, NewState}
                   | {noreply, State},
         Response :: ok
                   | {error, {listening, inet:port_number()}},
         NewState :: state().
%% @private
%% The gen_server:handle_call/3 callback.
%% See: http://erlang.org/doc/man/gen_server.html#Module:handle_call-3

handle_call(listen, _, State) ->
    {Response, NewState} = do_listen(State),
    {reply, Response, NewState};
handle_call({retire, ID}, _, State) ->
    Result = do_retire(ID, State),
    {reply, Result, State};
handle_call(Unexpected, From, State) ->
    ok = io:format("~p Unexpected call from ~tp: ~tp~n", [self(), From, Unexpected]),
    {noreply, State}.


-spec handle_cast(Message, State) -> {noreply, NewState}
    when Message  :: term(),
         State    :: state(),
         NewState :: state().
%% @private
%% The gen_server:handle_cast/2 callback.
%% See: http://erlang.org/doc/man/gen_server.html#Module:handle_cast-2

handle_cast({enroll, Pid}, State) ->
    NewState = do_enroll(Pid, State),
    {noreply, NewState};
handle_cast({broadcast, Channel, Message}, State) ->
    ok = do_broadcast(Channel, Message, State),
    {noreply, State};
handle_cast(ignore, State) ->
    NewState = do_ignore(State),
    {noreply, NewState};
handle_cast(Unexpected, State) ->
    ok = io:format("~p Unexpected cast: ~tp~n", [self(), Unexpected]),
    {noreply, State}.


-spec handle_info(Message, State) -> {noreply, NewState}
    when Message  :: term(),
         State    :: state(),
         NewState :: state().
%% @private
%% The gen_server:handle_info/2 callback.
%% See: http://erlang.org/doc/man/gen_server.html#Module:handle_info-2

handle_info({'DOWN', Mon, process, Pid, Info}, State) ->
    NewState = handle_down(Mon, Pid, Info, State),
    {noreply, NewState};
handle_info(Unexpected, State) ->
    ok = io:format("~p Unexpected info: ~tp~n", [self(), Unexpected]),
    {noreply, State}.



%%% OTP Service Functions

-spec code_change(OldVersion, State, Extra) -> Result
    when OldVersion :: {down, Version} | Version,
         Version    :: term(),
         State      :: state(),
         Extra      :: term(),
         Result     :: {ok, NewState}
                     | {error, Reason :: term()},
         NewState   :: state().
%% @private
%% The gen_server:code_change/3 callback.
%% See: http://erlang.org/doc/man/gen_server.html#Module:code_change-3

code_change(_, State, _) ->
    {ok, State}.


-spec terminate(Reason, State) -> no_return()
    when Reason :: normal
                 | shutdown
                 | {shutdown, term()}
                 | term(),
         State  :: state().
%% @private
%% The gen_server:terminate/2 callback.
%% See: http://erlang.org/doc/man/gen_server.html#Module:terminate-2

terminate(_, _) ->
    ok.



%%% Doer Functions

-spec do_listen(State) -> {Result, NewState}
    when State    :: state(),
         Result   :: {ok, inet:port_number()}
                   | error,
         NewState :: state().
%% @private
%% The "doer" procedure called when a "listen" message is received.

do_listen(State = #s{listener = none}) ->
    {ok, Listener} = 
        case gen_tcp:listen(0, ipv6_options()) of
            {ok, L}                -> {ok, L};
            {error, eafnosupport}  -> gen_tcp:listen(0, ipv4_options());
            {error, eaddrnotavail} -> gen_tcp:listen(0, ipv4_options())
        end,
    {ok, Port} = inet:port(Listener),
    {ok, _} = zx_peer:start(Listener),
    {{ok, Port}, State#s{listener = Listener}};
do_listen(State) ->
    ok = log(warning, "Already listening."),
    {error, State}.

ipv6_options() ->
    [inet6,
     {ip,        {0,0,0,0,0,0,0,1}},
     {active,    true},
     {mode,      binary},
     {keepalive, true},
     {reuseaddr, true},
     {packet,    4}].

ipv4_options() ->
    [inet,
     {ip,        {127,0,0,1}},
     {active,    true},
     {mode,      binary},
     {keepalive, true},
     {reuseaddr, true},
     {packet,    4}].


-spec do_enroll(Pid, State) -> NewState
    when Pid      :: pid(),
         State    :: state(),
         NewState :: state().

do_enroll(Pid, State = #s{peers = []}) ->
    ok = zx_peer:become_secondary(Pid),
    Mon = monitor(process, Pid),
    State#s{secondary = Pid, peers = [{Mon, Pid}]};
do_enroll(Pid, State = #s{peers = Peers}) ->
    Mon = monitor(process, Pid),
    State#s{peers = [{Mon, Pid} | Peers]}.


do_broadcast(Channel, Message, #s{peers = Peers}) ->
    Notify = fun({_, Pid}) -> zx_peer:notify(Pid, Channel, Message) end,
    lists:foreach(Notify, Peers).


-spec handle_down(Mon, Pid, Info, State) -> NewState
    when Mon      :: reference(),
         Pid      :: pid(),
         Info     :: term(),
         State    :: state(),
         NewState :: state().

handle_down(Mon, Pid, Info, State = #s{secondary = Pid, peers = Peers}) ->
    Peer = {Mon, Pid},
    ok = log(info, "Secondary peer ~p retired with ~tp.", [Pid, Info]),
    case lists:delete(Peer, Peers) of
        [] ->
            State#s{secondary = none, peers = []};
        NewPeers ->
            {_, NextPid} = tl(NewPeers),
            ok = zx_peer:become_secondary(NextPid),
            State#s{secondary = NextPid, peers = NewPeers}
    end;
handle_down(Mon, Pid, Info, State = #s{peers = Peers}) ->
    Peer = {Mon, Pid},
    case lists:member(Peer, Peers) of
        true ->
            ok = log(info, "Peer ~p retired.", [Pid]),
            State#s{peers = lists:delete(Peer, Peers)};
        false ->
            Unexpected = {'DOWN', Mon, process, Pid, Info},
            ok = log(warning, "Unexpected info: ~160tp", [Unexpected]),
            State
    end.


-spec do_ignore(State) -> NewState
    when State    :: state(),
         NewState :: state().
%% @private
%% The "doer" procedure called when an "ignore" message is received.

do_ignore(State = #s{listener = none}) ->
    State;
do_ignore(State = #s{listener = Listener}) ->
    ok = gen_tcp:close(Listener),
    State#s{listener = none}.


do_retire(_, #s{secondary = none}) -> halt;
do_retire(ID, #s{secondary = Pid}) -> zx_peer:takeover(Pid, ID).
