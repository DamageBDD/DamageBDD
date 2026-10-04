-module(ecai_health).

-export([
    check/0,
    diagnostics/0,
    patch_queue/0,
    probe_patch_queue/1,
    all_systems_go/0,
    monitor_status/0,
    latest_report/0,
    resolution/0,
    check_with_resolution/0,
    print/0
]).

-ifdef(TEST).
-export([
    classify_patch_queue/1,
    classify_overall/1,
    patch_queue_diagnostics/5
]).
-endif.

-define(REQUIRED_PROCESSES, [
    ecai_code_security_sup,
    ecai_learning_store,
    ecai_ollama_pool,
    ecai_codebase_learner,
    ecai_log_learning,
    ecai_patch_sup,
    ecai_patch_manager,
    ecai_patch_integration,
    ecai_patch_reconciler
]).

-define(OPTIONAL_PROCESSES, [
    ecai_vuln_monitor,
    ecai_health_monitor,
    damage_ecai_log_bridge
]).

-define(DEFAULT_CALL_TIMEOUT_MS, 5000).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

check() ->
    D = diagnostics(),
    maps:with(
        [status, all_systems_go, patch_ready, summary, checked_at],
        D
    ).

all_systems_go() ->
    D = diagnostics(),
    case maps:get(all_systems_go, D, false) of
        true -> true;
        false -> {false, maps:get(summary, D, [])}
    end.

patch_queue() ->
    D = diagnostics(),
    maps:get(patch_queue, D).

monitor_status() ->
    safe_public_call(ecai_health_monitor, status, []).

latest_report() ->
    safe_public_call(ecai_health_monitor, latest, []).

resolution() ->
    safe_public_call(ecai_health_monitor, resolution, []).

check_with_resolution() ->
    safe_public_call(ecai_health_monitor, check_now, []).

print() ->
    D = diagnostics(),
    PQ = maps:get(patch_queue, D, #{}),
    Inf = maps:get(inference, D, #{}),
    io:format(
        "ECAI health status=~p all_systems_go=~p patch_ready=~p~n"
        "  learner phase=~p ready=~p progress=~p%~n"
        "  inference patch_free=~p audit_free=~p learning_free=~p~n"
        "  patch_queue state=~p manager_active=~p live_workers=~p "
        "running=~p manager_queued=~p durable_queued=~p retry_wait=~p~n"
        "  repairs validated=~p failed=~p proposed=~p~n"
        "  integration state=~p~n"
        "  summary=~p~n",
        [
            maps:get(status, D, unknown),
            maps:get(all_systems_go, D, false),
            maps:get(patch_ready, D, false),
            get_in(D, [learner, phase], unknown),
            get_in(D, [learner, ready], false),
            get_in(D, [learner, progress_percent], 0.0),
            get_in(Inf, [roles, patch, available], unknown),
            get_in(Inf, [roles, audit, available], unknown),
            get_in(Inf, [roles, learning, available], unknown),
            maps:get(state, PQ, unknown),
            maps:get(manager_active, PQ, unknown),
            maps:get(live_workers, PQ, unknown),
            maps:get(persisted_running, PQ, unknown),
            maps:get(manager_queued, PQ, unknown),
            maps:get(durable_queued, PQ, unknown),
            maps:get(retry_wait, PQ, unknown),
            maps:get(validated, PQ, 0),
            maps:get(failed, PQ, 0),
            maps:get(proposed, PQ, 0),
            get_in(D, [integration, diagnostic_state], unknown),
            maps:get(summary, D, [])
        ]
    ),
    D.

diagnostics() ->
    Processes = process_diagnostics(),

    StoreR = safe_apply(ecai_learning_store, status, []),
    LearnerR = safe_apply(ecai_codebase_learner, status, []),
    LogLearningR = safe_apply(ecai_log_learning, status, []),
    LogBridgeR = safe_apply(damage_ecai_log_bridge, status, []),
    PoolR = safe_apply(ecai_ollama_pool, status, []),
    ManagerR = safe_apply(ecai_patch_manager, status, []),
    IntegrationR = safe_apply(ecai_patch_integration, status, []),
    ReconcilerR = safe_apply(ecai_patch_reconciler, status, []),
    RepairsR = safe_apply(ecai_learning_store, repairs, []),

    Store = component_value(StoreR),
    Learner = component_map(LearnerR),
    LogLearning = component_map(LogLearningR),
    LogBridge = component_map(LogBridgeR),
    Pool = component_map(PoolR),
    Manager = component_map(ManagerR),
    Integration0 = component_map(IntegrationR),
    Reconciler = component_map(ReconcilerR),

    Workers = patch_worker_diagnostics(),
    Repairs = repair_diagnostics(RepairsR),
    Inference = inference_diagnostics(PoolR),
    PatchQueue = patch_queue_diagnostics(
        ManagerR, LearnerR, Inference, Repairs, Workers
    ),
    Integration = integration_diagnostics(Integration0, Repairs),

    Base = #{
        checked_at => now_iso8601(),
        processes => Processes,
        store => Store,
        learner => Learner,
        log_learning => LogLearning,
        log_bridge => LogBridge,
        inference_pool => Pool,
        inference => Inference,
        patch_manager => Manager,
        patch_workers => Workers,
        repairs => Repairs,
        patch_queue => PatchQueue,
        reconciler => Reconciler,
        integration => Integration
    },
    Status = classify_overall(Base),
    PatchReady = patch_ready(Base),
    Summary = diagnostic_summary(Base, Status, PatchReady),
    Base#{
        status => Status,
        all_systems_go => (Status =:= go) orelse (Status =:= busy),
        patch_ready => PatchReady,
        summary => Summary
    }.

probe_patch_queue(IntervalMs) when
    is_integer(IntervalMs), IntervalMs >= 0, IntervalMs =< 600000
->
    Before = probe_snapshot(),
    timer:sleep(IntervalMs),
    After = probe_snapshot(),
    Signals = progress_signals(Before, After),
    ProgressObserved = queue_progress_observed(Signals),
    State = probe_state(After, Signals),
    #{
        status => State,
        interval_ms => IntervalMs,
        progress_observed => ProgressObserved,
        signals => Signals,
        before => Before,
        after_snapshot => After
    };
probe_patch_queue(IntervalMs) ->
    {error, {invalid_probe_interval_ms, IntervalMs}}.

%%--------------------------------------------------------------------
%% Component diagnostics
%%--------------------------------------------------------------------

process_diagnostics() ->
    Required = maps:from_list([{Name, process_state(Name)} || Name <- ?REQUIRED_PROCESSES]),
    Optional = maps:from_list([{Name, process_state(Name)} || Name <- ?OPTIONAL_PROCESSES]),
    Missing = [
        Name
     || {Name, State} <- maps:to_list(Required),
        State =/= up
    ],
    #{
        required => Required,
        optional => Optional,
        missing_required => Missing,
        all_required_up => (Missing =:= [])
    }.

process_state(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> up;
                false -> down
            end;
        undefined ->
            down
    end.

patch_worker_diagnostics() ->
    case whereis(ecai_patch_sup) of
        undefined ->
            #{
                status => unavailable,
                live_count => 0,
                live_worker_ids => [],
                children => 0
            };
        _ ->
            try supervisor:which_children(ecai_patch_sup) of
                Children ->
                    Live = [
                        #{id => Id, pid => Pid}
                     || {Id, Pid, _Type, _Mods} <- Children,
                        is_patch_worker_id(Id),
                        is_pid(Pid),
                        is_process_alive(Pid)
                    ],
                    #{
                        status => ok,
                        live_count => length(Live),
                        live_worker_ids => [maps:get(id, W) || W <- Live],
                        children => length(Children)
                    }
            catch
                Class:Reason ->
                    #{
                        status => error,
                        error => {Class, Reason},
                        live_count => 0,
                        live_worker_ids => [],
                        children => 0
                    }
            end
    end.

is_patch_worker_id({ecai_patch_worker, _Fingerprint, _Version}) -> true;
is_patch_worker_id({ecai_patch_worker, _Other}) -> true;
is_patch_worker_id(_) -> false.

repair_diagnostics({ok, Repairs}) when is_list(Repairs) ->
    Counts = lists:foldl(
        fun
            (Repair, Acc) when is_map(Repair) ->
                Status = maps:get(status, Repair, undefined),
                Acc#{Status => maps:get(Status, Acc, 0) + 1};
            (_, Acc) ->
                Acc
        end,
        #{},
        Repairs
    ),
    FailureClasses = lists:foldl(
        fun
            (Repair, Acc) when is_map(Repair) ->
                case maps:get(status, Repair, undefined) of
                    failed ->
                        Key = error_class(maps:get(error, Repair, undefined)),
                        Acc#{Key => maps:get(Key, Acc, 0) + 1};
                    <<"failed">> ->
                        Key = error_class(maps:get(error, Repair, undefined)),
                        Acc#{Key => maps:get(Key, Acc, 0) + 1};
                    _ ->
                        Acc
                end;
            (_, Acc) ->
                Acc
        end,
        #{},
        Repairs
    ),
    #{
        status => ok,
        total => length(Repairs),
        counts => Counts,
        failure_classes => FailureClasses
    };
repair_diagnostics({ok, Other}) ->
    #{
        status => error,
        error => {unexpected_repairs_response, Other},
        total => 0,
        counts => #{},
        failure_classes => #{}
    };
repair_diagnostics({error, Reason}) ->
    #{
        status => error,
        error => Reason,
        total => 0,
        counts => #{},
        failure_classes => #{}
    }.

error_class({Key, _}) when is_atom(Key) -> Key;
error_class({Key, _, _}) when is_atom(Key) -> Key;
error_class(Key) when is_atom(Key) -> Key;
error_class(_) -> other.

inference_diagnostics({ok, Pool}) when is_map(Pool) ->
    Nodes = maps:get(nodes, Pool, []),
    Roles = maps:from_list([
        {Role, role_capacity(Role, Nodes)}
     || Role <- [learning, audit, patch, synthesis]
    ]),
    Receipts = maps:get(inference_receipts, Pool, #{}),
    ReceiptStatuses = maps:get(statuses, Receipts, #{}),
    Sent = maps:get(sent, ReceiptStatuses, 0),
    Uncertain = maps:get(uncertain, ReceiptStatuses, 0),
    #{
        status =>
            case maps:get(healthy, Pool, 0) of
                N when is_integer(N), N > 0 -> healthy;
                _ -> unavailable
            end,
        healthy_nodes => maps:get(healthy, Pool, 0),
        degraded_nodes => maps:get(degraded, Pool, 0),
        down_nodes => maps:get(down, Pool, 0),
        active_leases => maps:get(active_leases, Pool, 0),
        roles => Roles,
        receipts => ReceiptStatuses,
        unresolved_receipts => Sent + Uncertain
    };
inference_diagnostics({ok, Other}) ->
    #{status => error, error => {unexpected_pool_status, Other}, roles => #{}};
inference_diagnostics({error, Reason}) ->
    #{status => error, error => Reason, roles => #{}}.

role_capacity(Role, Nodes) ->
    Eligible = [
        Node
     || Node <- Nodes,
        is_map(Node),
        lists:member(Role, maps:get(roles, Node, [])),
        maps:get(health, Node, unknown) =:= healthy
    ],
    Total = lists:sum([
        positive_int(maps:get(max_inflight, Node, 1), 1)
     || Node <- Eligible
    ]),
    Used = lists:sum([
        min(
            positive_int(maps:get(inflight, Node, 0), 0),
            positive_int(maps:get(max_inflight, Node, 1), 1)
        )
     || Node <- Eligible
    ]),
    #{
        nodes => length(Eligible),
        total => Total,
        used => Used,
        available => max(0, Total - Used),
        saturated => (Total > 0) andalso (Used >= Total)
    }.

patch_queue_diagnostics(ManagerR, LearnerR, Inference, Repairs, Workers) ->
    Manager = map_or_empty(ManagerR),
    Learner = map_or_empty(LearnerR),
    Counts = maps:get(counts, Repairs, #{}),

    Active = int_value(maps:get(active, Manager, 0)),
    %% `queued` / `queued_total` are historical cumulative counters in the
    %% patch manager. Queue health must use `queued_live`; otherwise a node can
    %% remain permanently blocked_manager after all durable work is drained.
    ManagerQueued = int_value(
        maps:get(
            queued_live,
            Manager,
            status_count(queued, Counts)
        )
    ),
    ManagerQueuedTotal = int_value(
        maps:get(
            queued_total,
            Manager,
            maps:get(queued, Manager, 0)
        )
    ),
    Running = status_count(running, Counts),
    Queued = status_count(queued, Counts),
    RetryWait = status_count(retry_wait, Counts),
    Validated = status_count(validated, Counts),
    Proposed = status_count(proposed, Counts),
    Failed = status_count(failed, Counts),
    Live = int_value(maps:get(live_count, Workers, 0)),
    DurableQueued = Queued + RetryWait,
    LearnerReady = maps:get(ready, Learner, false) =:= true,
    PatchFree = get_in(Inference, [roles, patch, available], 0),
    LastError = maps:get(last_error, Manager, undefined),

    Inputs = #{
        manager_active => Active,
        live_workers => Live,
        persisted_running => Running,
        manager_queued => ManagerQueued,
        manager_queued_total => ManagerQueuedTotal,
        durable_queued => DurableQueued,
        retry_wait => RetryWait,
        learner_ready => LearnerReady,
        patch_free_capacity => PatchFree,
        manager_last_error => LastError
    },
    State = classify_patch_queue(Inputs),
    Inputs#{
        state => State,
        working => lists:member(State, [working, working_transitional]),
        queued => Queued,
        validated => Validated,
        proposed => Proposed,
        failed => Failed,
        last_run_at => maps:get(last_run_at, Manager, undefined),
        last_retry_at => maps:get(last_retry_at, Manager, undefined),
        retried => maps:get(retried, Manager, 0),
        live_worker_ids => maps:get(live_worker_ids, Workers, []),
        failure_classes => maps:get(failure_classes, Repairs, #{})
    }.

classify_patch_queue(I) ->
    Active = maps:get(manager_active, I, 0),
    Live = maps:get(live_workers, I, 0),
    Running = maps:get(persisted_running, I, 0),
    DurablePending = maps:get(durable_queued, I, 0),
    ManagerLivePending = maps:get(manager_queued, I, 0),
    Pending = max(DurablePending, ManagerLivePending),
    LearnerReady = maps:get(learner_ready, I, false),
    PatchFree = maps:get(patch_free_capacity, I, 0),
    LastError = maps:get(manager_last_error, I, undefined),
    case true of
        _ when
            Active > 0,
            Live > 0,
            Active =:= Live,
            Active =:= Running
        ->
            working;
        _ when Active > 0, Live > 0 ->
            working_transitional;
        _ when Active > 0, Live =:= 0 ->
            active_without_worker;
        _ when Active =:= 0, Live > 0 ->
            worker_without_manager;
        _ when Running > 0, Active =:= 0, Live =:= 0 ->
            stale_running;
        _ when Pending > 0, LearnerReady =:= false ->
            blocked_learning;
        _ when Pending > 0, LearnerReady =:= true, PatchFree =:= 0 ->
            blocked_inference;
        _ when
            Pending > 0,
            LearnerReady =:= true,
            LastError =/= undefined
        ->
            blocked_manager;
        _ when Pending > 0, LearnerReady =:= true, PatchFree > 0 ->
            stalled;
        true ->
            idle
    end.

integration_diagnostics(Integration0, Repairs) ->
    Integration =
        case Integration0 of
            M when is_map(M) -> M;
            Other -> #{status => error, error => Other}
        end,
    Counts = maps:get(counts, Repairs, #{}),
    Validated = status_count(validated, Counts),
    Current = maps:get(current, Integration, undefined),
    JobCounts = maps:get(job_counts, Integration, #{}),
    JobCount = lists:sum([int_value(V) || {_K, V} <- maps:to_list(JobCounts)]),
    DiagnosticState =
        case {Validated, Current, JobCount} of
            {0, undefined, 0} -> waiting_for_validated_repairs;
            {V, undefined, 0} when V > 0 -> validated_repairs_pending_integration;
            {_V, C, _N} when C =/= undefined -> working;
            {_V, _C, N} when N > 0 -> has_jobs;
            _ -> idle
        end,
    Integration#{
        diagnostic_state => DiagnosticState,
        validated_repairs => Validated,
        integration_job_count => JobCount
    }.

%%--------------------------------------------------------------------
%% Overall classification
%%--------------------------------------------------------------------

classify_overall(D) ->
    Processes = maps:get(processes, D, #{}),
    Inference = maps:get(inference, D, #{}),
    PQ = maps:get(patch_queue, D, #{}),
    Learner = maps:get(learner, D, #{}),
    LogLearning = maps:get(log_learning, D, #{}),
    Integration = maps:get(integration, D, #{}),
    RequiredUp = maps:get(all_required_up, Processes, false),
    ComponentsResponding = components_responding(D),
    PoolHealthy = maps:get(status, Inference, error) =:= healthy,
    PQState = maps:get(state, PQ, unknown),
    LearnerPhase = maps:get(phase, Learner, unknown),
    LearnerReady = maps:get(ready, Learner, false) =:= true,
    LogLearningHealthy = log_learning_healthy(LogLearning),
    IntegrationState = maps:get(diagnostic_state, Integration, unknown),
    case true of
        _ when RequiredUp =:= false ->
            fail;
        _ when PoolHealthy =:= false ->
            fail;
        _ when ComponentsResponding =:= false ->
            degraded;
        _ when LogLearningHealthy =:= false ->
            degraded;
        _ when IntegrationState =:= validated_repairs_pending_integration ->
            degraded;
        _ when
            PQState =:= active_without_worker;
            PQState =:= worker_without_manager;
            PQState =:= stale_running
        ->
            degraded;
        _ when
            PQState =:= stalled;
            PQState =:= blocked_manager
        ->
            degraded;
        _ when PQState =:= blocked_inference ->
            degraded;
        _ when
            PQState =:= working;
            PQState =:= working_transitional
        ->
            busy;
        _ when
            LearnerPhase =:= learning;
            LearnerPhase =:= queued;
            LearnerPhase =:= finalizing
        ->
            busy;
        _ when LearnerReady =:= false ->
            degraded;
        true ->
            go
    end.

log_learning_healthy(LogLearning) when is_map(LogLearning) ->
    case maps:get(enabled, LogLearning, true) of
        false ->
            true;
        true ->
            Queued = maps:get(queued, LogLearning, 0),
            MaxQueue = maps:get(max_queue, LogLearning, 0),
            AtCapacity =
                is_integer(Queued) andalso Queued > 0 andalso
                    is_integer(MaxQueue) andalso MaxQueue > 0 andalso
                    Queued >= MaxQueue,
            maps:get(last_error, LogLearning, undefined) =:= undefined andalso
                not AtCapacity;
        _ ->
            false
    end;
log_learning_healthy(_) ->
    false.

patch_ready(D) ->
    Learner = maps:get(learner, D, #{}),
    Inference = maps:get(inference, D, #{}),
    Processes = maps:get(processes, D, #{}),
    maps:get(all_required_up, Processes, false) andalso
        components_responding(D) andalso
        maps:get(ready, Learner, false) =:= true andalso
        get_in(Inference, [roles, patch, total], 0) > 0.

components_responding(D) ->
    lists:all(
        fun(Key) ->
            case maps:get(Key, D, #{status => error}) of
                M when is_map(M) -> maps:get(status, M, ok) =/= error;
                _ -> false
            end
        end,
        [
            store,
            learner,
            log_learning,
            inference_pool,
            patch_manager,
            reconciler,
            integration
        ]
    ).

diagnostic_summary(D, Status, PatchReady) ->
    Processes = maps:get(processes, D, #{}),
    PQ = maps:get(patch_queue, D, #{}),
    Inference = maps:get(inference, D, #{}),
    Integration = maps:get(integration, D, #{}),
    Missing = maps:get(missing_required, Processes, []),
    Base = [
        {overall, Status},
        {patch_ready, PatchReady},
        {components_responding, components_responding(D)},
        {learner_ready, get_in(D, [learner, ready], false)},
        {log_learning_healthy, log_learning_healthy(maps:get(log_learning, D, #{}))},
        {log_learning_queued, get_in(D, [log_learning, queued], unknown)},
        {patch_queue, maps:get(state, PQ, unknown)},
        {patch_free_capacity, get_in(Inference, [roles, patch, available], unknown)},
        {audit_free_capacity, get_in(Inference, [roles, audit, available], unknown)},
        {integration, maps:get(diagnostic_state, Integration, unknown)}
    ],
    case Missing of
        [] -> Base;
        _ -> [{missing_processes, Missing} | Base]
    end.

%%--------------------------------------------------------------------
%% Active queue probe
%%--------------------------------------------------------------------

probe_snapshot() ->
    D = diagnostics(),
    PQ = maps:get(patch_queue, D, #{}),
    Inf = maps:get(inference, D, #{}),
    #{
        checked_at => maps:get(checked_at, D),
        queue_state => maps:get(state, PQ, unknown),
        manager_active => maps:get(manager_active, PQ, 0),
        manager_queued => maps:get(manager_queued, PQ, 0),
        manager_queued_total =>
            maps:get(manager_queued_total, PQ, 0),
        durable_queued => maps:get(durable_queued, PQ, 0),
        persisted_running => maps:get(persisted_running, PQ, 0),
        retry_wait => maps:get(retry_wait, PQ, 0),
        validated => maps:get(validated, PQ, 0),
        failed => maps:get(failed, PQ, 0),
        retried => int_value(maps:get(retried, PQ, 0)),
        live_worker_ids => maps:get(live_worker_ids, PQ, []),
        inference_completed =>
            int_value(get_in(Inf, [receipts, completed], 0))
    }.

progress_signals(Before, After) ->
    #{
        retry_counter_advanced =>
            maps:get(retried, After, 0) > maps:get(retried, Before, 0),
        cluster_inference_completed =>
            maps:get(inference_completed, After, 0) >
            maps:get(inference_completed, Before, 0),
        repair_counts_changed =>
            repair_count_signature(Before) =/= repair_count_signature(After),
        worker_set_changed =>
            maps:get(live_worker_ids, Before, []) =/=
            maps:get(live_worker_ids, After, [])
    }.

repair_count_signature(S) ->
    {
        maps:get(manager_active, S, 0),
        maps:get(durable_queued, S, 0),
        maps:get(persisted_running, S, 0),
        maps:get(retry_wait, S, 0),
        maps:get(validated, S, 0),
        maps:get(failed, S, 0)
    }.

queue_progress_observed(Signals) ->
    lists:any(
        fun(Key) -> maps:get(Key, Signals, false) =:= true end,
        [retry_counter_advanced, repair_counts_changed, worker_set_changed]
    ).

probe_state(After, Signals) ->
    Progress = queue_progress_observed(Signals),
    QueueState = maps:get(queue_state, After, unknown),
    case {Progress, QueueState} of
        {true, _} -> progressing;
        {false, working} -> executing_no_completion_observed;
        {false, working_transitional} -> executing_no_completion_observed;
        {false, blocked_learning} -> blocked_learning;
        {false, blocked_inference} -> blocked_inference;
        {false, blocked_manager} -> blocked_manager;
        {false, stalled} -> stalled;
        {false, idle} -> idle;
        {false, Other} -> Other
    end.

%%--------------------------------------------------------------------
%% Utilities
%%--------------------------------------------------------------------

safe_public_call(Module, Function, Args) ->
    try apply(Module, Function, Args) of
        Value -> Value
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

safe_apply(Module, Function, Args) ->
    Parent = self(),
    Ref = make_ref(),
    Timeout = health_call_timeout_ms(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Parent ! {ecai_health_call, Ref, do_safe_apply(Module, Function, Args)}
    end),
    receive
        {ecai_health_call, Ref, Result} ->
            _ = erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, DownReason} ->
            {error, {call_worker_down, Module, Function, DownReason}}
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', MRef, process, Pid, _} -> ok
        after 100 ->
            _ = erlang:demonitor(MRef, [flush]),
            ok
        end,
        flush_health_result(Ref),
        {error, {call_timeout, Module, Function, Timeout}}
    end.

do_safe_apply(Module, Function, Args) ->
    try
        case code:ensure_loaded(Module) of
            {module, Module} ->
                case erlang:function_exported(Module, Function, length(Args)) of
                    true -> {ok, apply(Module, Function, Args)};
                    false -> {error, {not_exported, Module, Function, length(Args)}}
                end;
            {error, LoadReason} ->
                {error, {module_unavailable, Module, LoadReason}}
        end
    catch
        Class:CallReason:Stack ->
            {error, {call_failed, Module, Function, Class, CallReason, Stack}}
    end.

flush_health_result(Ref) ->
    receive
        {ecai_health_call, Ref, _LateResult} -> ok
    after 0 ->
        ok
    end.

health_call_timeout_ms() ->
    case
        application:get_env(
            ecai, ecai_health_call_timeout_ms, ?DEFAULT_CALL_TIMEOUT_MS
        )
    of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_CALL_TIMEOUT_MS
    end.

component_value({ok, Value}) -> Value;
component_value({error, Reason}) -> #{status => error, error => Reason}.

component_map({ok, M}) when is_map(M) -> M;
component_map({ok, Other}) -> #{status => error, error => {unexpected_component_response, Other}};
component_map({error, Reason}) -> #{status => error, error => Reason}.

map_or_empty({ok, M}) when is_map(M) -> M;
map_or_empty(_) -> #{}.

status_count(Key, Counts) ->
    int_value(
        maps:get(
            Key,
            Counts,
            maps:get(atom_to_binary(Key, utf8), Counts, 0)
        )
    ).

positive_int(V, _Default) when is_integer(V), V >= 0 -> V;
positive_int(_V, Default) -> Default.

int_value(V) when is_integer(V), V >= 0 -> V;
int_value(_) -> 0.

get_in(Map, [], _Default) ->
    Map;
get_in(Map, [Key | Rest], Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> get_in(Value, Rest, Default);
        error -> Default
    end;
get_in(_Other, _Path, Default) ->
    Default.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second),
            [{unit, second}, {offset, "Z"}]
        )
    ).
