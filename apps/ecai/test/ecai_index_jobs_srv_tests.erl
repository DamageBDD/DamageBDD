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
        remove_tree(Dir)
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
    wait_unregistered(100).

wait_unregistered(0) ->
    ok;
wait_unregistered(Attempts) ->
    Names = [
        ecai_index_jobs_sup,
        ecai_index_jobs_srv,
        ecai_index_job_worker_sup,
        ecai_index_job_events
    ],
    case lists:any(fun(Name) -> whereis(Name) =/= undefined end, Names) of
        true -> timer:sleep(10), wait_unregistered(Attempts - 1);
        false -> ok
    end.

temp_dir() ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(
        Root,
        "ecai-index-jobs-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

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
        {error, enoent} -> ok;
        {error, _Reason} -> ok
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
        remove_tree(Dir)
    end.

start_queue_with_opts(Dir, Extra) ->
    wait_unregistered(100),
    Opts = maps:merge(#{store_dir => Dir}, Extra),
    {ok, Sup} = ecai_index_jobs_sup:start_link(Opts),
    unlink(Sup),
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
        remove_tree(Dir)
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
