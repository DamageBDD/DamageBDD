-module(ecai_patch_resilience_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real DETS, manager, supervisor and patch workers. Only source-analysis/report
%% boundaries are mocked: no inference service or DamageBDD node is contacted.

stale_pid_attachment_cannot_overwrite_completion_test() ->
    with_fixture(fun(_) ->
        Before = save(repair(running)),
        Finished = save(Before#{status => validated, stage => terminal}),
        ?assertEqual({error, conflict}, ecai_learning_store:compare_and_put_repair(
            <<"fp">>, <<"v1">>, Before, Before#{worker_pid => self()})),
        ?assertEqual(Finished, current())
    end).

stale_worker_cannot_publish_into_newer_revision_test() ->
    with_fixture(fun(_) ->
        Before = save((repair(running))#{worker_pid => self()}),
        Finished = save(Before#{status => validated}),
        ?assertEqual({error, conflict}, ecai_patch_worker:persist_worker_update(
            <<"fp">>, <<"v1">>, Before, Before#{status => failed},
            #{worker_id => {<<"fp">>, <<"v1">>}})),
        ?assertEqual(Finished, current())
    end).

competing_recovery_charges_only_once_test() ->
    with_fixture(fun(_) ->
        Before = save(repair(running)),
        Parent = self(),
        Ref = make_ref(),
        Work = fun() ->
            receive go ->
                Parent ! {Ref, ecai_patch_lifecycle:recover(
                    Before, {worker_down, killed}, options())}
            end
        end,
        P1 = spawn(Work), P2 = spawn(Work),
        P1 ! go, P2 ! go,
        R1 = receive {Ref, A} -> A after 2000 -> error(recovery_timeout) end,
        R2 = receive {Ref, B} -> B after 2000 -> error(recovery_timeout) end,
        ?assert(lists:member({ok, unchanged}, [R1, R2])),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assertEqual(retry_wait, maps:get(status, current()))
    end).

recovery_does_not_undo_a_terminal_result_test() ->
    with_fixture(fun(_) ->
        Before = save(repair(running)),
        Finished = save(Before#{status => validated}),
        ?assertEqual({ok, unchanged}, ecai_patch_lifecycle:recover(
            Before, {orphaned_worker, undefined}, options())),
        ?assertEqual(Finished, current())
    end).

recovery_preserves_saved_work_and_honours_backoff_test() ->
    R = (repair(running))#{attempt => 2, patch => <<"saved diff">>,
        verifier_output => #{status => failed}, inference_history => [#{attempt => 1}]},
    Now = erlang:system_time(millisecond),
    Failed = ecai_patch_lifecycle:failure_record(R, {orphaned_worker, undefined}, options()),
    ?assertEqual(2, maps:get(attempt, Failed)),
    ?assertEqual(<<"saved diff">>, maps:get(patch, Failed)),
    ?assertEqual(maps:get(verifier_output, R), maps:get(verifier_output, Failed)),
    ?assertEqual(maps:get(inference_history, R), maps:get(inference_history, Failed)),
    ?assert(maps:get(next_retry_at_ms, Failed) >= Now + 60000),
    ?assertNot(ecai_patch_retry:due(Failed, Now)),
    %% The legacy orphan preflight must not erase this real crash's backoff.
    ?assertNot(ecai_patch_manager:is_orphan_retry_wait(Failed)).

retry_limit_is_terminal_at_equality_test() ->
    Failed = ecai_patch_lifecycle:failure_record(
        (repair(running))#{retry_count => 2, worker_pid => self(),
            dispatch_pid => self(), next_retry_at_ms => 1},
        {worker_down, killed}, options()),
    ?assertEqual(3, maps:get(retry_count, Failed)),
    ?assertEqual(failed, maps:get(status, Failed)),
    ?assertEqual(false, maps:get(retryable, Failed)),
    ?assert(maps:is_key(completed_at, Failed)),
    ?assertNot(maps:is_key(worker_pid, Failed)),
    ?assertNot(maps:is_key(dispatch_pid, Failed)),
    ?assertNot(maps:is_key(next_retry_at_ms, Failed)).

live_dispatch_reservation_is_not_an_orphan_test() ->
    R = (repair(running))#{dispatch_pid => self(), updated_at_ms => 1},
    ?assertNot(ecai_patch_reconciler:should_recover(
        R, {<<"fp">>, <<"v1">>}, #{}, {1000000, 0})).

live_worker_pid_is_not_an_orphan_test() ->
    R = (repair(running))#{worker_pid => self(), updated_at_ms => 1},
    ?assertNot(ecai_patch_reconciler:should_recover(
        R, {<<"fp">>, <<"v1">>}, #{}, {1000000, 0})).

recovery_survives_store_restart_test() ->
    with_fixture(fun(#{root := Root}) ->
        Before = save(repair(running)),
        {ok, Recovered} = ecai_patch_lifecycle:recover(Before, {worker_down, killed}, options()),
        ok = ecai_learning_store:stop(),
        {ok, Store} = ecai_learning_store:start_link(#{state_root => Root}), unlink(Store),
        ?assertEqual(Recovered, current()),
        ?assertEqual({error, conflict}, ecai_learning_store:compare_and_put_repair(
            <<"fp">>, <<"v1">>, Before, Before))
    end).

status_remains_responsive_during_blocked_scan_test() ->
    with_fixture(fun(_) ->
        block_reports(self()),
        Manager = start_manager(#{}),
        ecai_patch_manager:scan_now(),
        Runner = await_report_runner(),
        Status = gen_server:call(Manager, status, 500),
        ?assertEqual(true, maps:get(cycle_running, Status)),
        ?assertEqual(Runner, maps:get(pid, maps:get(cycle, Status))),
        Runner ! release,
        await(fun() -> not maps:get(cycle_running, ecai_patch_manager:status()) end)
    end).

repeated_manual_scans_coalesce_test() ->
    with_fixture(fun(_) ->
        block_reports(self()),
        Manager = start_manager(#{}),
        ecai_patch_manager:scan_now(),
        First = await_report_runner(),
        [ecai_patch_manager:scan_now() || _ <- lists:seq(1, 50)],
        S = gen_server:call(Manager, status, 500),
        ?assert(maps:get(scan_pending, S)),
        ?assertEqual(First, maps:get(pid, maps:get(cycle, S))),
        First ! release,
        Second = await_report_runner(),
        ?assertNotEqual(First, Second),
        Second ! release,
        await(fun() -> not maps:get(cycle_running, ecai_patch_manager:status()) end),
        ?assertEqual(2, maps:get(cycles, ecai_patch_manager:status())),
        receive {report_runner, _} -> error(extra_scan) after 50 -> ok end
    end).

killed_worker_is_recovered_without_killing_manager_test() ->
    with_fixture(fun(_) ->
        block_context(self()), save(repair(queued)),
        Manager = start_manager(#{}), Manager ! retry_tick,
        Worker = await_context_worker(),
        await(fun() -> maps:get(active, ecai_patch_manager:status()) =:= 1 end),
        exit(Worker, kill),
        await_status(retry_wait),
        ?assert(erlang:is_process_alive(Manager)),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assertEqual(worker_down, maps:get(failure_class, current())),
        ?assert(maps:get(next_retry_at_ms, current()) > erlang:system_time(millisecond))
    end).

early_context_error_has_a_durable_retry_record_test() ->
    with_fixture(fun(_) ->
        save(repair(queued)),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await_status(retry_wait),
        ?assertEqual(worker_error, maps:get(failure_class, current())),
        ?assertEqual({worker_error, analysis_unavailable}, maps:get(last_error, current())),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assert(erlang:is_process_alive(Manager))
    end).

worker_exception_does_not_strand_running_record_test() ->
    with_fixture(fun(_) ->
        meck:expect(ecai_code_context, for_vulnerability,
            fun(_, _, _, _) -> erlang:error(injected_worker_crash) end),
        save(repair(queued)),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await_status(retry_wait),
        ?assertMatch({worker_error, {worker_exception, error, injected_worker_crash, _}},
            maps:get(last_error, current())),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assert(erlang:is_process_alive(Manager))
    end).

fast_terminal_worker_result_is_not_overwritten_test() ->
    with_fixture(fun(_) ->
        meck:expect(ecai_code_context, for_vulnerability, fun(_, _, _, _) ->
            Before = current(),
            _ = save((maps:remove(worker_pid, Before))#{status => validated, stage => terminal}),
            {error, already_finished}
        end),
        save(repair(queued)),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await_status(validated),
        await(fun() -> maps:get(active, ecai_patch_manager:status()) =:= 0 andalso
            not maps:get(cycle_running, ecai_patch_manager:status()) end),
        ?assertEqual(validated, maps:get(status, current())),
        ?assertEqual(0, maps:get(retry_count, current(), 0))
    end).

manager_restart_adopts_live_worker_without_duplicate_test() ->
    with_fixture(fun(_) ->
        block_context(self()), save(repair(queued)),
        First = start_manager(#{}), First ! retry_tick,
        Worker = await_context_worker(),
        %% Adoption is announced before dispatch finishes. Wait for the whole
        %% cycle, not merely active=1, before asserting no replacement started.
        AwaitAdoption = fun() ->
            await(fun() ->
                S = ecai_patch_manager:status(),
                maps:get(active, S) =:= 1 andalso
                    maps:get(snapshot_ready, S) andalso
                    not maps:get(cycle_running, S)
            end)
        end,
        try
            AwaitAdoption(),
            BeforeRestart = current(),
            stop(ecai_patch_manager),
            ?assert(erlang:is_process_alive(Worker)),
            Second = start_manager(#{}), Second ! retry_tick,
            AwaitAdoption(),
            ?assertNotEqual(First, Second),
            ?assert(erlang:is_process_alive(Worker)),
            ?assertEqual(Worker, maps:get(worker_pid, current())),
            ?assertEqual(BeforeRestart, current()),
            ?assertMatch(
                [{{ecai_patch_worker, <<"fp">>, <<"v1">>}, Worker, worker, _}],
                supervisor:which_children(ecai_patch_sup)),
            ?assertEqual(undefined, maps:get(last_error, ecai_patch_manager:status()))
        after
            %% Also unblock the mock when an adoption assertion fails.
            Worker ! release
        end,
        await_status(retry_wait),
        %% Meck adds history AFTER the expectation returns. Its history update
        %% is asynchronous, so wait for visibility before asserting the count.
        await(fun() ->
            meck:num_calls(ecai_code_context, for_vulnerability, 4) >= 1
        end),
        ?assertEqual(1, meck:num_calls(ecai_code_context, for_vulnerability, 4)),
        ?assertEqual(1, meck:num_calls(ecai_code_context, for_vulnerability, 4, Worker)),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assertEqual({worker_error, injected_context_failure},
            maps:get(last_error, current()))
    end).

killed_manager_does_not_leak_its_cycle_runner_test() ->
    with_fixture(fun(_) ->
        block_reports(self()),
        Manager = start_manager(#{}), ecai_patch_manager:scan_now(),
        Runner = await_report_runner(),
        exit(Manager, kill),
        await(fun() -> not erlang:is_process_alive(Manager) end),
        await(fun() -> not erlang:is_process_alive(Runner) end)
    end).

cycle_timeout_is_contained_and_error_clears_on_success_test() ->
    with_fixture(fun(_) ->
        block_reports(self()),
        Manager = start_manager(#{cycle_timeout_ms => 100}),
        ecai_patch_manager:scan_now(),
        Runner = await_report_runner(),
        await(fun() -> maps:get(cycle_failures, ecai_patch_manager:status()) =:= 1 end),
        ?assertNot(erlang:is_process_alive(Runner)),
        ?assert(erlang:is_process_alive(Manager)),
        ?assertEqual([{patch_cycle_timeout, scan}], maps:get(last_error, ecai_patch_manager:status())),
        meck:expect(ecai_vuln_monitor, app_findings, fun(_) -> [] end),
        ecai_patch_manager:scan_now(),
        await(fun() -> maps:get(last_error, ecai_patch_manager:status()) =:= undefined end),
        ?assertMatch(#{errors := [_]}, maps:get(last_failure, ecai_patch_manager:status()))
    end).

late_result_cannot_clear_a_cycle_timeout_test() ->
    with_fixture(fun(_) ->
        block_reports(self()),
        Manager = start_manager(#{}), ecai_patch_manager:scan_now(),
        _ = await_report_runner(),
        %% Locate the internal task by shape rather than hard-coding record offsets.
        [Task] = [M || M <- tuple_to_list(sys:get_state(Manager)),
            is_map(M), maps:is_key(mref, M), maps:is_key(kind, M)],
        Ref = maps:get(ref, Task),
        Manager ! {timeout, maps:get(timer, Task), {patch_cycle_timeout, Ref}},
        Manager ! {patch_cycle_result, Ref, #{errors => []}},
        await(fun() -> maps:get(cycle_failures, ecai_patch_manager:status()) =:= 1 end),
        ?assertEqual([{patch_cycle_timeout, scan}], maps:get(last_error, ecai_patch_manager:status()))
    end).

missing_supervisor_is_not_an_empty_worker_set_test() ->
    with_fixture(fun(_) ->
        Before = save(repair(running)),
        stop(ecai_patch_sup),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await(fun() -> maps:get(last_error, ecai_patch_manager:status()) =/= undefined end),
        ?assertEqual(Before, current()),
        ?assertNotEqual(undefined, maps:get(snapshot_error, ecai_patch_manager:status())),
        ?assert(erlang:is_process_alive(Manager))
    end).

unavailable_store_preserves_last_snapshot_test() ->
    with_fixture(fun(_) ->
        save((repair(retry_wait))#{next_retry_at_ms => erlang:system_time(millisecond) + 60000}),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await(fun() -> maps:get(snapshot_ready, ecai_patch_manager:status()) end),
        ?assertEqual(1, maps:get(pending, ecai_patch_manager:status())),
        stop(ecai_learning_store), Manager ! retry_tick,
        await(fun() -> maps:get(snapshot_error, ecai_patch_manager:status()) =/= undefined end),
        S = gen_server:call(Manager, status, 500),
        ?assertEqual(1, maps:get(pending, S)),
        ?assertNotEqual(undefined, maps:get(snapshot_error, S))
    end).

direct_proposals_have_durable_identity_and_no_duplicate_worker_test() ->
    with_fixture(fun(_) ->
        block_context(self()),
        Finding = maps:get(finding, repair(queued)),
        {ok, Worker} = ecai_patch_sup:propose(ecai, ecai_resilience_fixture, Finding, options()),
        ?assertEqual(Worker, await_context_worker()),
        ?assertMatch([{{ecai_patch_worker, <<"fp">>, <<"v1">>}, Worker, _, _}],
            supervisor:which_children(ecai_patch_sup)),
        ?assertEqual({error, {already_started, Worker}},
            ecai_patch_sup:propose(ecai, ecai_resilience_fixture, Finding, options())),
        Worker ! release,
        await_status(retry_wait),
        ?assertEqual(1, maps:get(retry_count, current()))
    end).

malformed_report_does_not_abort_other_reports_test() ->
    with_fixture(fun(_) ->
        meck:expect(ecai_vuln_monitor, app_findings, fun
            (damage) -> [not_a_map];
            (_) -> []
        end),
        Manager = start_manager(#{}), ecai_patch_manager:scan_now(),
        await(fun() -> maps:get(cycles, ecai_patch_manager:status()) =:= 1 end),
        ?assert(erlang:is_process_alive(Manager)),
        ?assertEqual(3, meck:num_calls(ecai_vuln_monitor, app_findings, 1))
    end).

reconciler_uses_the_same_bounded_transition_test() ->
    with_fixture(fun(_) ->
        save((repair(running))#{updated_at_ms => 1}),
        {ok, Pid} = ecai_patch_reconciler:start_link((options())#{grace_ms => 0}),
        unlink(Pid),
        Summary = ecai_patch_reconciler:run_now(),
        ?assertEqual(1, maps:get(recovered_running, Summary)),
        ?assertEqual(retry_wait, maps:get(status, current())),
        ?assertEqual(1, maps:get(retry_count, current())),
        Summary2 = ecai_patch_reconciler:run_now(),
        ?assertEqual(0, maps:get(recovered_running, Summary2)),
        ?assertEqual(1, maps:get(retry_count, current()))
    end).

dead_dispatch_reservation_is_recovered_on_startup_test() ->
    with_fixture(fun(_) ->
        Pid = spawn(fun() -> ok end),
        await(fun() -> not erlang:is_process_alive(Pid) end),
        save((repair(running))#{dispatch_pid => Pid}),
        Manager = start_manager(#{}), Manager ! retry_tick,
        await_status(retry_wait),
        ?assertEqual(1, maps:get(retry_count, current())),
        ?assertEqual(0, meck:num_calls(ecai_code_context, for_vulnerability, 4)),
        ?assert(maps:get(next_retry_at_ms, current()) > erlang:system_time(millisecond))
    end).

failed_recovery_write_is_not_reported_as_success_test() ->
    with_mocks([ecai_learning_store], fun() ->
        meck:expect(ecai_learning_store, compare_and_put_repair,
            fun(_, _, _, _) -> {error, disk_full} end),
        ?assertEqual({error, {recovery_persist_failed, <<"fp">>, <<"v1">>, {error, disk_full}}},
            ecai_patch_lifecycle:recover(repair(running), {worker_down, killed}, options()))
    end).

preflight_persistence_failure_never_returns_allow_test() ->
    with_mocks([ecai_learning_store, ecai_code_context, ecai_git_snapshot], fun() ->
        meck:expect(ecai_learning_store, get_analysis, fun(_, _) -> {ok, #{}} end),
        meck:expect(ecai_learning_store, get_repair, fun(_, _) -> not_found end),
        meck:expect(ecai_learning_store, compare_and_put_repair,
            fun(_, _, _, _) -> {error, disk_full} end),
        meck:expect(ecai_code_context, finding_version, fun(_, _, _) -> <<"v1">> end),
        meck:expect(ecai_git_snapshot, check_analysis,
            fun(_, _) -> {error, #{kind => source_base_mismatch}} end),
        ?assertEqual({error, {<<"fp">>, <<"v1">>, {error, disk_full}}},
            ecai_repair_preflight:check(ecai, ecai_resilience_fixture,
                maps:get(finding, repair(queued)), <<"fp">>, <<"v1">>,
                #{preflight_source_snapshot => true}))
    end).

with_mocks(Modules, Fun) ->
    try
        [ok = meck:new(M, [non_strict, no_link]) || M <- Modules],
        Fun()
    after
        [try meck:unload(M) catch _:_ -> ok end || M <- Modules]
    end.

%% Fixtures deliberately use long periodic timers; each test requests work.
options() ->
    #{require_global_learning => false, preflight_source_snapshot => false,
        orphan_preflight_batch => 0, retry_limit => 3, retry_base_ms => 60000,
        retry_max_ms => 60000, interval_ms => 600000, retry_tick_ms => 600000,
        initial_scan_delay_ms => 600000, initial_retry_delay_ms => 600000,
        cycle_timeout_ms => 5000}.

repair(Status) ->
    #{fingerprint => <<"fp">>, finding_version => <<"v1">>, application => ecai,
        module => ecai_resilience_fixture, status => Status, retry_count => 0,
        finding => #{<<"fingerprint">> => <<"fp">>, <<"severity">> => <<"high">>}}.

save(Repair) ->
    ok = ecai_learning_store:put_repair(<<"fp">>, <<"v1">>, Repair),
    current().

current() ->
    {ok, Repair} = ecai_learning_store:get_repair(<<"fp">>, <<"v1">>),
    Repair.

start_manager(Extra) ->
    {ok, Pid} = ecai_patch_manager:start_link(maps:merge(options(), Extra)),
    unlink(Pid),
    Pid.

block_context(Parent) ->
    meck:expect(ecai_code_context, for_vulnerability, fun(_, _, _, _) ->
        Parent ! {context_worker, self()},
        receive release -> {error, injected_context_failure} end
    end).

block_reports(Parent) ->
    meck:expect(ecai_vuln_monitor, app_findings, fun
        (damage) -> Parent ! {report_runner, self()}, receive release -> [] end;
        (_) -> []
    end).

await_context_worker() ->
    receive {context_worker, Pid} -> Pid after 2000 -> error(context_worker_timeout) end.
await_report_runner() ->
    receive {report_runner, Pid} -> Pid after 2000 -> error(report_runner_timeout) end.
await_status(Status) -> await(fun() -> maps:get(status, current()) =:= Status end).
await(Fun) -> await(Fun, erlang:monotonic_time(millisecond) + 2000).
await(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(condition_timeout);
                false -> timer:sleep(10), await(Fun, Deadline)
            end
    end.

with_fixture(Fun) ->
    Root = filename:join("/tmp", "ecai-resilience-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    Mocks = [ecai_code_context, ecai_vuln_monitor, ecai_repair_feedback],
    try
        [ok = meck:new(M, [non_strict, no_link]) || M <- Mocks],
        meck:expect(ecai_code_context, finding_version, fun(_, _, _) -> <<"v1">> end),
        meck:expect(ecai_code_context, for_vulnerability,
            fun(_, _, _, _) -> {error, analysis_unavailable} end),
        meck:expect(ecai_vuln_monitor, app_findings, fun(_) -> [] end),
        meck:expect(ecai_repair_feedback, replay, fun() -> ok end),
        {ok, Store} = ecai_learning_store:start_link(#{state_root => Root}), unlink(Store),
        {ok, Sup} = ecai_patch_sup:start_link(), unlink(Sup),
        Fun(#{root => Root})
    after
        stop(ecai_patch_reconciler), stop(ecai_patch_manager),
        stop(ecai_patch_sup), stop(ecai_learning_store),
        [try meck:unload(M) catch _:_ -> ok end || M <- Mocks],
        _ = file:del_dir_r(Root)
    end.

stop(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            try gen_server:stop(Pid, normal, 3000)
            catch _:_ -> exit(Pid, kill) end,
            await(fun() -> not erlang:is_process_alive(Pid) end)
    end.
