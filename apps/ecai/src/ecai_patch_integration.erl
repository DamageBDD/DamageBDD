-module(ecai_patch_integration).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    child_spec/1,
    run_now/0,
    run_now/1,
    status/0,
    jobs/0,
    job/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ecai_patch_integration_dets).
-define(DEFAULT_INTERVAL, 60000).
-define(MAX_DIAGNOSTIC_BYTES, 65536).
-define(MAX_PATCH_EXCERPT_BYTES, 8192).

-record(state, {
    tab,
    state_root,
    file,
    repo_root,
    interval_ms = ?DEFAULT_INTERVAL,
    current = undefined,
    cycles = 0,
    last_run_at = undefined,
    last_error = undefined,
    opts = #{}
}).

start_link() -> start_link(#{}).
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

child_spec(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

run_now() -> run_now(#{}).
run_now(Opts) when is_map(Opts) -> gen_server:cast(?SERVER, {run_now, Opts}).
status() -> gen_server:call(?SERVER, status).
jobs() -> gen_server:call(?SERVER, jobs, infinity).
job(JobId) -> gen_server:call(?SERVER, {job, to_binary(JobId)}).

init(Opts) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root(Opts) of
        {error, Reason} -> {stop, {cannot_resolve_state_root, Reason}};
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, "code_integration_jobs.dets"),
            RepoRoot = repo_root(Opts),
            Interval = maps:get(interval_ms, Opts,
                application:get_env(ecai, code_integration_interval_ms, ?DEFAULT_INTERVAL)),
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 10000}]) of
                {error, Reason} -> {stop, {cannot_open_integration_store, File, Reason}};
                {ok, ?TABLE} ->
                    ok = recover_interrupted_jobs(?TABLE),
                    State = #state{tab = ?TABLE, state_root = Root, file = File,
                                   repo_root = RepoRoot, interval_ms = Interval, opts = Opts},
                    erlang:send_after(5000, self(), scan),
                    {ok, State}
            end
    end.

handle_call(status, _From, State) ->
    Info = case dets:info(State#state.tab) of undefined -> []; I -> I end,
    Reply = #{
        current => current_summary(State#state.current),
        cycles => State#state.cycles,
        last_run_at => State#state.last_run_at,
        last_error => State#state.last_error,
        repo_root => State#state.repo_root,
        state_root => State#state.state_root,
        store_file => State#state.file,
        table_info => Info,
        job_counts => job_counts(State#state.tab)
    },
    {reply, Reply, State};
handle_call(jobs, _From, State) ->
    {reply, collect_jobs(State#state.tab), State};
handle_call({job, JobId}, _From, State) ->
    {reply, lookup_job(State#state.tab, JobId), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({run_now, RunOpts}, State) ->
    self() ! {scan, RunOpts},
    {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(scan, State) ->
    handle_scan(#{}, State);
handle_info({scan, RunOpts}, State) ->
    handle_scan(RunOpts, State);
handle_info({integration_result, Ref, JobId, ExecResult},
            State = #state{current = #{ref := Ref, job_id := JobId}}) ->
    _ = erlang:demonitor(maps:get(mon, State#state.current), [flush]),
    State1 = complete_job(JobId, ExecResult, State),
    schedule_next(State1#state.interval_ms),
    {noreply, State1#state{current = undefined}};
handle_info({'DOWN', Mon, process, _Pid, Reason},
            State = #state{current = #{mon := Mon, job_id := JobId}}) ->
    case Reason of
        normal -> {noreply, State};
        _ ->
            Job0 = value_or_empty(lookup_job(State#state.tab, JobId)),
            Job1 = Job0#{status => queued, last_error => {worker_down, Reason},
                         resumed_at => now_iso8601(),
                         resume_count => maps:get(resume_count, Job0, 0) + 1},
            ok = put_job(State#state.tab, Job1),
            schedule_next(1000),
            {noreply, State#state{current = undefined, last_error = {JobId, Reason}}}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    _ = dets:sync(State#state.tab),
    _ = dets:close(State#state.tab),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

handle_scan(_RunOpts, State = #state{current = Current}) when Current =/= undefined ->
    {noreply, State};
handle_scan(RunOpts, State0) ->
    EffectiveOpts = maps:merge(State0#state.opts, RunOpts),
    RepoRoot = repo_root(EffectiveOpts),
    %% Refresh only while idle. A running integration job remains pinned to the
    %% repository root/base commit it started with.
    StateR = State0#state{repo_root = RepoRoot},
    StateA = maybe_resume_feedback(StateR),
    case current_patchset(StateA, RunOpts) of
        {no_patches, _BaseCommit} ->
            State1 = StateA#state{cycles = StateA#state.cycles + 1,
                                  last_run_at = now_iso8601(), last_error = undefined},
            schedule_next(State1#state.interval_ms),
            {noreply, State1};
        {error, Reason} ->
            State1 = StateA#state{cycles = StateA#state.cycles + 1,
                                  last_run_at = now_iso8601(), last_error = Reason},
            schedule_next(State1#state.interval_ms),
            {noreply, State1};
        {ok, Job0} ->
            Force = maps:get(force, RunOpts, false),
            case lookup_job(StateA#state.tab, maps:get(job_id, Job0)) of
                {ok, Existing} when Force =:= false ->
                    case maps:get(status, Existing, queued) of
                        clean ->
                            State1 = StateA#state{cycles = StateA#state.cycles + 1,
                                                  last_run_at = now_iso8601(),
                                                  last_error = undefined},
                            schedule_next(State1#state.interval_ms),
                            {noreply, State1};
                        broken ->
                            State1 = maybe_dispatch_feedback(Existing, StateA),
                            schedule_next(State1#state.interval_ms),
                            {noreply, State1#state{cycles = State1#state.cycles + 1,
                                                  last_run_at = now_iso8601()}};
                        _ -> start_job(Existing, RunOpts, StateA)
                    end;
                _ ->
                    Job = Job0#{status => queued, created_at => now_iso8601(),
                                resume_count => 0, feedback => #{state => none}},
                    ok = put_job(StateA#state.tab, Job),
                    start_job(Job, RunOpts, StateA)
            end
    end.

start_job(Job0, RunOpts, State0) ->
    Job = Job0#{status => running, started_at => now_iso8601(), last_error => undefined},
    ok = put_job(State0#state.tab, Job),
    Ref = make_ref(),
    Parent = self(),
    ExecOpts = maps:merge(State0#state.opts, RunOpts),
    {Pid, Mon} = spawn_monitor(fun() ->
        Parent ! {integration_result, Ref, maps:get(job_id, Job), execute_job(Job, State0, ExecOpts)}
    end),
    Current = #{job_id => maps:get(job_id, Job), ref => Ref, mon => Mon, pid => Pid},
    {noreply, State0#state{current = Current,
                           cycles = State0#state.cycles + 1,
                           last_run_at = now_iso8601(),
                           last_error = undefined}}.

execute_job(Job, State, Opts) ->
    PatchFiles = [binary_to_list(maps:get(patch_file, P)) || P <- maps:get(patches, Job, [])],
    VerifyOpts = maps:merge(Opts, #{
        repo_root => State#state.repo_root,
        state_root => State#state.state_root,
        base_commit => maps:get(base_commit, Job),
        worktree_root => ecai_code_paths:integration_worktree_root(State#state.state_root),
        worktree_prefix => "integration",
        keep_worktree => false,
        run_eunit => maps:get(run_eunit, Opts,
            application:get_env(ecai, code_integration_run_eunit, true)),
        run_ct => maps:get(run_ct, Opts,
            application:get_env(ecai, code_integration_run_ct, false)),
        command_timeout_ms => maps:get(command_timeout_ms, Opts,
            application:get_env(ecai, code_integration_command_timeout_ms, 600000))
    }),
    ecai_patch_verifier:verify_patchset(PatchFiles, VerifyOpts).

complete_job(JobId, {ok, #{status := validated} = Verification}, State) ->
    Job0 = value_or_empty(lookup_job(State#state.tab, JobId)),
    Job = Job0#{status => clean, completed_at => now_iso8601(),
                verification => Verification, last_error => undefined},
    ok = put_job(State#state.tab, Job),
    _ = write_job_report(Job, State),
    State#state{last_error = undefined};
complete_job(JobId, {ok, #{status := failed} = Verification}, State0) ->
    Job0 = value_or_empty(lookup_job(State0#state.tab, JobId)),
    Breakage = build_breakage(Job0, Verification),
    Job1 = Job0#{status => broken, completed_at => now_iso8601(),
                 verification => Verification, breakage => Breakage,
                 feedback => #{state => pending}, last_error => undefined},
    ok = put_job(State0#state.tab, Job1),
    _ = write_job_report(Job1, State0),
    maybe_dispatch_feedback(Job1, State0);
complete_job(JobId, {error, Reason}, State) ->
    Job0 = value_or_empty(lookup_job(State#state.tab, JobId)),
    Job = Job0#{status => error, completed_at => now_iso8601(), last_error => Reason},
    ok = put_job(State#state.tab, Job),
    _ = write_job_report(Job, State),
    State#state{last_error = {JobId, Reason}};
complete_job(JobId, Other, State) ->
    complete_job(JobId, {error, {unexpected_integration_result, Other}}, State).

maybe_resume_feedback(State) ->
    Pending = [J || J <- collect_jobs(State#state.tab),
                    maps:get(status, J, undefined) =:= broken,
                    feedback_retryable(maps:get(feedback, J, #{}))],
    case Pending of
        [Job | _] -> maybe_dispatch_feedback(Job, State);
        [] -> State
    end.

feedback_retryable(#{state := pending}) -> true;
feedback_retryable(#{state := dispatching}) -> true;
feedback_retryable(#{state := failed}) -> true;
feedback_retryable(_) -> false.

maybe_dispatch_feedback(Job, State) ->
    case maps:get(breakage, Job, undefined) of
        #{application := App, module := Module, finding := Finding} = Breakage ->
            Fingerprint = mget(<<"fingerprint">>, Finding, <<>>),
            Version = ecai_code_context:finding_version(App, Module, Finding),
            case ecai_learning_store:get_repair(Fingerprint, Version) of
                {ok, _Existing} ->
                    update_feedback(Job, #{state => already_queued, fingerprint => Fingerprint,
                                           finding_version => Version}, State);
                not_found ->
                    PatchFiles = [maps:get(patch_file, P) || P <- maps:get(patches, Job, [])],
                    RepairOpts0 = maps:get(repair_opts, State#state.opts, #{}),
                    Verifier = maps:merge(maps:get(verifier, RepairOpts0, #{}), #{
                        base_commit => maps:get(base_commit, Job),
                        preapply_patch_files => [binary_to_list(P) || P <- PatchFiles],
                        run_eunit => application:get_env(ecai, code_integration_run_eunit, true),
                        run_ct => application:get_env(ecai, code_integration_run_ct, false)
                    }),
                    RepairOpts = RepairOpts0#{verifier => Verifier,
                                              integration_job_id => maps:get(job_id, Job),
                                              integration_breakage => Breakage},
                    Dispatching = Job#{feedback => #{state => dispatching,
                                                     fingerprint => Fingerprint,
                                                     finding_version => Version}},
                    ok = put_job(State#state.tab, Dispatching),
                    case ecai_code_repair:propose_finding(App, Module, Finding, RepairOpts) of
                        {ok, _Pid} ->
                            update_feedback(Dispatching, #{state => dispatched,
                                                          fingerprint => Fingerprint,
                                                          finding_version => Version}, State);
                        {ok, _Pid, _Info} ->
                            update_feedback(Dispatching, #{state => dispatched,
                                                          fingerprint => Fingerprint,
                                                          finding_version => Version}, State);
                        {error, Reason} ->
                            update_feedback(Dispatching, #{state => failed,
                                                          fingerprint => Fingerprint,
                                                          finding_version => Version,
                                                          error => Reason}, State)
                    end
            end;
        _ -> State
    end.

update_feedback(Job, Feedback, State) ->
    Updated = Job#{feedback => Feedback, feedback_updated_at => now_iso8601()},
    ok = put_job(State#state.tab, Updated),
    _ = write_job_report(Updated, State),
    State.

current_patchset(State, RunOpts) ->
    EffectiveOpts = maps:merge(State#state.opts, RunOpts),
    case resolve_base_commit(State#state.repo_root, EffectiveOpts) of
        {error, _} = Error -> Error;
        {ok, BaseCommit} ->
            case safe_repairs() of
                {error, _} = Error ->
                    Error;
                {ok, AllRepairs} ->
                    Repairs = [
                        R
                     || R <- AllRepairs,
                        validated_repair_for_base(R, BaseCommit)
                    ],
                    case repair_descriptors(Repairs, []) of
                        {error, _} = Error ->
                            Error;
                        {ok, Patches0} ->
                            Patches = lists:sort(fun patch_before/2, Patches0),
                            case Patches of
                                [] -> {no_patches, BaseCommit};
                                _ ->
                                    PatchIdentity = [
                                        {maps:get(fingerprint, P), maps:get(finding_version, P), maps:get(patch_sha256, P)}
                                     || P <- Patches
                                    ],
                                    PatchsetSha = sha256_hex(term_to_binary(PatchIdentity, [deterministic])),
                                    JobId = sha256_hex(term_to_binary({BaseCommit, PatchsetSha}, [deterministic])),
                                    {ok, #{job_id => JobId, base_commit => BaseCommit,
                                           patchset_sha256 => PatchsetSha, patches => Patches}}
                            end
                    end
            end
    end.

safe_repairs() ->
    try ecai_learning_store:repairs() of
        Repairs when is_list(Repairs) -> {ok, Repairs};
        Other -> {error, {unexpected_repairs_response, Other}}
    catch
        exit:{noproc, _} -> {error, learning_store_unavailable};
        exit:{timeout, _} -> {error, learning_store_timeout};
        Class:Reason -> {error, {learning_store_failed, Class, Reason}}
    end.

validated_repair(Repair) when is_map(Repair) ->
    Status = get_any(status, Repair, undefined),
    PatchFile = get_any(patch_file, Repair, undefined),
    status_is_validated(Status) andalso PatchFile =/= undefined;
validated_repair(_) -> false.

validated_repair_for_base(Repair, BaseCommit) ->
    validated_repair(Repair) andalso
        repair_base_commit(Repair) =:= BaseCommit.

repair_base_commit(Repair) ->
    case get_any(base_commit, Repair, undefined) of
        undefined ->
            Verification = get_any(verifier_output, Repair, #{}),
            to_binary(get_any(base_commit, Verification, <<>>));
        Commit ->
            to_binary(Commit)
    end.

status_is_validated(validated) -> true;
status_is_validated(<<"validated">>) -> true;
status_is_validated(_) -> false.

repair_descriptors([], Acc) ->
    {ok, lists:reverse(Acc)};
repair_descriptors([Repair | Rest], Acc) ->
    case repair_descriptor(Repair) of
        {ok, Descriptor} -> repair_descriptors(Rest, [Descriptor | Acc]);
        {error, _} = Error -> Error
    end.

repair_descriptor(Repair) ->
    PatchFile0 = get_any(patch_file, Repair, undefined),
    PatchFile = path_to_list(PatchFile0),
    Fp = to_binary(get_any(fingerprint, Repair, <<>>)),
    Version = to_binary(get_any(finding_version, Repair, <<>>)),
    case file:read_file(PatchFile) of
        {error, Reason} ->
            {error, {validated_patch_unavailable, Fp, Version, to_binary(PatchFile), Reason}};
        {ok, Patch} ->
            ActualSha = sha256_hex(Patch),
            ExpectedSha = case get_any(patch_sha256, Repair, undefined) of
                undefined -> ActualSha;
                Value -> to_binary(Value)
            end,
            case ExpectedSha =:= ActualSha of
                false ->
                    {error, {validated_patch_digest_mismatch, Fp, Version,
                             ExpectedSha, ActualSha, to_binary(PatchFile)}};
                true ->
                    {ok, #{
                        fingerprint => Fp,
                        finding_version => Version,
                        patch_sha256 => ActualSha,
                        patch_file => to_binary(PatchFile),
                        created_at => to_binary(get_any(created_at, Repair, <<>>)),
                        application => get_any(application, Repair, undefined),
                        module => get_any(module, Repair, undefined),
                        touched_paths => [to_binary(P) || P <- ecai_patch_verifier:patch_paths(Patch)],
                        patch_excerpt => truncate_binary(Patch, ?MAX_PATCH_EXCERPT_BYTES)
                    }}
            end
    end.

patch_before(A, B) ->
    {maps:get(created_at, A, <<>>), maps:get(fingerprint, A, <<>>), maps:get(finding_version, A, <<>>)} =<
    {maps:get(created_at, B, <<>>), maps:get(fingerprint, B, <<>>), maps:get(finding_version, B, <<>>)}.

build_breakage(Job, Verification) ->
    Failure = maps:get(failure, Verification, #{}),
    Phase = maps:get(phase, Failure, unknown),
    Result = maps:get(result, Failure, #{}),
    Output = truncate_binary(maps:get(output, Result, <<>>), ?MAX_DIAGNOSTIC_BYTES),
    Sources = maps:get(failure_sources, Verification, []),
    Target = choose_target(Sources, maps:get(patches, Job, [])),
    App = maps:get(application, Target),
    Module = maps:get(module, Target),
    Path = maps:get(path, Target, <<>>),
    Source = maps:get(source, Target, <<>>),
    JobId = maps:get(job_id, Job),
    Fingerprint = sha256_hex(term_to_binary({integration, JobId, Phase, Path}, [deterministic])),
    IssueKey = iolist_to_binary([<<"integration:">>, to_binary(Phase), <<":">>, Path]),
    IntegrationContext = #{
        <<"job_id">> => JobId,
        <<"base_commit">> => maps:get(base_commit, Job),
        <<"patchset_sha256">> => maps:get(patchset_sha256, Job),
        <<"failed_phase">> => to_binary(Phase),
        <<"diagnostic">> => Output,
        <<"target_source_path">> => Path,
        <<"target_source">> => Source,
        <<"patches">> => breakage_patch_contexts(maps:get(patches, Job, []))
    },
    Finding = #{
        <<"fingerprint">> => Fingerprint,
        <<"issue_key">> => IssueKey,
        <<"title">> => integration_title(Phase),
        <<"severity">> => integration_severity(Phase),
        <<"confidence">> => <<"high">>,
        <<"cwe">> => null,
        <<"function">> => null,
        <<"line_start">> => null,
        <<"line_end">> => null,
        <<"evidence">> => Output,
        <<"attack_preconditions">> => <<"Patchset integration validation must reach this stage.">>,
        <<"impact">> => <<"The validated patchset cannot be safely integrated as a whole.">>,
        <<"remediation">> => <<"Repair the integration breakage without reverting unrelated validated fixes.">>,
        <<"proposed_patch">> => <<>>,
        <<"status">> => <<"open">>,
        <<"change">> => <<"new">>,
        <<"integration_context">> => IntegrationContext
    },
    #{application => App, module => Module, path => Path, phase => Phase,
      diagnostic => Output, finding => Finding}.

choose_target([Source | _], _Patches) ->
    path_target(maps:get(path, Source, <<>>), maps:get(source, Source, <<>>));
choose_target([], Patches) ->
    case first_touched_erl(Patches) of
        undefined -> #{application => ecai, module => ecai_patch_integration,
                       path => <<"apps/ecai/src/ecai_patch_integration.erl">>, source => <<>>};
        Path -> path_target(Path, <<>>)
    end.

first_touched_erl([]) -> undefined;
first_touched_erl([Patch | Rest]) ->
    case [P || P <- maps:get(touched_paths, Patch, []),
               filename:extension(binary_to_list(P)) =:= ".erl"] of
        [P | _] -> P;
        [] -> first_touched_erl(Rest)
    end.

path_target(Path0, Source) ->
    Path = to_binary(Path0),
    Segments = filename:split(binary_to_list(Path)),
    App = case Segments of
        ["apps", "damage" | _] -> damage;
        ["apps", "erm" | _] -> erm;
        ["apps", "ecai" | _] -> ecai;
        _ -> ecai
    end,
    ModuleName = filename:basename(binary_to_list(Path), ".erl"),
    Module = safe_module_atom(ModuleName, App),
    #{application => App, module => Module, path => Path, source => Source}.

safe_module_atom([], App) -> anchor_module(App);
safe_module_atom(Name, App) ->
    try list_to_existing_atom(Name)
    catch error:badarg -> anchor_module(App) end.

anchor_module(damage) -> damage;
anchor_module(erm) -> erm;
anchor_module(ecai) -> ecai_patch_integration.

breakage_patch_contexts(Patches) ->
    Recent = tail_limit(Patches, 24),
    [breakage_patch_context(P) || P <- Recent].

tail_limit(List, Max) when length(List) =< Max -> List;
tail_limit(List, Max) -> lists:nthtail(length(List) - Max, List).

breakage_patch_context(Patch) ->
    #{
        <<"fingerprint">> => maps:get(fingerprint, Patch),
        <<"finding_version">> => maps:get(finding_version, Patch),
        <<"patch_sha256">> => maps:get(patch_sha256, Patch),
        <<"patch_file">> => maps:get(patch_file, Patch),
        <<"touched_paths">> => maps:get(touched_paths, Patch, []),
        <<"patch_excerpt">> => maps:get(patch_excerpt, Patch, <<>>)
    }.

integration_title(patch_apply_check) -> <<"Patchset application conflict">>;
integration_title(patch_apply) -> <<"Patchset application failure">>;
integration_title(diff_check) -> <<"Patchset produces invalid Git diff">>;
integration_title(compile) -> <<"Patchset compilation failure">>;
integration_title(eunit) -> <<"Patchset EUnit regression">>;
integration_title(ct) -> <<"Patchset Common Test regression">>;
integration_title(Other) -> iolist_to_binary([<<"Patchset integration failure: ">>, to_binary(Other)]).

integration_severity(patch_apply_check) -> <<"high">>;
integration_severity(patch_apply) -> <<"high">>;
integration_severity(diff_check) -> <<"high">>;
integration_severity(compile) -> <<"high">>;
integration_severity(_) -> <<"medium">>.

resolve_base_commit(RepoRoot, Opts) ->
    Base0 = integration_base(Opts),
    Base = path_to_list(Base0),
    Result = run_git(
        RepoRoot,
        ["rev-parse", "--verify", "--end-of-options",
         Base ++ "^{commit}"],
        30000
    ),
    case Result of
        {ok, Output} -> {ok, trim_binary(Output)};
        {error, Reason} ->
            {error, {cannot_resolve_integration_base, Base0, Reason}}
    end.

integration_base(Opts) ->
    case maps:get(base_commit, Opts, undefined) of
        undefined ->
            case application:get_env(ecai, code_integration_base_commit) of
                {ok, Value} when Value =/= "HEAD",
                                 Value =/= <<"HEAD">> ->
                    Value;
                _ ->
                    case ecai_otp_compat:catch_value(fun() -> ecai_source_repository:current(Opts) end) of
                        {ok, #{commit := Commit}} -> Commit;
                        _ -> "HEAD"
                    end
            end;
        Value ->
            Value
    end.

run_git(RepoRoot, Args, Timeout) ->
    case os:find_executable("git") of
        false -> {error, git_not_found};
        Git ->
            Port = open_port({spawn_executable, Git}, [binary, exit_status, stderr_to_stdout,
                {args, ["-C", RepoRoot | Args]}, {cd, RepoRoot}]),
            collect_git(Port, <<>>, Timeout)
    end.

collect_git(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} -> collect_git(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, Acc}}
    after Timeout ->
        try port_close(Port) catch _:_:_ -> ok end,
        {error, timeout}
    end.

recover_interrupted_jobs(Tab) ->
    Updates = dets:foldl(fun
        ({{job, Id}, Job}, Acc) when is_map(Job) ->
            case maps:get(status, Job, undefined) of
                running -> [{Id, Job#{status => queued,
                                      resumed_at => now_iso8601(),
                                      resume_count => maps:get(resume_count, Job, 0) + 1}} | Acc];
                _ -> Acc
            end;
        (_, Acc) -> Acc
    end, [], Tab),
    lists:foreach(fun({Id, Job}) -> dets:insert(Tab, {{job, Id}, Job}) end, Updates),
    dets:sync(Tab).

put_job(Tab, #{job_id := Id} = Job) ->
    case dets:insert(Tab, {{job, Id}, Job}) of
        ok -> dets:sync(Tab);
        Error -> Error
    end.

lookup_job(Tab, JobId) ->
    case dets:lookup(Tab, {job, to_binary(JobId)}) of
        [{{job, _}, Job}] -> {ok, Job};
        [] -> not_found
    end.

collect_jobs(Tab) ->
    Jobs = dets:foldl(fun
        ({{job, _}, Job}, Acc) when is_map(Job) -> [Job | Acc];
        (_, Acc) -> Acc
    end, [], Tab),
    lists:sort(fun(A, B) -> maps:get(created_at, A, <<>>) >= maps:get(created_at, B, <<>>) end, Jobs).

job_counts(Tab) ->
    lists:foldl(fun(Job, Acc) ->
        Status = maps:get(status, Job, unknown),
        maps:update_with(Status, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, collect_jobs(Tab)).

write_job_report(Job, State) ->
    Dir = ecai_code_paths:integration_log_root(State#state.state_root),
    ok = filelib:ensure_dir(filename:join(Dir, ".keep")),
    File = filename:join(Dir, binary_to_list(maps:get(job_id, Job)) ++ ".json"),
    Tmp = File ++ ".tmp",
    case file:write_file(Tmp, jsx:encode(json_safe(Job))) of
        ok -> file:rename(Tmp, File);
        Error -> Error
    end.

current_summary(undefined) -> undefined;
current_summary(Current) when is_map(Current) -> maps:without([pid, mon, ref], Current).

schedule_next(Delay) -> erlang:send_after(Delay, self(), scan), ok.

repo_root(Opts) ->
    case ecai_otp_compat:catch_value(fun() -> ecai_source_repository:current(Opts) end) of
        {ok, #{root := Root}} ->
            filename:absname(path_to_list(Root));
        _ ->
            filename:absname(path_to_list(maps:get(
                repo_root,
                Opts,
                application:get_env(ecai, code_repo_root, ".")
            )))
    end.

value_or_empty({ok, Value}) -> Value;
value_or_empty(not_found) -> #{}.

get_any(Key, Map, Default) when is_map(Map), is_atom(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

mget(Key, Map, Default) when is_binary(Key), is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                Atom -> maps:get(Atom, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map),
                                                    not transient_key(K)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(Tuple) when is_tuple(Tuple) -> [json_safe(V) || V <- tuple_to_list(Tuple)];
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(undefined) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Number) when is_number(Number) -> Number;
json_safe(Other) -> to_binary(Other).

transient_key(pid) -> true;
transient_key(mon) -> true;
transient_key(ref) -> true;
transient_key(_) -> false.

json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_list(K) -> unicode:characters_to_binary(K);
json_key(K) -> to_binary(K).

sha256_hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).

truncate_binary(Bin, _Max) when not is_binary(Bin) -> to_binary(Bin);
truncate_binary(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_binary(Bin, Max) when Max > 0 ->
    <<Prefix:Max/binary, _/binary>> = Bin,
    <<Prefix/binary, "\n... truncated ...\n">>.

trim_binary(Bin) -> unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P);
path_to_list(P) when is_atom(P) -> atom_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
