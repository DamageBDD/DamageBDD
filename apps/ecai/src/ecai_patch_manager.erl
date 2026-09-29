-module(ecai_patch_manager).
-behaviour(gen_server).

-export([start_link/0, start_link/1, scan_now/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 60000).
-define(DEFAULT_RETRY_TICK, 15000).
-define(DEFAULT_MAX_CONCURRENT, 2).

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
    last_error = undefined
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
scan_now() -> gen_server:cast(?SERVER, scan_now).
status() -> gen_server:call(?SERVER, status).

init(Opts) ->
    Interval = maps:get(interval_ms, Opts,
        application:get_env(ecai, code_patch_scan_interval_ms, ?DEFAULT_INTERVAL)),
    RetryTick = positive_int(
        maps:get(retry_tick_ms, Opts,
            application:get_env(ecai, code_patch_retry_tick_ms, ?DEFAULT_RETRY_TICK)),
        ?DEFAULT_RETRY_TICK),
    MaxConcurrent = positive_int(
        maps:get(max_concurrent, Opts,
            application:get_env(ecai, code_patch_max_concurrent, ?DEFAULT_MAX_CONCURRENT)),
        ?DEFAULT_MAX_CONCURRENT),
    erlang:send_after(1000, self(), retry_tick),
    erlang:send_after(10000, self(), scan),
    {ok, #state{
        interval_ms = Interval,
        retry_tick_ms = RetryTick,
        max_concurrent = MaxConcurrent,
        opts = Opts
    }}.

handle_call(status, _From, State) ->
    Repairs = safe_repairs(),
    {reply, #{
        cycles => State#state.cycles,
        queued => State#state.queued,
        retried => State#state.retried,
        active => active_patch_workers(),
        max_concurrent => State#state.max_concurrent,
        repair_statuses => repair_counts(Repairs),
        last_run_at => State#state.last_run_at,
        last_retry_at => State#state.last_retry_at,
        last_error => State#state.last_error
    }, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(scan_now, State) ->
    self() ! retry_tick,
    self() ! scan,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(retry_tick, State0) ->
    {Started, Errors} = dispatch_persisted(State0#state.opts,
                                           State0#state.max_concurrent),
    State1 = State0#state{
        retried = State0#state.retried + Started,
        last_retry_at = now_iso8601(),
        last_error = merge_errors(State0#state.last_error, Errors)
    },
    erlang:send_after(State1#state.retry_tick_ms, self(), retry_tick),
    {noreply, State1};
handle_info(scan, State0) ->
    case learning_ready(State0#state.opts) of
        false ->
            State1 = State0#state{
                cycles = State0#state.cycles + 1,
                last_run_at = now_iso8601(),
                last_error = learning_not_ready
            },
            erlang:send_after(State1#state.interval_ms, self(), scan),
            {noreply, State1};
        true ->
            {Queued, Errors} = lists:foldl(fun(App, {Q, E}) ->
                case safe_app_findings(App) of
                    {ok, Reports} ->
                        {Q1, E1} = process_reports(
                            App, Reports, State0#state.opts,
                            State0#state.max_concurrent),
                        {Q + Q1, E1 ++ E};
                    {error, Reason} ->
                        {Q, [{App, Reason} | E]}
                end
            end, {0, []}, ?APPS),
            State1 = State0#state{
                cycles = State0#state.cycles + 1,
                queued = State0#state.queued + Queued,
                last_run_at = now_iso8601(),
                last_error = case Errors of [] -> undefined; _ -> Errors end
            },
            erlang:send_after(State1#state.interval_ms, self(), scan),
            {noreply, State1}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

learning_ready(Opts) ->
    Require = maps:get(require_global_learning, Opts,
        application:get_env(ecai, code_patch_require_global_learning, true)),
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
                LearnerReady = case ecai_codebase_learner:status() of
                    #{phase := idle, ready := true, last_completed_at := Completed}
                      when Completed =/= undefined -> true;
                    _ -> false
                end,
                AppsReady = lists:all(fun(App) ->
                    ecai_learning_store:get_app_knowledge(App) =/= not_found
                end, ?APPS),
                LearnerReady andalso AppsReady andalso
                    ecai_learning_store:get_global_knowledge() =/= not_found
            catch
                exit:{noproc, _} -> false;
                exit:{timeout, _} -> false;
                _:_ -> false
            end
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
    lists:foldl(fun(Report, {Q, E}) ->
        ModuleBin = mget(<<"module">>, Report, <<>>),
        case existing_module_atom(ModuleBin) of
            {error, Reason} -> {Q, [Reason | E]};
            {ok, Module} ->
                Findings = mget(<<"findings">>, Report, []),
                process_findings(App, Module, Findings, Opts, MaxConcurrent, Q, E)
        end
    end, {0, []}, Reports).

process_findings(_App, _Module, [], _Opts, _MaxConcurrent, Q, E) ->
    {Q, E};
process_findings(App, Module, [Finding | Rest], Opts, MaxConcurrent, Q0, E0) ->
    {Q1, E1} =
        case patchable(Finding, Opts) of
            false ->
                {Q0, E0};
            true ->
                case ecai_learning_store:get_analysis(App, Module) of
                    not_found ->
                        ecai_codebase_learner:module_changed(App, Module),
                        {Q0, E0};
                    {ok, _} ->
                        queue_if_needed(
                            App, Module, Finding, Opts, MaxConcurrent, Q0, E0)
                end
        end,
    process_findings(App, Module, Rest, Opts, MaxConcurrent, Q1, E1).

queue_if_needed(App, Module, Finding, Opts, MaxConcurrent, Q, E) ->
    Fp = finding_fingerprint(Module, Finding),
    Version = ecai_code_context:finding_version(App, Module, Finding),
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, Existing} ->
            maybe_dispatch(
                App, Module, Finding, Fp, Version, Existing,
                Opts, MaxConcurrent, Q, E);
        not_found ->
            Queued = #{
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
            ok = ecai_learning_store:put_repair(Fp, Version, Queued),
            maybe_dispatch(
                App, Module, Finding, Fp, Version, Queued,
                Opts, MaxConcurrent, Q, E)
    end.

dispatch_persisted(Opts, MaxConcurrent) ->
    Repairs0 = safe_repairs(),
    Repairs1 = migrate_legacy_retries(Repairs0, Opts),
    Repairs = lists:sort(fun repair_order/2, Repairs1),
    lists:foldl(
        fun(Repair, {Started, Errors}) ->
            case active_patch_workers() >= MaxConcurrent of
                true ->
                    {Started, Errors};
                false ->
                    dispatch_persisted_repair(
                        Repair, Opts, MaxConcurrent, Started, Errors)
            end
        end,
        {0, []},
        Repairs).

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
            case LegacyFailed andalso
                 RetryCount < Limit andalso
                 ecai_patch_retry:is_retryable(Error) of
                true ->
                    Migrated0 = maps:without(
                        [completed_at, worker_pid, worker_started_at],
                        Repair),
                    Migrated = Migrated0#{
                        status => retry_wait,
                        stage => inference_wait,
                        retryable => true,
                        last_error => Error,
                        next_retry_at_ms =>
                            maps:get(next_retry_at_ms, Repair, NowMs),
                        updated_at => Now
                    },
                    case {
                        maps:get(fingerprint, Repair, undefined),
                        maps:get(finding_version, Repair, undefined)
                    } of
                        {Fp, Version}
                                when is_binary(Fp), is_binary(Version) ->
                            _ = ecai_learning_store:put_repair(
                                Fp, Version, Migrated),
                            Migrated;
                        _ ->
                            Repair
                    end;
                false ->
                    Repair
            end
        end,
        Repairs).

dispatch_persisted_repair(Repair, Opts, MaxConcurrent, Started, Errors) ->
    case {
        maps:get(application, Repair, undefined),
        maps:get(module, Repair, undefined),
        maps:get(finding, Repair, undefined),
        maps:get(fingerprint, Repair, undefined),
        maps:get(finding_version, Repair, undefined)
    } of
        {App, Module, Finding, Fp, Version}
                when is_atom(App), is_atom(Module), is_map(Finding),
                     is_binary(Fp), is_binary(Version) ->
            maybe_dispatch(
                App, Module, Finding, Fp, Version, Repair,
                Opts, MaxConcurrent, Started, Errors);
        _ ->
            {Started, Errors}
    end.

maybe_dispatch(App, Module, Finding, Fp, Version, Repair,
               Opts, MaxConcurrent, Q, E) ->
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
                        App, Module, Finding, Fp, Version, Repair,
                        Opts, Q, E)
            end
    end.

dispatchable(Repair, Fp, Version, NowMs, Opts) ->
    Status = maps:get(status, Repair, undefined),
    RetryCount = maps:get(retry_count, Repair, 0),
    RetryAllowed = RetryCount < ecai_patch_retry:retry_limit(Opts),
    case Status of
        running -> not worker_alive(Fp, Version);
        <<"running">> -> not worker_alive(Fp, Version);
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
    Now = now_iso8601(),
    Running0 = maps:without([completed_at, worker_pid], Repair),
    Running = Running0#{
        status => running,
        stage => inference,
        retryable => false,
        updated_at => Now,
        worker_started_at => Now
    },
    ok = ecai_learning_store:put_repair(Fp, Version, Running),
    WorkerOpts = maps:merge(
        Opts,
        #{resume_repair => Repair, worker_id => {Fp, Version}}),
    case ecai_patch_sup:propose(App, Module, Finding, WorkerOpts) of
        {ok, Pid} ->
            ok = ecai_learning_store:put_repair(
                Fp, Version, Running#{worker_pid => Pid}),
            {Q + 1, E};
        {ok, Pid, _Info} ->
            ok = ecai_learning_store:put_repair(
                Fp, Version, Running#{worker_pid => Pid}),
            {Q + 1, E};
        {error, {already_started, _Pid}} ->
            {Q, E};
        {error, already_present} ->
            {Q, E};
        {error, Reason} ->
            StartFailed = start_failure_record(Running, Reason, Opts),
            ok = ecai_learning_store:put_repair(Fp, Version, StartFailed),
            {Q, [{App, Module, Fp, Reason} | E]}
    end.

start_failure_record(Repair, Reason, Opts) ->
    RetryCount = maps:get(retry_count, Repair, 0) + 1,
    NowMs = erlang:system_time(millisecond),
    Now = now_iso8601(),
    Limit = ecai_patch_retry:retry_limit(Opts),
    case RetryCount > Limit of
        true ->
            (maps:without([worker_pid], Repair))#{
                status => failed,
                stage => terminal,
                retryable => false,
                retry_count => RetryCount,
                error => {retry_exhausted, {worker_start_failed, Reason}},
                last_error => {worker_start_failed, Reason},
                completed_at => Now,
                updated_at => Now
            };
        false ->
            (maps:without([worker_pid, completed_at], Repair))#{
                status => retry_wait,
                stage => dispatch_wait,
                retryable => true,
                retry_count => RetryCount,
                error => {worker_start_failed, Reason},
                last_error => {worker_start_failed, Reason},
                next_retry_at_ms =>
                    ecai_patch_retry:next_retry_at_ms(
                        RetryCount, NowMs, Opts),
                updated_at => Now
            }
    end.

worker_alive(Fp, Version) ->
    Id = {ecai_patch_worker, Fp, Version},
    lists:any(
        fun
            ({Id0, Pid, _Type, _Modules})
                    when Id0 =:= Id, is_pid(Pid) ->
                true;
            (_) ->
                false
        end,
        safe_patch_children()).

active_patch_workers() ->
    length([
        Pid
     || {_Id, Pid, _Type, _Modules} <- safe_patch_children(),
        is_pid(Pid)
    ]).

safe_patch_children() ->
    try supervisor:which_children(ecai_patch_sup) of
        Children when is_list(Children) ->
            Children;
        _ ->
            []
    catch
        _Class:_Reason ->
            []
    end.

safe_repairs() ->
    try ecai_learning_store:repairs() of
        Repairs when is_list(Repairs) ->
            Repairs;
        _ ->
            []
    catch
        _Class:_Reason ->
            []
    end.

repair_counts(Repairs) ->
    lists:foldl(
        fun(Repair, Acc) ->
            Status = maps:get(status, Repair, undefined),
            maps:update_with(Status, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        Repairs).

repair_order(A, B) ->
    repair_order_key(A) < repair_order_key(B).

repair_order_key(Repair) ->
    {
        status_priority(maps:get(status, Repair, undefined)),
        maps:get(next_retry_at_ms, Repair, 0),
        maps:get(created_at, Repair, <<>>),
        maps:get(fingerprint, Repair, <<>>)
    }.

status_priority(retry_wait) -> 0;
status_priority(<<"retry_wait">>) -> 0;
status_priority(failed) -> 1;
status_priority(<<"failed">>) -> 1;
status_priority(running) -> 2;
status_priority(<<"running">>) -> 2;
status_priority(queued) -> 3;
status_priority(<<"queued">>) -> 3;
status_priority(_) -> 9.

merge_errors(Previous, []) -> Previous;
merge_errors(_Previous, Errors) -> Errors.

finding_fingerprint(Module, Finding) ->
    case mget(<<"fingerprint">>, Finding, undefined) of
        Fp when is_binary(Fp), byte_size(Fp) > 0 -> Fp;
        _ ->
            Issue = to_binary(mget(<<"issue_key">>, Finding, <<"unknown">>)),
            Data = <<(atom_to_binary(Module, utf8))/binary, 0, Issue/binary>>,
            iolist_to_binary([io_lib:format("~2.16.0b", [B]) ||
                              <<B>> <= crypto:hash(sha256, Data)])
    end.

patchable(Finding, Opts) when is_map(Finding) ->
    Status = mget(<<"status">>, Finding, <<"open">>),
    Severity = mget(<<"severity">>, Finding, <<"info">>),
    IncludeInfo = maps:get(include_info, Opts,
        application:get_env(ecai, code_patch_include_info, false)),
    Status =/= <<"resolved">> andalso (IncludeInfo orelse Severity =/= <<"info">>);
patchable(_, _) -> false.

existing_module_atom(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try {ok, binary_to_existing_atom(Bin, utf8)}
    catch error:badarg -> {error, {unknown_module, Bin}} end;
existing_module_atom(Other) -> {error, {invalid_module, Other}}.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

positive_int(V, _Default) when is_integer(V), V > 0 -> V;
positive_int(_, Default) -> Default.

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
