%%%-------------------------------------------------------------------
%%% @doc
%%% A GS-style object abstraction backed by the gtknode4 protocol.
%%%
%%% The public shape follows the useful parts of the retired GS API and the
%%% supplied wxgs module:
%%%   * hierarchical logical objects
%%%   * owner-local names
%%%   * create/config/read/destroy and create_tree
%%%   * owner-process event delivery
%%%   * modal message dialogs
%%%
%%% BDD seams are first-class:
%%%   * sync/0 is a renderer barrier (no sleeps in scenarios)
%%%   * inspect/1 reads logical and native state
%%%   * snapshot/2 captures the actual GTK rendering
%%%   * monotonically sequenced event history prevents event races
%%%   * await_event/4 waits after a known cursor
%%%   * inject/3 is available only when test_mode is enabled
%%%
%%% Owner events:
%%%     {gtkgs, IdOrName, EventType, Data, Args}
%%%
%%% Logical references:
%%%     {gtkgs_ref, ServerPid, IntegerId}
%%%-------------------------------------------------------------------
-module(gtkgs).
-behaviour(gen_server).

-export([
    start/0,
    start_link/0,
    start_link/1,
    stop/0,
    stop/1,
    server/0,

    create/2,
    create/3,
    create/4,
    create_tree/2,
    config/2,
    read/2,
    destroy/1,
    message_dialog/3,
    respond_dialog/2,
    active_dialogs/0,

    sync/0,
    sync/1,
    inspect/1,
    snapshot/1,
    snapshot/2,
    snapshot_dialog/1,
    snapshot_dialog/2,
    event_cursor/0,
    events_since/1,
    clear_events/0,
    await_event/3,
    await_event/4,
    inject/3
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
-define(FIRST_ID, 1000).
-define(FIRST_NATIVE_ID, 2000).
-define(FIRST_DIALOG_ID, 1000000).
-define(DEFAULT_BACKEND_TIMEOUT, 5000).
-define(DEFAULT_EVENT_LOG_LIMIT, 1000).

-record(object, {
    id,
    native_id,
    name = undefined,
    owner,
    type,
    parent = root,
    children = [],
    data = [],
    options = #{}
}).

-record(state, {
    next_id = ?FIRST_ID,
    next_native_id = ?FIRST_NATIVE_ID,
    next_dialog_id = ?FIRST_DIALOG_ID,
    objects = #{},
    names = #{},
    native_to_id = #{},
    owner_monitors = #{},
    dialogs = #{},
    test_mode = false,
    backend_timeout = ?DEFAULT_BACKEND_TIMEOUT,
    dialog_timeout = infinity,
    event_seq = 0,
    event_log = {[], []},
    event_log_limit = ?DEFAULT_EVENT_LOG_LIMIT,
    waiters = #{}
}).

-type server_ref() :: pid().
-type object_ref() :: {gtkgs_ref, pid(), pos_integer()}.
-type dialog_ref() :: {gtkgs_dialog, pid(), pos_integer()}.
-type object_name() :: atom().
-type object_key() :: object_ref() | object_name().
-type option() :: atom() | tuple().
-type options() :: map() | option() | [option()].
-type event_map() :: map().

-export_type([
    server_ref/0,
    object_ref/0,
    dialog_ref/0,
    object_key/0,
    option/0,
    options/0,
    event_map/0
]).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start() -> server_ref().
start() ->
    case whereis(?SERVER) of
        undefined ->
            case gen_server:start({local, ?SERVER}, ?MODULE, #{}, []) of
                {ok, Pid} -> Pid;
                {error, {already_started, Pid}} -> Pid;
                {error, Reason} -> error({gtkgs_start_failed, Reason})
            end;
        Pid ->
            Pid
    end.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map() | list()) -> gen_server:start_ret().
start_link(Opts0) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, options_map(Opts0), []).

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> stop(Pid)
    end.

-spec stop(server_ref()) -> ok.
stop(Server) when is_pid(Server) ->
    gen_server:stop(Server).

-spec server() -> server_ref().
server() ->
    case whereis(?SERVER) of
        undefined -> error(gtkgs_not_started);
        Pid -> Pid
    end.

-spec create(atom(), server_ref() | object_key()) -> object_ref() | {error, term()}.
create(Type, Parent) ->
    create(Type, Parent, []).

-spec create(atom(), server_ref() | object_key(), options()) -> object_ref() | {error, term()}.
create(Type, Parent, Options) ->
    Server = server_for(Parent),
    gen_server:call(
        Server,
        {create, self(), Type, undefined, Parent, normalize_options(Options)},
        infinity
    ).

-spec create(atom(), object_name(), server_ref() | object_key(), options()) ->
    object_ref() | {error, term()}.
create(Type, Name, Parent, Options) when is_atom(Name) ->
    Server = server_for(Parent),
    gen_server:call(
        Server,
        {create, self(), Type, Name, Parent, normalize_options(Options)},
        infinity
    ).

-spec create_tree(server_ref() | object_key(), list()) ->
    {ok, [object_ref()]} | {error, term()}.
create_tree(Parent, Tree) when is_list(Tree) ->
    create_tree_nodes(Parent, Tree, []).

-spec config(object_key(), options()) -> ok | {error, term()}.
config(Object, Options) ->
    Server = server_for(Object),
    gen_server:call(Server, {config, self(), Object, normalize_options(Options)}, infinity).

-spec read(object_key(), atom() | tuple()) -> term().
read(Object, Key) ->
    Server = server_for(Object),
    gen_server:call(Server, {read, self(), Object, Key}, infinity).

-spec destroy(object_key()) -> ok | {error, term()}.
destroy(Object) ->
    Server = server_for(Object),
    gen_server:call(Server, {destroy, self(), Object}, infinity).

-spec message_dialog(object_key(), unicode:chardata(), options()) ->
    atom() | {error, term()}.
message_dialog(Parent, Message, Options0) ->
    Server = server_for(Parent),
    Options = normalize_options(Options0),
    case gen_server:call(Server, {prepare_dialog, self(), Parent, Message, Options}, infinity) of
        {ok, DialogRef, Command, Timeout} ->
            Result = safe_backend_call(Command, Timeout),
            maybe_dismiss_failed_dialog(DialogRef, Result),
            gen_server:cast(Server, {dialog_finished, DialogRef, Result}),
            normalize_dialog_result(Result);
        Error ->
            Error
    end.

-spec respond_dialog(dialog_ref() | pos_integer(), atom()) -> ok | {error, term()}.
respond_dialog(DialogRef, Response) ->
    Server = dialog_server(DialogRef),
    gen_server:call(Server, {respond_dialog, DialogRef, Response}, infinity).

-spec active_dialogs() -> [map()].
active_dialogs() ->
    gen_server:call(server(), active_dialogs).

-spec sync() -> ok | {error, term()}.
sync() ->
    sync(?DEFAULT_BACKEND_TIMEOUT).

-spec sync(timeout()) -> ok | {error, term()}.
sync(Timeout) ->
    safe_backend_call(sync, Timeout).

-spec inspect(object_key()) -> {ok, map()} | {error, term()}.
inspect(Object) ->
    Server = server_for(Object),
    gen_server:call(Server, {inspect, self(), Object}, infinity).

-spec snapshot(object_key()) -> {ok, map() | binary()} | {error, term()}.
snapshot(Object) ->
    snapshot(Object, []).

-spec snapshot(object_key(), options()) -> {ok, map() | binary()} | {error, term()}.
snapshot(Object, Options) ->
    Server = server_for(Object),
    gen_server:call(
        Server,
        {snapshot, self(), Object, normalize_options(Options)},
        infinity
    ).

%% Capture a currently open native dialog. For a human-in-the-loop scenario,
%% open message_dialog/3 from a helper process, wait for dialog_opened, obtain
%% its ref from active_dialogs/0, then call snapshot_dialog/1.
-spec snapshot_dialog(dialog_ref() | pos_integer()) ->
    {ok, map() | binary()} | {error, term()}.
snapshot_dialog(DialogRef) ->
    snapshot_dialog(DialogRef, []).

-spec snapshot_dialog(dialog_ref() | pos_integer(), options()) ->
    {ok, map() | binary()} | {error, term()}.
snapshot_dialog(DialogRef, Options) ->
    Server = dialog_server(DialogRef),
    gen_server:call(
        Server,
        {snapshot_dialog, DialogRef, normalize_options(Options)},
        infinity
    ).

-spec event_cursor() -> non_neg_integer().
event_cursor() ->
    gen_server:call(server(), event_cursor).

-spec events_since(non_neg_integer()) -> [event_map()].
events_since(Seq) when is_integer(Seq), Seq >= 0 ->
    gen_server:call(server(), {events_since, Seq}).

-spec clear_events() -> ok.
clear_events() ->
    gen_server:call(server(), clear_events).

-spec await_event(object_key(), atom(), timeout()) ->
    {ok, event_map()} | {error, timeout | term()}.
await_event(Object, EventType, Timeout) ->
    Cursor = event_cursor(),
    await_event(Object, EventType, Cursor, Timeout).

-spec await_event(object_key(), atom(), non_neg_integer(), timeout()) ->
    {ok, event_map()} | {error, timeout | term()}.
await_event(Object, EventType, AfterSeq, Timeout) ->
    Server = server_for(Object),
    gen_server:call(
        Server,
        {await_event, self(), Object, EventType, AfterSeq, Timeout},
        outer_timeout(Timeout)
    ).

-spec inject(object_key(), atom(), map() | term()) -> ok | {error, term()}.
inject(Object, EventType, Payload) ->
    Server = server_for(Object),
    gen_server:call(Server, {inject, self(), Object, EventType, Payload}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    try gtknode4:subscribe(self()) of
        ok ->
            {ok, #state{
                test_mode = maps:get(test_mode, Opts, false),
                backend_timeout = maps:get(backend_timeout, Opts, ?DEFAULT_BACKEND_TIMEOUT),
                dialog_timeout = maps:get(dialog_timeout, Opts, infinity),
                event_log_limit = maps:get(event_log_limit, Opts, ?DEFAULT_EVENT_LOG_LIMIT)
            }};
        SubscribeResult ->
            {stop, {gtknode4_subscribe_failed, SubscribeResult}}
    catch
        exit:ExitReason ->
            {stop, {gtknode4_not_available, ExitReason}};
        Class:ExceptionReason:Stacktrace ->
            {stop, {gtknode4_subscribe_failed, Class, ExceptionReason, Stacktrace}}
    end.

handle_call({create, Owner, Type, Name, ParentRef, Options}, _From, State0) ->
    case safe_create(Owner, Type, Name, ParentRef, Options, State0) of
        {ok, Ref, State} -> {reply, Ref, State};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call({config, Owner, Ref, Options}, _From, State0) ->
    case safe_config(Owner, Ref, Options, State0) of
        {ok, State} -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call({read, Owner, Ref, Key}, _From, State) ->
    case resolve_object(Owner, Ref, State) of
        {ok, Object} -> {reply, safe_read(Object, Key, State), State};
        Error -> {reply, Error, State}
    end;
handle_call({destroy, Owner, Ref}, _From, State0) ->
    case resolve_object_id(Owner, Ref, State0) of
        {ok, Id} ->
            case destroy_object(Id, State0) of
                {ok, State} -> {reply, ok, State};
                {error, Reason} -> {reply, {error, Reason}, State0}
            end;
        Error ->
            {reply, Error, State0}
    end;
handle_call({prepare_dialog, Owner, ParentRef, Message, Options}, _From, State0) ->
    case prepare_dialog(Owner, ParentRef, Message, Options, State0) of
        {ok, DialogRef, Command, Timeout, State} ->
            {reply, {ok, DialogRef, Command, Timeout}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call({respond_dialog, _DialogRef0, _Response}, _From, State = #state{test_mode = false}) ->
    {reply, {error, test_mode_disabled}, State};
handle_call({respond_dialog, DialogRef0, Response}, _From, State) ->
    case resolve_dialog_id(DialogRef0, State) of
        {ok, DialogId} ->
            {reply,
                safe_backend_call(
                    {dialog_response, DialogId, Response}, State#state.backend_timeout
                ),
                State};
        Error ->
            {reply, Error, State}
    end;
handle_call(active_dialogs, _From, State) ->
    Dialogs0 = [dialog_public(Dialog) || Dialog <- maps:values(State#state.dialogs)],
    Dialogs = lists:sort(
        fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end,
        Dialogs0
    ),
    {reply, Dialogs, State};
handle_call({inspect, Owner, Ref}, _From, State) ->
    case resolve_object(Owner, Ref, State) of
        {ok, Object} -> {reply, inspect_object(Object, State), State};
        Error -> {reply, Error, State}
    end;
handle_call({snapshot, Owner, Ref, Options}, _From, State) ->
    case resolve_object(Owner, Ref, State) of
        {ok, Object} -> {reply, snapshot_object(Object, Options, State), State};
        Error -> {reply, Error, State}
    end;
handle_call({snapshot_dialog, DialogRef0, Options}, _From, State) ->
    case resolve_dialog_id(DialogRef0, State) of
        {ok, DialogId} -> {reply, snapshot_dialog_native(DialogId, Options, State), State};
        Error -> {reply, Error, State}
    end;
handle_call(event_cursor, _From, State) ->
    {reply, State#state.event_seq, State};
handle_call({events_since, Seq}, _From, State) ->
    Events = [Event || Event <- queue:to_list(State#state.event_log), maps:get(seq, Event) > Seq],
    {reply, Events, State};
handle_call(clear_events, _From, State) ->
    {reply, ok, State#state{event_log = queue:new()}};
handle_call({await_event, Owner, Ref, EventType0, AfterSeq, Timeout}, From, State0) ->
    EventType = canonical_event(EventType0),
    case resolve_object_id(Owner, Ref, State0) of
        {ok, Id} ->
            case find_event(Id, EventType, AfterSeq, State0#state.event_log) of
                {ok, Event} ->
                    {reply, {ok, Event}, State0};
                error when Timeout =:= 0 ->
                    {reply, {error, timeout}, State0};
                error ->
                    WaitRef = make_ref(),
                    Timer = start_timer(Timeout, {event_wait_timeout, WaitRef}),
                    Waiter = #{
                        from => From,
                        owner => Owner,
                        id => Id,
                        event => EventType,
                        after_seq => AfterSeq,
                        timer => Timer
                    },
                    Waiters = maps:put(WaitRef, Waiter, State0#state.waiters),
                    Monitors = ensure_owner_monitor(Owner, State0#state.owner_monitors),
                    {noreply, State0#state{waiters = Waiters, owner_monitors = Monitors}}
            end;
        Error ->
            {reply, Error, State0}
    end;
handle_call({inject, _Owner, _Ref, _EventType, _Payload}, _From, State = #state{test_mode = false}) ->
    {reply, {error, test_mode_disabled}, State};
handle_call({inject, Owner, Ref, EventType, Payload}, _From, State) ->
    case resolve_object(Owner, Ref, State) of
        {ok, Object} ->
            Command =
                {inject, Object#object.native_id, canonical_event(EventType),
                    normalize_payload(Payload)},
            {reply, safe_backend_call(Command, State#state.backend_timeout), State};
        Error ->
            {reply, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({dialog_finished, DialogRef, _Result}, State0) ->
    case dialog_id(DialogRef) of
        {ok, DialogId} ->
            case maps:take(DialogId, State0#state.dialogs) of
                {Dialog, Dialogs} ->
                    State1 = State0#state{dialogs = Dialogs},
                    {noreply, maybe_remove_owner_monitor(maps:get(owner, Dialog), State1)};
                error ->
                    {noreply, State0}
            end;
        error ->
            {noreply, State0}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({gtknode4, event, TransportSeq, NativeKey, EventType0, Payload0}, State0) ->
    case resolve_native_event_object(NativeKey, State0) of
        {ok, Object} ->
            EventType = canonical_event(EventType0),
            Payload = normalize_payload(Payload0),
            {Event, State1} = record_event(TransportSeq, Object, EventType, Payload, State0),
            State2 = satisfy_waiters(Event, State1),
            State3 =
                case EventType of
                    destroy -> forget_subtree(Object#object.id, State2);
                    _ -> State2
                end,
            {noreply, State3};
        error ->
            %% A late signal from a just-destroyed native object is harmless.
            {noreply, State0}
    end;
handle_info({gtknode4, status, disconnected, Reason}, State0) ->
    State1 = fail_all_waiters({transport_disconnected, Reason}, State0),
    {noreply, State1};
handle_info({gtknode4, status, ready, _Info}, State) ->
    {noreply, State};
handle_info({event_wait_timeout, WaitRef}, State0) ->
    case maps:take(WaitRef, State0#state.waiters) of
        {Waiter, Waiters1} ->
            gen_server:reply(maps:get(from, Waiter), {error, timeout}),
            State1 = State0#state{waiters = Waiters1},
            {noreply, maybe_remove_owner_monitor(maps:get(owner, Waiter), State1)};
        error ->
            {noreply, State0}
    end;
handle_info({'DOWN', _MonitorRef, process, Owner, _Reason}, State0) ->
    State1 = remove_owner_waiters(Owner, State0),
    State2 = destroy_owner_objects(Owner, State1),
    State3 = cancel_owner_dialogs(Owner, State2),
    {noreply, State3#state{owner_monitors = maps:remove(Owner, State3#state.owner_monitors)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State0) ->
    best_effort(fun() -> gtknode4:unsubscribe(self()) end),
    RootIds = root_object_ids(State0#state.objects),
    lists:foreach(
        fun(Id) ->
            case maps:get(Id, State0#state.objects, undefined) of
                #object{native_id = NativeId} -> gtknode4:cast({destroy, NativeId});
                undefined -> ok
            end
        end,
        RootIds
    ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Tree creation
%%%===================================================================

create_tree_nodes(_Parent, [], Acc) ->
    {ok, lists:reverse(Acc)};
create_tree_nodes(Parent, [Node | Rest], Acc) ->
    try create_tree_node(Parent, Node) of
        Ref -> create_tree_nodes(Parent, Rest, [Ref | Acc])
    catch
        error:TreeError:_Stacktrace
            when is_tuple(TreeError), tuple_size(TreeError) =:= 4,
                 element(1, TreeError) =:= tree_node_failed
        ->
            lists:foreach(fun best_effort_destroy/1, Acc),
            {error, TreeError};
        Class:Reason:_Stacktrace ->
            lists:foreach(fun best_effort_destroy/1, Acc),
            %% Tree construction is already transactional. Do not turn a
            %% backend capability error into several nested stack traces as it
            %% unwinds through every parent. Preserve the logical node instead.
            {error, {tree_node_failed, tree_node_identity(Node), Class, Reason}}
    end.

tree_node_identity({Type, Name, _Options, _Children}) when is_atom(Type), is_atom(Name) ->
    {Type, Name};
tree_node_identity({Type, Name, _Options}) when is_atom(Type), is_atom(Name) ->
    {Type, Name};
tree_node_identity({Type, _Options, _Children}) when is_atom(Type) ->
    {Type, undefined};
tree_node_identity({Type, _Options}) when is_atom(Type) ->
    {Type, undefined};
tree_node_identity(Other) ->
    {invalid_tree_node, Other}.

create_tree_node(Parent, {Type, Name, Options, Children}) when
    is_atom(Type), is_atom(Name), is_list(Children)
->
    Ref = expect_ref(create(Type, Name, Parent, Options)),
    create_children_or_rollback(Ref, Children),
    Ref;
create_tree_node(Parent, {Type, Name, Options}) when is_atom(Type), is_atom(Name) ->
    expect_ref(create(Type, Name, Parent, Options));
create_tree_node(Parent, {Type, Options, Children}) when is_atom(Type), is_list(Children) ->
    Ref = expect_ref(create(Type, Parent, Options)),
    create_children_or_rollback(Ref, Children),
    Ref;
create_tree_node(Parent, {Type, Options}) when is_atom(Type) ->
    expect_ref(create(Type, Parent, Options));
create_tree_node(_Parent, BadNode) ->
    error({bad_tree_node, BadNode}).

create_children_or_rollback(Parent, Children) ->
    case create_tree_nodes(Parent, Children, []) of
        {ok, _Refs} ->
            ok;
        {error, Reason} ->
            best_effort_destroy(Parent),
            error(Reason)
    end.

expect_ref({gtkgs_ref, _, _} = Ref) -> Ref;
expect_ref({error, Reason}) -> error(Reason).

%%%===================================================================
%%% Creation, configuration and reading
%%%===================================================================

safe_create(Owner, Type, Name, ParentRef, Options, State0) ->
    try do_create(Owner, Type, Name, ParentRef, Options, State0) of
        Result -> Result
    catch
        error:{unsupported_backend_widget, _, _, _} = CapabilityError ->
            {error, CapabilityError};
        Class:Reason:Stacktrace ->
            {error, {create_failed, Type, Class, Reason, Stacktrace}}
    end.

do_create(Owner, Type, Name, ParentRef, Options, State0) ->
    ok = validate_type(Type),
    ok = validate_name(Owner, Name, State0),
    {ParentId, ParentNativeId} = resolve_parent(Owner, Type, ParentRef, State0),
    Id = State0#state.next_id,
    NativeId = State0#state.next_native_id,
    NativeType = native_type(Type),
    ok = require_backend_widget(Type, NativeType),
    NativeOptions = native_options(Type, Name, Id, Options),
    Command = {create, NativeId, NativeType, ParentNativeId, NativeOptions},
    case mutation_result(safe_backend_call(Command, State0#state.backend_timeout)) of
        ok ->
            Object = #object{
                id = Id,
                native_id = NativeId,
                name = Name,
                owner = Owner,
                type = Type,
                parent = ParentId,
                data = proplists:get_value(data, Options, []),
                options = stored_options_with_automation(Name, Id, Options)
            },
            Objects0 = maps:put(Id, Object, State0#state.objects),
            Objects = add_child_to_parent(ParentId, Id, Objects0),
            Names = add_name(Owner, Name, Id, State0#state.names),
            NativeToId = maps:put(NativeId, Id, State0#state.native_to_id),
            Monitors = ensure_owner_monitor(Owner, State0#state.owner_monitors),
            State = State0#state{
                next_id = Id + 1,
                next_native_id = NativeId + 1,
                objects = Objects,
                names = Names,
                native_to_id = NativeToId,
                owner_monitors = Monitors
            },
            {ok, make_ref_handle(Id), State};
        {error, Reason} ->
            {error, Reason}
    end.

safe_config(Owner, Ref, Options, State0) ->
    case resolve_object_id(Owner, Ref, State0) of
        {ok, Id} ->
            try
                Object0 = maps:get(Id, State0#state.objects),
                NativePatch = native_patch(Options),
                MutationResult =
                    case map_size(NativePatch) of
                        0 ->
                            ok;
                        _ ->
                            mutation_result(
                                safe_backend_call(
                                    {config, Object0#object.native_id, NativePatch},
                                    State0#state.backend_timeout
                                )
                            )
                    end,
                case MutationResult of
                    ok ->
                        Object = apply_stored_options(Options, Object0),
                        Objects = maps:put(Id, Object, State0#state.objects),
                        {ok, State0#state{objects = Objects}};
                    {error, BackendReason} ->
                        {error, BackendReason}
                end
            catch
                Class:ExceptionReason:Stacktrace ->
                    {error, {config_failed, Class, ExceptionReason, Stacktrace}}
            end;
        {error, ResolveReason} ->
            {error, ResolveReason}
    end.

safe_read(Object, Key, State) ->
    try read_value(Object, Key, State) of
        Value -> Value
    catch
        Class:Reason:Stacktrace ->
            {error, {read_failed, Class, Reason, Stacktrace}}
    end.

read_value(Object, id, _State) ->
    make_ref_handle(Object#object.id);
read_value(Object, native_id, _State) ->
    Object#object.native_id;
read_value(Object, native, _State) ->
    Object#object.native_id;
read_value(Object, name, _State) ->
    Object#object.name;
read_value(Object, type, _State) ->
    Object#object.type;
read_value(Object, owner, _State) ->
    Object#object.owner;
read_value(Object, data, _State) ->
    Object#object.data;
read_value(Object, options, _State) ->
    Object#object.options;
read_value(#object{parent = root}, parent, _State) ->
    self();
read_value(#object{parent = ParentId}, parent, _State) ->
    make_ref_handle(ParentId);
read_value(Object, children, _State) ->
    [make_ref_handle(Id) || Id <- Object#object.children];
read_value(Object, Key, State) ->
    case
        safe_backend_call(
            {read, Object#object.native_id, normalize_read_key(Key)}, State#state.backend_timeout
        )
    of
        {ok, Value} -> Value;
        Error -> Error
    end.

inspect_object(Object, State) ->
    Logical = object_public(Object),
    case safe_backend_call({inspect, Object#object.native_id}, State#state.backend_timeout) of
        {ok, Native} -> {ok, #{logical => Logical, native => Native}};
        {error, {unsupported_command, _}} -> {ok, #{logical => Logical, native => unsupported}};
        Error -> Error
    end.

snapshot_object(Object, Options, State) ->
    OptMap0 = native_patch(Options),
    DoSync = maps:get(sync, OptMap0, true),
    OptMap = maps:remove(sync, OptMap0),
    case maybe_sync(DoSync, State#state.backend_timeout) of
        ok -> safe_backend_call({snapshot, Object#object.native_id, OptMap}, infinity);
        Error -> Error
    end.

snapshot_dialog_native(DialogId, Options, State) ->
    OptMap0 = native_patch(Options),
    DoSync = maps:get(sync, OptMap0, true),
    OptMap = maps:remove(sync, OptMap0),
    case maybe_sync(DoSync, State#state.backend_timeout) of
        ok -> safe_backend_call({snapshot_dialog, DialogId, OptMap}, infinity);
        Error -> Error
    end.

maybe_sync(true, Timeout) -> safe_backend_call(sync, Timeout);
maybe_sync(false, _Timeout) -> ok.

%%%===================================================================
%%% Dialogs
%%%===================================================================

prepare_dialog(Owner, ParentRef, Message, Options, State0) ->
    try
        {ok, Parent} = resolve_object(Owner, ParentRef, State0),
        DialogId = State0#state.next_dialog_id,
        DialogRef = make_dialog_ref(DialogId),
        DialogOptions = dialog_options(Options, State0#state.test_mode),
        Timeout = proplists:get_value(timeout, Options, State0#state.dialog_timeout),
        Dialog = #{
            id => DialogId,
            ref => DialogRef,
            owner => Owner,
            parent_id => Parent#object.id,
            parent_native_id => Parent#object.native_id,
            caption => maps:get(caption, DialogOptions),
            buttons => maps:get(buttons, DialogOptions),
            default_response => maps:get(default_response, DialogOptions),
            cancel_response => maps:get(cancel_response, DialogOptions)
        },
        Command = {
            message_dialog,
            DialogId,
            Parent#object.native_id,
            to_binary(Message),
            DialogOptions
        },
        Dialogs = maps:put(DialogId, Dialog, State0#state.dialogs),
        Monitors = ensure_owner_monitor(Owner, State0#state.owner_monitors),
        State = State0#state{
            next_dialog_id = DialogId + 1,
            dialogs = Dialogs,
            owner_monitors = Monitors
        },
        {ok, DialogRef, Command, Timeout, State}
    catch
        error:{badmatch, {error, ResolveReason}} ->
            {error, ResolveReason};
        Class:ExceptionReason:Stacktrace ->
            {error, {message_dialog_failed, Class, ExceptionReason, Stacktrace}}
    end.

dialog_options(Options, TestMode) ->
    Style = proplists:get_value(style, Options, [ok, information]),
    StyleList = style_list(Style),
    ExplicitButtons = proplists:get_value(buttons, Options, undefined),
    Buttons =
        case ExplicitButtons of
            undefined -> style_buttons(StyleList);
            Value -> Value
        end,
    Kind = style_kind(StyleList),
    Base0 = #{
        caption => to_binary(proplists:get_value(caption, Options, "gtkgs")),
        kind => Kind,
        buttons => Buttons,
        modal => proplists:get_value(modal, Options, true),
        default_response => proplists:get_value(
            default_response,
            Options,
            style_default_response(StyleList, Buttons)
        ),
        cancel_response => proplists:get_value(cancel_response, Options, cancel_response(Buttons))
    },
    Base1 = maybe_put(detail, proplists:get_value(detail, Options, undefined), Base0),
    case proplists:get_value(auto_response, Options, undefined) of
        undefined -> Base1;
        Response when TestMode =:= true -> maps:put(auto_response, Response, Base1);
        _Response -> error(auto_response_requires_test_mode)
    end.

style_list(Style) when is_atom(Style) -> [Style];
style_list(Styles) when is_list(Styles) -> Styles;
style_list(Other) -> error({bad_dialog_style, Other}).

style_buttons(Styles) ->
    case lists:member(yes_no, Styles) of
        true ->
            [no, yes];
        false ->
            Buttons0 = [],
            Buttons1 =
                case lists:member(cancel, Styles) of
                    true -> Buttons0 ++ [cancel];
                    false -> Buttons0
                end,
            Buttons2 =
                case lists:member(help, Styles) of
                    true -> Buttons1 ++ [help];
                    false -> Buttons1
                end,
            Buttons3 =
                case lists:member(ok, Styles) of
                    true -> Buttons2 ++ [ok];
                    false -> Buttons2
                end,
            case Buttons3 of
                [] -> [ok];
                _ -> Buttons3
            end
    end.

style_kind(Styles) ->
    case lists:member(error, Styles) of
        true ->
            error;
        false ->
            case lists:member(warning, Styles) of
                true ->
                    warning;
                false ->
                    case lists:member(question, Styles) of
                        true -> question;
                        false -> information
                    end
            end
    end.

style_default_response(Styles, Buttons) ->
    Defaults = [
        {yes_default, yes},
        {no_default, no},
        {cancel_default, cancel},
        {ok_default, ok}
    ],
    case [Response || {Style, Response} <- Defaults, lists:member(Style, Styles)] of
        [Response | _] -> Response;
        [] -> hd_or_ok(Buttons)
    end.

cancel_response(Buttons) ->
    case lists:member(cancel, Buttons) of
        true ->
            cancel;
        false ->
            case lists:member(no, Buttons) of
                true -> no;
                false -> undefined
            end
    end.

hd_or_ok([First | _]) -> First;
hd_or_ok([]) -> ok.

maybe_dismiss_failed_dialog(_DialogRef, {ok, _Response}) ->
    ok;
maybe_dismiss_failed_dialog(_DialogRef, Response) when is_atom(Response) ->
    ok;
maybe_dismiss_failed_dialog(DialogRef, _Error) ->
    case dialog_id(DialogRef) of
        {ok, DialogId} -> gtknode4:cast({dismiss_dialog, DialogId});
        error -> ok
    end.

normalize_dialog_result({ok, Response}) when is_atom(Response) -> Response;
normalize_dialog_result(Response) when is_atom(Response) -> Response;
normalize_dialog_result(Error) -> Error.

resolve_dialog_id(DialogRef, State) ->
    case dialog_id(DialogRef) of
        {ok, DialogId} ->
            case maps:is_key(DialogId, State#state.dialogs) of
                true -> {ok, DialogId};
                false -> {error, {dialog_not_found, DialogId}}
            end;
        error ->
            {error, {bad_dialog_reference, DialogRef}}
    end.

dialog_id({gtkgs_dialog, Server, DialogId}) when Server =:= self(), is_integer(DialogId) ->
    {ok, DialogId};
dialog_id(DialogId) when is_integer(DialogId), DialogId > 0 ->
    {ok, DialogId};
dialog_id(_) ->
    error.

dialog_public(Dialog) ->
    maps:without([owner, parent_native_id], Dialog).

%%%===================================================================
%%% Event recording and BDD waiters
%%%===================================================================

record_event(TransportSeq, Object, EventType, Payload, State0) ->
    Seq = State0#state.event_seq + 1,
    Args = event_args(EventType, Payload),
    IdOrName = id_or_name(Object),
    Event = #{
        seq => Seq,
        transport_seq => TransportSeq,
        object => make_ref_handle(Object#object.id),
        id => Object#object.id,
        native_id => Object#object.native_id,
        name => Object#object.name,
        event => EventType,
        data => Object#object.data,
        args => Args,
        payload => Payload
    },
    Object#object.owner ! {gtkgs, IdOrName, EventType, Object#object.data, Args},
    Log = bounded_queue_in(Event, State0#state.event_log, State0#state.event_log_limit),
    {Event, State0#state{event_seq = Seq, event_log = Log}}.

find_event(Id, EventType, AfterSeq, Queue) ->
    case
        lists:dropwhile(
            fun(Event) -> not event_matches(Event, Id, EventType, AfterSeq) end,
            queue:to_list(Queue)
        )
    of
        [Event | _] -> {ok, Event};
        [] -> error
    end.

event_matches(Event, Id, EventType, AfterSeq) ->
    maps:get(id, Event) =:= Id andalso
        maps:get(event, Event) =:= EventType andalso
        maps:get(seq, Event) > AfterSeq.

satisfy_waiters(Event, State0) ->
    {Waiters1, Owners0} = maps:fold(
        fun(WaitRef, Waiter, {Acc, Owners}) ->
            case
                event_matches(
                    Event,
                    maps:get(id, Waiter),
                    maps:get(event, Waiter),
                    maps:get(after_seq, Waiter)
                )
            of
                true ->
                    cancel_timer(maps:get(timer, Waiter, undefined)),
                    gen_server:reply(maps:get(from, Waiter), {ok, Event}),
                    {maps:remove(WaitRef, Acc), [maps:get(owner, Waiter) | Owners]};
                false ->
                    {Acc, Owners}
            end
        end,
        {State0#state.waiters, []},
        State0#state.waiters
    ),
    State1 = State0#state{waiters = Waiters1},
    lists:foldl(fun maybe_remove_owner_monitor/2, State1, lists:usort(Owners0)).

fail_all_waiters(Reason, State0) ->
    maps:foreach(
        fun(_WaitRef, Waiter) ->
            cancel_timer(maps:get(timer, Waiter, undefined)),
            gen_server:reply(maps:get(from, Waiter), {error, Reason})
        end,
        State0#state.waiters
    ),
    State0#state{waiters = #{}}.

remove_owner_waiters(Owner, State0) ->
    Waiters = maps:filter(
        fun(_WaitRef, Waiter) ->
            case maps:get(owner, Waiter) =:= Owner of
                true ->
                    cancel_timer(maps:get(timer, Waiter, undefined)),
                    false;
                false ->
                    true
            end
        end,
        State0#state.waiters
    ),
    State0#state{waiters = Waiters}.

cancel_object_waiters(Id, State0) ->
    {Waiters, Owners0} = maps:fold(
        fun(WaitRef, Waiter, {Acc, Owners}) ->
            case maps:get(id, Waiter) =:= Id of
                true ->
                    cancel_timer(maps:get(timer, Waiter, undefined)),
                    gen_server:reply(maps:get(from, Waiter), {error, object_destroyed}),
                    {maps:remove(WaitRef, Acc), [maps:get(owner, Waiter) | Owners]};
                false ->
                    {Acc, Owners}
            end
        end,
        {State0#state.waiters, []},
        State0#state.waiters
    ),
    State1 = State0#state{waiters = Waiters},
    lists:foldl(fun maybe_remove_owner_monitor/2, State1, lists:usort(Owners0)).

bounded_queue_in(_Event, _Queue0, Limit) when Limit =< 0 ->
    queue:new();
bounded_queue_in(Event, Queue0, Limit) ->
    Queue1 = queue:in(Event, Queue0),
    case queue:len(Queue1) > Limit of
        true -> element(2, queue:out(Queue1));
        false -> Queue1
    end.

%%%===================================================================
%%% Destruction and ownership
%%%===================================================================

destroy_object(Id, State0) ->
    Object = maps:get(Id, State0#state.objects),
    case
        mutation_result(
            safe_backend_call(
                {destroy, Object#object.native_id},
                State0#state.backend_timeout
            )
        )
    of
        ok -> {ok, forget_subtree(Id, State0)};
        {error, Reason} -> {error, Reason}
    end.

forget_subtree(Id, State0) ->
    case maps:get(Id, State0#state.objects, undefined) of
        undefined ->
            State0;
        Object ->
            State1 = lists:foldl(fun forget_subtree/2, State0, Object#object.children),
            State2 = cancel_object_waiters(Id, State1),
            Objects1 = remove_child_from_parent(Object#object.parent, Id, State2#state.objects),
            Objects = maps:remove(Id, Objects1),
            Names = remove_name(Object, State2#state.names),
            NativeToId = maps:remove(Object#object.native_id, State2#state.native_to_id),
            State3 = State2#state{objects = Objects, names = Names, native_to_id = NativeToId},
            maybe_remove_owner_monitor(Object#object.owner, State3)
    end.

destroy_owner_objects(Owner, State0) ->
    RootIds = owned_root_ids(Owner, State0#state.objects),
    lists:foldl(
        fun(Id, StateAcc) ->
            case maps:get(Id, StateAcc#state.objects, undefined) of
                undefined ->
                    StateAcc;
                Object ->
                    gtknode4:cast({destroy, Object#object.native_id}),
                    forget_subtree(Id, StateAcc)
            end
        end,
        State0,
        RootIds
    ).

cancel_owner_dialogs(Owner, State0) ->
    {Owned, Remaining} = maps:fold(
        fun(DialogId, Dialog, {OwnedAcc, RemainingAcc}) ->
            case maps:get(owner, Dialog) =:= Owner of
                true -> {[{DialogId, Dialog} | OwnedAcc], RemainingAcc};
                false -> {OwnedAcc, maps:put(DialogId, Dialog, RemainingAcc)}
            end
        end,
        {[], #{}},
        State0#state.dialogs
    ),
    lists:foreach(
        fun({DialogId, _Dialog}) ->
            gtknode4:cast({dismiss_dialog, DialogId})
        end,
        Owned
    ),
    State0#state{dialogs = Remaining}.

owned_root_ids(Owner, Objects) ->
    [
        Id
     || {Id, Object} <- maps:to_list(Objects),
        Object#object.owner =:= Owner,
        is_owned_root(Object, Owner, Objects)
    ].

is_owned_root(#object{parent = root}, _Owner, _Objects) ->
    true;
is_owned_root(#object{parent = ParentId}, Owner, Objects) ->
    case maps:get(ParentId, Objects, undefined) of
        #object{owner = Owner} -> false;
        _ -> true
    end.

root_object_ids(Objects) ->
    [Id || {Id, #object{parent = root}} <- maps:to_list(Objects)].

maybe_remove_owner_monitor(
    Owner,
    State = #state{objects = Objects, dialogs = Dialogs, owner_monitors = Monitors}
) ->
    OwnsObject = lists:any(
        fun({_Id, Object}) -> Object#object.owner =:= Owner end,
        maps:to_list(Objects)
    ),
    OwnsDialog = lists:any(
        fun({_DialogId, Dialog}) -> maps:get(owner, Dialog) =:= Owner end,
        maps:to_list(Dialogs)
    ),
    OwnsWaiter = lists:any(
        fun({_WaitRef, Waiter}) -> maps:get(owner, Waiter) =:= Owner end,
        maps:to_list(State#state.waiters)
    ),
    StillOwns = OwnsObject orelse OwnsDialog orelse OwnsWaiter,
    case {StillOwns, maps:get(Owner, Monitors, undefined)} of
        {false, MonitorRef} when is_reference(MonitorRef) ->
            erlang:demonitor(MonitorRef, [flush]),
            State#state{owner_monitors = maps:remove(Owner, Monitors)};
        _ ->
            State
    end.

%%%===================================================================
%%% Object lookup and bookkeeping
%%%===================================================================

resolve_object(Owner, Ref, State) ->
    case resolve_object_id(Owner, Ref, State) of
        {ok, Id} ->
            case maps:get(Id, State#state.objects, undefined) of
                undefined -> {error, {object_not_found, Ref}};
                Object -> {ok, Object}
            end;
        Error ->
            Error
    end.

resolve_object_id(_Owner, {gtkgs_ref, Server, Id}, _State) when
    Server =:= self(), is_integer(Id)
->
    {ok, Id};
resolve_object_id(Owner, Name, #state{names = Names}) when is_atom(Name) ->
    case maps:get({Owner, Name}, Names, undefined) of
        undefined -> {error, {name_not_found, Name}};
        Id -> {ok, Id}
    end;
resolve_object_id(_Owner, Ref, _State) ->
    {error, {bad_object_reference, Ref}}.

resolve_parent(_Owner, window, ParentRef, _State) when is_pid(ParentRef), ParentRef =:= self() ->
    {root, root};
resolve_parent(_Owner, window, root, _State) ->
    {root, root};
resolve_parent(_Owner, window, gtkgs, _State) ->
    {root, root};
resolve_parent(Owner, window, ParentRef, _State) ->
    error({bad_window_parent, Owner, ParentRef});
resolve_parent(Owner, _Type, ParentRef, State) ->
    case resolve_object(Owner, ParentRef, State) of
        {ok, #object{id = Id, native_id = NativeId, type = ParentType}} ->
            case is_container(ParentType) of
                true -> {Id, NativeId};
                false -> error({not_a_container, ParentType})
            end;
        {error, Reason} ->
            error(Reason)
    end.

resolve_native_event_object(NativeKey, State) ->
    case maps:get(NativeKey, State#state.native_to_id, undefined) of
        undefined when is_binary(NativeKey); is_atom(NativeKey); is_list(NativeKey) ->
            AutomationId = to_binary(NativeKey),
            find_by_automation_id(AutomationId, State#state.objects);
        undefined ->
            error;
        Id ->
            case maps:get(Id, State#state.objects, undefined) of
                undefined -> error;
                Object -> {ok, Object}
            end
    end.

find_by_automation_id(AutomationId, Objects) ->
    case
        [
            Object
         || {_Id, Object} <- maps:to_list(Objects),
            maps:get(automation_id, Object#object.options, undefined) =:= AutomationId
        ]
    of
        [Object] -> {ok, Object};
        _ -> error
    end.

validate_type(Type) when
    Type =:= window;
    Type =:= frame;
    Type =:= button;
    Type =:= label;
    Type =:= entry;
    Type =:= editor;
    Type =:= listbox;
    Type =:= scale;
    Type =:= picture;
    Type =:= scrolled
->
    ok;
validate_type(Type) ->
    error({unsupported_object_type, Type}).

validate_name(_Owner, undefined, _State) ->
    ok;
validate_name(Owner, Name, #state{names = Names}) when is_atom(Name) ->
    case maps:is_key({Owner, Name}, Names) of
        true -> error({name_already_exists, Name});
        false -> ok
    end.

is_container(window) -> true;
is_container(frame) -> true;
is_container(scrolled) -> true;
is_container(_) -> false.

native_type(window) -> window;
native_type(frame) -> box;
native_type(button) -> button;
native_type(label) -> label;
native_type(entry) -> entry;
native_type(editor) -> text_view;
native_type(listbox) -> list_view;
native_type(scale) -> scale;
native_type(picture) -> picture;
native_type(scrolled) -> scrolled_box.


%% Refuse unsupported native widgets before allocating logical state. This is
%% intentionally negotiated from gtknode4's hello capabilities instead of
%% assuming that gtkgs.erl and the native executable were rebuilt together.
require_backend_widget(LogicalType, NativeType) ->
    try gtknode4:status() of
        #{ready := true, capabilities := Caps} ->
            Widgets = maps:get(widgets, Caps, []),
            case Widgets of
                [] ->
                    %% Older/fake transports may not advertise widgets.
                    ok;
                _ ->
                    case lists:member(NativeType, Widgets) of
                        true -> ok;
                        false ->
                            error({unsupported_backend_widget,
                                   LogicalType, NativeType, Widgets})
                    end
            end;
        _ ->
            %% Readiness/transport failures are handled by safe_backend_call/2.
            ok
    catch
        error:{unsupported_backend_widget, _, _, _} = Reason ->
            error(Reason);
        _:_ ->
            %% Do not make status introspection itself a new failure mode.
            ok
    end.
add_child_to_parent(root, _ChildId, Objects) ->
    Objects;
add_child_to_parent(ParentId, ChildId, Objects0) ->
    Parent = maps:get(ParentId, Objects0),
    maps:put(ParentId, Parent#object{children = Parent#object.children ++ [ChildId]}, Objects0).

remove_child_from_parent(root, _ChildId, Objects) ->
    Objects;
remove_child_from_parent(ParentId, ChildId, Objects0) ->
    case maps:get(ParentId, Objects0, undefined) of
        undefined ->
            Objects0;
        Parent ->
            maps:put(
                ParentId,
                Parent#object{children = lists:delete(ChildId, Parent#object.children)},
                Objects0
            )
    end.

add_name(_Owner, undefined, _Id, Names) -> Names;
add_name(Owner, Name, Id, Names) -> maps:put({Owner, Name}, Id, Names).

remove_name(#object{name = undefined}, Names) -> Names;
remove_name(#object{owner = Owner, name = Name}, Names) -> maps:remove({Owner, Name}, Names).

ensure_owner_monitor(Owner, Monitors) ->
    case maps:get(Owner, Monitors, undefined) of
        undefined -> maps:put(Owner, erlang:monitor(process, Owner), Monitors);
        _ -> Monitors
    end.

make_ref_handle(Id) -> {gtkgs_ref, self(), Id}.
make_dialog_ref(Id) -> {gtkgs_dialog, self(), Id}.

id_or_name(#object{name = undefined, id = Id}) -> make_ref_handle(Id);
id_or_name(#object{name = Name}) -> Name.

object_public(Object) ->
    #{
        ref => make_ref_handle(Object#object.id),
        id => Object#object.id,
        native_id => Object#object.native_id,
        name => Object#object.name,
        owner => Object#object.owner,
        type => Object#object.type,
        parent => Object#object.parent,
        children => [make_ref_handle(Id) || Id <- Object#object.children],
        data => Object#object.data,
        options => Object#object.options
    }.

%%%===================================================================
%%% Option and protocol normalization
%%%===================================================================

native_options(Type, Name, Id, Options) ->
    AutomationId =
        case Name of
            undefined -> iolist_to_binary(["gtkgs-", integer_to_list(Id)]);
            _ -> atom_to_binary(Name, utf8)
        end,
    maps:merge(
        #{
            automation_id => AutomationId,
            logical_type => Type
        },
        native_patch(Options)
    ).

native_patch(Options) ->
    lists:foldl(fun native_option/2, #{}, normalize_options(Options)).

native_option({data, _Data}, Acc) -> Acc;
native_option({label, {text, Text}}, Acc) -> maps:put(label, to_binary(Text), Acc);
native_option({label, Text}, Acc) -> maps:put(label, to_binary(Text), Acc);
%% ERM_LENS_WIDGETS_V1: only local, normalized files cross into GTK.
native_option({file, Path}, Acc) ->
    Bin = to_binary(Path),
    case Bin =:= <<>> orelse filename:pathtype(Bin) =:= absolute of
        true -> maps:put(text, Bin, Acc);
        false -> error(picture_requires_absolute_local_path)
    end;
native_option({text, Text}, Acc) -> maps:put(text, to_binary(Text), Acc);
native_option({title, Text}, Acc) -> maps:put(title, to_binary(Text), Acc);
native_option({tooltip, Text}, Acc) -> maps:put(tooltip, to_binary(Text), Acc);
native_option({items, Items}, Acc) -> maps:put(items, [to_binary(Item) || Item <- Items], Acc);
native_option({add, Item}, Acc) -> maps:put(add, to_binary(Item), Acc);
native_option({enable, Bool}, Acc) when is_boolean(Bool) -> maps:put(enabled, Bool, Acc);
native_option({map, Bool}, Acc) when is_boolean(Bool) -> maps:put(shown, Bool, Acc);
native_option({show, Bool}, Acc) when is_boolean(Bool) -> maps:put(shown, Bool, Acc);
native_option({setfocus, Bool}, Acc) when is_boolean(Bool) -> maps:put(focus, Bool, Acc);
native_option({orient, Orientation}, Acc) -> maps:put(orientation, Orientation, Acc);
native_option({layout, Orientation}, Acc) -> maps:put(orientation, Orientation, Acc);
native_option({Key, Value}, Acc) when is_atom(Key) -> maps:put(Key, normalize_value(Value), Acc);
native_option(Key, Acc) when is_atom(Key) -> maps:put(Key, true, Acc);
native_option(_Other, Acc) -> Acc.

stored_options(Options) ->
    Automation = native_patch(Options),
    maps:remove(data, Automation).

apply_stored_options(Options, Object0) ->
    Data = proplists:get_value(data, Options, Object0#object.data),
    Patch = native_patch(Options),
    Object0#object{data = Data, options = maps:merge(Object0#object.options, Patch)}.

normalize_read_key(enable) -> enabled;
normalize_read_key(map) -> shown;
normalize_read_key(show) -> shown;
normalize_read_key(Key) -> Key.

stored_options_with_automation(Name, Id, Options) ->
    maps:put(
        automation_id,
        case Name of
            undefined -> iolist_to_binary(["gtkgs-", integer_to_list(Id)]);
            _ -> atom_to_binary(Name, utf8)
        end,
        stored_options(Options)
    ).

mutation_result(ok) -> ok;
mutation_result({ok, _Value}) -> ok;
mutation_result({error, _Reason} = Error) -> Error;
mutation_result(Other) -> {error, {bad_backend_reply, Other}}.

safe_backend_call(Command, Timeout) ->
    try gtknode4:call(Command, Timeout) of
        Result -> Result
    catch
        exit:{timeout, _} ->
            {error, timeout};
        exit:{noproc, _} ->
            {error, not_started};
        exit:ExitReason ->
            {error, {controller_exit, ExitReason}};
        Class:ExceptionReason:Stacktrace ->
            {error, {controller_failed, Class, ExceptionReason, Stacktrace}}
    end.

best_effort_destroy(Ref) ->
    best_effort(fun() -> destroy(Ref) end).

best_effort(Fun) when is_function(Fun, 0) ->
    try Fun() of
        _ -> ok
    catch
        _:_ -> ok
    end.

canonical_event(clicked) -> click;
canonical_event(button_clicked) -> click;
canonical_event(<<"clicked">>) -> click;
canonical_event("clicked") -> click;
canonical_event(activate) -> keypress;
canonical_event(<<"activate">>) -> keypress;
canonical_event("activate") -> keypress;
canonical_event(selection_changed) -> select;
canonical_event('selection-changed') -> select;
canonical_event(<<"selection-changed">>) -> select;
canonical_event("selection-changed") -> select;
canonical_event(value_changed) -> change;
canonical_event('value-changed') -> change;
canonical_event(<<"value-changed">>) -> change;
canonical_event("value-changed") -> change;
canonical_event(changed) -> change;
canonical_event(<<"changed">>) -> change;
canonical_event("changed") -> change;
canonical_event(close_request) -> destroy;
canonical_event(<<"close-request">>) -> destroy;
canonical_event("close-request") -> destroy;
canonical_event(Event) when is_atom(Event) -> Event;
canonical_event(_Other) -> raw_event.

event_args(_EventType, #{args := Args}) when is_list(Args) -> Args;
event_args(click, #{index := _Index} = Payload) ->
    selection_args(Payload);
event_args(click, _Payload) ->
    [];
event_args(doubleclick, Payload) ->
    selection_args(Payload);
event_args(select, Payload) ->
    selection_args(Payload);
event_args(keypress, Payload) ->
    [key_value(Payload), maps:get(text, Payload, <<>>)];
event_args(configure, Payload) ->
    [maps:get(width, Payload, 0), maps:get(height, Payload, 0)];
event_args(destroy, _Payload) ->
    [];
event_args(dialog_opened, Payload) ->
    [maps:get(dialog_id, Payload, undefined)];
event_args(dialog_closed, Payload) ->
    [
        maps:get(dialog_id, Payload, undefined),
        maps:get(response, Payload, undefined)
    ];
event_args(_EventType, Payload) ->
    [Payload].

selection_args(Payload) ->
    [
        maps:get(index, Payload, -1),
        maps:get(text, Payload, <<>>),
        maps:get(selected, Payload, true)
    ].

key_value(#{key := return}) -> 'Return';
key_value(#{key := <<"Return">>}) -> 'Return';
key_value(#{key := Key}) -> Key;
key_value(_Payload) -> undefined.

normalize_payload(Map) when is_map(Map) -> Map;
normalize_payload(undefined) -> #{};
normalize_payload(Value) -> #{value => Value}.

normalize_options(Options) when is_map(Options) -> maps:to_list(Options);
normalize_options(Options) when is_list(Options) -> Options;
normalize_options(Option) when is_tuple(Option); is_atom(Option) -> [Option];
normalize_options(undefined) -> [].

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List).

normalize_value({text, Text}) ->
    to_binary(Text);
normalize_value(Value) when is_binary(Value); is_integer(Value); is_float(Value); is_atom(Value) ->
    Value;
normalize_value(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true -> to_binary(Value);
        false -> [normalize_value(Item) || Item <- Value]
    end;
normalize_value(Value) when is_tuple(Value) -> Value;
normalize_value(Value) when is_map(Value) -> Value;
normalize_value(Value) ->
    Value.

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> maps:put(Key, normalize_value(Value), Map).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).

server_for({gtkgs_ref, Server, _Id}) when is_pid(Server) -> Server;
server_for(Server) when is_pid(Server) -> Server;
server_for(_NameOrRoot) -> server().

dialog_server({gtkgs_dialog, Server, _Id}) when is_pid(Server) -> Server;
dialog_server(_DialogId) -> server().

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
