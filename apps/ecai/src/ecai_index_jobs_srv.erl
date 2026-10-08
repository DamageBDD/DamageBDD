%%--------------------------------------------------------------------
%% Durable indexing-job queue and state machine.
%%
%% Marketplace/mining jobs remain in ecai_jobs_srv. This module owns local
%% operational indexing jobs: queue order, controls, checkpoints, workers and
%% NFT-ready artifacts.
%%--------------------------------------------------------------------
-module(ecai_index_jobs_srv).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    stop/0,
    enqueue/1,
    enqueue/2,
    list/1,
    get/1,
    status/0,
    pause/1,
    resume/1,
    cancel/1,
    retry/1,
    events/3,
    nft_metadata/1,
    control/1,
    worker_job/1,
    worker_started/2,
    checkpoint/3,
    begin_finalizing/2,
    artifact_ready/3,
    worker_paused/2,
    worker_canceled/2,
    worker_failed/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([enrich_progress/2, job_runtime/2, stop_run_clock/2, visible_progress/3]).
-endif.

-record(st, {
    store,
    jobs = #{},
    running = #{},
    monitors = #{},
    max_concurrency = 1,
    max_pending = 10000,
    max_pending_per_owner = 1000,
    worker_samples = #{}
}).

-define(DEFAULT_EVENT_LIMIT, 1000).
-define(MAX_EVENT_LIMIT, 10000).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:call(?MODULE, stop, 30000).

enqueue(Spec) ->
    enqueue(Spec, #{}).

enqueue(Spec, Options) when is_map(Options) ->
    gen_server:call(?MODULE, {enqueue, Spec, Options}, 30000).

list(Filter) when is_map(Filter) ->
    gen_server:call(?MODULE, {list, Filter}).

get(JobId) ->
    gen_server:call(?MODULE, {get, normalize_job_id(JobId)}).

status() ->
    gen_server:call(?MODULE, status).

pause(JobId) ->
    gen_server:call(?MODULE, {pause, normalize_job_id(JobId)}, 30000).

resume(JobId) ->
    gen_server:call(?MODULE, {resume, normalize_job_id(JobId)}, 30000).

cancel(JobId) ->
    gen_server:call(?MODULE, {cancel, normalize_job_id(JobId)}, 30000).

retry(JobId) ->
    gen_server:call(?MODULE, {retry, normalize_job_id(JobId)}, 30000).

nft_metadata(JobId) ->
    gen_server:call(?MODULE, {nft_metadata, normalize_job_id(JobId)}, 30000).

events(JobId, AfterSeq, Limit) ->
    gen_server:call(
        ?MODULE,
        {events, normalize_job_id(JobId), AfterSeq, Limit},
        30000
    ).

control(JobId) ->
    gen_server:call(?MODULE, {control, normalize_job_id(JobId)}).

worker_job(JobId) ->
    gen_server:call(?MODULE, {worker_job, normalize_job_id(JobId)}, 30000).

worker_started(JobId, Pid) ->
    gen_server:call(?MODULE, {worker_started, JobId, Pid}, 30000).

checkpoint(JobId, Checkpoint, Progress) ->
    gen_server:call(
        ?MODULE,
        {checkpoint, JobId, Checkpoint, Progress},
        30000
    ).

begin_finalizing(JobId, Result) ->
    gen_server:call(?MODULE, {begin_finalizing, JobId, Result}, 30000).

artifact_ready(JobId, Artifact, Result) ->
    gen_server:call(
        ?MODULE,
        {artifact_ready, JobId, Artifact, Result},
        30000
    ).

worker_paused(JobId, Checkpoint) ->
    gen_server:call(?MODULE, {worker_paused, JobId, Checkpoint}, 30000).

worker_canceled(JobId, Checkpoint) ->
    gen_server:call(?MODULE, {worker_canceled, JobId, Checkpoint}, 30000).

worker_failed(JobId, Reason) ->
    gen_server:call(?MODULE, {worker_failed, JobId, Reason}, 30000).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    StoreDir = maps:get(store_dir, Opts, configured_store_dir()),
    MaxConcurrency = maps:get(
        max_concurrency,
        Opts,
        application:get_env(ecai, index_jobs_max_concurrency, 1)
    ),
    MaxPending = maps:get(
        max_pending,
        Opts,
        application:get_env(ecai, index_jobs_max_pending, 10000)
    ),
    MaxPendingPerOwner = maps:get(
        max_pending_per_owner,
        Opts,
        application:get_env(ecai, index_jobs_max_pending_per_owner, 1000)
    ),
    true = is_integer(MaxConcurrency) andalso MaxConcurrency >= 0,
    true = is_integer(MaxPending) andalso MaxPending > 0,
    true = is_integer(MaxPendingPerOwner) andalso MaxPendingPerOwner > 0,
    {ok, Store} = ecai_index_job_store:open(StoreDir),
    {ok, Jobs0} = ecai_index_job_store:list_jobs(Store),
    Jobs1 = recover_jobs(Store, Jobs0),
    {ok, IdempotencyEntries} = idempotency_entries(maps:values(Jobs1)),
    ok = ecai_index_job_store:replace_idempotency(Store, IdempotencyEntries),
    ok = ecai_index_job_store:sync(Store),
    self() ! schedule,
    {ok, #st{
        store = Store,
        jobs = Jobs1,
        max_concurrency = MaxConcurrency,
        max_pending = MaxPending,
        max_pending_per_owner = MaxPendingPerOwner
    }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({enqueue, Spec0, Options}, _From, State0) ->
    case ecai_index_job_codec:normalize_spec(Spec0) of
        {ok, Spec} ->
            case normalize_enqueue_options(Options) of
                {ok, EnqueueOpts} ->
                    {Reply, State1} = enqueue_job(Spec, EnqueueOpts, State0),
                    self() ! schedule,
                    {reply, Reply, State1};
                {error, _Reason} = Error ->
                    {reply, Error, State0}
            end;
        {error, _Reason} = Error ->
            {reply, Error, State0}
    end;
handle_call({list, Filter}, _From, State = #st{jobs = Jobs}) ->
    case normalize_list_limit(filter_value(limit, Filter, 100)) of
        {ok, Limit} ->
            Sorted = lists:sort(
                fun(A, B) ->
                    CreatedA = maps:get(created_at_ms, A, 0),
                    CreatedB = maps:get(created_at_ms, B, 0),
                    case CreatedA =:= CreatedB of
                        true -> maps:get(id, A) < maps:get(id, B);
                        false -> CreatedA > CreatedB
                    end
                end,
                [Job || Job <- maps:values(Jobs), matches_filter(Job, Filter)]
            ),
            Positions = queue_positions(Jobs),
            Listed = [
                public_job(Job, Positions)
             || Job <- lists:sublist(Sorted, Limit)
            ],
            {reply, {ok, Listed}, State};
        {error, _Reason} = Error ->
            {reply, Error, State}
    end;
handle_call({get, JobId}, _From, State = #st{jobs = Jobs}) ->
    case maps:find(JobId, Jobs) of
        {ok, Job} ->
            {Resources, State1} = sample_worker(JobId, State),
            Public = (public_job(Job, State1))#{
                <<"resources">> => ecai_index_job_codec:externalize(Resources)
            },
            {reply, {ok, Public}, State1};
        error -> {reply, {error, not_found}, State}
    end;
handle_call(status, _From, State = #st{jobs = Jobs, running = Running}) ->
    Counts = lists:foldl(
        fun(Job, Acc) ->
            JobState = maps:get(state, Job),
            maps:update_with(JobState, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        maps:values(Jobs)
    ),
    PendingCount = length([
        Job
     || Job <- maps:values(Jobs),
        pending_state(maps:get(state, Job))
    ]),
    Reply = #{
        ready => true,
        runtime_schema => <<"ecai-index-jobs-telemetry/v2">>,
        canceled_checkpoint_retry => true,
        total_jobs => map_size(Jobs),
        pending_jobs => PendingCount,
        queued_jobs => maps:get(queued, Counts, 0),
        running_jobs => map_size(Running),
        running_job_ids => lists:sort(maps:keys(Running)),
        max_concurrency => State#st.max_concurrency,
        max_pending => State#st.max_pending,
        max_pending_per_owner => State#st.max_pending_per_owner,
        counts => ecai_index_job_codec:externalize(Counts)
    },
    {reply, Reply, State};
handle_call({nft_metadata, JobId}, _From, State = #st{jobs = Jobs}) ->
    case maps:find(JobId, Jobs) of
        {ok, Job} ->
            case ecai_index_artifact:nft_metadata(Job) of
                {ok, Metadata} ->
                    {reply, {ok, ecai_index_job_codec:externalize(Metadata)}, State};
                {error, _Reason} = Error ->
                    {reply, Error, State}
            end;
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({events, JobId, AfterSeq, Limit0}, _From, State = #st{store = Store, jobs = Jobs}) ->
    case maps:is_key(JobId, Jobs) of
        false ->
            {reply, {error, not_found}, State};
        true ->
            case normalize_event_query(AfterSeq, Limit0) of
                {ok, After, Limit} ->
                    case ecai_index_job_store:events_after(Store, JobId, After, Limit) of
                        {ok, Events0} ->
                            Events = [ecai_index_job_codec:externalize(E) || E <- Events0],
                            {reply, {ok, Events}, State};
                        {error, _Reason} = Error ->
                            {reply, Error, State}
                    end;
                {error, _Reason} = Error ->
                    {reply, Error, State}
            end
    end;
handle_call({worker_job, JobId}, _From, State = #st{jobs = Jobs}) ->
    case maps:find(JobId, Jobs) of
        {ok, Job} -> {reply, {ok, Job}, State};
        error -> {reply, {error, not_found}, State}
    end;
handle_call({control, JobId}, _From, State = #st{jobs = Jobs}) ->
    Reply =
        case maps:find(JobId, Jobs) of
            {ok, #{state := pause_requested}} -> pause;
            {ok, #{state := cancel_requested}} -> cancel;
            {ok, _Job} -> continue;
            error -> cancel
        end,
    {reply, Reply, State};
handle_call({pause, JobId}, _From, State0) ->
    {Reply, State1} = request_pause(JobId, State0),
    {reply, Reply, State1};
handle_call({resume, JobId}, _From, State0) ->
    {Reply, State1} = request_resume(JobId, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call({cancel, JobId}, _From, State0) ->
    {Reply, State1} = request_cancel(JobId, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call({retry, JobId}, _From, State0) ->
    {Reply, State1} = request_retry(JobId, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call({worker_started, JobId, Pid}, _From, State0) when is_pid(Pid) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := preparing} = Job0} ->
            JobBase = Job0#{state => running, updated_at_ms => now_ms()},
            {Job1, State1} = emit_event(JobBase, state, #{state => running}, State0),
            {reply, {ok, worker_ack(Job1)}, State1};
        {ok, #{state := StateName} = Job} when
            StateName =:= pause_requested;
            StateName =:= cancel_requested
        ->
            %% A control request can race worker startup. Keep the requested
            %% state so the worker can acknowledge it before doing source work.
            {reply, {ok, worker_ack(Job)}, State0};
        {ok, Job} ->
            {reply, {error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {reply, {error, not_found}, State0}
    end;
handle_call({checkpoint, JobId, Checkpoint0, Progress0}, _From, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := StateName} = Job0} when
            is_map(Checkpoint0),
            is_map(Progress0),
            (StateName =:= running orelse
                StateName =:= pause_requested orelse
                StateName =:= cancel_requested)
        ->
            {Progress, RateFields} = enrich_progress(Job0, Progress0),
            JobBase = (maps:merge(Job0, RateFields))#{
                checkpoint => Checkpoint0,
                progress => Progress,
                updated_at_ms => now_ms()
            },
            {Job1, State1} = emit_event(
                JobBase,
                progress,
                #{checkpoint => Checkpoint0, progress => Progress},
                State0
            ),
            {reply, {ok, worker_ack(Job1)}, State1};
        {ok, Job} when is_map(Checkpoint0), is_map(Progress0) ->
            {reply, {error, {invalid_state, maps:get(state, Job)}}, State0};
        {ok, _Job} ->
            {reply, {error, badarg}, State0};
        error ->
            {reply, {error, not_found}, State0}
    end;
handle_call({begin_finalizing, JobId, Result}, _From, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := running} = Job0} ->
            Progress0 = maps:get(progress, Job0, #{}),
            JobBase = Job0#{
                state => finalizing,
                result => Result,
                progress => Progress0#{phase => finalizing},
                updated_at_ms => now_ms()
            },
            {Job1, State1} = emit_event(
                JobBase,
                state,
                #{state => finalizing, result => Result},
                State0
            ),
            {reply, {ok, worker_ack(Job1)}, State1};
        {ok, #{state := pause_requested}} ->
            %% The operator can race the worker between its final control check
            %% and this atomic state transition. Return the control decision
            %% instead of converting a valid pause into a failed job.
            {reply, {control, pause}, State0};
        {ok, #{state := cancel_requested}} ->
            {reply, {control, cancel}, State0};
        {ok, Job} ->
            {reply, {error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {reply, {error, not_found}, State0}
    end;
handle_call({artifact_ready, JobId, Artifact, Result}, _From, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := finalizing} = Job0} when is_map(Artifact) ->
            Ready = maps:get(ready_to_mint, Artifact, false),
            FinalState =
                case Ready of
                    true -> ready_to_mint;
                    false -> completed
                end,
            Now = now_ms(),
            JobBase = maps:remove(worker_pid, (stop_run_clock(Job0, Now))#{
                state => FinalState,
                artifact => Artifact,
                result => Result,
                finished_at_ms => Now,
                updated_at_ms => Now,
                progress => complete_progress(maps:get(progress, Job0, #{}), FinalState)
            }),
            StateA = remove_running(JobId, State0),
            {Job1, State1} = emit_event(
                JobBase,
                artifact,
                #{state => FinalState, artifact => Artifact},
                StateA
            ),
            self() ! schedule,
            {reply, {ok, worker_ack(Job1)}, State1};
        {ok, Job} ->
            {reply, {error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {reply, {error, not_found}, State0}
    end;
handle_call({worker_paused, JobId, Checkpoint}, _From, State0) ->
    {Reply, State1} = finish_worker_state(JobId, paused, Checkpoint, undefined, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call({worker_canceled, JobId, Checkpoint}, _From, State0) ->
    {Reply, State1} = finish_worker_state(JobId, canceled, Checkpoint, undefined, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call({worker_failed, JobId, Reason}, _From, State0) ->
    {Reply, State1} = finish_worker_state(JobId, failed, undefined, Reason, State0),
    self() ! schedule,
    {reply, Reply, State1};
handle_call(_Request, _From, State) ->
    {reply, {error, unhandled}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(schedule, State0) ->
    {noreply, schedule_jobs(State0)};
handle_info({'DOWN', Ref, process, _Pid, Reason}, State0 = #st{monitors = Monitors}) ->
    case maps:take(Ref, Monitors) of
        {JobId, Monitors1} ->
            State1 = State0#st{
                monitors = Monitors1,
                running = maps:remove(JobId, State0#st.running),
                worker_samples = maps:remove(JobId, State0#st.worker_samples)
            },
            State2 = handle_worker_down(JobId, Reason, State1),
            self() ! schedule,
            {noreply, State2};
        error ->
            {noreply, State0}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #st{store = Store}) ->
    _ = ecai_index_job_store:sync(Store),
    _ = ecai_index_job_store:close(Store),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Queue and transitions
%%%===================================================================

enqueue_job(Spec, EnqueueOpts, State0 = #st{store = Store}) ->
    Owner = maps:get(owner, Spec, <<>>),
    IdempotencyKey = maps:get(idempotency_key, EnqueueOpts, <<>>),
    {ok, SpecHash} = ecai_index_job_codec:spec_hash(Spec),
    case existing_idempotent_job(Store, State0#st.jobs, Owner, IdempotencyKey) of
        {ok, Existing} ->
            case maps:get(spec_hash, Existing, undefined) of
                SpecHash ->
                    {{ok, public_job(Existing, State0)}, State0};
                ExistingHash ->
                    {
                        {error, {
                            idempotency_conflict,
                            safe_hash_hex(ExistingHash),
                            safe_hash_hex(SpecHash)
                        }},
                        State0
                    }
            end;
        not_found ->
            case ensure_queue_capacity(Owner, State0) of
                ok ->
                    create_new_job(
                        Spec,
                        SpecHash,
                        Owner,
                        IdempotencyKey,
                        State0
                    );
                {error, _Reason} = Error ->
                    {Error, State0}
            end;
        {error, _Reason} = Error ->
            {Error, State0}
    end.

create_new_job(
    Spec,
    SpecHash,
    Owner,
    IdempotencyKey,
    State0 = #st{store = Store}
) ->
    {ok, QueueSequence} = ecai_index_job_store:next_sequence(Store),
    Now = now_ms(),
    JobId = make_unique_job_id(State0#st.jobs),
    Options = maps:get(options, Spec),
    Job0 = #{
        id => JobId,
        spec => Spec,
        spec_hash => SpecHash,
        state => queued,
        priority => maps:get(priority, Options),
        max_retries => maps:get(max_retries, Options),
        attempt => 0,
        queue_sequence => QueueSequence,
        idempotency_key => IdempotencyKey,
        created_at_ms => Now,
        updated_at_ms => Now,
        started_at_ms => undefined,
        first_started_at_ms => undefined,
        run_started_at_ms => undefined,
        active_elapsed_ms => 0,
        last_attempt_elapsed_ms => 0,
        finished_at_ms => undefined,
        checkpoint => #{},
        progress => #{
            phase => queued,
            unit => jobs,
            completed => 0,
            total => 1,
            percent => 0.0
        },
        result => undefined,
        artifact => undefined,
        error => undefined,
        event_seq => 0
    },
    {Job1, State1} = emit_created_event(
        Job0,
        Owner,
        IdempotencyKey,
        #{state => queued},
        State0
    ),
    {{ok, public_job(Job1, State1)}, State1}.

ensure_queue_capacity(Owner, #st{
    jobs = Jobs,
    max_pending = MaxPending,
    max_pending_per_owner = MaxPerOwner
}) ->
    Pending = [Job || Job <- maps:values(Jobs), pending_state(maps:get(state, Job))],
    PendingCount = length(Pending),
    OwnerPendingCount = length([
        Job
     || Job <- Pending,
        maps:get(owner, maps:get(spec, Job, #{}), <<>>) =:= Owner
    ]),
    case PendingCount >= MaxPending of
        true ->
            {error, {queue_capacity_exceeded, PendingCount, MaxPending}};
        false ->
            case OwnerPendingCount >= MaxPerOwner of
                true ->
                    {error, {
                        owner_queue_capacity_exceeded,
                        Owner,
                        OwnerPendingCount,
                        MaxPerOwner
                    }};
                false ->
                    ok
            end
    end.

pending_state(queued) -> true;
pending_state(preparing) -> true;
pending_state(running) -> true;
pending_state(pause_requested) -> true;
pending_state(paused) -> true;
pending_state(cancel_requested) -> true;
pending_state(finalizing) -> true;
pending_state(_) -> false.

request_pause(JobId, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := queued} = Job0} ->
            transition_reply(Job0, paused, #{reason => operator_pause}, State0);
        {ok, #{state := StateName} = Job0} when
            StateName =:= preparing;
            StateName =:= running
        ->
            transition_reply(Job0, pause_requested, #{reason => operator_pause}, State0);
        {ok, #{state := pause_requested} = Job} ->
            {{ok, public_job(Job, State0)}, State0};
        {ok, Job} ->
            {{error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {{error, not_found}, State0}
    end.

request_resume(JobId, State0 = #st{store = Store}) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := paused} = Job0} ->
            case ensure_queue_capacity(maps:get(owner, maps:get(spec, Job0), <<>>), State0) of
                ok ->
                    {ok, QueueSequence} = ecai_index_job_store:next_sequence(Store),
                    JobBase = (preserve_first_start(Job0))#{
                        state => queued,
                        queue_sequence => QueueSequence,
                        error => undefined,
                        started_at_ms => undefined,
                        updated_at_ms => now_ms(),
                        progress => stop_progress(maps:get(progress, Job0, #{}), queued)
                    },
                    {Job1, State1} = emit_event(
                        JobBase,
                        state,
                        #{state => queued, reason => operator_resume},
                        State0
                    ),
                    {{ok, public_job(Job1, State1)}, State1};
                {error, _} = Error ->
                    {Error, State0}
            end;
        {ok, Job} ->
            {{error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {{error, not_found}, State0}
    end.

request_cancel(JobId, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := StateName} = Job0} when
            StateName =:= queued;
            StateName =:= paused;
            StateName =:= failed
        ->
            Now = now_ms(),
            JobBase = maps:remove(worker_pid, (stop_run_clock(Job0, Now))#{
                state => canceled,
                finished_at_ms => Now,
                updated_at_ms => Now,
                progress => stop_progress(maps:get(progress, Job0, #{}), canceled)
            }),
            {Job1, State1} = emit_event(
                JobBase,
                state,
                #{state => canceled, reason => operator_cancel},
                State0
            ),
            {{ok, public_job(Job1, State1)}, State1};
        {ok, #{state := StateName} = Job0} when
            StateName =:= preparing;
            StateName =:= running;
            StateName =:= pause_requested
        ->
            transition_reply(
                Job0,
                cancel_requested,
                #{reason => operator_cancel},
                State0
            );
        {ok, #{state := cancel_requested} = Job} ->
            {{ok, public_job(Job, State0)}, State0};
        {ok, Job} ->
            {{error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {{error, not_found}, State0}
    end.

%% An explicit operator retry may resume a canceled job at its durable
%% checkpoint. Cancellation is not a worker failure and must not consume the
%% retry budget in the job specification.
request_retry(JobId, State0) ->
    case lookup_job(JobId, State0) of
        {ok, #{state := canceled} = Job0} ->
            requeue_checkpoint(Job0, operator_resume_canceled, State0);
        {ok, #{state := failed} = Job0} ->
            Attempt = maps:get(attempt, Job0, 0),
            MaxRetries = maps:get(max_retries, Job0, 0),
            case Attempt =< MaxRetries of
                true ->
                    requeue_checkpoint(Job0, operator_retry_failed, State0);
                false ->
                    {{error, {retry_limit_exceeded, Attempt, MaxRetries}}, State0}
            end;
        {ok, Job} ->
            {{error, {invalid_state, maps:get(state, Job)}}, State0};
        error ->
            {{error, not_found}, State0}
    end.

requeue_checkpoint(Job0, Reason, State0 = #st{store = Store}) ->
    %% A terminal job is re-admitted as pending work; enforce the normal
    %% owner and global capacity limits before changing durable state.
    Spec = maps:get(spec, Job0),
    Owner = maps:get(owner, Spec, <<>>),
    case ensure_queue_capacity(Owner, State0) of
        ok ->
            {ok, QueueSequence} = ecai_index_job_store:next_sequence(Store),
            Now = now_ms(),
            Checkpoint = maps:get(checkpoint, Job0, #{}),
            Progress0 = maps:get(progress, Job0, #{}),
            %% Keep completed/total/percent and the adapter checkpoint while
            %% discarding rates/ETA from the previous worker lifetime.
            Progress = (stop_progress(Progress0, queued))#{updated_at_ms => Now},
            JobBase = maps:without(
                [worker_pid, rate_started_at_ms, rate_base_completed, rate_phase],
                (preserve_first_start(Job0))#{
                    state => queued,
                    queue_sequence => QueueSequence,
                    error => undefined,
                    result => undefined,
                    artifact => undefined,
                    started_at_ms => undefined,
                    active_elapsed_ms => legacy_active_ms(Job0),
                    run_started_at_ms => undefined,
                    finished_at_ms => undefined,
                    updated_at_ms => Now,
                    progress => Progress
                }
            ),
            %% emit_event durably stores the checkpoint and state transition
            %% together, then wakes the queue scheduler in handle_call/3.
            {Job1, State1} = emit_event(
                JobBase,
                state,
                #{
                    state => queued,
                    reason => Reason,
                    resumed_from_checkpoint => is_map(Checkpoint) andalso
                        map_size(Checkpoint) > 0,
                    attempt => maps:get(attempt, Job0, 0)
                },
                State0
            ),
            {{ok, public_job(Job1, State1)}, State1};
        {error, _Reason} = Error ->
            {Error, State0}
    end.

transition_reply(Job0, NewState, Data, State0) ->
    JobBase = Job0#{
        state => NewState,
        updated_at_ms => now_ms(),
        progress => (maps:get(progress, Job0, #{}))#{phase => NewState}
    },
    {Job1, State1} = emit_event(
        JobBase,
        state,
        Data#{state => NewState},
        State0
    ),
    {{ok, public_job(Job1, State1)}, State1}.

finish_worker_state(JobId, FinalState, Checkpoint, Error, State0) ->
    case lookup_job(JobId, State0) of
        {ok, Job0} ->
            case terminal_or_stopped(maps:get(state, Job0)) of
                true ->
                    {{ok, worker_ack(Job0)}, State0};
                false ->
                    finish_active_worker_state(
                        JobId,
                        Job0,
                        FinalState,
                        Checkpoint,
                        Error,
                        State0
                    )
            end;
        error ->
            {{error, not_found}, State0}
    end.

finish_active_worker_state(JobId, Job0, FinalState, Checkpoint, Error, State0) ->
    FinishedAt =
        case FinalState of
            failed -> now_ms();
            canceled -> now_ms();
            _ -> undefined
        end,
    Now = now_ms(),
    JobBase0 = (stop_run_clock(Job0, Now))#{
        state => FinalState,
        updated_at_ms => Now,
        finished_at_ms => FinishedAt,
        error => Error,
        progress => stop_progress(maps:get(progress, Job0, #{}), FinalState)
    },
    JobBase1 =
        case Checkpoint of
            undefined -> JobBase0;
            _ when is_map(Checkpoint) -> JobBase0#{checkpoint => Checkpoint}
        end,
    JobBase = maps:remove(worker_pid, JobBase1),
    StateA = remove_running(JobId, State0),
    {Job1, State1} = emit_event(
        JobBase,
        state,
        #{state => FinalState, error => Error, checkpoint => Checkpoint},
        StateA
    ),
    {{ok, worker_ack(Job1)}, State1}.

schedule_jobs(State = #st{max_concurrency = 0}) ->
    State;
schedule_jobs(State = #st{max_concurrency = Max, running = Running}) when
    map_size(Running) >= Max
->
    State;
schedule_jobs(State0) ->
    case next_queued_job(State0#st.jobs) of
        none ->
            State0;
        {ok, Job0} ->
            State1 = start_queued_job(Job0, State0),
            schedule_jobs(State1)
    end.

start_queued_job(Job0, State0) ->
    JobId = maps:get(id, Job0),
    Attempt = maps:get(attempt, Job0, 0) + 1,
    Progress0 = maps:get(progress, Job0, #{}),
    Now = now_ms(),
    JobBase = maps:remove(worker_pid, (preserve_first_start(Job0))#{
        state => preparing,
        attempt => Attempt,
        error => undefined,
        started_at_ms => Now,
        first_started_at_ms => case first_start_time(Job0, Now) of
            undefined -> Now;
            ExistingStart -> ExistingStart
        end,
        run_started_at_ms => Now,
        finished_at_ms => undefined,
        updated_at_ms => Now,
        rate_started_at_ms => Now,
        rate_base_completed => maps:get(completed, Progress0, 0),
        rate_phase => preparing,
        progress => (stop_progress(Progress0, preparing))#{updated_at_ms => Now}
    }),
    {Job1, State1} = emit_event(
        JobBase,
        state,
        #{state => preparing, attempt => Attempt},
        State0
    ),
    case ecai_index_job_worker_sup:start_job(JobId) of
        {ok, Pid} ->
            Ref = erlang:monitor(process, Pid),
            State1#st{
                running = (State1#st.running)#{JobId => #{pid => Pid, ref => Ref}},
                monitors = (State1#st.monitors)#{Ref => JobId}
            };
        {error, Reason} ->
            ?LOG_ERROR("Failed to start index job ~p: ~p", [JobId, Reason]),
            FailAt = now_ms(),
            JobFail = (stop_run_clock(Job1, FailAt))#{
                state => failed,
                error => {worker_start_failed, Reason},
                finished_at_ms => FailAt,
                updated_at_ms => FailAt,
                progress => stop_progress(maps:get(progress, Job1, #{}), failed)
            },
            {_Persisted, State2} = emit_event(
                JobFail,
                state,
                #{state => failed, error => {worker_start_failed, Reason}},
                State1
            ),
            State2
    end.

next_queued_job(Jobs) ->
    Queued = [Job || Job <- maps:values(Jobs), maps:get(state, Job) =:= queued],
    case lists:sort(fun queue_before/2, Queued) of
        [] -> none;
        [Job | _] -> {ok, Job}
    end.

queue_before(A, B) ->
    PriorityA = maps:get(priority, A, 0),
    PriorityB = maps:get(priority, B, 0),
    case PriorityA =:= PriorityB of
        true -> maps:get(queue_sequence, A, 0) < maps:get(queue_sequence, B, 0);
        false -> PriorityA > PriorityB
    end.

handle_worker_down(JobId, Reason, State0) ->
    case lookup_job(JobId, State0) of
        {ok, Job} ->
            case terminal_or_stopped(maps:get(state, Job)) of
                true ->
                    State0;
                false ->
                    Now = now_ms(),
                    JobBase = maps:remove(worker_pid, (stop_run_clock(Job, Now))#{
                        state => failed,
                        error => {worker_down, Reason},
                        finished_at_ms => Now,
                        updated_at_ms => Now,
                        progress => stop_progress(maps:get(progress, Job, #{}), failed)
                    }),
                    {_Job1, State1} = emit_event(
                        JobBase,
                        state,
                        #{state => failed, error => {worker_down, Reason}},
                        State0
                    ),
                    State1
            end;
        error ->
            State0
    end.

terminal_or_stopped(paused) -> true;
terminal_or_stopped(canceled) -> true;
terminal_or_stopped(failed) -> true;
terminal_or_stopped(completed) -> true;
terminal_or_stopped(ready_to_mint) -> true;
terminal_or_stopped(minted) -> true;
terminal_or_stopped(_) -> false.

remove_running(JobId, State0 = #st{running = Running0, monitors = Monitors0}) ->
    case maps:take(JobId, Running0) of
        {#{ref := Ref}, Running1} ->
            _ = erlang:demonitor(Ref, [flush]),
            State0#st{
                running = Running1,
                monitors = maps:remove(Ref, Monitors0),
                worker_samples = maps:remove(JobId, State0#st.worker_samples)
            };
        error ->
            State0
    end.

emit_event(Job0, Type, Data0, State0 = #st{store = Store, jobs = Jobs0}) ->
    {Job1, Event} = make_event(Job0, Type, Data0),
    ok = ecai_index_job_store:put_job_event(Store, Job1, Event),
    ok = ecai_index_job_store:sync(Store),
    JobId = maps:get(id, Job1),
    _ = ecai_index_job_events:publish(JobId, Event),
    {Job1, State0#st{jobs = Jobs0#{JobId => Job1}}}.

emit_created_event(
    Job0,
    Owner,
    IdempotencyKey,
    Data0,
    State0 = #st{store = Store, jobs = Jobs0}
) ->
    {Job1, Event} = make_event(Job0, state, Data0),
    ok = ecai_index_job_store:create_job(
        Store,
        Job1,
        Event,
        Owner,
        IdempotencyKey
    ),
    ok = ecai_index_job_store:sync(Store),
    JobId = maps:get(id, Job1),
    _ = ecai_index_job_events:publish(JobId, Event),
    {Job1, State0#st{jobs = Jobs0#{JobId => Job1}}}.

make_event(Job0, Type, Data0) ->
    Seq = maps:get(event_seq, Job0, 0) + 1,
    JobId = maps:get(id, Job0),
    Event = #{
        seq => Seq,
        job_id => JobId,
        type => event_type_binary(Type),
        state => atom_to_binary(maps:get(state, Job0), utf8),
        at_ms => now_ms(),
        data => ecai_index_job_codec:externalize(Data0)
    },
    {Job0#{event_seq => Seq}, Event}.

%%%===================================================================
%%% Helpers
%%%===================================================================

lookup_job(JobId, #st{jobs = Jobs}) ->
    maps:find(JobId, Jobs).

existing_idempotent_job(_Store, _Jobs, _Owner, <<>>) ->
    not_found;
existing_idempotent_job(Store, Jobs, Owner, Key) ->
    case ecai_index_job_store:get_idempotency(Store, Owner, Key) of
        {ok, JobId} ->
            case maps:find(JobId, Jobs) of
                {ok, Job} -> {ok, Job};
                error -> {error, {dangling_idempotency_key, JobId}}
            end;
        not_found ->
            not_found;
        {error, _Reason} = Error ->
            Error
    end.

normalize_enqueue_options(Options) ->
    case maps:get(idempotency_key, Options, maps:get(<<"idempotency_key">>, Options, <<>>)) of
        <<>> ->
            {ok, #{idempotency_key => <<>>}};
        Bin when is_binary(Bin), byte_size(Bin) =< 4096 ->
            {ok, #{idempotency_key => Bin}};
        List when is_list(List) ->
            try unicode:characters_to_binary(List) of
                Bin when byte_size(Bin) =< 4096 -> {ok, #{idempotency_key => Bin}};
                _ -> {error, invalid_idempotency_key}
            catch
                _Class:_Reason -> {error, invalid_idempotency_key}
            end;
        _ ->
            {error, invalid_idempotency_key}
    end.

normalize_event_query(AfterSeq, Limit0) when
    is_integer(AfterSeq), AfterSeq >= 0
->
    Limit =
        case Limit0 of
            undefined -> ?DEFAULT_EVENT_LIMIT;
            Value when is_integer(Value), Value > 0, Value =< ?MAX_EVENT_LIMIT -> Value;
            _ -> invalid
        end,
    case Limit of
        invalid -> {error, invalid_limit};
        _ -> {ok, AfterSeq, Limit}
    end;
normalize_event_query(_AfterSeq, _Limit) ->
    {error, invalid_after_sequence}.

normalize_list_limit(Value) when is_integer(Value), Value > 0, Value =< 1000 ->
    {ok, Value};
normalize_list_limit(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        Value -> normalize_list_limit(Value)
    catch
        error:badarg -> {error, invalid_limit}
    end;
normalize_list_limit(_Value) ->
    {error, invalid_limit}.

matches_filter(Job, Filter) ->
    match_state(Job, filter_value(state, Filter, any)) andalso
        match_kind(Job, filter_value(kind, Filter, any)) andalso
        match_owner(Job, filter_value(owner, Filter, any)).

match_state(_Job, any) -> true;
match_state(Job, Value) -> maps:get(state, Job) =:= normalize_state_filter(Value).

match_kind(_Job, any) -> true;
match_kind(Job, Value) -> maps:get(kind, maps:get(spec, Job)) =:= normalize_kind_filter(Value).

match_owner(_Job, any) ->
    true;
match_owner(Job, Value) ->
    maps:get(owner, maps:get(spec, Job), <<>>) =:= normalize_binary_filter(Value).

filter_value(Key, Filter, Default) ->
    maps:get(Key, Filter, maps:get(atom_to_binary(Key, utf8), Filter, Default)).

normalize_state_filter(any) ->
    any;
normalize_state_filter(Value) when is_atom(Value) -> Value;
normalize_state_filter(Value) when is_binary(Value) ->
    case Value of
        <<"any">> -> any;
        <<"queued">> -> queued;
        <<"preparing">> -> preparing;
        <<"running">> -> running;
        <<"pause_requested">> -> pause_requested;
        <<"paused">> -> paused;
        <<"cancel_requested">> -> cancel_requested;
        <<"canceled">> -> canceled;
        <<"finalizing">> -> finalizing;
        <<"completed">> -> completed;
        <<"ready_to_mint">> -> ready_to_mint;
        <<"failed">> -> failed;
        <<"minted">> -> minted;
        _ -> invalid
    end;
normalize_state_filter(_Value) ->
    invalid.

normalize_kind_filter(any) -> any;
normalize_kind_filter(Value) when is_atom(Value) -> Value;
normalize_kind_filter(<<"yelp_ndjson">>) -> yelp_ndjson;
normalize_kind_filter(<<"wikipedia_jsonl">>) -> wikipedia_jsonl;
normalize_kind_filter(<<"ipfs_cid">>) -> ipfs_cid;
normalize_kind_filter(<<"ipfs_manifest">>) -> ipfs_manifest;
normalize_kind_filter(_Value) -> invalid.

normalize_binary_filter(Bin) when is_binary(Bin) -> Bin;
normalize_binary_filter(List) when is_list(List) -> unicode:characters_to_binary(List);
normalize_binary_filter(_Value) -> <<"__invalid__">>.

recover_jobs(Store, Jobs0) ->
    maps:from_list([
        recover_one_job(Store, Job0)
     || Job0 <- Jobs0
    ]).

recover_one_job(Store, Job0) ->
    PreviousState = maps:get(state, Job0, failed),
    Job1 = recover_job(Job0),
    RecoveredState = maps:get(state, Job1, failed),
    Job2 =
        case RecoveredState =:= PreviousState of
            true ->
                ok = ecai_index_job_store:put_job(Store, Job1),
                Job1;
            false ->
                {PersistedJob, RecoveryEvent} = make_event(
                    Job1,
                    recovery,
                    #{
                        previous_state => PreviousState,
                        state => RecoveredState,
                        reason => restart_recovery
                    }
                ),
                ok = ecai_index_job_store:put_job_event(
                    Store,
                    PersistedJob,
                    RecoveryEvent
                ),
                PersistedJob
        end,
    {maps:get(id, Job2), Job2}.

recover_job(Job0) ->
    Job1 = maps:remove(worker_pid, Job0),
    State = maps:get(state, Job1, failed),
    case State of
        preparing ->
            recover_to_queue(Job1, preparing);
        running ->
            recover_to_queue(Job1, running);
        finalizing ->
            recover_to_queue(Job1, finalizing);
        pause_requested ->
            (stop_run_clock(Job1, recovery_end_time(Job1)))#{
                state => paused, updated_at_ms => now_ms(),
                progress => stop_progress(maps:get(progress, Job1, #{}), paused)
            };
        cancel_requested ->
            (stop_run_clock(Job1, recovery_end_time(Job1)))#{
                state => canceled, finished_at_ms => now_ms(), updated_at_ms => now_ms(),
                progress => stop_progress(maps:get(progress, Job1, #{}), canceled)
            };
        minting ->
            Job1#{state => ready_to_mint, updated_at_ms => now_ms()};
        _ ->
            Job1
    end.

recover_to_queue(Job0, PreviousState) ->
    Job = maps:without(
        [rate_started_at_ms, rate_base_completed, rate_phase],
        stop_run_clock(Job0, recovery_end_time(Job0))
    ),
    (preserve_first_start(Job))#{
        state => queued,
        error => {recovered_after_restart, PreviousState},
        started_at_ms => undefined,
        updated_at_ms => now_ms(),
        progress => stop_progress(maps:get(progress, Job, #{}), queued)
    }.

%% Progress units are heterogeneous across Wikimedia phases. Do not publish
%% a precise-looking ETA from the first processed dump. Reset the observed
%% rate each time the adapter changes phase; expose when still warming up.
enrich_progress(Job, Progress0) ->
    Now = now_ms(),
    Previous = maps:get(progress, Job, #{}),
    Completed = maps:get(completed, Progress0, 0),
    Total = maps:get(total, Progress0, undefined),
    Phase = maps:get(phase, Progress0, undefined),
    PrevPhase = maps:get(rate_phase, Job, undefined),
    Changed = Phase =/= PrevPhase,
    Base = case Changed of
        true -> Completed;
        false -> maps:get(rate_base_completed, Job, Completed)
    end,
    Started = case Changed of
        true -> Now;
        false -> maps:get(rate_started_at_ms, Job, Now)
    end,
    PreviousCompleted = maps:get(completed, Previous, Completed),
    PreviousSamples = maps:get(rate_samples, Previous, 0),
    Samples = case Changed of
        true -> 0;
        false when is_number(Completed), is_number(PreviousCompleted),
            Completed > PreviousCompleted -> PreviousSamples + 1;
        false -> PreviousSamples
    end,
    Elapsed = erlang:max(Now - Started, 1),
    Delta = case is_number(Completed) andalso is_number(Base) of
        true -> erlang:max(Completed - Base, 0);
        false -> 0
    end,
    Rate = Delta * 1000.0 / Elapsed,
    Percent = case {Total, Completed} of
        {Ptotal, Pdone} when is_number(Ptotal), Ptotal > 0,
            is_number(Pdone) ->
            erlang:min(100.0, erlang:max(0.0, 100.0 * Pdone / Ptotal));
        _ -> undefined
    end,
    Warm = Samples >= 3 andalso Elapsed >= 15000 andalso Delta >= 3,
    Eta = case {Total, Completed, Rate, Warm} of
        {Etotal, Edone, Erate, true} when is_number(Etotal),
            is_number(Edone), Etotal > Edone, Erate > 0 ->
            trunc((Etotal - Edone) * 1000.0 / Erate);
        {Etotal2, Edone2, _OtherRate, _} when is_number(Etotal2),
            is_number(Edone2), Etotal2 > 0, Edone2 >= Etotal2 -> 0;
        _ -> undefined
    end,
    EtaStatus = case Eta of
        N when is_integer(N) -> provisional;
        _ when not Warm -> warming_up;
        _ -> unavailable
    end,
    Progress = Progress0#{
        percent => Percent,
        rate_per_second => Rate,
        eta_ms => Eta,
        eta_status => EtaStatus,
        eta_method => phase_average_work_units,
        rate_samples => Samples,
        updated_at_ms => Now
    },
    {Progress, #{rate_started_at_ms => Started,
        rate_base_completed => Base, rate_phase => Phase}}.

complete_progress(Progress0, State) ->
    Completed0 = maps:get(completed, Progress0, 0),
    Total = maps:get(total, Progress0, undefined),
    {Completed, Percent, Eta} =
        case Total of
            N when is_number(N), N >= 0 -> {N, 100.0, 0};
            _ -> {Completed0, undefined, undefined}
        end,
    Progress0#{
        phase => State,
        completed => Completed,
        percent => Percent,
        eta_ms => Eta,
        eta_status => complete,
        rate_per_second => 0.0,
        updated_at_ms => now_ms()
    }.

safe_hash_hex(Hash) when is_binary(Hash) ->
    ecai_index_job_codec:id_hex(Hash);
safe_hash_hex(_Other) ->
    <<"unknown">>.

worker_ack(Job) ->
    #{
        id => maps:get(id, Job),
        state => maps:get(state, Job),
        event_seq => maps:get(event_seq, Job, 0)
    }.

public_job(Job, #st{jobs = Jobs}) ->
    public_job(Job, queue_positions(Jobs));
public_job(Job, QueuePositions) when is_map(QueuePositions) ->
    JobId = maps:get(id, Job),
    QueuePosition = maps:get(JobId, QueuePositions, undefined),
    Clean = maps:without(
        [worker_pid, rate_started_at_ms, rate_base_completed, rate_phase,
            run_started_at_ms],
        Job
    ),
    Now = now_ms(),
    Progress0 = maps:get(progress, Job, #{}),
    Progress = visible_progress(Progress0, maps:get(state, Job), Now),
    ecai_index_job_codec:externalize(Clean#{
        spec_hash => safe_hash_hex(maps:get(spec_hash, Job, undefined)),
        queue_position => QueuePosition,
        progress => Progress,
        runtime => job_runtime(Job, Now)
    }).

%% These process counters are native BEAM equivalents of the existing
%% DamageBDD node telemetry, but scoped to one running indexing worker.
%% A reduction is scheduler work, not a measured CPU percentage.
sample_worker(JobId, State = #st{running = Running, worker_samples = Samples}) ->
    case maps:find(JobId, Running) of
        {ok, #{pid := Pid}} when is_pid(Pid) ->
            case erlang:process_info(Pid, [memory, heap_size, total_heap_size,
                stack_size, reductions, message_queue_len, status,
                garbage_collection]) of
                undefined ->
                    {#{active => false}, State#st{
                        worker_samples = maps:remove(JobId, Samples)}};
                Info ->
                    Now = now_ms(),
                    Reds = proplists:get_value(reductions, Info, 0),
                    RedsRate = case maps:get(JobId, Samples, undefined) of
                        #{pid := Pid, reductions := Old, at_ms := At}
                            when Now > At, Reds >= Old ->
                            (Reds - Old) * 1000.0 / (Now - At);
                        _ -> undefined
                    end,
                    Gc = proplists:get_value(garbage_collection, Info, []),
                    Worker = #{
                        active => true,
                        memory_bytes => proplists:get_value(memory, Info),
                        heap_words => proplists:get_value(heap_size, Info),
                        total_heap_words => proplists:get_value(total_heap_size, Info),
                        stack_words => proplists:get_value(stack_size, Info),
                        reductions_total => Reds,
                        reductions_per_second => RedsRate,
                        message_queue_len => proplists:get_value(message_queue_len, Info),
                        status => proplists:get_value(status, Info),
                        minor_gcs => proplists:get_value(minor_gcs, Gc),
                        sampled_at_ms => Now
                    },
                    NewSamples = Samples#{JobId => #{pid => Pid,
                        reductions => Reds, at_ms => Now}},
                    {ecai_index_job_codec:externalize(Worker),
                        State#st{worker_samples = NewSamples}}
            end;
        _ ->
            {#{active => false}, State#st{
                worker_samples = maps:remove(JobId, Samples)}}
    end.

%% Durable active duration only increases while a worker owns the attempt.
%% First-start and accumulated durations survive pause, retry and restart.
preserve_first_start(Job) ->
    case maps:get(first_started_at_ms, Job, undefined) of
        First when is_integer(First), First > 0 -> Job;
        _ -> Job#{first_started_at_ms => maps:get(started_at_ms, Job, undefined)}
    end.

first_start_time(Job, _Now) ->
    case maps:get(first_started_at_ms, Job, undefined) of
        First when is_integer(First), First > 0 -> First;
        _ -> case maps:get(started_at_ms, Job, undefined) of
            Started when is_integer(Started), Started > 0 -> Started;
            _ -> undefined
        end
    end.

valid_elapsed(N) when is_integer(N), N >= 0 -> N;
valid_elapsed(_) -> 0.

legacy_active_ms(Job) ->
    case maps:get(active_elapsed_ms, Job, undefined) of
        N when is_integer(N), N >= 0 -> N;
        _ -> case {maps:get(started_at_ms, Job, undefined),
                   maps:get(finished_at_ms, Job, undefined)} of
            {Start, Finish} when is_integer(Start), is_integer(Finish),
                Finish >= Start -> Finish - Start;
            _ -> 0
        end
    end.

running_clock(Job, Now) ->
    case maps:get(run_started_at_ms, Job, undefined) of
        Start when is_integer(Start), Start > 0 ->
            erlang:max(0, Now - Start);
        _ -> 0
    end.

stop_run_clock(Job0, Now) ->
    Job = preserve_first_start(Job0),
    AttemptMs = running_clock(Job, Now),
    Base = legacy_active_ms(Job),
    Job#{active_elapsed_ms => Base + AttemptMs,
        last_attempt_elapsed_ms => AttemptMs,
        run_started_at_ms => undefined}.

recovery_end_time(Job) ->
    case maps:get(updated_at_ms, Job, undefined) of
        T when is_integer(T), T > 0 -> erlang:min(T, now_ms());
        _ -> now_ms()
    end.

job_runtime(Job, Now) ->
    State = maps:get(state, Job, queued),
    Active = lists:member(State, [preparing, running, pause_requested,
        cancel_requested, finalizing]),
    Current = case Active of true -> running_clock(Job, Now); false -> 0 end,
    Base = legacy_active_ms(Job),
    Created = maps:get(created_at_ms, Job, Now),
    EndAt = case lists:member(State, [completed, ready_to_mint, minted,
        canceled, failed]) of
        true -> maps:get(finished_at_ms, Job, Now);
        false -> Now
    end,
    EndSafe = case EndAt of E when is_integer(E) -> E; _ -> Now end,
    Since = case Created of C when is_integer(C) -> C; _ -> Now end,
    #{sampled_at_ms => Now,
      wall_elapsed_ms => erlang:max(0, EndSafe - Since),
      active_elapsed_ms => Base + Current,
      attempt_elapsed_ms => Current,
      last_attempt_elapsed_ms => maps:get(last_attempt_elapsed_ms, Job, 0),
      first_started_at_ms => first_start_time(Job, Now),
      active_time_estimated => not maps:is_key(active_elapsed_ms, Job),
      running => Active,
      last_progress_age_ms => case maps:get(updated_at_ms, maps:get(progress, Job, #{}), undefined) of
          T when is_integer(T) -> erlang:max(0, Now - T);
          _ -> undefined
      end}.

stop_progress(Progress, Phase) ->
    Progress#{phase => Phase, eta_ms => undefined,
        eta_status => unavailable, rate_per_second => 0.0,
        rate_samples => 0, updated_at_ms => now_ms()}.

visible_progress(Progress, State, Now) ->
    case lists:member(State, [preparing, running, pause_requested,
        cancel_requested, finalizing]) of
        true ->
            case maps:get(updated_at_ms, Progress, Now) of
                T when is_integer(T), Now - T > 120000 ->
                    Progress#{eta_ms => undefined, eta_status => stale};
                _ -> Progress
            end;
        false -> Progress#{eta_ms => undefined,
            eta_status => unavailable, rate_per_second => 0.0}
    end.

queue_positions(Jobs) ->
    Queued = lists:sort(
        fun queue_before/2,
        [Job || Job <- maps:values(Jobs), maps:get(state, Job) =:= queued]
    ),
    maps:from_list(
        lists:zip(
            [maps:get(id, Job) || Job <- Queued],
            lists:seq(1, length(Queued))
        )
    ).

configured_store_dir() ->
    application:get_env(
        ecai,
        index_jobs_dir,
        "/var/lib/damage/ecai/index-jobs"
    ).

make_unique_job_id(Jobs) ->
    JobId = make_job_id(),
    case maps:is_key(JobId, Jobs) of
        true -> make_unique_job_id(Jobs);
        false -> JobId
    end.

make_job_id() ->
    Random = crypto:strong_rand_bytes(12),
    <<"ijob-", (ecai_index_job_codec:id_hex(Random))/binary>>.

idempotency_entries(Jobs) ->
    Sorted = lists:sort(
        fun(A, B) ->
            SequenceA = maps:get(queue_sequence, A, 0),
            SequenceB = maps:get(queue_sequence, B, 0),
            case SequenceA =:= SequenceB of
                true -> maps:get(id, A) < maps:get(id, B);
                false -> SequenceA < SequenceB
            end
        end,
        Jobs
    ),
    idempotency_entries(Sorted, #{}, []).

idempotency_entries([], _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
idempotency_entries([Job | Rest], Seen0, Acc) ->
    Spec = maps:get(spec, Job, #{}),
    Owner = maps:get(owner, Spec, <<>>),
    Key = maps:get(idempotency_key, Job, <<>>),
    JobId = maps:get(id, Job),
    case Key of
        <<>> ->
            idempotency_entries(Rest, Seen0, Acc);
        _ ->
            Identity = {Owner, Key},
            case maps:find(Identity, Seen0) of
                error ->
                    idempotency_entries(
                        Rest,
                        Seen0#{Identity => JobId},
                        [{Owner, Key, JobId} | Acc]
                    );
                {ok, ExistingJobId} ->
                    {error, {
                        duplicate_idempotency_key,
                        Owner,
                        Key,
                        ExistingJobId,
                        JobId
                    }}
            end
    end.

normalize_job_id(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
normalize_job_id(List) when is_list(List), List =/= [] -> unicode:characters_to_binary(List);
normalize_job_id(_Other) -> <<>>.

event_type_binary(Type) when is_atom(Type) -> atom_to_binary(Type, utf8);
event_type_binary(Type) when is_binary(Type) -> Type.

now_ms() ->
    erlang:system_time(millisecond).
