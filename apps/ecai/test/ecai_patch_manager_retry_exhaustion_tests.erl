-module(ecai_patch_manager_retry_exhaustion_tests).

-include_lib("eunit/include/eunit.hrl").

exhausted_retry_wait_becomes_terminal_test() ->
    Repair = #{
        status => retry_wait,
        stage => inference_wait,
        retryable => true,
        retry_count => 12,
        failure_class => inference_failed,
        error => {inference_failed, timeout},
        last_error => {inference_failed, timeout},
        next_retry_at_ms => 1,
        worker_started_at => <<"old">>,
        fingerprint => <<"fp">>,
        finding_version => <<"version">>
    },
    Terminal =
        ecai_patch_manager:
            terminalize_exhausted_retry_wait(Repair, 6),
    ?assertEqual(failed, maps:get(status, Terminal)),
    ?assertEqual(terminal, maps:get(stage, Terminal)),
    ?assertEqual(false, maps:get(retryable, Terminal)),
    ?assertEqual(12, maps:get(retry_count, Terminal)),
    ?assertEqual(
        inference_failed,
        maps:get(failure_class, Terminal)
    ),
    ?assertEqual(
        {retry_exhausted, {inference_failed, timeout}},
        maps:get(error, Terminal)
    ),
    ?assertNot(maps:is_key(next_retry_at_ms, Terminal)),
    ?assertNot(maps:is_key(worker_started_at, Terminal)),
    ?assert(maps:is_key(completed_at, Terminal)).

retry_wait_below_limit_is_unchanged_test() ->
    Repair = #{
        status => retry_wait,
        retryable => true,
        retry_count => 2,
        next_retry_at_ms => 123
    },
    ?assertEqual(
        Repair,
        ecai_patch_manager:
            terminalize_exhausted_retry_wait(Repair, 6)
    ).

queued_record_is_not_terminalized_test() ->
    Repair = #{
        status => queued,
        retry_count => 99,
        next_retry_at_ms => 0
    },
    ?assertEqual(
        Repair,
        ecai_patch_manager:
            terminalize_exhausted_retry_wait(Repair, 6)
    ).

binary_retry_wait_status_is_supported_test() ->
    Repair = #{
        status => <<"retry_wait">>,
        retry_count => 6,
        last_error => {orphaned_worker, <<"old">>}
    },
    Terminal =
        ecai_patch_manager:
            terminalize_exhausted_retry_wait(Repair, 6),
    ?assertEqual(failed, maps:get(status, Terminal)),
    ?assertEqual(false, maps:get(retryable, Terminal)).
