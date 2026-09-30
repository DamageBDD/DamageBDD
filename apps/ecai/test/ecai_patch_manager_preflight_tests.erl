-module(ecai_patch_manager_preflight_tests).

-include_lib("eunit/include/eunit.hrl").

blocked_preflight_clears_worker_lifecycle_test() ->
    Running = #{
        status => running,
        stage => inference,
        retryable => false,
        worker_pid => self(),
        worker_started_at => <<"old-start">>,
        next_retry_at_ms => 123,
        completed_at => <<"old-complete">>,
        retry_count => 2,
        fingerprint => <<"fp">>,
        finding_version => <<"v">>
    },
    Blocked = #{
        status => blocked,
        stage => source_snapshot_blocked,
        retryable => false,
        failure_class => source_snapshot_blocked,
        last_error => {source_snapshot_blocked,
                       #{kind => source_base_mismatch}},
        updated_at => <<"blocked-at">>
    },
    Result =
        ecai_patch_manager:normalize_preflight_terminal(
            blocked, Blocked, Running),
    ?assertEqual(blocked, maps:get(status, Result)),
    ?assertEqual(false, maps:get(retryable, Result)),
    ?assertEqual(source_snapshot_blocked,
                 maps:get(stage, Result)),
    ?assertEqual(2, maps:get(retry_count, Result)),
    ?assertNot(maps:is_key(worker_pid, Result)),
    ?assertNot(maps:is_key(worker_started_at, Result)),
    ?assertNot(maps:is_key(next_retry_at_ms, Result)),
    ?assertNot(maps:is_key(completed_at, Result)).

superseded_preflight_clears_orphan_retry_state_test() ->
    Running = #{
        status => running,
        stage => inference,
        worker_started_at => <<"start">>,
        next_retry_at_ms => 999,
        failure_class => orphaned_worker,
        last_error => {orphaned_worker, <<"start">>},
        retry_count => 4
    },
    Superseded = #{
        status => superseded,
        stage => preflight_superseded,
        retryable => false,
        failure_class => stale_finding_version,
        current_finding_version => <<"new-version">>
    },
    Result =
        ecai_patch_manager:normalize_preflight_terminal(
            superseded, Superseded, Running),
    ?assertEqual(superseded, maps:get(status, Result)),
    ?assertEqual(preflight_superseded,
                 maps:get(stage, Result)),
    ?assertEqual(stale_finding_version,
                 maps:get(failure_class, Result)),
    ?assertEqual(false, maps:get(retryable, Result)),
    ?assertNot(maps:is_key(worker_started_at, Result)),
    ?assertNot(maps:is_key(next_retry_at_ms, Result)).
