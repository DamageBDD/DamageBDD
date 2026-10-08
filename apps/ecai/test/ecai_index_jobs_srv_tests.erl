-module(ecai_index_jobs_srv_tests).

-include_lib("eunit/include/eunit.hrl").

queue_controls_and_recovery_test() ->
    Dir = temp_dir(),
    try
        Sup1 = start_queue(Dir),
        Spec = fixture_spec(),
        {ok, Job1} = ecai_index_jobs_srv:enqueue(
            Spec,
            #{idempotency_key => <<"fixture-1">>}
        ),
        JobId = maps:get(<<"id">>, Job1),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, Job1)),

        {ok, SameJob} = ecai_index_jobs_srv:enqueue(
            Spec,
            #{idempotency_key => <<"fixture-1">>}
        ),
        ?assertEqual(JobId, maps:get(<<"id">>, SameJob)),
        ConflictSpec = Spec#{owner => <<"operator">>, options => #{priority => 999}},
        ?assertMatch(
            {error, {idempotency_conflict, _, _}},
            ecai_index_jobs_srv:enqueue(
                ConflictSpec,
                #{idempotency_key => <<"fixture-1">>}
            )
        ),
        ?assertEqual({error, invalid_limit}, ecai_index_jobs_srv:list(#{limit => 0})),

        {ok, Paused} = ecai_index_jobs_srv:pause(JobId),
        ?assertEqual(<<"paused">>, maps:get(<<"state">>, Paused)),
        {ok, QueuedAgain} = ecai_index_jobs_srv:resume(JobId),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, QueuedAgain)),

        {ok, Events} = ecai_index_jobs_srv:events(JobId, 0, 100),
        ?assert(length(Events) >= 3),
        stop_queue(Sup1),

        %% Simulate a host failure after the durable state reached running.
        %% Startup must queue the job from its checkpoint and append a durable
        %% recovery event rather than silently changing the public state.
        {ok, Store} = ecai_index_job_store:open(Dir),
        {ok, StoredJob0} = ecai_index_job_store:get_job(Store, JobId),
        PreviousEventSeq = maps:get(event_seq, StoredJob0),
        StoredJob1 = StoredJob0#{
            state => running,
            progress => (maps:get(progress, StoredJob0, #{}))#{phase => running}
        },
        ok = ecai_index_job_store:put_job(Store, StoredJob1),
        ok = ecai_index_job_store:sync(Store),
        ok = ecai_index_job_store:close(Store),

        Sup2 = start_queue(Dir),
        {ok, Recovered} = ecai_index_jobs_srv:get(JobId),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, Recovered)),
        ?assertEqual(
            PreviousEventSeq + 1,
            maps:get(<<"event_seq">>, Recovered)
        ),
        {ok, [RecoveryEvent]} = ecai_index_jobs_srv:events(
            JobId,
            PreviousEventSeq,
            10
        ),
        ?assertEqual(<<"recovery">>, maps:get(<<"type">>, RecoveryEvent)),
        RecoveryData = maps:get(<<"data">>, RecoveryEvent),
        ?assertEqual(<<"running">>, maps:get(<<"previous_state">>, RecoveryData)),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, RecoveryData)),
        {ok, Canceled} = ecai_index_jobs_srv:cancel(JobId),
        ?assertEqual(<<"canceled">>, maps:get(<<"state">>, Canceled)),
        stop_queue(Sup2)
    after
        cleanup_queue(Dir)
    end.


%% A canceled job retains its identity and checkpoint. Operator resume via
%% /retry is permitted even if max_retries = 0 (cancellation is not failure).
canceled_retry_requeues_checkpoint_test() ->
    Dir = temp_dir(),
    try
        Sup1 = start_queue(Dir),
        Spec0 = fixture_spec(),
        Spec = Spec0#{options => #{batch_size => 1, max_retries => 0}},
        {ok, Created} = ecai_index_jobs_srv:enqueue(Spec),
        JobId = maps:get(<<"id">>, Created),
        stop_queue(Sup1),
        Checkpoint = #{source_index => 2, records_indexed => 123},
        {ok, Store} = ecai_index_job_store:open(Dir),
        {ok, Stored} = ecai_index_job_store:get_job(Store, JobId),
        InitialAttempt = 1,
        ok = ecai_index_job_store:put_job(Store, Stored#{
            state => running,
            attempt => InitialAttempt,
            checkpoint => Checkpoint,
            progress => #{
                phase => indexing, unit => sources, completed => 2,
                total => 5, percent => 40.0,
                eta_ms => 300000, rate_per_second => 0.9
            }
        }),
        ok = ecai_index_job_store:sync(Store),
        ok = ecai_index_job_store:close(Store),
        Sup2 = start_queue(Dir),
        {ok, Canceled} = ecai_index_jobs_srv:cancel(JobId),
        ?assertEqual(<<"canceled">>, maps:get(<<"state">>, Canceled)),
        {ok, Resumed} = ecai_index_jobs_srv:retry(JobId),
        ?assertEqual(JobId, maps:get(<<"id">>, Resumed)),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, Resumed)),
        ?assertEqual(InitialAttempt, maps:get(<<"attempt">>, Resumed)),
        ?assertEqual(<<"queued">>, maps:get(<<"phase">>, maps:get(<<"progress">>, Resumed))),
        ?assertEqual(2, maps:get(<<"completed">>, maps:get(<<"progress">>, Resumed))),
        ?assertEqual(null, maps:get(<<"eta_ms">>, maps:get(<<"progress">>, Resumed))),
        ExpectedPublicCheckpoint = #{
            <<"source_index">> => 2, <<"records_indexed">> => 123
        },
        ?assertEqual(ExpectedPublicCheckpoint, maps:get(<<"checkpoint">>, Resumed)),
        ?assertEqual({error, {invalid_state, queued}}, ecai_index_jobs_srv:retry(JobId)),
        {ok, Events} = ecai_index_jobs_srv:events(JobId, 0, 100),
        ?assert(lists:any(fun(E) ->
            Data = maps:get(<<"data">>, E, #{}),
            maps:get(<<"reason">>, Data, undefined) =:= <<"operator_resume_canceled">> andalso
            maps:get(<<"resumed_from_checkpoint">>, Data, false) =:= true
        end, Events)),
        stop_queue(Sup2),
        Sup3 = start_queue(Dir),
        {ok, AfterRestart} = ecai_index_jobs_srv:get(JobId),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, AfterRestart)),
        ?assertEqual(ExpectedPublicCheckpoint, maps:get(<<"checkpoint">>, AfterRestart)),
        stop_queue(Sup3)
    after
        cleanup_queue(Dir)
    end.

failed_retry_keeps_existing_budget_test() ->
    Dir = temp_dir(),
    try
        Sup1 = start_queue(Dir),
        {ok, Created} = ecai_index_jobs_srv:enqueue(fixture_spec()),
        JobId = maps:get(<<"id">>, Created),
        stop_queue(Sup1),
        {ok, Store} = ecai_index_job_store:open(Dir),
        {ok, Job} = ecai_index_job_store:get_job(Store, JobId),
        ok = ecai_index_job_store:put_job(Store, Job#{
            state => failed, attempt => 4, error => simulated_failure
        }),
        ok = ecai_index_job_store:sync(Store),
        ok = ecai_index_job_store:close(Store),
        Sup2 = start_queue(Dir),
        ?assertEqual({error, {retry_limit_exceeded, 4, 3}}, ecai_index_jobs_srv:retry(JobId)),
        {ok, Failed} = ecai_index_jobs_srv:get(JobId),
        ?assertEqual(<<"failed">>, maps:get(<<"state">>, Failed)),
        stop_queue(Sup2)
    after
        cleanup_queue(Dir)
    end.

retry_obeys_pending_capacity_test() ->
    Dir = temp_dir(),
    try
        Sup = start_queue_with_opts(Dir, #{max_concurrency => 0, max_pending => 1}),
        {ok, First} = ecai_index_jobs_srv:enqueue(fixture_spec()),
        FirstId = maps:get(<<"id">>, First),
        {ok, _} = ecai_index_jobs_srv:cancel(FirstId),
        {ok, _} = ecai_index_jobs_srv:enqueue(fixture_spec()),
        ?assertMatch({error, {queue_capacity_exceeded, 1, 1}}, ecai_index_jobs_srv:retry(FirstId)),
        {ok, Canceled} = ecai_index_jobs_srv:get(FirstId),
        ?assertEqual(<<"canceled">>, maps:get(<<"state">>, Canceled)),
        stop_queue(Sup)
    after
        cleanup_queue(Dir)
    end.


%% Worker-local durations accumulate across attempts while wall time includes
%% queueing and pauses. These tests use fixed timestamps to avoid flaky sleeps.
runtime_clocks_test() ->
    Now = erlang:system_time(millisecond),
    Job = #{
        state => running,
        created_at_ms => Now - 90000,
        first_started_at_ms => Now - 70000,
        run_started_at_ms => Now - 12000,
        started_at_ms => Now - 12000,
        active_elapsed_ms => 20000,
        last_attempt_elapsed_ms => 20000,
        progress => #{updated_at_ms => Now - 3500}
    },
    Runtime = ecai_index_jobs_srv:job_runtime(Job, Now),
    ?assertEqual(90000, maps:get(wall_elapsed_ms, Runtime)),
    ?assertEqual(32000, maps:get(active_elapsed_ms, Runtime)),
    ?assertEqual(12000, maps:get(attempt_elapsed_ms, Runtime)),
    ?assertEqual(3500, maps:get(last_progress_age_ms, Runtime)),
    Stopped = ecai_index_jobs_srv:stop_run_clock(Job, Now),
    ?assertEqual(32000, maps:get(active_elapsed_ms, Stopped)),
    ?assertEqual(undefined, maps:get(run_started_at_ms, Stopped)),
    ?assertEqual(0, maps:get(attempt_elapsed_ms,
        ecai_index_jobs_srv:job_runtime(Stopped#{state => canceled,
            finished_at_ms => Now}, Now))).

legacy_stopped_timing_test() ->
    Now = erlang:system_time(millisecond),
    LegacyJob = #{state => canceled, created_at_ms => Now - 240000,
        started_at_ms => Now - 200000, finished_at_ms => Now - 100000,
        progress => #{}},
    Runtime = ecai_index_jobs_srv:job_runtime(LegacyJob, Now),
    ?assertEqual(140000, maps:get(wall_elapsed_ms, Runtime)),
    ?assertEqual(100000, maps:get(active_elapsed_ms, Runtime)),
    ?assertEqual(true, maps:get(active_time_estimated, Runtime)).

eta_requires_phase_evidence_test() ->
    Now = erlang:system_time(millisecond),
    Job = #{rate_started_at_ms => Now - 60000,
        rate_base_completed => 0,
        rate_phase => selecting_by_pageviews,
        progress => #{phase => selecting_by_pageviews,
            completed => 1, rate_samples => 0}},
    {Early, _} = ecai_index_jobs_srv:enrich_progress(Job, #{
        phase => selecting_by_pageviews, completed => 2, total => 144}),
    ?assertEqual(undefined, maps:get(eta_ms, Early)),
    ?assertEqual(warming_up, maps:get(eta_status, Early)),
    ?assertEqual(1, maps:get(rate_samples, Early)),
    MatureJob = Job#{progress => #{phase => selecting_by_pageviews,
        completed => 8, rate_samples => 3}},
    {Mature, _} = ecai_index_jobs_srv:enrich_progress(MatureJob, #{
        phase => selecting_by_pageviews, completed => 9, total => 144}),
    ?assert(is_integer(maps:get(eta_ms, Mature))),
    ?assertEqual(provisional, maps:get(eta_status, Mature)),
    {NextPhase, _} = ecai_index_jobs_srv:enrich_progress(MatureJob, #{
        phase => extracting_selected_articles, completed => 10, total => 144}),
    ?assertEqual(undefined, maps:get(eta_ms, NextPhase)),
    ?assertEqual(0, maps:get(rate_samples, NextPhase)),
    ?assertEqual(warming_up, maps:get(eta_status, NextPhase)).

stopped_eta_is_hidden_test() ->
    Now = erlang:system_time(millisecond),
    Progress = #{phase => canceled, completed => 2, total => 144,
        eta_ms => 9000000, rate_per_second => 1.4},
    Stopped = ecai_index_jobs_srv:visible_progress(Progress, canceled, Now),
    ?assertEqual(undefined, maps:get(eta_ms, Stopped)),
    ?assertEqual(0.0, maps:get(rate_per_second, Stopped)),
    ?assertEqual(unavailable, maps:get(eta_status, Stopped)).

job_runtime_api_contract_test() ->
    Dir = temp_dir(),
    try
        Sup = start_queue(Dir),
        {ok, Job} = ecai_index_jobs_srv:enqueue(fixture_spec()),
        JobId = maps:get(<<"id">>, Job),
        {ok, Result} = ecai_index_jobs_srv:get(JobId),
        Runtime = maps:get(<<"runtime">>, Result),
        Resources = maps:get(<<"resources">>, Result),
        ?assert(maps:get(<<"wall_elapsed_ms">>, Runtime) >= 0),
        ?assertEqual(0, maps:get(<<"active_elapsed_ms">>, Runtime)),
        ?assertEqual(false, maps:get(<<"active">>, Resources)),
        Status = ecai_index_jobs_srv:status(),
        ?assertEqual(<<"ecai-index-jobs-telemetry/v2">>, maps:get(runtime_schema, Status)),
        ?assertEqual(true, maps:get(canceled_checkpoint_retry, Status)),
        stop_queue(Sup)
    after
        cleanup_queue(Dir)
    end.

fixture_spec() ->
    #{
        kind => yelp_ndjson,
        owner => <<"operator">>,
        source => #{paths => [<<"/tmp/chunk-1.ndjson">>]},
        target => #{mode => live_search, base_dir => <<"/tmp/ecai-index">>},
        options => #{batch_size => 1, max_retries => 3},
        finalize => #{build_nft_manifest => false, publish_ipfs => false}
    }.

start_queue(Dir) ->
    start_queue_with_opts(Dir, #{max_concurrency => 0}).

stop_queue(Sup) ->
    Ref = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 ->
        error(queue_stop_timeout)
    end,
    wait_unregistered(100),
    case get(ecai_test_queue_supervisor) of
        Sup -> erase(ecai_test_queue_supervisor);
        _ -> ok
    end,
    ok.

wait_unregistered(0) ->
    error({queue_still_registered, [Name || Name <-
        [ecai_index_jobs_sup, ecai_index_jobs_srv,
         ecai_index_job_worker_sup, ecai_index_job_events],
        whereis(Name) =/= undefined]});
wait_unregistered(Attempts) ->
    Names = [
        ecai_index_jobs_sup,
        ecai_index_jobs_srv,
        ecai_index_job_worker_sup,
        ecai_index_job_events
    ],
    case lists:any(fun(Name) -> whereis(Name) =/= undefined end, Names) of
        true ->
            timer:sleep(10),
            wait_unregistered(Attempts - 1);
        false ->
            ok
    end.

temp_dir() ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Dir = filename:join(
        Root,
        "ecai-index-jobs-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% Always release singleton processes before deleting the DETS directory.
cleanup_queue(Dir) ->
    case erase(ecai_test_queue_supervisor) of
        Sup when is_pid(Sup) ->
            case is_process_alive(Sup) of
                true -> stop_queue(Sup);
                false -> wait_unregistered(100)
            end;
        _ -> ok
    end,
    remove_tree(Dir).

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Child = filename:join(Path, Name),
                    case filelib:is_dir(Child) of
                        true -> remove_tree(Child);
                        false -> _ = file:delete(Child)
                    end
                end,
                Names
            ),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} ->
            ok;
        {error, _Reason} ->
            ok
    end.

queue_capacity_and_position_test() ->
    Dir = temp_dir(),
    try
        Sup = start_queue_with_opts(Dir, #{
            max_concurrency => 0,
            max_pending => 1,
            max_pending_per_owner => 1
        }),
        Spec = fixture_spec(),
        {ok, Job1} = ecai_index_jobs_srv:enqueue(
            Spec,
            #{idempotency_key => <<"capacity-1">>}
        ),
        ?assertEqual(1, maps:get(<<"queue_position">>, Job1)),
        {ok, SameJob} = ecai_index_jobs_srv:enqueue(
            Spec,
            #{idempotency_key => <<"capacity-1">>}
        ),
        ?assertEqual(maps:get(<<"id">>, Job1), maps:get(<<"id">>, SameJob)),
        ?assertMatch(
            {error, {queue_capacity_exceeded, 1, 1}},
            ecai_index_jobs_srv:enqueue(
                Spec#{source => #{paths => [<<"/tmp/chunk-2.ndjson">>]}},
                #{idempotency_key => <<"capacity-2">>}
            )
        ),
        stop_queue(Sup)
    after
        cleanup_queue(Dir)
    end.

start_queue_with_opts(Dir, Extra) ->
    wait_unregistered(100),
    Opts = maps:merge(#{store_dir => Dir}, Extra),
    {ok, Sup} = ecai_index_jobs_sup:start_link(Opts),
    unlink(Sup),
    put(ecai_test_queue_supervisor, Sup),
    Sup.

control_plane_restart_replaces_workers_and_recovers_queue_test() ->
    Dir = temp_dir(),
    try
        Sup = start_queue(Dir),
        {ok, Job} = ecai_index_jobs_srv:enqueue(
            fixture_spec(),
            #{idempotency_key => <<"restart-queue">>}
        ),
        JobId = maps:get(<<"id">>, Job),
        Server1 = whereis(ecai_index_jobs_srv),
        WorkerSup1 = whereis(ecai_index_job_worker_sup),
        ServerMonitor = erlang:monitor(process, Server1),
        exit(Server1, kill),
        receive
            {'DOWN', ServerMonitor, process, Server1, _Reason} -> ok
        after 5000 ->
            error(index_jobs_server_restart_timeout)
        end,
        Server2 = wait_new_registered(ecai_index_jobs_srv, Server1, 500),
        WorkerSup2 = wait_new_registered(
            ecai_index_job_worker_sup,
            WorkerSup1,
            500
        ),
        ?assert(Server2 =/= Server1),
        ?assert(WorkerSup2 =/= WorkerSup1),
        {ok, Recovered} = ecai_index_jobs_srv:get(JobId),
        ?assertEqual(<<"queued">>, maps:get(<<"state">>, Recovered)),
        stop_queue(Sup)
    after
        cleanup_queue(Dir)
    end.

wait_new_registered(_Name, _Previous, 0) ->
    error(registered_process_restart_timeout);
wait_new_registered(Name, Previous, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Previous -> Pid;
        _ ->
            timer:sleep(10),
            wait_new_registered(Name, Previous, Attempts - 1)
    end.
