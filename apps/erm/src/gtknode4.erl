%%%-------------------------------------------------------------------
%%% @doc
%%% OTP controller for the GTK4 C-node.
%%%
%%% The controller owns correlation references, readiness, call timeouts and
%%% event subscriptions.  It can either talk to a distributed C-node endpoint
%%% or execute the same protocol through a deterministic Erlang backend.
%%%
%%% C-node transport protocol:
%%%   Erlang -> C: {gtknode4, call, Ref, Command}
%%%   Erlang -> C: {gtknode4, cast, Command}
%%%   C -> Erlang: {gtknode4, reply, Ref, Result}
%%%   C -> Erlang: {gtknode4, event, NativeId, EventType, Payload}
%%%   C -> Erlang: {gtknode4, hello, Version, Endpoint, Capabilities}
%%%
%%% Endpoint is either a remote pid or {RegisteredName, CNode}.
%%%-------------------------------------------------------------------
-module(gtknode4).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    stop/0,
    call/1,
    call/2,
    cast/1,
    await_ready/1,
    status/0,
    subscribe/0,
    subscribe/1,
    unsubscribe/0,
    unsubscribe/1,
    transport_down/1,

    %% Compatibility conveniences from the original sketch.
    load_ui/1,
    set_label/2,
    get_label/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(PROTOCOL_VERSION, 1).
-define(DEFAULT_CALL_TIMEOUT, 5000).

-record(state, {
    endpoint = undefined,
    endpoint_monitor = undefined,
    ready = false,
    protocol_version = ?PROTOCOL_VERSION,
    capabilities = #{},
    pending = #{},
    ready_waiters = #{},
    subscribers = #{},
    backend_mod = undefined,
    backend_state = undefined,
    event_seq = 0,
    last_error = undefined
}).

-type endpoint() :: pid() | {atom(), node()}.
-type command() :: term().
-type result() :: term().

-export_type([endpoint/0, command/0, result/0]).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map() | list()) -> gen_server:start_ret().
start_link(Opts0) ->
    Opts = options_map(Opts0),
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _Pid -> gen_server:stop(?SERVER)
    end.

-spec call(command()) -> result().
call(Command) ->
    call(Command, ?DEFAULT_CALL_TIMEOUT).

-spec call(command(), timeout()) -> result().
call(Command, Timeout) ->
    gen_server:call(?SERVER, {command, Command, Timeout}, outer_timeout(Timeout)).

-spec cast(command()) -> ok.
cast(Command) ->
    gen_server:cast(?SERVER, {command, Command}).

-spec await_ready(timeout()) -> ok | {error, timeout}.
await_ready(Timeout) ->
    gen_server:call(?SERVER, {await_ready, Timeout}, outer_timeout(Timeout)).

-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-spec subscribe() -> ok.
subscribe() ->
    subscribe(self()).

-spec subscribe(pid()) -> ok.
subscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?SERVER, {subscribe, Pid}).

-spec unsubscribe() -> ok.
unsubscribe() ->
    unsubscribe(self()).

-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?SERVER, {unsubscribe, Pid}).

-spec transport_down(term()) -> ok.
transport_down(Reason) ->
    gen_server:cast(?SERVER, {transport_down, Reason}).

-spec load_ui(file:filename_all()) -> ok | {error, term()}.
load_ui(Filename) ->
    call({load_ui, filename_to_binary(Filename)}).

-spec set_label(atom() | binary() | string(), iodata()) -> ok | {error, term()}.
set_label(WidgetName, Text) ->
    call({set_label, normalize_name(WidgetName), iolist_to_binary(Text)}).

-spec get_label(atom() | binary() | string()) -> {ok, binary()} | {error, term()}.
get_label(WidgetName) ->
    call({get_label, normalize_name(WidgetName)}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Endpoint = maps:get(endpoint, Opts, undefined),
    case maps:get(backend, Opts, undefined) of
        undefined ->
            %% In local_cnode mode the native process is started after this
            %% controller. Avoid initiating a distribution connection to a
            %% node that cannot exist yet; the native hello enables monitoring.
            MonitorOnStart = maps:get(monitor_endpoint_on_start, Opts, true),
            maybe_monitor_endpoint(Endpoint, MonitorOnStart),
            {ok, #state{
                endpoint = Endpoint,
                endpoint_monitor = monitor_endpoint_process(Endpoint)
            }};
        Backend when is_atom(Backend) ->
            BackendOpts = options_map(maps:get(backend_opts, Opts, #{})),
            case Backend:init(BackendOpts) of
                {ok, BackendState, Capabilities} ->
                    {ok, #state{
                        ready = true,
                        capabilities = Capabilities,
                        backend_mod = Backend,
                        backend_state = BackendState
                    }};
                {error, Reason} ->
                    {stop, {backend_init_failed, Backend, Reason}}
            end
    end.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call({subscribe, Pid}, _From, State0) ->
    State = add_subscriber(Pid, State0),
    send_current_status(Pid, State),
    {reply, ok, State};
handle_call({unsubscribe, Pid}, _From, State0) ->
    {reply, ok, remove_subscriber(Pid, State0)};
handle_call({await_ready, _Timeout}, _From, State = #state{ready = true}) ->
    {reply, ok, State};
handle_call({await_ready, 0}, _From, State) ->
    {reply, {error, timeout}, State};
handle_call({await_ready, Timeout}, From, State0) ->
    WaitRef = make_ref(),
    Timer = start_timer(Timeout, {ready_timeout, WaitRef}),
    Waiter = #{from => From, timer => Timer},
    Waiters = maps:put(WaitRef, Waiter, State0#state.ready_waiters),
    {noreply, State0#state{ready_waiters = Waiters}};
handle_call({command, _Command, _Timeout}, _From, State = #state{ready = false}) ->
    {reply, {error, not_connected}, State};
handle_call({command, Command, Timeout}, From, State = #state{backend_mod = Backend}) when
    is_atom(Backend), Backend =/= undefined
->
    execute_backend_call(Command, From, Timeout, State);
handle_call({command, Command, Timeout}, From, State0) ->
    Ref = make_ref(),
    case send_endpoint(State0#state.endpoint, {gtknode4, call, Ref, Command}) of
        ok ->
            Timer = start_timer(Timeout, {command_timeout, Ref}),
            Pending = maps:put(Ref, #{from => From, timer => Timer}, State0#state.pending),
            {noreply, State0#state{pending = Pending}};
        {error, Reason} ->
            State1 = mark_disconnected(Reason, State0),
            {reply, {error, Reason}, State1}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({command, Command}, State = #state{ready = true, backend_mod = Backend}) when
    is_atom(Backend), Backend =/= undefined
->
    execute_backend_cast(Command, State);
handle_cast({command, Command}, State = #state{ready = true}) ->
    _ = send_endpoint(State#state.endpoint, {gtknode4, cast, Command}),
    {noreply, State};
handle_cast({command, _Command}, State) ->
    {noreply, State};
handle_cast({transport_down, Reason}, State0) ->
    {noreply, mark_disconnected(Reason, State0)};
handle_cast(_Message, State) ->
    {noreply, State}.

%% Preferred handshake, with an endpoint value directly usable by send/2.
handle_info({gtknode4, hello, Version, Endpoint, Capabilities}, State0) ->
    {noreply, accept_handshake(Version, Endpoint, Capabilities, State0)};
%% Alternative handshake convenient for C code that sends node/name separately.
handle_info({gtknode4, hello, Version, CNode, CRegName, Capabilities}, State0) when
    is_atom(CNode), is_atom(CRegName)
->
    {noreply, accept_handshake(Version, {CRegName, CNode}, Capabilities, State0)};
%% Compatibility with the historical gtknode handshake shape.
handle_info({{RemotePid, handshake}, Capabilities}, State0) when is_pid(RemotePid) ->
    {noreply, accept_handshake(1, RemotePid, Capabilities, State0)};
%% Compatibility with the original sketch. This only works when endpoint was
%% configured before the C-node was launched.
handle_info({gtknode4, ok}, State0 = #state{endpoint = Endpoint}) when
    Endpoint =/= undefined
->
    {noreply, accept_handshake(1, Endpoint, #{}, State0)};
handle_info({gtknode4, reply, Ref, Result}, State0) ->
    case maps:take(Ref, State0#state.pending) of
        {Pending, Pending1} ->
            cancel_timer(maps:get(timer, Pending, undefined)),
            gen_server:reply(maps:get(from, Pending), Result),
            {noreply, State0#state{pending = Pending1}};
        error ->
            {noreply, State0}
    end;
handle_info({gtknode4, event, _RemoteSeq, NativeId, EventType, Payload}, State0) ->
    {noreply, publish_event(NativeId, EventType, normalize_payload(Payload), State0)};
handle_info({gtknode4, event, NativeId, EventType, Payload}, State0) ->
    {noreply, publish_event(NativeId, EventType, normalize_payload(Payload), State0)};
%% Compatibility with the earlier signal tuple.
handle_info({gtknode4, signal, NativeId, SignalName, Payload}, State0) ->
    Canonical = canonical_signal(SignalName),
    Payload1 = maps:put(raw_signal, SignalName, normalize_payload(Payload)),
    {noreply, publish_event(NativeId, Canonical, Payload1, State0)};
handle_info({command_timeout, Ref}, State0) ->
    case maps:take(Ref, State0#state.pending) of
        {Pending, Pending1} ->
            gen_server:reply(maps:get(from, Pending), {error, timeout}),
            {noreply, State0#state{pending = Pending1}};
        error ->
            {noreply, State0}
    end;
handle_info({ready_timeout, WaitRef}, State0) ->
    case maps:take(WaitRef, State0#state.ready_waiters) of
        {Waiter, Waiters1} ->
            gen_server:reply(maps:get(from, Waiter), {error, timeout}),
            {noreply, State0#state{ready_waiters = Waiters1}};
        error ->
            {noreply, State0}
    end;
handle_info({nodedown, CNode}, State0) ->
    case endpoint_node(State0#state.endpoint) of
        CNode -> {noreply, mark_disconnected({nodedown, CNode}, State0)};
        _Other -> {noreply, State0}
    end;
handle_info(
    {'DOWN', MonitorRef, process, Pid, Reason},
    State0 = #state{endpoint_monitor = MonitorRef}
) ->
    {noreply, mark_disconnected({endpoint_down, Pid, Reason}, State0)};
handle_info({'DOWN', MonitorRef, process, Pid, _Reason}, State0) ->
    case maps:get(Pid, State0#state.subscribers, undefined) of
        MonitorRef -> {noreply, remove_subscriber(Pid, State0)};
        _ -> {noreply, State0}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State = #state{backend_mod = Backend, backend_state = BackendState}) ->
    maybe_monitor_endpoint(State#state.endpoint, false),
    demonitor_endpoint(State#state.endpoint_monitor),
    case Backend of
        undefined -> ok;
        _ when is_atom(Backend) -> best_effort_backend_terminate(Backend, Reason, BackendState)
    end.

best_effort_backend_terminate(Backend, Reason, BackendState) ->
    try Backend:terminate(Reason, BackendState) of
        _ -> ok
    catch
        _:_ -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Backend execution
%%%===================================================================

execute_backend_call(Command, _From, _Timeout, State0) ->
    Backend = State0#state.backend_mod,
    BackendState = State0#state.backend_state,
    try Backend:handle_command(Command, BackendState) of
        {reply, Result, BackendState1} ->
            {reply, Result, State0#state{backend_state = BackendState1}};
        {reply, Result, BackendState1, Events} ->
            State1 = publish_events(Events, State0#state{backend_state = BackendState1}),
            {reply, Result, State1};
        Other ->
            {reply, {error, {bad_backend_reply, Other}}, State0}
    catch
        Class:Reason:Stacktrace ->
            {reply, {error, {backend_failed, Class, Reason, Stacktrace}}, State0}
    end.

execute_backend_cast(Command, State0) ->
    Backend = State0#state.backend_mod,
    BackendState = State0#state.backend_state,
    try Backend:handle_cast(Command, BackendState) of
        {noreply, BackendState1} ->
            {noreply, State0#state{backend_state = BackendState1}};
        {noreply, BackendState1, Events} ->
            {noreply, publish_events(Events, State0#state{backend_state = BackendState1})};
        Other ->
            logger:warning("gtknode4 backend returned invalid cast result: ~p", [Other]),
            {noreply, State0}
    catch
        Class:Reason:Stacktrace ->
            logger:error("gtknode4 backend cast failed: ~p", [{Class, Reason, Stacktrace}]),
            {noreply, State0}
    end.

%%%===================================================================
%%% State transitions and event publication
%%%===================================================================

accept_handshake(?PROTOCOL_VERSION, Endpoint, Capabilities, State0) ->
    case valid_endpoint(Endpoint) of
        true -> mark_ready(?PROTOCOL_VERSION, Endpoint, Capabilities, State0);
        false -> mark_disconnected({bad_handshake_endpoint, Endpoint}, State0)
    end;
accept_handshake(Version, _Endpoint, _Capabilities, State0) ->
    mark_disconnected(
        {unsupported_protocol, #{received => Version, supported => [?PROTOCOL_VERSION]}},
        State0
    ).

valid_endpoint(Pid) when is_pid(Pid) -> true;
valid_endpoint({Name, CNode}) when is_atom(Name), is_atom(CNode) -> true;
valid_endpoint(_Endpoint) -> false.

mark_ready(Version, Endpoint, Capabilities0, State0) ->
    maybe_monitor_endpoint(State0#state.endpoint, false),
    demonitor_endpoint(State0#state.endpoint_monitor),
    maybe_monitor_endpoint(Endpoint, true),
    Capabilities = capability_map(Capabilities0),
    State1 = State0#state{
        endpoint = Endpoint,
        endpoint_monitor = monitor_endpoint_process(Endpoint),
        ready = true,
        protocol_version = Version,
        capabilities = Capabilities,
        last_error = undefined
    },
    State2 = reply_ready_waiters(State1),
    notify_subscribers(
        {gtknode4, status, ready, #{
            protocol => Version, endpoint => Endpoint, capabilities => Capabilities
        }},
        State2
    ),
    State2.

mark_disconnected(Reason, State0) ->
    maybe_monitor_endpoint(State0#state.endpoint, false),
    demonitor_endpoint(State0#state.endpoint_monitor),
    State1 = fail_pending(Reason, State0#state{
        endpoint_monitor = undefined,
        ready = false,
        last_error = Reason
    }),
    State2 = fail_ready_waiters(Reason, State1),
    notify_subscribers({gtknode4, status, disconnected, Reason}, State2),
    State2.

fail_pending(Reason, State0) ->
    maps:foreach(
        fun(_Ref, Pending) ->
            cancel_timer(maps:get(timer, Pending, undefined)),
            gen_server:reply(maps:get(from, Pending), {error, {disconnected, Reason}})
        end,
        State0#state.pending
    ),
    State0#state{pending = #{}}.

reply_ready_waiters(State0) ->
    maps:foreach(
        fun(_Ref, Waiter) ->
            cancel_timer(maps:get(timer, Waiter, undefined)),
            gen_server:reply(maps:get(from, Waiter), ok)
        end,
        State0#state.ready_waiters
    ),
    State0#state{ready_waiters = #{}}.

fail_ready_waiters(Reason, State0) ->
    maps:foreach(
        fun(_Ref, Waiter) ->
            cancel_timer(maps:get(timer, Waiter, undefined)),
            gen_server:reply(maps:get(from, Waiter), {error, Reason})
        end,
        State0#state.ready_waiters
    ),
    State0#state{ready_waiters = #{}}.

publish_events(Events, State0) when is_list(Events) ->
    lists:foldl(
        fun
            ({NativeId, EventType, Payload}, Acc) ->
                publish_event(NativeId, EventType, normalize_payload(Payload), Acc);
            (BadEvent, Acc) ->
                logger:warning("gtknode4 backend emitted invalid event: ~p", [BadEvent]),
                Acc
        end,
        State0,
        Events
    ).

publish_event(NativeId, EventType, Payload, State0) ->
    Seq = State0#state.event_seq + 1,
    Message = {gtknode4, event, Seq, NativeId, EventType, Payload},
    notify_subscribers(Message, State0),
    State0#state{event_seq = Seq}.

notify_subscribers(Message, #state{subscribers = Subscribers}) ->
    maps:foreach(fun(Pid, _MonitorRef) -> Pid ! Message end, Subscribers),
    ok.

send_current_status(Pid, State = #state{ready = true}) ->
    Pid !
        {gtknode4, status, ready, #{
            protocol => State#state.protocol_version,
            endpoint => State#state.endpoint,
            capabilities => State#state.capabilities
        }},
    ok;
send_current_status(Pid, #state{last_error = Reason}) when Reason =/= undefined ->
    Pid ! {gtknode4, status, disconnected, Reason},
    ok;
send_current_status(_Pid, _State) ->
    ok.

add_subscriber(Pid, State = #state{subscribers = Subscribers}) ->
    case maps:is_key(Pid, Subscribers) of
        true -> State;
        false -> State#state{subscribers = maps:put(Pid, erlang:monitor(process, Pid), Subscribers)}
    end.

remove_subscriber(Pid, State = #state{subscribers = Subscribers}) ->
    case maps:take(Pid, Subscribers) of
        {MonitorRef, Subscribers1} ->
            erlang:demonitor(MonitorRef, [flush]),
            State#state{subscribers = Subscribers1};
        error ->
            State
    end.

%%%===================================================================
%%% Transport helpers
%%%===================================================================

send_endpoint(Pid, Message) when is_pid(Pid) ->
    Pid ! Message,
    ok;
send_endpoint({Name, CNode} = Endpoint, Message) when is_atom(Name), is_atom(CNode) ->
    case erlang:send(Endpoint, Message, [noconnect]) of
        noconnect -> {error, not_connected};
        nosuspend -> {error, busy};
        _ -> ok
    end;
send_endpoint(undefined, _Message) ->
    {error, no_endpoint};
send_endpoint(Endpoint, _Message) ->
    {error, {bad_endpoint, Endpoint}}.

maybe_monitor_endpoint({_, CNode}, Enable) when is_atom(CNode), CNode =/= node() ->
    monitor_node(CNode, Enable),
    ok;
maybe_monitor_endpoint(_Endpoint, _Enable) ->
    ok.

monitor_endpoint_process(Pid) when is_pid(Pid) ->
    erlang:monitor(process, Pid);
monitor_endpoint_process(_Endpoint) ->
    undefined.

demonitor_endpoint(undefined) ->
    ok;
demonitor_endpoint(MonitorRef) when is_reference(MonitorRef) ->
    erlang:demonitor(MonitorRef, [flush]),
    ok.

endpoint_node({_Name, CNode}) when is_atom(CNode) -> CNode;
endpoint_node(_Endpoint) -> undefined.

%%%===================================================================
%%% General helpers
%%%===================================================================

status_map(State) ->
    #{
        ready => State#state.ready,
        endpoint => State#state.endpoint,
        protocol_version => State#state.protocol_version,
        capabilities => State#state.capabilities,
        backend => State#state.backend_mod,
        pending_calls => map_size(State#state.pending),
        subscribers => map_size(State#state.subscribers),
        event_seq => State#state.event_seq,
        last_error => State#state.last_error
    }.

outer_timeout(infinity) -> infinity;
outer_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 -> Timeout + 1000.

start_timer(infinity, _Message) ->
    undefined;
start_timer(Timeout, Message) when is_integer(Timeout), Timeout >= 0 ->
    erlang:send_after(Timeout, self(), Message).

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List).

capability_map(Map) when is_map(Map) -> Map;
capability_map(List) when is_list(List) -> #{items => List};
capability_map(Other) -> #{raw => Other}.

normalize_payload(Map) when is_map(Map) -> Map;
normalize_payload(undefined) -> #{};
normalize_payload(Other) -> #{value => Other}.

canonical_signal(clicked) -> click;
canonical_signal(<<"clicked">>) -> click;
canonical_signal("clicked") -> click;
canonical_signal(changed) -> change;
canonical_signal(<<"changed">>) -> change;
canonical_signal("changed") -> change;
canonical_signal(activate) -> keypress;
canonical_signal(<<"activate">>) -> keypress;
canonical_signal("activate") -> keypress;
canonical_signal(close_request) -> destroy;
canonical_signal(<<"close-request">>) -> destroy;
canonical_signal("close-request") -> destroy;
canonical_signal(Signal) when is_atom(Signal) -> Signal;
canonical_signal(_Signal) -> raw_signal.

normalize_name(Name) when is_binary(Name) -> Name;
normalize_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
normalize_name(Name) when is_list(Name) -> unicode:characters_to_binary(Name).

filename_to_binary(Filename) when is_binary(Filename) -> Filename;
filename_to_binary(Filename) -> unicode:characters_to_binary(filename:flatten(Filename)).
