-module(ecai_patch_manager_retry_exhaustion_tests).

-include_lib("eunit/include/eunit.hrl").

exhausted_retry_wait_becomes_terminal_test() ->
    with_store_mock(fun() ->
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
            worker_pid => self(),
            fingerprint => <<"fp">>,
            finding_version => <<"version">>
        },
        Terminal =
            ecai_patch_manager:terminalize_exhausted_retry_wait(
                Repair, 6
            ),
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
        ?assert(maps:is_key(completed_at, Terminal)),
        ?assertNot(maps:is_key(worker_pid, Terminal)),
        ?assert(
            meck:called(
                ecai_learning_store,
                put_repair,
                [<<"fp">>, <<"version">>, Terminal]
            )
        ),
        ?assertEqual(1, meck:num_calls(ecai_learning_store, put_repair, 3)),
        %% A second pass through a terminal record must not persist it again.
        ?assertEqual(
            Terminal,
            ecai_patch_manager:terminalize_exhausted_retry_wait(Terminal, 6)
        ),
        ?assertEqual(1, meck:num_calls(ecai_learning_store, put_repair, 3))
    end).

retry_wait_below_limit_is_unchanged_test() ->
    with_store_mock(fun() ->
        Repair = #{
            status => retry_wait,
            retryable => true,
            retry_count => 2,
            next_retry_at_ms => 123
        },
        ?assertEqual(
            Repair,
            ecai_patch_manager:terminalize_exhausted_retry_wait(
                Repair, 6
            )
        ),
        ?assertEqual(0, meck:num_calls(ecai_learning_store, put_repair, 3))
    end).

queued_record_is_not_terminalized_test() ->
    with_store_mock(fun() ->
        Repair = #{
            status => queued,
            retry_count => 99,
            next_retry_at_ms => 0
        },
        ?assertEqual(
            Repair,
            ecai_patch_manager:terminalize_exhausted_retry_wait(
                Repair, 6
            )
        ),
        ?assertEqual(0, meck:num_calls(ecai_learning_store, put_repair, 3))
    end).

binary_retry_wait_status_is_supported_test() ->
    with_store_mock(fun() ->
        Repair = #{
            status => <<"retry_wait">>,
            retry_count => 6,
            fingerprint => <<"binary-fp">>,
            finding_version => <<"version">>,
            last_error => {orphaned_worker, <<"old">>}
        },
        Terminal =
            ecai_patch_manager:terminalize_exhausted_retry_wait(
                Repair, 6
            ),
        ?assertEqual(failed, maps:get(status, Terminal)),
        ?assertEqual(false, maps:get(retryable, Terminal)),
        ?assert(
            meck:called(
                ecai_learning_store,
                put_repair,
                [<<"binary-fp">>, <<"version">>, Terminal]
            )
        ),
        ?assertEqual(1, meck:num_calls(ecai_learning_store, put_repair, 3))
    end).

terminalization_does_not_hide_store_failure_test() ->
    with_store_mock(fun() ->
        ok = meck:expect(
            ecai_learning_store,
            put_repair,
            fun(_, _, _) -> {error, injected_store_failure} end
        ),
        Repair = #{
            status => retry_wait,
            retry_count => 6,
            fingerprint => <<"failed-write">>,
            finding_version => <<"v1">>
        },
        ?assertError(
            {badmatch, {error, injected_store_failure}},
            ecai_patch_manager:terminalize_exhausted_retry_wait(Repair, 6)
        ),
        ?assertEqual(1, meck:num_calls(ecai_learning_store, put_repair, 3))
    end).

with_store_mock(Fun) ->
    %% Test the transition plus its persistence request, not DETS or the
    %% node-global learning-store lifecycle. No original functions may run.
    ok = meck:new(ecai_learning_store, []),
    try
        ok = meck:expect(ecai_learning_store, put_repair, fun(_, _, _) -> ok end),
        Result = Fun(),
        ?assert(meck:validate(ecai_learning_store)),
        Result
    after
        ok = meck:unload(ecai_learning_store)
    end.
