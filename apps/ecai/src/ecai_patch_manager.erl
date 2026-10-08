-module(ecai_patch_manager).
-behaviour(gen_server).

-export([start_link/0, start_link/1, scan_now/0, status/0, enqueue_feedback/4]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([
    normalize_preflight_terminal/3,
    is_orphan_retry_wait/1,
    recover_orphan_retry/1,
    orphan_preflight_batch/1,
    terminalize_exhausted_retry_wait/2,
    analysis_matches_report_source/2,
    repair_order_key/1,
    source_priority/1,
    severity_priority/1
]).
-endif.

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 60000).
-define(DEFAULT_RETRY_TICK, 15000).
-define(DEFAULT_MAX_CONCURRENT, 2).
-define(DEFAULT_ORPHAN_PREFLIGHT_BATCH, 8).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL,
    retry_tick_ms = ?DEFAULT_RETRY_TICK,
    max_concurrent = ?DEFAULT_MAX_CONCURRENT,
    opts = #{},
    cycles = 0,
    queued = 0,
    retried = 0,
    last_run_at = undefined,
    last_retry_at = undefined,
    last_error = undefined,
    scan_timer = undefined,
    retry_timer = undefined,
    task = undefined,
    scan_pending = false,
    retry_pending = false,
    feedback_pending = [],
    down_reasons = #{},
    workers = #{},
    snapshot = #{},
    snapshot_at = undefined,
    snapshot_error = not_sampled,
    cycle_failures = 0,
    last_failure = undefined,
    last_worker_down = undefined
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
scan_now() -> gen_server:cast(?SERVER, scan_now).
status() -> gen_server:call(?SERVER, status).
enqueue_feedback(App, Module, Finding, Meta)
  when is_atom(App), is_atom(Module), is_map(Finding), is_map(Meta) ->
    gen_server:cast(?SERVER, {enqueue_feedback, App, Module, Finding, Meta}).

init(Opts) ->
    %% The cycle runner is linked so it cannot outlive a killed manager. Monitor
    %% delivery, rather than the link, owns failure accounting for that runner.
    process_flag(trap_exit, true),
    Interval = positive_int(maps:get(interval_ms, Opts,
        application:get_env(ecai, code_patch_scan_interval_ms, ?DEFAULT_INTERVAL)),
        ?DEFAULT_INTERVAL),
    RetryTick = positive_int(maps:get(retry_tick_ms, Opts,
        application:get_env(ecai, code_patch_retry_tick_ms, ?DEFAULT_RETRY_TICK)),
        ?DEFAULT_RETRY_TICK),
    MaxConcurrent = positive_int(maps:get(max_concurrent, Opts,
        application:get_env(ecai, code_patch_max_concurrent, ?DEFAULT_MAX_CONCURRENT)),
        ?DEFAULT_MAX_CONCURRENT),
    State = #state{interval_ms = Interval, retry_tick_ms = RetryTick,
        max_concurrent = MaxConcurrent, opts = Opts},
    {ok, arm_timer(scan, nonneg_int(maps:get(initial_scan_delay_ms, Opts, 10000), 10000),
        arm_timer(retry_tick, nonneg_int(maps:get(initial_retry_delay_ms, Opts, 1000), 1000), State))}.

handle_call(status, _From, State) ->
    %% No DETS fold, Git invocation, or supervisor call may run in this callback.
    %% Durable counts are explicitly timestamped; active counts use monitored PIDs.
    Active = length([Pid || Pid <- maps:keys(State#state.workers),
        erlang:is_process_alive(Pid)]),
    Base = maps:merge(empty_snapshot(), State#state.snapshot),
    Reply = Base#{cycles => State#state.cycles,
        queued => State#state.queued, queued_total => State#state.queued,
        retried => State#state.retried, retried_total => State#state.retried,
        active => Active, max_concurrent => State#state.max_concurrent,
        last_run_at => State#state.last_run_at, last_retry_at => State#state.last_retry_at,
        last_error => State#state.last_error, last_failure => State#state.last_failure,
        cycle_failures => State#state.cycle_failures,
        cycle_running => State#state.task =/= undefined,
        cycle => task_status(State#state.task),
        scan_pending => State#state.scan_pending,
        retry_pending => State#state.retry_pending,
        monitored_workers => map_size(State#state.workers),
        last_worker_down => State#state.last_worker_down,
        snapshot_ready => State#state.snapshot_at =/= undefined,
        snapshot_at => State#state.snapshot_at,
        snapshot_error => State#state.snapshot_error},
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(scan_now, State) ->
    {noreply, request_cycle(scan, State)};
handle_cast({enqueue_feedback, App, Module, Finding, Meta}, State) ->
    %% Admission is serialized with scans/dispatch, not with status requests.
    Item = {App, Module, Finding, Meta},
    Pending = [Item | State#state.feedback_pending],
    {noreply, request_cycle(retry_tick, State#state{feedback_pending = Pending})};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({timeout, Ref, scan}, State = #state{scan_timer = Ref}) ->
    {noreply, request_cycle(scan, arm_timer(scan, State#state.interval_ms,
        State#state{scan_timer = undefined}))};
handle_info({timeout, Ref, retry_tick}, State = #state{retry_timer = Ref}) ->
    {noreply, request_cycle(retry_tick, arm_timer(retry_tick, State#state.retry_tick_ms,
        State#state{retry_timer = undefined}))};
handle_info(scan, State) ->
    %% Legacy/manual messages request work but never mint another timer chain.
    {noreply, request_cycle(scan, State)};
handle_info(retry_tick, State) ->
    {noreply, request_cycle(retry_tick, State)};
handle_info({patch_worker_started, Fp, Version, Pid}, State) when is_pid(Pid) ->
    {noreply, monitor_worker(Fp, Version, Pid, State)};
handle_info({patch_children, Children}, State) when is_list(Children) ->
    {noreply, adopt_workers(Children, State)};
handle_info({patch_cycle_result, Ref, _Result},
        State = #state{task = #{ref := Ref, timed_out := true}}) ->
    %% A result already in flight must not release a timed-out runner's lease.
    {noreply, State};
handle_info({patch_cycle_result, Ref, Result}, State = #state{task = #{ref := Ref} = Task}) ->
    _ = erlang:demonitor(maps:get(mref, Task), [flush]),
    _ = erlang:cancel_timer(maps:get(timer, Task)),
    State1 = finish_cycle(maps:get(kind, Task), Result, State#state{task = undefined}),
    {noreply, start_pending_cycle(State1)};
handle_info({timeout, TRef, {patch_cycle_timeout, Ref}},
        State = #state{task = #{ref := Ref, timer := TRef, pid := Pid} = Task}) ->
    exit(Pid, kill),
    %% Keep ownership until DOWN confirms death. No overlapping dispatchers.
    {noreply, State#state{task = Task#{timed_out => true}}};
handle_info({'DOWN', MRef, process, _Pid, Reason},
        State = #state{task = #{mref := MRef} = Task}) ->
    _ = erlang:cancel_timer(maps:get(timer, Task)),
    Error = case maps:get(timed_out, Task, false) of
        true -> {patch_cycle_timeout, maps:get(kind, Task)};
        false -> {patch_cycle_down, maps:get(kind, Task), Reason}
    end,
    State1 = finish_cycle(maps:get(kind, Task), #{errors => [Error]},
        State#state{task = undefined}),
    {noreply, start_pending_cycle(State1)};
handle_info({'DOWN', MRef, process, Pid, Reason}, State) ->
    case maps:find(Pid, State#state.workers) of
        {ok, #{mref := MRef, key := Key}} ->
            Reasons = (State#state.down_reasons)#{Key => {worker_down, Reason}},
            State1 = State#state{workers = maps:remove(Pid, State#state.workers),
                down_reasons = Reasons,
                last_worker_down = #{key => Key, reason => Reason, at => now_iso8601()}},
            %% Recovery rereads durable state; normal completion must not be retried.
            {noreply, request_cycle(retry_tick, State1)};
        _ -> {noreply, State}
    end;
handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.scan_timer),
    cancel_timer(State#state.retry_timer),
    case State#state.task of
        #{pid := Pid, timer := Timer} -> cancel_timer(Timer), exit(Pid, kill);
        _ -> ok
    end,
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref), ok.

arm_timer(scan, Delay, State) ->
    cancel_timer(State#state.scan_timer),
    State#state{scan_timer = erlang:start_timer(Delay, self(), scan)};
arm_timer(retry_tick, Delay, State) ->
    cancel_timer(State#state.retry_timer),
    State#state{retry_timer = erlang:start_timer(Delay, self(), retry_tick)}.

request_cycle(scan, State) -> start_pending_cycle(State#state{scan_pending = true});
request_cycle(retry_tick, State) -> start_pending_cycle(State#state{retry_pending = true}).

start_pending_cycle(State = #state{task = Task}) when Task =/= undefined -> State;
start_pending_cycle(State = #state{scan_pending = false, retry_pending = false}) -> State;
start_pending_cycle(State) ->
    Kind = case State#state.scan_pending of true -> scan; false -> retry_tick end,
    Parent = self(),
    Ref = make_ref(),
    Opts = (State#state.opts)#{manager_pid => Parent,
        worker_down_reasons => State#state.down_reasons},
    Feedback = lists:reverse(State#state.feedback_pending),
    Max = State#state.max_concurrent,
    {Pid, MRef} = spawn_opt(fun() ->
        Result = run_cycle(Kind, Feedback, Opts, Max),
        Parent ! {patch_cycle_result, Ref, Result}
    end, [link, monitor]),
    Timeout = positive_int(maps:get(cycle_timeout_ms, Opts,
        application:get_env(ecai, code_patch_cycle_timeout_ms, 300000)), 300000),
    Timer = erlang:start_timer(Timeout, self(), {patch_cycle_timeout, Ref}),
    Task = #{pid => Pid, mref => MRef, ref => Ref, timer => Timer,
        kind => Kind, started_ms => erlang:monotonic_time(millisecond)},
    State#state{task = Task, scan_pending = false, retry_pending = false,
        feedback_pending = [], down_reasons = #{}}.

run_cycle(Kind, Feedback, Opts, Max) ->
    Result = try
        Children = safe_patch_children(),
        notify_manager(Opts, {patch_children, Children}),
        {FQ, FE} = lists:foldl(fun({App, Module, Finding, Meta}, {Q, E}) ->
            case guarded(fun() -> admit_feedback(App, Module, Finding, Meta, Opts) end) of
                {ok, {Q1, E1}} -> {Q + Q1, E1 ++ E};
                {error, Error} -> {Q, [{feedback_admission_failed, App, Module, Error} | E]}
            end
        end, {0, []}, Feedback),
        {SQ, SE} = scan_candidates(Kind, Opts, Max),
        {Started, DE} = dispatch_persisted(Opts, Max),
        #{queued => FQ + SQ, started => Started, errors => DE ++ SE ++ FE}
    catch
        Class:Reason:Stack ->
            #{errors => [{patch_cycle_exception, Class, Reason, lists:sublist(Stack, 8)}]}
    end,
    %% Even failed cycles can report a fresh snapshot; errors are never replaced
    %% by an empty queue when a dependency cannot be read.
    case guarded(fun() -> queue_snapshot(Opts) end) of
        {ok, Snapshot} -> Result#{snapshot => Snapshot, snapshot_at => now_iso8601()};
        {error, Error} -> Result#{snapshot_error => Error}
    end.

scan_candidates(retry_tick, _Opts, _Max) -> {0, []};
scan_candidates(scan, Opts, Max) ->
    case learning_ready(Opts) of
        false -> {0, [learning_not_ready]};
        true ->
            _ = safe_replay_feedback(),
            lists:foldl(fun(App, {Q, E}) ->
                case safe_app_findings(App) of
                    {ok, Reports} ->
                        %% A malformed report cannot abort unrelated applications.
                        lists:foldl(fun(Report, {RQ, RE}) ->
                            case guarded(fun() -> process_reports(App, [Report], Opts, Max) end) of
                                {ok, {N, Errors}} -> {RQ + N, Errors ++ RE};
                                {error, Error} -> {RQ, [{report_admission_failed, App, Error} | RE]}
                            end
                        end, {Q, E}, Reports);
                    {error, Reason} -> {Q, [{App, Reason} | E]}
                end
            end, {0, []}, ?APPS)
    end.

guarded(Fun) ->
    try {ok, Fun()} catch
        Class:Reason:Stack -> {error, {Class, Reason, lists:sublist(Stack, 8)}}
    end.

finish_cycle(Kind, Result, State) ->
    Errors0 = maps:get(errors, Result, []),
    Errors = case maps:find(snapshot_error, Result) of
        {ok, Error} -> [{queue_snapshot_failed, Error} | Errors0];
        error -> Errors0
    end,
    LastError = merge_errors(State#state.last_error, Errors),
    Now = now_iso8601(),
    State1 = State#state{
        cycles = State#state.cycles + case Kind of scan -> 1; _ -> 0 end,
        queued = State#state.queued + maps:get(queued, Result, 0),
        retried = State#state.retried + maps:get(started, Result, 0),
        cycle_failures = State#state.cycle_failures + case Errors of [] -> 0; _ -> 1 end,
        last_run_at = case Kind of scan -> Now; _ -> State#state.last_run_at end,
        last_retry_at = Now, last_error = LastError,
        last_failure = case Errors of
            [] -> State#state.last_failure;
            _ -> #{at => Now, errors => Errors}
        end},
    case maps:find(snapshot, Result) of
        {ok, Snapshot} -> State1#state{snapshot = Snapshot,
            snapshot_at = maps:get(snapshot_at, Result), snapshot_error = undefined};
        error -> State1#state{snapshot_error = maps:get(snapshot_error, Result, LastError)}
    end.

empty_snapshot() ->
    #{queued_live => 0, retry_wait => 0, pending => 0, running_persisted => 0,
        stale_running => 0, repair_statuses => #{}, failure_summary => #{}}.

queue_snapshot(Opts) ->
    Repairs = safe_repairs(),
    Counts = repair_counts(Repairs),
    Queued = status_count(queued, Counts),
    RetryWait = status_count(retry_wait, Counts),
    Children = safe_patch_children(),
    notify_manager(Opts, {patch_children, Children}),
    #{queued_live => Queued, retry_wait => RetryWait, pending => Queued + RetryWait,
        running_persisted => status_count(running, Counts),
        stale_running => stale_running_count(Repairs), repair_statuses => Counts,
        failure_summary => failure_summary(Repairs, Opts)}.

monitor_worker(Fp, Version, Pid, State) ->
    case maps:is_key(Pid, State#state.workers) of
        true -> State;
        false ->
            MRef = erlang:monitor(process, Pid),
            State#state{workers = (State#state.workers)#{Pid =>
                #{mref => MRef, key => {Fp, Version}}}}
    end.

adopt_workers(Children, State) ->
    lists:foldl(fun
        ({{ecai_patch_worker, Fp, Version}, Pid, _, _}, Acc) when is_pid(Pid) ->
            case erlang:is_process_alive(Pid) of
                true -> monitor_worker(Fp, Version, Pid, Acc);
                false -> Acc
            end;
        (_, Acc) -> Acc
    end, State, Children).

task_status(undefined) -> idle;
task_status(Task) ->
    #{kind => maps:get(kind, Task), pid => maps:get(pid, Task),
        timed_out => maps:get(timed_out, Task, false),
        elapsed_ms => max(0, erlang:monotonic_time(millisecond) - maps:get(started_ms, Task))}.

learning_ready(Opts) ->
    Require = maps:get(
        require_global_learning,
        Opts,
        application:get_env(ecai, code_patch_require_global_learning, true)
    ),
    case Require of
        false -> true;
        true -> safe_learning_ready()
    end.

safe_learning_ready() ->
    case whereis(ecai_learning_store) of
        undefined ->
            false;
        _Pid ->
            try
                LearnerReady =
                    case ecai_codebase_learner:status() of
                        #{phase := idle, ready := true, last_completed_at := Completed} when
                            Completed =/= undefined
                        ->
                            true;
                        _ ->
                            false
                    end,
                AppsReady = lists:all(
                    fun(App) ->
                        ecai_learning_store:get_app_knowledge(App) =/= not_found
                    end,
                    ?APPS
                ),
                LearnerReady andalso AppsReady andalso
                    ecai_learning_store:get_global_knowledge() =/= not_found
            catch
                exit:{noproc, _} -> false;
                exit:{timeout, _} -> false;
                _:_ -> false
            end
    end.

safe_replay_feedback() ->
    try ecai_repair_feedback:replay() of
        _ -> ok
    catch
        _:_ -> ok
    end.

safe_app_findings(App) ->
    try ecai_vuln_monitor:app_findings(App) of
        Reports when is_list(Reports) ->
            {ok, Reports};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_findings_response, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {app_findings_exception, Class, Reason, Stacktrace}}
    end.

process_reports(App, Reports, Opts, MaxConcurrent) ->
    lists:foldl(
        fun(Report, {Q, E}) ->
            ModuleBin = mget(<<"module">>, Report, <<>>),
            ReportSourceSha = report_source_sha256(Report),
            case existing_module_atom(ModuleBin) of
                {error, Reason} ->
                    {Q, [Reason | E]};
                {ok, Module} ->
                    Findings = mget(<<"findings">>, Report, []),
                    process_findings(
                        App,
                        Module,
                        Findings,
                        ReportSourceSha,
                        Opts,
                        MaxConcurrent,
                        Q,
                        E
                    )
            end
        end,
        {0, []},
        Reports
    ).

process_findings(
    _App,
    _Module,
    [],
    _ReportSourceSha,
    _Opts,
    _MaxConcurrent,
    Q,
    E
) ->
    {Q, E};
process_findings(
    App,
    Module,
    [Finding | Rest],
    ReportSourceSha,
    Opts,
    MaxConcurrent,
    Q0,
    E0
) ->
    {Q1, E1} =
        case patchable(Finding, Opts) of
            false ->
                {Q0, E0};
            true ->
                case ecai_finding_adjudicator:adjudicate(Finding) of
                    {reject, Reason} ->
                        logger:notice(
                            "ECAI repair finding rejected by deterministic "
                            "adjudication app=~p module=~p "
                            "fingerprint=~p reason=~p",
                            [
                                App,
                                Module,
                                finding_fingerprint(Module, Finding),
                                Reason
                            ]
                        ),
                        {Q0, E0};
                    accept ->
                        case ecai_learning_store:get_analysis(App, Module) of
                            not_found ->
                                ecai_codebase_learner:module_changed(App, Module),
                                {Q0, E0};
                            {ok, Analysis} ->
                                case
                                    analysis_matches_report_source(
                                        ReportSourceSha, Analysis
                                    )
                                of
                                    true ->
                                        queue_if_needed(
                                            App,
                                            Module,
                                            Finding,
                                            Analysis,
                                            Opts,
                                            MaxConcurrent,
                                            Q0,
                                            E0
                                        );
                                    false ->
                                        logger:notice(
                                            "ECAI repair admission deferred source "
                                            "identity mismatch app=~p module=~p "
                                            "report_sha=~p analysis_sha=~p",
                                            [
                                                App,
                                                Module,
                                                ReportSourceSha,
                                                maps:get(
                                                    source_sha256,
                                                    Analysis,
                                                    undefined
                                                )
                                            ]
                                        ),
                                        ecai_codebase_learner:module_changed(
                                            App, Module
                                        ),
                                        {Q0, E0}
                                end
                        end
                end
        end,
    process_findings(
        App,
        Module,
        Rest,
        ReportSourceSha,
        Opts,
        MaxConcurrent,
        Q1,
        E1
    ).


admit_feedback(App, Module, Finding, Meta, Opts) ->
    case patchable(Finding, Opts) of
        false ->
            {0, []};
        true ->
            case ecai_finding_adjudicator:adjudicate(Finding) of
                {reject, Reason} ->
                    {0, [{feedback_rejected, App, Module, Reason}]};
                accept ->
                    case ecai_learning_store:get_analysis(App, Module) of
                        not_found ->
                            ecai_codebase_learner:module_changed(App, Module),
                            {0, [{feedback_analysis_unavailable, App, Module}]};
                        {ok, Analysis} when is_map(Analysis) ->
                            ExpectedSha = maps:get(source_sha256, Meta, undefined),
                            case analysis_matches_report_source(ExpectedSha, Analysis) of
                                true ->
                                    queue_feedback_if_needed(
                                        App, Module, Finding, Analysis, Meta, Opts);
                                false ->
                                    ecai_codebase_learner:module_changed(App, Module),
                                    {0, [{feedback_source_changed, App, Module, ExpectedSha,
                                          maps:get(source_sha256, Analysis, undefined)}]}
                            end;
                        Other ->
                            {0, [{feedback_analysis_invalid, App, Module, Other}]}
                    end
            end
    end.

queue_feedback_if_needed(App, Module, Finding, Analysis, Meta, _Opts) ->
    Fp = finding_fingerprint(Module, Finding),
    Version = ecai_code_context:finding_version(App, Module, Finding),
    Provenance0 = analysis_repair_provenance(Analysis),
    Provenance = Provenance0#{
        repair_source => maps:get(source, Meta, runtime_feedback),
        feedback => maps:without([source_sha256], Meta)
    },
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, Existing0} ->
            Existing = ensure_repair_provenance(Existing0, Provenance),
            maybe_persist_enriched_repair(Fp, Version, Existing0, Existing),
            {0, []};
        not_found ->
            case has_active_feedback_repair(Fp) of
                true ->
                    {0, []};
                false ->
                    Now = now_iso8601(),
                    Queued0 = #{
                        status => queued,
                        stage => queued,
                        fingerprint => Fp,
                        finding_version => Version,
                        application => App,
                        module => Module,
                        finding => Finding,
                        created_at => Now,
                        updated_at => Now
                    },
                    case ecai_learning_store:compare_and_put_repair(
                            Fp, Version, not_found, maps:merge(Queued0, Provenance)) of
                        {ok, _} -> {1, []};
                        {error, conflict} -> {0, []};
                        Error -> {0, [{feedback_reservation_failed, Fp, Version, Error}]}
                    end
            end
    end.

has_active_feedback_repair(Fp) ->
    try ecai_learning_store:repairs(Fp) of
        Repairs when is_list(Repairs) ->
            lists:any(fun feedback_repair_active/1, Repairs);
        _ -> false
    catch
        _:_ -> false
    end.

feedback_repair_active(Repair) when is_map(Repair) ->
    case maps:get(status, Repair, undefined) of
        failed -> false;
        <<"failed">> -> false;
        blocked -> false;
        <<"blocked">> -> false;
        superseded -> false;
        <<"superseded">> -> false;
        _ -> true
    end;
feedback_repair_active(_) -> false.

report_source_sha256(Report) ->
    case mget(<<"source_sha256">>, Report, undefined) of
        undefined -> undefined;
        <<>> -> undefined;
        Value -> to_binary(Value)
    end.

analysis_matches_report_source(undefined, _Analysis) ->
    %% Legacy reports without a source identity remain compatible; the
    %% immutable source-snapshot preflight is still authoritative.
    true;
analysis_matches_report_source(ReportSourceSha, Analysis) when
    is_binary(ReportSourceSha), is_map(Analysis)
->
    ReportSourceSha =:=
        maps:get(source_sha256, Analysis, undefined);
analysis_matches_report_source(_ReportSourceSha, _Analysis) ->
    false.

queue_if_needed(
    App,
    Module,
    Finding,
    Analysis,
    _Opts,
    _MaxConcurrent,
    Q,
    E
) ->
    Fp = finding_fingerprint(Module, Finding),
    Version = ecai_code_context:finding_version(App, Module, Finding),
    Provenance = analysis_repair_provenance(Analysis),
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, Existing0} ->
            Existing = ensure_repair_provenance(Existing0, Provenance),
            maybe_persist_enriched_repair(
                Fp, Version, Existing0, Existing
            ),
            {Q, E};
        not_found ->
            Queued0 = #{
                status => queued,
                stage => queued,
                fingerprint => Fp,
                finding_version => Version,
                application => App,
                module => Module,
                finding => Finding,
                created_at => now_iso8601(),
                updated_at => now_iso8601()
            },
            Queued = maps:merge(Queued0, Provenance),
            case ecai_learning_store:compare_and_put_repair(Fp, Version, not_found, Queued) of
                {ok, _} -> {Q + 1, E};
                {error, conflict} -> {Q, E};
                Error -> {Q, [{admission_persist_failed, Fp, Version, Error} | E]}
            end
    end.

analysis_repair_provenance(Analysis) when is_map(Analysis) ->
    Provenance0 = #{},
    Provenance1 = maybe_put_provenance(
        base_commit, maps:get(base_commit, Analysis, undefined), Provenance0
    ),
    Provenance2 = maybe_put_provenance(
        source_sha256, maps:get(source_sha256, Analysis, undefined), Provenance1
    ),
    maybe_put_provenance(
        source_path, analysis_source_path(Analysis), Provenance2
    );
analysis_repair_provenance(_) ->
    #{}.

maybe_put_provenance(_Key, undefined, Provenance) ->
    Provenance;
maybe_put_provenance(_Key, <<>>, Provenance) ->
    Provenance;
maybe_put_provenance(_Key, [], Provenance) ->
    Provenance;
maybe_put_provenance(Key, Value, Provenance) ->
    Provenance#{Key => Value}.

ensure_repair_provenance(Repair, Provenance) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            case maps:get(Key, Acc, undefined) of
                undefined -> Acc#{Key => Value};
                <<>> -> Acc#{Key => Value};
                [] -> Acc#{Key => Value};
                _ -> Acc
            end
        end,
        Repair,
        Provenance
    ).

maybe_persist_enriched_repair(
    _Fp, _Version, Repair, Repair
) ->
    ok;
maybe_persist_enriched_repair(
    Fp, Version, Before, After
) ->
    _ = put_current_repair(Fp, Version, Before, After),
    ok.

put_current_repair(Fp, Version, Before, After) ->
    case ecai_learning_store:compare_and_put_repair(Fp, Version, Before, After) of
        {ok, Stored} -> Stored;
        {error, conflict} ->
            case ecai_learning_store:get_repair(Fp, Version) of
                {ok, Current} -> Current;
                Other -> erlang:error({repair_reload_failed, Fp, Version, Other})
            end;
        Error -> erlang:error({repair_transition_failed, Fp, Version, Error})
    end.

dispatch_persisted(Opts, MaxConcurrent) ->
    Repairs0 = safe_repairs(),
    %% A persisted running state is only authoritative while its supervised
    %% worker still exists. Reconcile orphaned records before considering any
    %% repair for dispatch so they cannot inflate running counts forever or be
    %% restarted without consuming retry budget.
    Repairs1 = reconcile_stale_running(Repairs0, Opts),
    Repairs2 = migrate_legacy_retries(Repairs1, Opts),
    Repairs3 = terminalize_exhausted_retry_waits(Repairs2, Opts),
    {PreflightChanged, PreflightErrors} =
        preflight_orphan_retry_batch(Repairs3, Opts),
    %% Preflight persists its terminal/recovered decisions. Reload only when
    %% something changed so the same retry tick can immediately dispatch a
    %% recovered valid repair without waiting for another 15-second cycle.
    Repairs4 =
        case PreflightChanged of
            0 -> Repairs3;
            _ -> safe_repairs()
        end,
    Repairs = prioritize_repairs(Repairs4),
    lists:foldl(
        fun(Repair, {Started, Errors}) ->
            case active_patch_workers() >= MaxConcurrent of
                true ->
                    {Started, Errors};
                false ->
                    case guarded(fun() -> dispatch_persisted_repair(
                        Repair, Opts, MaxConcurrent, Started, Errors) end) of
                        {ok, Result} -> Result;
                        {error, Error} -> {Started, [{repair_dispatch_failed,
                            maps:get(fingerprint, Repair, undefined), Error} | Errors]}
                    end
            end
        end,
        {0, PreflightErrors},
        Repairs
    ).

terminalize_exhausted_retry_waits(Repairs, Opts) ->
    Limit = positive_int(ecai_patch_retry:retry_limit(Opts), 1),
    lists:map(
        fun(Repair) ->
            terminalize_exhausted_retry_wait(Repair, Limit)
        end,
        Repairs
    ).

terminalize_exhausted_retry_wait(Repair, Limit) when
    is_map(Repair), is_integer(Limit), Limit > 0
->
    Status = maps:get(status, Repair, undefined),
    RetryCount = nonneg_int(maps:get(retry_count, Repair, 0), 0),
    IsRetryWait =
        (Status =:= retry_wait) orelse
            (Status =:= <<"retry_wait">>),
    case IsRetryWait andalso RetryCount >= Limit of
        false ->
            Repair;
        true ->
            Now = now_iso8601(),
            LastError = maps:get(
                last_error,
                Repair,
                maps:get(error, Repair, retry_limit_reached)
            ),
            Base = maps:without(
                [
                    worker_pid,
                    worker_started_at,
                    next_retry_at_ms
                ],
                Repair
            ),
            Terminal = Base#{
                status => failed,
                stage => terminal,
                retryable => false,
                retry_count => RetryCount,
                failure_class =>
                    maps:get(
                        failure_class,
                        Repair,
                        failure_class(LastError)
                    ),
                error => {retry_exhausted, LastError},
                last_error => LastError,
                completed_at => Now,
                updated_at => Now
            },
            persist_terminalized_retry(Repair, Terminal)
    end;
terminalize_exhausted_retry_wait(Repair, _Limit) ->
    Repair.

persist_terminalized_retry(Before, Terminal) ->
    case {maps:get(fingerprint, Terminal, undefined),
            maps:get(finding_version, Terminal, undefined)} of
        {Fp, Version} when is_binary(Fp), is_binary(Version) ->
            put_current_repair(Fp, Version, Before, Terminal);
        _ -> Terminal
    end.

preflight_orphan_retry_batch(Repairs, Opts) ->
    Batch = orphan_preflight_batch(Opts),
    case Batch of
        0 ->
            {0, []};
        _ ->
            Candidates0 = [
                Repair
             || Repair <- Repairs,
                is_orphan_retry_wait(Repair)
            ],
            Candidates = lists:sublist(
                prioritize_repairs(Candidates0),
                Batch
            ),
            lists:foldl(
                fun(Repair, Acc) ->
                    preflight_orphan_retry(Repair, Opts, Acc)
                end,
                {0, []},
                Candidates
            )
    end.

preflight_orphan_retry(Repair, Opts, {Changed, Errors}) ->
    case
        {
            maps:get(application, Repair, undefined),
            maps:get(module, Repair, undefined),
            maps:get(finding, Repair, undefined),
            maps:get(fingerprint, Repair, undefined),
            maps:get(finding_version, Repair, undefined)
        }
    of
        {App, Module, Finding, Fp, Version} when
            is_atom(App),
            is_atom(Module),
            is_map(Finding),
            is_binary(Fp),
            is_binary(Version)
        ->
            try
                ecai_repair_preflight:check(
                    App, Module, Finding, Fp, Version, Opts
                )
            of
                {blocked, _Blocked} ->
                    {Changed + 1, Errors};
                {superseded, _Superseded} ->
                    {Changed + 1, Errors};
                {allow, #{preflight := passed}} ->
                    Recovered = recover_orphan_retry(Repair),
                    _ = put_current_repair(Fp, Version, Repair, Recovered),
                    logger:notice(
                        "ECAI repair rechecked legacy orphan retry "
                        "fingerprint=~p version=~p module=~p",
                        [Fp, Version, Module]
                    ),
                    {Changed + 1, Errors};
                {allow, _Meta} ->
                    %% If preflight was disabled/deferred or analysis is not
                    %% available, preserve the original retry backoff.
                    {Changed, Errors};
                Other ->
                    {
                        Changed,
                        [
                            {orphan_preflight_unexpected, Fp, Version, Other}
                            | Errors
                        ]
                    }
            catch
                Class:Reason:Stacktrace ->
                    {
                        Changed,
                        [
                            {orphan_preflight_failed, Fp, Version, Class, Reason, Stacktrace}
                            | Errors
                        ]
                    }
            end;
        _ ->
            {Changed, Errors}
    end.

is_orphan_retry_wait(Repair) when is_map(Repair) ->
    Status = maps:get(status, Repair, undefined),
    IsRetryWait =
        (Status =:= retry_wait) orelse
            (Status =:= <<"retry_wait">>),
    FailureClass = maps:get(failure_class, Repair, undefined),
    LastError = maps:get(
        last_error, Repair, maps:get(error, Repair, undefined)
    ),
    IsOrphan =
        (FailureClass =:= orphaned_worker) orelse
            case LastError of
                {orphaned_worker, _} -> true;
                _ -> false
            end,
    IsRetryWait andalso IsOrphan andalso
        maps:get(recovery_protocol, Repair, 0) =/= 1;
is_orphan_retry_wait(_) ->
    false.

recover_orphan_retry(Repair) ->
    NowMs = erlang:system_time(millisecond),
    Now = now_iso8601(),
    Base = maps:without(
        [
            worker_pid,
            worker_started_at,
            completed_at,
            failure_class,
            error,
            last_error,
            last_failed_at
        ],
        Repair
    ),
    Base#{
        status => queued,
        stage => queued,
        retryable => false,
        %% Preserve retry_count: the sweep removes the bogus backoff but does
        %% not grant extra retry budget. Setting the timestamp to "now" makes
        %% the recovered record dispatchable in this same retry tick.
        next_retry_at_ms => NowMs,
        recovered_from => orphaned_worker,
        orphan_recovered_at => Now,
        updated_at => Now
    }.

orphan_preflight_batch(Opts) ->
    Configured = maps:get(
        orphan_preflight_batch,
        Opts,
        application:get_env(
            ecai,
            code_patch_orphan_preflight_batch,
            ?DEFAULT_ORPHAN_PREFLIGHT_BATCH
        )
    ),
    %% Bound each background cycle's legacy Git-preflight work.
    erlang:min(
        64,
        nonneg_int(
            Configured, ?DEFAULT_ORPHAN_PREFLIGHT_BATCH
        )
    ).

reconcile_stale_running(Repairs, Opts) ->
    lists:map(
        fun(Repair) ->
            case stale_running(Repair) of
                true ->
                    reconcile_stale_running_repair(Repair, Opts);
                false ->
                    Repair
            end
        end,
        Repairs
    ).

reconcile_stale_running_repair(Repair, Opts) ->
    Key = {maps:get(fingerprint, Repair), maps:get(finding_version, Repair)},
    Reason = maps:get(Key, maps:get(worker_down_reasons, Opts, #{}),
        {orphaned_worker, maps:get(worker_started_at, Repair, undefined)}),
    case ecai_patch_lifecycle:recover(Repair, Reason, Opts) of
        {ok, unchanged} ->
            case ecai_learning_store:get_repair(element(1, Key), element(2, Key)) of
                {ok, Current} -> Current;
                _ -> Repair
            end;
        {ok, Recovered} -> Recovered;
        {error, Error} -> erlang:error(Error)
    end.

migrate_legacy_retries(Repairs, Opts) ->
    NowMs = erlang:system_time(millisecond),
    Now = now_iso8601(),
    Limit = ecai_patch_retry:retry_limit(Opts),
    lists:map(
        fun(Repair) ->
            Status = maps:get(status, Repair, undefined),
            Error = maps:get(error, Repair, undefined),
            RetryCount = maps:get(retry_count, Repair, 0),
            LegacyFailed =
                (Status =:= failed) orelse
                    (Status =:= <<"failed">>),
            case
                LegacyFailed andalso
                    RetryCount < Limit andalso
                    ecai_patch_retry:is_retryable(Error)
            of
                true ->
                    Migrated0 = maps:without(
                        [completed_at, worker_pid, worker_started_at],
                        Repair
                    ),
                    Migrated = Migrated0#{
                        status => retry_wait,
                        stage => inference_wait,
                        retryable => true,
                        last_error => Error,
                        next_retry_at_ms =>
                            maps:get(next_retry_at_ms, Repair, NowMs),
                        updated_at => Now
                    },
                    case
                        {
                            maps:get(fingerprint, Repair, undefined),
                            maps:get(finding_version, Repair, undefined)
                        }
                    of
                        {Fp, Version} when
                            is_binary(Fp), is_binary(Version)
                        ->
                            put_current_repair(Fp, Version, Repair, Migrated);
                        _ ->
                            Repair
                    end;
                false ->
                    Repair
            end
        end,
        Repairs
    ).

dispatch_persisted_repair(Repair, Opts, MaxConcurrent, Started, Errors) ->
    case
        {
            maps:get(application, Repair, undefined),
            maps:get(module, Repair, undefined),
            maps:get(finding, Repair, undefined),
            maps:get(fingerprint, Repair, undefined),
            maps:get(finding_version, Repair, undefined)
        }
    of
        {App, Module, Finding, Fp, Version} when
            is_atom(App),
            is_atom(Module),
            is_map(Finding),
            is_binary(Fp),
            is_binary(Version)
        ->
            maybe_dispatch(
                App,
                Module,
                Finding,
                Fp,
                Version,
                Repair,
                Opts,
                MaxConcurrent,
                Started,
                Errors
            );
        _ ->
            {Started, Errors}
    end.

maybe_dispatch(
    App,
    Module,
    Finding,
    Fp,
    Version,
    Repair,
    Opts,
    MaxConcurrent,
    Q,
    E
) ->
    NowMs = erlang:system_time(millisecond),
    case dispatchable(Repair, Fp, Version, NowMs, Opts) of
        false ->
            {Q, E};
        true ->
            case active_patch_workers() >= MaxConcurrent of
                true ->
                    {Q, E};
                false ->
                    start_repair(
                        App,
                        Module,
                        Finding,
                        Fp,
                        Version,
                        Repair,
                        Opts,
                        Q,
                        E
                    )
            end
    end.

dispatchable(Repair, _Fp, _Version, NowMs, Opts) ->
    Status = maps:get(status, Repair, undefined),
    RetryCount = maps:get(retry_count, Repair, 0),
    RetryAllowed = RetryCount < ecai_patch_retry:retry_limit(Opts),
    case Status of
        %% Running records are reconciled by reconcile_stale_running/2.
        %% Never bypass retry accounting by dispatching one directly here.
        running ->
            false;
        <<"running">> ->
            false;
        failed ->
            RetryAllowed andalso
                ecai_patch_retry:is_retryable(maps:get(error, Repair, undefined));
        <<"failed">> ->
            RetryAllowed andalso
                ecai_patch_retry:is_retryable(maps:get(error, Repair, undefined));
        _ ->
            RetryAllowed andalso ecai_patch_retry:due(Repair, NowMs)
    end.

start_repair(App, Module, Finding, Fp, Version, Repair, Opts, Q, E) ->
    case worker_alive(Fp, Version) of
        true -> {Q, E};
        false -> reserve_repair(App, Module, Finding, Fp, Version, Repair, Opts, Q, E)
    end.

reserve_repair(App, Module, Finding, Fp, Version, Repair, Opts, Q, E) ->
    Now = now_iso8601(),
    Running = (maps:without([completed_at, worker_pid, next_retry_at_ms], Repair))#{
        status => running, stage => inference, retryable => false,
        updated_at => Now, worker_started_at => Now, dispatch_pid => self()},
    case ecai_learning_store:compare_and_put_repair(Fp, Version, Repair, Running) of
        {error, conflict} -> {Q, E};
        {ok, Reserved} ->
            WorkerOpts = maps:merge(Opts,
                #{resume_repair => Repair, worker_id => {Fp, Version},
                    reservation_seq => maps:get(persist_seq, Reserved)}),
            Result = try ecai_patch_sup:propose(App, Module, Finding, WorkerOpts)
                catch Class:Reason -> {error, {worker_start_exception, Class, Reason}} end,
            finish_start(Result, App, Module, Fp, Version, Reserved, Opts, Q, E);
        Other -> {Q, [{repair_reservation_failed, Fp, Version, Other} | E]}
    end.

finish_start({ok, Status, Terminal}, _App, _Module, Fp, Version, _Running, _Opts, Q, E)
  when (Status =:= blocked orelse Status =:= superseded), is_map(Terminal) ->
    %% Preserve the preflight decision and strip old lifecycle metadata without
    %% ever replacing a newer worker/operator transition.
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, #{status := Status} = Current} ->
            Clean = normalize_preflight_terminal(Status, Current, #{}),
            case Clean =:= Current of
                true -> ok;
                false -> _ = put_current_repair(Fp, Version, Current, Clean), ok
            end,
            {Q, E};
        {ok, _Newer} -> {Q, E};
        Error -> {Q, [{preflight_result_unavailable, Fp, Version, Error} | E]}
    end;
finish_start({ok, Pid}, App, Module, Fp, Version, Running, Opts, Q, E) when is_pid(Pid) ->
    attach_started_worker(Pid, App, Module, Fp, Version, Running, Opts, Q + 1, E);
finish_start({ok, Pid, _Info}, App, Module, Fp, Version, Running, Opts, Q, E) when is_pid(Pid) ->
    attach_started_worker(Pid, App, Module, Fp, Version, Running, Opts, Q + 1, E);
finish_start({error, {already_started, Pid}}, App, Module, Fp, Version, Running, Opts, Q, E)
  when is_pid(Pid) ->
    attach_started_worker(Pid, App, Module, Fp, Version, Running, Opts, Q, E);
finish_start(Result, App, Module, Fp, Version, Running, Opts, Q, E) ->
    Reason = case Result of
        {error, R} -> R;
        Other -> {invalid_worker_start_result, Other}
    end,
    Failed = start_failure_record(Running, Reason, Opts),
    case ecai_learning_store:compare_and_put_repair(Fp, Version, Running, Failed) of
        {ok, _} -> {Q, [{App, Module, Fp, Reason} | E]};
        {error, conflict} -> {Q, E};
        Error -> {Q, [{worker_start_persist_failed, Fp, Version, Error} | E]}
    end.

attach_started_worker(Pid, _App, _Module, Fp, Version, Running, Opts, Q, E) ->
    notify_manager(Opts, {patch_worker_started, Fp, Version, Pid}),
    Updated = (maps:remove(dispatch_pid, Running))#{worker_pid => Pid},
    case ecai_learning_store:compare_and_put_repair(Fp, Version, Running, Updated) of
        {ok, _} -> {Q, E};
        %% A fast worker can finish before start_child returns. Do not undo it.
        {error, conflict} -> {Q, E};
        Error -> {Q, [{worker_pid_persist_failed, Fp, Version, Error} | E]}
    end.

notify_manager(Opts, Message) ->
    case maps:get(manager_pid, Opts, whereis(?SERVER)) of
        Pid when is_pid(Pid) -> Pid ! Message, ok;
        _ -> ok
    end.

normalize_preflight_terminal(ExpectedStatus, Terminal0, Running) ->
    Now = now_iso8601(),
    %% Preflight owns the terminal classification. Strip any worker lifecycle
    %% residue from both the provisional running record and older orphan
    %% retries so reconciliation can never see this repair as a live worker.
    Terminal1 = maps:merge(Running, Terminal0),
    Terminal2 = maps:without(
        [
            worker_pid,
            dispatch_pid,
            worker_started_at,
            next_retry_at_ms,
            completed_at
        ],
        Terminal1
    ),
    Terminal2#{
        status => ExpectedStatus,
        retryable => false,
        updated_at => maps:get(updated_at, Terminal0, Now)
    }.

start_failure_record(Repair, Reason, Opts) ->
    ecai_patch_lifecycle:failure_record(Repair, {worker_start_failed, Reason}, Opts).

worker_alive(Fp, Version) ->
    Id = {ecai_patch_worker, Fp, Version},
    lists:any(
        fun
            ({Id0, Pid, _Type, _Modules}) when
                Id0 =:= Id, is_pid(Pid)
            ->
                erlang:is_process_alive(Pid);
            (_) ->
                false
        end,
        safe_patch_children()
    ).

active_patch_workers() ->
    length([
        Pid
     || {_Id, Pid, _Type, _Modules} <- safe_patch_children(),
        is_pid(Pid), erlang:is_process_alive(Pid)
    ]).

safe_patch_children() ->
    case supervisor:which_children(ecai_patch_sup) of
        Children when is_list(Children) -> Children;
        Other -> erlang:error({patch_supervisor_unavailable, Other})
    end.

safe_repairs() ->
    case ecai_learning_store:repairs() of
        Repairs when is_list(Repairs) -> Repairs;
        Other -> erlang:error({learning_store_unavailable, Other})
    end.

repair_counts(Repairs) ->
    lists:foldl(
        fun(Repair, Acc) ->
            Status = maps:get(status, Repair, undefined),
            maps:update_with(Status, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        Repairs
    ).

status_count(Status, Counts) ->
    maps:get(Status, Counts, 0) + maps:get(atom_to_binary(Status, utf8), Counts, 0).

stale_running_count(Repairs) ->
    length([Repair || Repair <- Repairs, stale_running(Repair)]).

stale_running(Repair) when is_map(Repair) ->
    case
        {
            is_running_status(maps:get(status, Repair, undefined)),
            maps:get(fingerprint, Repair, undefined),
            maps:get(finding_version, Repair, undefined)
        }
    of
        {true, Fp, Version} when is_binary(Fp), is_binary(Version) ->
            not ecai_patch_lifecycle:owner_alive(Repair) andalso
                not worker_alive(Fp, Version);
        _ ->
            false
    end;
stale_running(_) ->
    false.

is_running_status(running) -> true;
is_running_status(<<"running">>) -> true;
is_running_status(_) -> false.

failure_summary(Repairs, Opts) ->
    Limit = positive_int(ecai_patch_retry:retry_limit(Opts), 1),
    lists:foldl(
        fun(Repair, Acc0) ->
            Status = maps:get(status, Repair, undefined),
            case is_failure_status(Status) of
                false ->
                    Acc0;
                true ->
                    RetryCount = nonneg_int(maps:get(retry_count, Repair, 0), 0),
                    Error = maps:get(
                        last_error, Repair, maps:get(error, Repair, undefined)
                    ),
                    Retryable =
                        RetryCount < Limit andalso
                            (maps:get(retryable, Repair, false) =:= true orelse
                                safe_retryable(Error)),
                    Class = repair_failure_class(Repair),
                    Acc1 =
                        case {is_failed_status(Status), is_retry_wait_status(Status), Retryable} of
                            {true, _, true} ->
                                maps:update_with(
                                    retryable_failed, fun(N) -> N + 1 end, 1, Acc0
                                );
                            {true, _, false} ->
                                maps:update_with(
                                    failed_terminal, fun(N) -> N + 1 end, 1, Acc0
                                );
                            {false, true, _} ->
                                maps:update_with(
                                    retry_wait, fun(N) -> N + 1 end, 1, Acc0
                                );
                            _ ->
                                Acc0
                        end,
                    ByClass0 = maps:get(by_class, Acc1, #{}),
                    ByClass1 = maps:update_with(
                        Class, fun(N) -> N + 1 end, 1, ByClass0
                    ),
                    Acc1#{by_class => ByClass1}
            end
        end,
        #{
            failed_terminal => 0,
            retryable_failed => 0,
            retry_wait => 0,
            by_class => #{}
        },
        Repairs
    ).

safe_retryable(Error) ->
    try ecai_patch_retry:is_retryable(Error) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

is_failure_status(failed) -> true;
is_failure_status(<<"failed">>) -> true;
is_failure_status(retry_wait) -> true;
is_failure_status(<<"retry_wait">>) -> true;
is_failure_status(_) -> false.

is_failed_status(failed) -> true;
is_failed_status(<<"failed">>) -> true;
is_failed_status(_) -> false.

is_retry_wait_status(retry_wait) -> true;
is_retry_wait_status(<<"retry_wait">>) -> true;
is_retry_wait_status(_) -> false.

repair_failure_class(Repair) ->
    case maps:get(failure_class, Repair, undefined) of
        undefined ->
            failure_class(
                maps:get(last_error, Repair, maps:get(error, Repair, undefined))
            );
        Class ->
            Class
    end.

failure_class({retry_exhausted, Reason}) -> failure_class(Reason);
failure_class({worker_start_failed, _}) -> worker_start_failed;
failure_class({orphaned_worker, _}) -> orphaned_worker;
failure_class({Class, _}) when is_atom(Class) -> Class;
failure_class({Class, _, _}) when is_atom(Class) -> Class;
failure_class(Class) when is_atom(Class) -> Class;
failure_class(_) -> unknown.

prioritize_repairs(Repairs) ->
    Decorated = [
        {repair_order_key(Repair), Repair}
     || Repair <- Repairs
    ],
    [Repair || {_Key, Repair} <- lists:sort(Decorated)].

repair_order_key(Repair) ->
    SourcePath = repair_source_path(Repair),
    {
        source_priority(SourcePath),
        severity_priority(repair_severity(Repair)),
        status_priority(maps:get(status, Repair, undefined)),
        maps:get(next_retry_at_ms, Repair, 0),
        maps:get(created_at, Repair, <<>>),
        maps:get(fingerprint, Repair, <<>>)
    }.

%% Production source is the primary dispatch class. Tests remain queued and
%% repairable, but cannot monopolize workers while src/ findings are due.
source_priority(Path0) ->
    Path = to_binary(Path0),
    case
        {
            binary:match(Path, <<"/src/">>),
            binary:match(Path, <<"/test/">>),
            binary:match(Path, <<"/tests/">>)
        }
    of
        {{_, _}, _, _} -> 0;
        {_, {_, _}, _} -> 2;
        {_, _, {_, _}} -> 2;
        _ -> 1
    end.

repair_source_path(Repair) ->
    case maps:get(source_path, Repair, undefined) of
        Path when is_binary(Path), byte_size(Path) > 0 ->
            Path;
        Path when is_list(Path), Path =/= [] ->
            to_binary(Path);
        _ ->
            lookup_analysis_source_path(
                maps:get(application, Repair, undefined),
                maps:get(module, Repair, undefined)
            )
    end.

lookup_analysis_source_path(App, Module) when
    is_atom(App), is_atom(Module)
->
    try ecai_learning_store:get_analysis(App, Module) of
        {ok, Analysis} when is_map(Analysis) ->
            analysis_source_path(Analysis);
        _ ->
            <<>>
    catch
        _:_ ->
            <<>>
    end;
lookup_analysis_source_path(_, _) ->
    <<>>.

analysis_source_path(Analysis) when is_map(Analysis) ->
    first_source_path([
        maps:get(source_path, Analysis, undefined),
        maps:get(source_name, Analysis, undefined),
        maps:get(repo_path, Analysis, undefined)
    ]);
analysis_source_path(_) ->
    <<>>.

first_source_path([]) ->
    <<>>;
first_source_path([Path | _Rest]) when
    is_binary(Path), byte_size(Path) > 0
->
    Path;
first_source_path([Path | _Rest]) when
    is_list(Path), Path =/= []
->
    to_binary(Path);
first_source_path([_ | Rest]) ->
    first_source_path(Rest).

repair_severity(Repair) ->
    Finding = maps:get(finding, Repair, #{}),
    mget(<<"severity">>, Finding, <<"unknown">>).

severity_priority(Severity0) ->
    Severity = lower_binary(to_binary(Severity0)),
    case Severity of
        <<"critical">> -> 0;
        <<"high">> -> 1;
        <<"medium">> -> 2;
        <<"low">> -> 3;
        <<"info">> -> 4;
        _ -> 5
    end.

lower_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(
        string:lowercase(binary_to_list(Bin))
    ).

status_priority(retry_wait) -> 0;
status_priority(<<"retry_wait">>) -> 0;
status_priority(failed) -> 1;
status_priority(<<"failed">>) -> 1;
status_priority(queued) -> 2;
status_priority(<<"queued">>) -> 2;
status_priority(running) -> 3;
status_priority(<<"running">>) -> 3;
status_priority(_) -> 9.

merge_errors(_Previous, []) -> undefined;
merge_errors(_Previous, Errors) -> Errors.

finding_fingerprint(Module, Finding) ->
    case mget(<<"fingerprint">>, Finding, undefined) of
        Fp when is_binary(Fp), byte_size(Fp) > 0 -> Fp;
        _ ->
            Issue = to_binary(mget(<<"issue_key">>, Finding, <<"unknown">>)),
            Data = <<(atom_to_binary(Module, utf8))/binary, 0, Issue/binary>>,
            iolist_to_binary([
                io_lib:format("~2.16.0b", [B])
             || <<B>> <= crypto:hash(sha256, Data)
            ])
    end.

patchable(Finding, Opts) when is_map(Finding) ->
    Status = mget(<<"status">>, Finding, <<"open">>),
    Severity = mget(<<"severity">>, Finding, <<"info">>),
    IncludeInfo = maps:get(
        include_info,
        Opts,
        application:get_env(ecai, code_patch_include_info, false)
    ),
    Status =/= <<"resolved">> andalso (IncludeInfo orelse Severity =/= <<"info">>);
patchable(_, _) ->
    false.

existing_module_atom(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try
        {ok, binary_to_existing_atom(Bin, utf8)}
    catch
        error:badarg -> {error, {unknown_module, Bin}}
    end;
existing_module_atom(Other) ->
    {error, {invalid_module, Other}}.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} ->
            V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) ->
    Default.

nonneg_int(V, _Default) when is_integer(V), V >= 0 -> V;
nonneg_int(_, Default) -> Default.

positive_int(V, _Default) when is_integer(V), V > 0 -> V;
positive_int(_, Default) -> Default.

now_iso8601() ->
    to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

production_source_precedes_critical_test_test() ->
    Src = priority_test_repair(
        <<"apps/damage/src/a.erl">>,
        <<"low">>,
        queued,
        <<"src">>
    ),
    Test = priority_test_repair(
        <<"apps/damage/test/a_tests.erl">>,
        <<"critical">>,
        queued,
        <<"test">>
    ),
    ?assert(repair_order_key(Src) < repair_order_key(Test)).

severity_orders_within_source_class_test() ->
    High = priority_test_repair(
        <<"apps/ecai/src/high.erl">>,
        <<"high">>,
        queued,
        <<"high">>
    ),
    Medium = priority_test_repair(
        <<"apps/ecai/src/medium.erl">>,
        <<"medium">>,
        queued,
        <<"medium">>
    ),
    ?assert(repair_order_key(High) < repair_order_key(Medium)).

retry_precedes_new_queue_within_same_class_test() ->
    Retry = priority_test_repair(
        <<"apps/erm/src/a.erl">>,
        <<"high">>,
        retry_wait,
        <<"retry">>
    ),
    Queued = priority_test_repair(
        <<"apps/erm/src/b.erl">>,
        <<"high">>,
        queued,
        <<"queued">>
    ),
    ?assert(repair_order_key(Retry) < repair_order_key(Queued)).

unknown_source_sits_between_src_and_test_test() ->
    ?assert(
        source_priority(<<"apps/ecai/src/a.erl">>) <
            source_priority(<<>>)
    ),
    ?assert(
        source_priority(<<>>) <
            source_priority(<<"apps/ecai/test/a_tests.erl">>)
    ).

analysis_repair_provenance_test() ->
    Analysis = #{
        base_commit => <<"0123456789abcdef">>,
        source_sha256 => <<"source-sha">>,
        source_path => <<"apps/ecai/src/ecai_patch_retry.erl">>
    },
    ?assertEqual(
        #{
            base_commit => <<"0123456789abcdef">>,
            source_sha256 => <<"source-sha">>,
            source_path => <<"apps/ecai/src/ecai_patch_retry.erl">>
        },
        analysis_repair_provenance(Analysis)
    ).

ensure_repair_provenance_fills_missing_fields_test() ->
    Repair = #{status => queued, source_path => <<>>},
    Provenance = #{
        base_commit => <<"base-a">>,
        source_sha256 => <<"sha-a">>,
        source_path => <<"apps/ecai/src/a.erl">>
    },
    Enriched = ensure_repair_provenance(Repair, Provenance),
    ?assertEqual(<<"base-a">>, maps:get(base_commit, Enriched)),
    ?assertEqual(<<"sha-a">>, maps:get(source_sha256, Enriched)),
    ?assertEqual(<<"apps/ecai/src/a.erl">>, maps:get(source_path, Enriched)).

ensure_repair_provenance_preserves_existing_generation_test() ->
    Repair = #{
        base_commit => <<"base-original">>,
        source_sha256 => <<"sha-original">>,
        source_path => <<"apps/ecai/src/original.erl">>
    },
    Provenance = #{
        base_commit => <<"base-new">>,
        source_sha256 => <<"sha-new">>,
        source_path => <<"apps/ecai/src/new.erl">>
    },
    ?assertEqual(Repair, ensure_repair_provenance(Repair, Provenance)).

priority_test_repair(SourcePath, Severity, Status, Fingerprint) ->
    #{
        source_path => SourcePath,
        finding => #{<<"severity">> => Severity},
        status => Status,
        next_retry_at_ms => 0,
        created_at => <<"2026-09-30T00:00:00Z">>,
        fingerprint => Fingerprint
    }.

-endif.
