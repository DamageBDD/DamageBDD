-module(ecai_patch_manager_orphan_preflight_tests).

-include_lib("eunit/include/eunit.hrl").

identifies_legacy_orphan_retry_test() ->
    ?assert(
        ecai_patch_manager:is_orphan_retry_wait(#{
            status => retry_wait,
            failure_class => orphaned_worker
        })
    ),
    ?assert(
        ecai_patch_manager:is_orphan_retry_wait(#{
            status => <<"retry_wait">>,
            last_error => {orphaned_worker, <<"started">>}
        })
    ),
    ?assertNot(
        ecai_patch_manager:is_orphan_retry_wait(#{
            status => queued,
            failure_class => orphaned_worker
        })
    ),
    ?assertNot(
        ecai_patch_manager:is_orphan_retry_wait(#{
            status => retry_wait,
            failure_class => inference_failed
        })
    ).

recover_orphan_retry_removes_false_failure_test() ->
    Repair = #{
        status => retry_wait,
        stage => dispatch_wait,
        retryable => true,
        retry_count => 2,
        failure_class => orphaned_worker,
        error => {orphaned_worker, <<"started">>},
        last_error => {orphaned_worker, <<"started">>},
        last_failed_at => <<"failed">>,
        worker_pid => self(),
        worker_started_at => <<"started">>,
        next_retry_at_ms => 9999999999999,
        fingerprint => <<"fp">>,
        finding_version => <<"version">>
    },
    Recovered =
        ecai_patch_manager:recover_orphan_retry(Repair),
    ?assertEqual(queued, maps:get(status, Recovered)),
    ?assertEqual(queued, maps:get(stage, Recovered)),
    ?assertEqual(false, maps:get(retryable, Recovered)),
    ?assertEqual(2, maps:get(retry_count, Recovered)),
    ?assertEqual(
        orphaned_worker,
        maps:get(recovered_from, Recovered)
    ),
    ?assert(is_integer(
        maps:get(next_retry_at_ms, Recovered)
    )),
    ?assertNot(maps:is_key(failure_class, Recovered)),
    ?assertNot(maps:is_key(error, Recovered)),
    ?assertNot(maps:is_key(last_error, Recovered)),
    ?assertNot(maps:is_key(last_failed_at, Recovered)),
    ?assertNot(maps:is_key(worker_pid, Recovered)),
    ?assertNot(maps:is_key(worker_started_at, Recovered)).

orphan_preflight_batch_is_bounded_test() ->
    ?assertEqual(
        8,
        ecai_patch_manager:orphan_preflight_batch(#{})
    ),
    ?assertEqual(
        0,
        ecai_patch_manager:orphan_preflight_batch(#{
            orphan_preflight_batch => 0
        })
    ),
    ?assertEqual(
        12,
        ecai_patch_manager:orphan_preflight_batch(#{
            orphan_preflight_batch => 12
        })
    ),
    ?assertEqual(
        64,
        ecai_patch_manager:orphan_preflight_batch(#{
            orphan_preflight_batch => 1000
        })
    ).
