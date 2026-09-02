%%-------------------------------------------------------------------
%% @doc Fault-containment boundary for Core Lightning.
%%
%% The rest of DamageBDD should call this module rather than cln directly.
%% Successful calls preserve cln's return value. Backend failures are
%% converted to {error, {cln_unavailable, ...}} instead of propagating exits.
%%
%% This process also owns the isolated CLN backend supervisor. Its init/1
%% always succeeds; CLN is bootstrapped asynchronously so a broken or absent
%% CLN installation cannot prevent the damage application from starting.
%%-------------------------------------------------------------------
-module(damage_cln).
-behaviour(gen_server).

-export([
    start_link/0,
    status/0,
    restart_backend/0,
    enabled/0,
    available/0,
    core_configured/0,
    websocket_configured/0,
    missing_core_config/0,
    missing_websocket_config/0
]).

%% Application-facing CLN facade. Keep this API aligned with cln's public API
%% so callers can be migrated mechanically from cln:foo(...) to
%% damage_cln:foo(...).
-export([
    newaddr/0,
    newaddr/1,
    getinfo/0,
    create_invoice/2,
    create_invoice/3,
    create_invoice/4,
    hold_invoice/3,
    hold_invoice/4,
    hold_invoice_cancel/1,
    cancel_invoice/1,
    decode_invoice/1,
    decodepay/1,
    rpc/2,
    list_invoices/0,
    list_invoices/1,
    list_invoices_by_label/1,
    list_invoices_by_invoicestring/1,
    list_invoices_by_payment_hash/1,
    channel_id_to_scid/1,
    list_channels/0,
    list_all_channels/0,
    find_best_peer_to_open/0,
    find_best_peer_to_open/1,
    score_peers_for_opening/1,
    top_five_nodes/1,
    get_node_balance/0,
    open_channels_with_best_peers/0,
    open_channels_with_best_peers/1,
    inbound_capacity/2,
    verify_peer/1,
    clear_cache/0,
    estimate_routing_fee/2,
    register_listener/1,
    existing_peers/1,
    connect_peer/1,
    connect_peer/2,
    connect_peers/1,
    connect_best_peers/0,
    connect_best_peers/1,
    blacklist_peer/3,
    sats_to_msat/1,
    msat_to_sats/1,
    pay_invoice/1,
    pay_invoice/2,
    list_funds/0,
    list_pays/0,
    list_sendpays/0,
    open_channel/2,
    open_channel/3,
    list_all_invoices/0,
    list_all_invoices/1,
    sort_invoices_desc/1,
    sort_sendpays_desc/1,
    sort_pays_desc/1,
    sort_peerchannels_desc/1,
    sort_outputs_desc/1,
    multifund_channels_with_best_peers/0,
    multifund_channels_with_best_peers/1,
    sql/1,
    sql_rows/1,
    recent_invoices/1,
    recent_invoices/2,
    unpaid_invoices/1,
    unpaid_invoices/2,
    paid_invoices_since/2,
    invoice_counts_by_status/0,
    recent_account_events/2,
    recent_account_events/3,
    account_event_summary/1,
    account_event_summary/2,
    recent_peerchannels/1,
    peerchannel_summary/0,
    test/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_RETRY_MS, 30000).

-record(state, {
    backend_sup = undefined,
    retry_timer = undefined,
    last_error = undefined,
    restart_pending = false
}).

%% ===================================================================
%% Lifecycle / status
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    try gen_server:call(?MODULE, status, 5000) of
        Reply -> Reply
    catch
        exit:_ ->
            #{
                manager => down,
                enabled => enabled(),
                cln_pool => available(),
                core_configured => core_configured(),
                websocket_configured => websocket_configured()
            }
    end.

restart_backend() ->
    gen_server:call(?MODULE, restart_backend, 5000).

%% Explicit false always disables CLN. Explicit true asks the manager to keep
%% trying. With no setting, auto-enable only when at least one CLN component
%% has enough configuration to be useful.
enabled() ->
    case application:get_env(damage, cln_enabled) of
        {ok, false} -> false;
        {ok, true} -> true;
        _ ->
            %% Auto-enable only if there is a backend component that the
            %% isolated supervisor can actually start. This avoids an
            %% endless retry loop when env keys exist but no CLN pool is
            %% configured and websocket support is disabled.
            try damage_cln_sup:configured_components() =/= []
            catch
                _:_ -> false
            end
    end.

available() ->
    case whereis(cln) of
        Pid when is_pid(Pid) -> is_process_alive(Pid);
        _ -> false
    end.

core_configured() ->
    missing_core_config() =:= [].

websocket_configured() ->
    websocket_enabled() andalso missing_websocket_config() =:= [].

missing_core_config() ->
    missing_env([
        cln_host,
        cln_port,
        cln_wspath,
        cln_cacertfile,
        cln_certfile,
        cln_keyfile
    ]).

missing_websocket_config() ->
    missing_env([
        cln_host,
        cln_port,
        cln_wspath,
        cln_cacertfile,
        cln_certfile,
        cln_keyfile
    ]).

websocket_enabled() ->
    application:get_env(damage, cln_websocket_enabled, true) =/= false.

missing_env(Keys) ->
    [Key || Key <- Keys, application:get_env(damage, Key) =:= undefined].

retry_ms() ->
    application:get_env(damage, cln_restart_backoff_ms, ?DEFAULT_RETRY_MS).

init([]) ->
    %% The containment boundary must survive failures of processes linked
    %% underneath it.
    process_flag(trap_exit, true),
    self() ! bootstrap,
    {ok, #state{}}.

handle_call(status, _From, State = #state{backend_sup = Backend, last_error = LastError}) ->
    Children = backend_children(Backend),
    {reply,
        #{
            manager => up,
            enabled => enabled(),
            backend_supervisor => backend_state(Backend),
            cln_pool => available(),
            core_configured => core_configured(),
            websocket_configured => websocket_configured(),
            missing_core_config => missing_core_config(),
            missing_websocket_config => missing_websocket_config(),
            children => Children,
            last_error => LastError
        },
        State};
handle_call(restart_backend, _From, State0 = #state{backend_sup = Backend}) ->
    State1 = cancel_retry(State0),
    case Backend of
        Pid when is_pid(Pid) ->
            %% Do not clear backend_sup yet. Wait for the matching EXIT before
            %% bootstrapping a replacement, otherwise start_link/0 can race
            %% the still-registered supervisor and attach to a dying pid.
            exit(Pid, shutdown),
            {reply, ok, State1#state{restart_pending = true, last_error = undefined}};
        _ ->
            self() ! bootstrap,
            {reply, ok, State1#state{restart_pending = false, last_error = undefined}}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(bootstrap, State = #state{backend_sup = Backend}) when is_pid(Backend) ->
    {noreply, State};
handle_info(bootstrap, State0) ->
    State1 = cancel_retry(State0),
    case enabled() of
        false ->
            {noreply, State1#state{last_error = disabled}};
        true ->
            case safe_start_backend() of
                {ok, Pid} ->
                    logger:notice("CLN isolated backend started pid=~p", [Pid]),
                    {noreply, State1#state{backend_sup = Pid, last_error = undefined}};
                {error, Reason} ->
                    logger:warning(
                        "CLN backend unavailable; DamageBDD continues without CLN: ~p",
                        [Reason]
                    ),
                    {noreply, schedule_retry(State1#state{last_error = Reason})}
            end
    end;
handle_info(
    {'EXIT', Pid, Reason},
    State = #state{backend_sup = Pid, restart_pending = true}
) ->
    logger:notice("CLN backend stopped for requested restart: ~p", [Reason]),
    State1 = State#state{
        backend_sup = undefined,
        restart_pending = false,
        last_error = undefined
    },
    self() ! bootstrap,
    {noreply, State1};
handle_info({'EXIT', Pid, Reason}, State = #state{backend_sup = Pid}) ->
    logger:warning(
        "CLN backend supervisor exited; DamageBDD remains running: ~p",
        [Reason]
    ),
    State1 = State#state{
        backend_sup = undefined,
        restart_pending = false,
        last_error = Reason
    },
    case enabled() of
        true -> {noreply, schedule_retry(State1)};
        false -> {noreply, State1}
    end;
handle_info(retry_backend, State) ->
    self() ! bootstrap,
    {noreply, State#state{retry_timer = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = stop_backend(cancel_retry(State)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

safe_start_backend() ->
    try damage_cln_sup:start_link() of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} when is_pid(Pid) ->
            link(Pid),
            {ok, Pid};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_start_result, Other}}
    catch
        Class:Reason:Stack ->
            logger:warning(
                "CLN backend start raised ~p:~p stack=~p",
                [Class, Reason, Stack]
            ),
            {error, {Class, Reason}}
    end.

backend_children(Pid) when is_pid(Pid) ->
    try supervisor:which_children(Pid) of
        Children ->
            [
                #{id => Id, pid => ChildPid, type => Type, modules => Modules}
             || {Id, ChildPid, Type, Modules} <- Children
            ]
    catch
        _:_ -> []
    end;
backend_children(_) ->
    [].

backend_state(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> up;
        false -> down
    end;
backend_state(_) ->
    down.

schedule_retry(State = #state{retry_timer = undefined}) ->
    TRef = erlang:send_after(retry_ms(), self(), retry_backend),
    State#state{retry_timer = TRef};
schedule_retry(State) ->
    State.

cancel_retry(State = #state{retry_timer = undefined}) ->
    State;
cancel_retry(State = #state{retry_timer = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{retry_timer = undefined}.

stop_backend(State = #state{backend_sup = Pid}) when is_pid(Pid) ->
    exit(Pid, shutdown),
    State#state{backend_sup = undefined};
stop_backend(State) ->
    State.

%% ===================================================================
%% Safe facade
%% ===================================================================

call(Function, Args) ->
    Arity = length(Args),
    case code:ensure_loaded(cln) of
        {module, cln} ->
            case erlang:function_exported(cln, Function, Arity) of
                true ->
                    try apply(cln, Function, Args) of
                        Result -> Result
                    catch
                        exit:Reason ->
                            cln_failure(Function, Arity, exit, Reason);
                        error:Reason:Stack ->
                            cln_failure(Function, Arity, error, {Reason, Stack});
                        throw:Reason ->
                            cln_failure(Function, Arity, throw, Reason)
                    end;
                false ->
                    cln_failure(
                        Function,
                        Arity,
                        error,
                        {unsupported_cln_call, Function, Arity}
                    )
            end;
        Error ->
            cln_failure(Function, Arity, error, {cln_module_unavailable, Error})
    end.

cln_failure(Function, Arity, Class, Reason) ->
    logger:warning(
        "CLN call ~p/~p unavailable (~p): ~p",
        [Function, Arity, Class, Reason]
    ),
    {error, {cln_unavailable, Reason}}.

newaddr() -> call(newaddr, []).
newaddr(A) -> call(newaddr, [A]).
getinfo() -> call(getinfo, []).
create_invoice(A, B) -> call(create_invoice, [A, B]).
create_invoice(A, B, C) -> call(create_invoice, [A, B, C]).
create_invoice(A, B, C, D) -> call(create_invoice, [A, B, C, D]).
%% Backward-compatible three-argument hold invoices require an explicit
%% default CLTV because the current holdinvoice backend requires cltv.
hold_invoice(A, B, C) ->
    case application:get_env(damage, cln_hold_invoice_cltv) of
        {ok, Cltv} when is_integer(Cltv), Cltv > 0 ->
            %% The historical hold_invoice/3 caller expects {ok, Map}, while
            %% the current cln:hold_invoice/4 backend returns Map directly.
            case call(hold_invoice, [A, B, C, Cltv]) of
                Map when is_map(Map) ->
                    {ok, Map};
                {ok, Map} when is_map(Map) ->
                    {ok, Map};
                Error ->
                    Error
            end;
        {ok, Other} ->
            {error, {cln_unavailable, {invalid_config, cln_hold_invoice_cltv, Other}}};
        undefined ->
            {error, {cln_unavailable, {missing_config, cln_hold_invoice_cltv}}}
    end.
hold_invoice(A, B, C, D) -> call(hold_invoice, [A, B, C, D]).
hold_invoice_cancel(A) -> call(hold_invoice_cancel, [A]).

%% These compatibility wrappers fail closed when the current cln backend does
%% not provide the older API; importantly they never raise undef into callers.
cancel_invoice(A) -> call(cancel_invoice, [A]).
decode_invoice(A) -> call(decode_invoice, [A]).
decodepay(A) -> call(decodepay, [A]).
rpc(A, B) -> call(rpc, [A, B]).
list_invoices() -> call(list_invoices, []).
list_invoices(A) -> call(list_invoices, [A]).
list_invoices_by_label(A) -> call(list_invoices_by_label, [A]).
list_invoices_by_invoicestring(A) -> call(list_invoices_by_invoicestring, [A]).
list_invoices_by_payment_hash(A) -> call(list_invoices_by_payment_hash, [A]).
channel_id_to_scid(A) -> call(channel_id_to_scid, [A]).
list_channels() -> call(list_channels, []).
list_all_channels() -> call(list_all_channels, []).
find_best_peer_to_open() -> call(find_best_peer_to_open, []).
find_best_peer_to_open(A) -> call(find_best_peer_to_open, [A]).
score_peers_for_opening(A) -> call(score_peers_for_opening, [A]).
top_five_nodes(A) -> call(top_five_nodes, [A]).
get_node_balance() -> call(get_node_balance, []).
open_channels_with_best_peers() -> call(open_channels_with_best_peers, []).
open_channels_with_best_peers(A) -> call(open_channels_with_best_peers, [A]).
inbound_capacity(A, B) -> call(inbound_capacity, [A, B]).
verify_peer(A) -> call(verify_peer, [A]).
clear_cache() -> call(clear_cache, []).
estimate_routing_fee(A, B) -> call(estimate_routing_fee, [A, B]).
register_listener(A) -> call(register_listener, [A]).
existing_peers(A) -> call(existing_peers, [A]).
connect_peer(A) -> call(connect_peer, [A]).
connect_peer(A, B) -> call(connect_peer, [A, B]).
connect_peers(A) -> call(connect_peers, [A]).
connect_best_peers() -> call(connect_best_peers, []).
connect_best_peers(A) -> call(connect_best_peers, [A]).
blacklist_peer(A, B, C) -> call(blacklist_peer, [A, B, C]).
sats_to_msat(A) -> call(sats_to_msat, [A]).
msat_to_sats(A) -> call(msat_to_sats, [A]).
pay_invoice(A) -> call(pay_invoice, [A]).
pay_invoice(A, B) -> call(pay_invoice, [A, B]).
list_funds() -> call(list_funds, []).
list_pays() -> call(list_pays, []).
list_sendpays() -> call(list_sendpays, []).
open_channel(A, B) -> call(open_channel, [A, B]).
open_channel(A, B, C) -> call(open_channel, [A, B, C]).
list_all_invoices() -> call(list_all_invoices, []).
list_all_invoices(A) -> call(list_all_invoices, [A]).
sort_invoices_desc(A) -> call(sort_invoices_desc, [A]).
sort_sendpays_desc(A) -> call(sort_sendpays_desc, [A]).
sort_pays_desc(A) -> call(sort_pays_desc, [A]).
sort_peerchannels_desc(A) -> call(sort_peerchannels_desc, [A]).
sort_outputs_desc(A) -> call(sort_outputs_desc, [A]).
multifund_channels_with_best_peers() -> call(multifund_channels_with_best_peers, []).
multifund_channels_with_best_peers(A) -> call(multifund_channels_with_best_peers, [A]).
sql(A) -> call(sql, [A]).
sql_rows(A) -> call(sql_rows, [A]).
recent_invoices(A) -> call(recent_invoices, [A]).
recent_invoices(A, B) -> call(recent_invoices, [A, B]).
unpaid_invoices(A) -> call(unpaid_invoices, [A]).
unpaid_invoices(A, B) -> call(unpaid_invoices, [A, B]).
paid_invoices_since(A, B) -> call(paid_invoices_since, [A, B]).
invoice_counts_by_status() -> call(invoice_counts_by_status, []).
recent_account_events(A, B) -> call(recent_account_events, [A, B]).
recent_account_events(A, B, C) -> call(recent_account_events, [A, B, C]).
account_event_summary(A) -> call(account_event_summary, [A]).
account_event_summary(A, B) -> call(account_event_summary, [A, B]).
recent_peerchannels(A) -> call(recent_peerchannels, [A]).
peerchannel_summary() -> call(peerchannel_summary, []).
test() -> call(test, []).
