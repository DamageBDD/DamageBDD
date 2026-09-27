-module(ecai_patch_manager).
-behaviour(gen_server).

-export([start_link/0, start_link/1, scan_now/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 60000).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL,
    opts = #{},
    state = starting,
    cycles = 0,
    queued = 0,
    resumed = 0,
    last_run_at = undefined,
    last_recovery_at = undefined,
    last_error = undefined,
    timer_ref = undefined,
    next_run_at_ms = undefined
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
scan_now() -> gen_server:cast(?SERVER, scan_now).
status() -> gen_server:call(?SERVER, status).

init(Opts) ->
    Interval = maps:get(
        interval_ms,
        Opts,
        application:get_env(ecai, code_patch_scan_interval_ms, ?DEFAULT_INTERVAL)
    ),
    Base = #state{interval_ms = Interval, opts = Opts},
    State0 = restore_checkpoint(Base),
    VerifyOpts = maps:merge(Opts, maps:get(verifier, Opts, #{})),
    _ = maybe_cleanup_stale_worktrees(VerifyOpts),
    self() ! recover_jobs,
    State1 = schedule_restored_scan(State0),
    _ = checkpoint(State1),
    {ok, State1}.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Req, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(scan_now, State0) ->
    State1 = cancel_scan_timer(State0),
    self() ! scan,
    _ = checkpoint(State1),
    {noreply, State1};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(recover_jobs, State0) ->
    case learning_ready(State0#state.opts) of
        false ->
            State1 = State0#state{
                state = waiting_for_learning,
                queued = pending_count(),
                last_error = undefined,
                last_recovery_at = now_iso8601()
            },
            _ = checkpoint(State1),
            {noreply, State1};
        true ->
            {Resumed, Errors} = resume_pending_repairs(State0#state.opts),
            State1 = State0#state{
                state = ready,
                queued = pending_count(),
                resumed = State0#state.resumed + Resumed,
                last_recovery_at = now_iso8601(),
                last_error = case Errors of [] -> undefined; _ -> Errors end
            },
            _ = checkpoint(State1),
            {noreply, State1}
    end;

handle_info(scan, State0) ->
    StateA = cancel_scan_timer(State0),
    case learning_ready(StateA#state.opts) of
        false ->
            State1 = schedule_next_scan(StateA#state{
                state = waiting_for_learning,
                cycles = StateA#state.cycles + 1,
                queued = pending_count(),
                last_run_at = now_iso8601(),
                last_error = undefined
            }),
            _ = checkpoint(State1),
            {noreply, State1};
        true ->
            {QueuedNew, ScanErrors} = lists:foldl(
                fun(App, {Q, E}) ->
                    case catch ecai_vuln_monitor:app_findings(App) of
                        Reports when is_list(Reports) ->
                            {Q1, E1} = process_reports(App, Reports, StateA#state.opts),
                            {Q + Q1, E1 ++ E};
                        {'EXIT', Reason} -> {Q, [{App, Reason} | E]};
                        {error, Reason} -> {Q, [{App, Reason} | E]};
                        Other -> {Q, [{App, {unexpected_findings_response, Other}} | E]}
                    end
                end,
                {0, []},
                ?APPS
            ),
            {Resumed, ResumeErrors} = resume_pending_repairs(StateA#state.opts),
            Errors = ScanErrors ++ ResumeErrors,
            State1 = schedule_next_scan(StateA#state{
                state = ready,
                cycles = StateA#state.cycles + 1,
                queued = pending_count(),
                resumed = StateA#state.resumed + Resumed,
                last_run_at = now_iso8601(),
                last_error = case Errors of [] -> undefined; _ -> Errors end
            }),
            _ = QueuedNew,
            _ = checkpoint(State1),
            {noreply, State1}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State0) ->
    State1 = cancel_timer_preserve_deadline(State0),
    _ = checkpoint(State1),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

learning_ready(Opts) ->
    Require = maps:get(
        require_global_learning,
        Opts,
        application:get_env(ecai, code_patch_require_global_learning, true)
    ),
    case Require of
        false -> true;
        true ->
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
    end.

process_reports(App, Reports, Opts) ->
    lists:foldl(fun(Report, {Q, E}) ->
        ModuleBin = mget(<<"module">>, Report, <<>>),
        case existing_module_atom(ModuleBin) of
            {error, Reason} -> {Q, [Reason | E]};
            {ok, Module} ->
                Findings = mget(<<"findings">>, Report, []),
                process_findings(App, Module, Findings, Opts, Q, E)
        end
    end, {0, []}, Reports).

process_findings(_App, _Module, [], _Opts, Q, E) -> {Q, E};
process_findings(App, Module, [Finding | Rest], Opts, Q0, E0) ->
    {Q1, E1} = case patchable(Finding, Opts) of
        false -> {Q0, E0};
        true ->
            case ecai_learning_store:get_analysis(App, Module) of
                not_found ->
                    ecai_codebase_learner:module_changed(App, Module),
                    {Q0, E0};
                {ok, _} -> queue_or_resume(App, Module, Finding, Opts, Q0, E0)
            end
    end,
    process_findings(App, Module, Rest, Opts, Q1, E1).

queue_or_resume(App, Module, Finding, _Opts, Q, E) ->
    Fp = finding_fingerprint(Module, Finding),
    Version = ecai_code_context:finding_version(App, Module, Finding),
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, Existing} when is_map(Existing) ->
            case pending_repair(Existing) of
                false -> {Q, E};
                true -> {Q, E}
            end;
        not_found ->
            Now = now_iso8601(),
            Queued = #{
                status => queued,
                stage => queued,
                fingerprint => Fp,
                finding_version => Version,
                application => App,
                module => Module,
                finding => Finding,
                attempt => 1,
                created_at => Now,
                updated_at => Now
            },
            ok = ecai_learning_store:put_repair(Fp, Version, Queued),
            {Q + 1, E}
    end.

resume_pending_repairs(Opts) ->
    lists:foldl(
        fun(Repair, {Count, Errors}) ->
            case pending_repair(Repair) of
                false -> {Count, Errors};
                true ->
                    App = maps:get(application, Repair, undefined),
                    Module = maps:get(module, Repair, undefined),
                    Finding = maps:get(finding, Repair, #{}),
                    Fp = maps:get(fingerprint, Repair, <<>>),
                    Version = maps:get(finding_version, Repair, <<>>),
                    case valid_job_identity(App, Module, Fp, Version) of
                        false ->
                            {Count, [{invalid_persisted_repair, Fp, Version} | Errors]};
                        true ->
                            case ensure_repair_started(App, Module, Finding, Fp, Version, Opts) of
                                ok -> {Count + 1, Errors};
                                {error, Reason} ->
                                    _ = mark_failed_to_start(Repair, Reason),
                                    {Count, [{App, Module, Fp, Reason} | Errors]}
                            end
                    end
            end
        end,
        {0, []},
        ecai_learning_store:repairs()
    ).

mark_failed_to_start(Repair, Reason) ->
    Fp = maps:get(fingerprint, Repair, <<>>),
    Version = maps:get(finding_version, Repair, <<>>),
    ecai_learning_store:put_repair(Fp, Version, Repair#{
        status => failed_to_start,
        stage => queued,
        error => Reason,
        updated_at => now_iso8601()
    }).

ensure_repair_started(App, Module, Finding, Fp, Version, Opts) ->
    StartOpts = Opts#{fingerprint => Fp, finding_version => Version},
    case ecai_patch_sup:propose(App, Module, Finding, StartOpts) of
        {ok, _Pid} -> ok;
        {ok, _Pid, _Info} -> ok;
        {error, Reason} -> {error, Reason}
    end.

pending_repair(Repair) when is_map(Repair) ->
    Status = maps:get(status, Repair, queued),
    lists:member(Status, [queued, running, failed_to_start]);
pending_repair(_) -> false.

pending_count() ->
    length([R || R <- ecai_learning_store:repairs(), pending_repair(R)]).

valid_job_identity(App, Module, Fp, Version) ->
    lists:member(App, ?APPS) andalso is_atom(Module) andalso
        is_binary(Fp) andalso byte_size(Fp) > 0 andalso
        is_binary(Version) andalso byte_size(Version) > 0.

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
    IncludeInfo = maps:get(
        include_info,
        Opts,
        application:get_env(ecai, code_patch_include_info, false)
    ),
    Status =/= <<"resolved">> andalso (IncludeInfo orelse Severity =/= <<"info">>);
patchable(_, _) -> false.

maybe_cleanup_stale_worktrees(VerifyOpts) ->
    case catch supervisor:which_children(ecai_patch_sup) of
        Children when is_list(Children) ->
            Active = [Pid || {_Id, Pid, _Type, _Mods} <- Children, is_pid(Pid)],
            case Active of
                [] -> catch ecai_patch_verifier:cleanup_stale(VerifyOpts);
                _ -> {ok, #{skipped => active_patch_workers, count => length(Active)}}
            end;
        _ -> catch ecai_patch_verifier:cleanup_stale(VerifyOpts)
    end.

restore_checkpoint(Base) ->
    case ecai_learning_store:get_checkpoint(patch_manager) of
        {ok, #{schema_version := 1} = Cp} ->
            Base#state{
                state = maps:get(state, Cp, starting),
                cycles = maps:get(cycles, Cp, 0),
                queued = maps:get(queued, Cp, 0),
                resumed = maps:get(resumed, Cp, 0),
                last_run_at = maps:get(last_run_at, Cp, undefined),
                last_recovery_at = maps:get(last_recovery_at, Cp, undefined),
                last_error = maps:get(last_error, Cp, undefined),
                next_run_at_ms = maps:get(next_run_at_ms, Cp, undefined)
            };
        _ -> Base
    end.

checkpoint(State) ->
    ecai_learning_store:put_checkpoint(patch_manager, #{
        schema_version => 1,
        state => State#state.state,
        cycles => State#state.cycles,
        queued => State#state.queued,
        active_jobs => State#state.queued,
        resumed => State#state.resumed,
        last_run_at => State#state.last_run_at,
        last_recovery_at => State#state.last_recovery_at,
        last_error => State#state.last_error,
        next_run_at_ms => State#state.next_run_at_ms
    }).

status_map(State) ->
    #{
        state => State#state.state,
        cycles => State#state.cycles,
        queued => State#state.queued,
        resumed => State#state.resumed,
        last_run_at => State#state.last_run_at,
        last_recovery_at => State#state.last_recovery_at,
        last_error => State#state.last_error,
        next_run_at_ms => State#state.next_run_at_ms
    }.

schedule_restored_scan(State = #state{next_run_at_ms = undefined}) ->
    schedule_scan_after(State, 10000);
schedule_restored_scan(State = #state{next_run_at_ms = Next}) ->
    Delay = max(0, Next - erlang:system_time(millisecond)),
    schedule_scan_after(State, Delay).

schedule_next_scan(State) ->
    schedule_scan_after(State, State#state.interval_ms).

schedule_scan_after(State0, Delay) ->
    TRef = erlang:send_after(Delay, self(), scan),
    Next = erlang:system_time(millisecond) + Delay,
    State0#state{timer_ref = TRef, next_run_at_ms = Next}.

cancel_scan_timer(State = #state{timer_ref = undefined}) ->
    State#state{next_run_at_ms = undefined};
cancel_scan_timer(State = #state{timer_ref = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{timer_ref = undefined, next_run_at_ms = undefined}.

cancel_timer_preserve_deadline(State = #state{timer_ref = undefined}) -> State;
cancel_timer_preserve_deadline(State = #state{timer_ref = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{timer_ref = undefined}.

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

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
