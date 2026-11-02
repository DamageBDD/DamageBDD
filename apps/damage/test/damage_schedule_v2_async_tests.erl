%% Isolated coordinator regressions: real gen_server and DETS, mocked chain.
%% Do not run these tests against an already running damage application.
-module(damage_schedule_v2_async_tests).
-include_lib("eunit/include/eunit.hrl").
-define(OWNER, <<"ak_fixture_owner">>).
-define(TABLE, damage_schedule_v2_store).

admission_deduplicates_and_keeps_reads_responsive_test() ->
    fixture(fun() ->
        Spec = spec(),
        {ok, #{operation_id := Id}} = damage_schedule_v2:create(?OWNER, Spec),
        {Worker, _ScheduleId} = await_backend(),
        ?assertEqual({ok, []}, damage_schedule_v2:list(?OWNER)),
        {ok, #{operation_id := Id, stage := create_schedule}} = damage_schedule_v2:create(?OWNER, Spec),
        ?assertEqual({error, not_found}, damage_schedule_v2:operation(<<"ak_other">>, Id)),
        Worker ! {fixture_reply, {ok, #{return_type => ok}}},
        Done = await_status(Id, complete, 100),
        ?assertEqual(<<"active">>, maps:get(status, maps:get(result, Done))),
        ?assertEqual(1, meck:num_calls(damage_schedule_v2_contract, create_schedule, 2)),
        ?assertEqual(1, meck:num_calls(damage_schedule_v2_contract, fund_schedule, 3)),
        {ok, #{operation_id := Id, status := complete}} = damage_schedule_v2:create(?OWNER, Spec)
    end).

explicit_key_conflict_test() ->
    fixture(fun() ->
        Spec = (spec())#{request_id => <<"fixed-request">>},
        {ok, #{operation_id := Id}} = damage_schedule_v2:create(?OWNER, Spec),
        {Worker, _} = await_backend(),
        ?assertEqual({error, idempotency_conflict}, damage_schedule_v2:create(?OWNER,
            Spec#{lock_amount => 20000})),
        Worker ! {fixture_reply, {ok, #{return_type => ok}}},
        _ = await_status(Id, complete, 100)
    end).

confirmation_timeout_does_not_approve_or_fund_test() ->
    fixture(fun() ->
        {ok, #{operation_id := Id}} = damage_schedule_v2:create(?OWNER, spec()),
        {Worker, _} = await_backend(),
        Worker ! {fixture_reply, {error, {tx_poll_timeout, #{tx_hash => <<"th_123ABC">>}}}},
        Done = await_status(Id, reconciliation_required, 100),
        ?assertEqual(<<"th_123ABC">>, maps:get(tx_hash, Done)),
        ?assertEqual(0, meck:num_calls(damage_schedule_v2_contract, approve_allowance, 2)),
        ?assertEqual(0, meck:num_calls(damage_schedule_v2_contract, fund_schedule, 3)),
        ?assertEqual({error, schedule_operation_in_progress},
            damage_schedule_v2:create(?OWNER, (spec())#{request_id => <<"replacement">>}))
    end).

interrupted_worker_is_not_replayed_after_restart_test() ->
    fixture(fun() ->
        {ok, #{operation_id := Id}} = damage_schedule_v2:create(?OWNER, spec()),
        {_Worker, _} = await_backend(),
        ok = gen_server:stop(damage_schedule_v2),
        {ok, Pid} = damage_schedule_v2:start_link(), unlink(Pid),
        {ok, #{status := reconciliation_required}} = damage_schedule_v2:operation(?OWNER, Id),
        ?assertEqual({error, schedule_operation_in_progress},
            damage_schedule_v2:create(?OWNER, (spec())#{request_id => <<"new">>})),
        receive {fixture_backend, _, _} -> ?assert(false) after 25 -> ok end
    end).

legacy_orphan_draft_is_visible_test() ->
    fixture(fun() ->
        ok = dets:insert(?TABLE, {{draft, ?OWNER, <<"sv2_legacy">>},
            #{owner => ?OWNER, id => <<"sv2_legacy">>, created_at => 1}}),
        ok = gen_server:stop(damage_schedule_v2),
        {ok, Pid} = damage_schedule_v2:start_link(), unlink(Pid),
        {ok, [#{status := reconciliation_required, stage := legacy_create,
            schedule_id := <<"sv2_legacy">>}]} = damage_schedule_v2:operations(?OWNER)
    end).

stale_timer_message_cannot_remove_current_timer_test() ->
    Ref = erlang:send_after(60000, self(), unused_fixture_timer),
    Token = make_ref(),
    State = #{timers => #{<<"sv2_fixture">> => {Ref, Token}}},
    try
        ?assertEqual({noreply, State}, damage_schedule_v2:handle_info(
            {schedule_due, <<"sv2_fixture">>, 1, make_ref()}, State)),
        ?assertEqual({noreply, State}, damage_schedule_v2:handle_info(
            {schedule_due, <<"sv2_fixture">>, 1}, State))
    after erlang:cancel_timer(Ref)
    end.

fixture(Fun) ->
    ?assertEqual(undefined, whereis(damage_schedule_v2)),
    Saved = application:get_env(damage, schedule_v2_data_dir),
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; V -> V end,
    Dir = filename:join(Root, "damage_schedule_async_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = application:set_env(damage, schedule_v2_data_dir, Dir),
    Mods = [damage_schedule_v2_contract, damage_config, damage_context, damage],
    Parent = self(),
    try
        ok = meck:new(Mods, [no_link, non_strict]),
        ok = meck:expect(damage_schedule_v2_contract, contract_address, fun() -> {ok, <<"ct_fixture">>} end),
        ok = meck:expect(damage_schedule_v2_contract, call_result_ok, fun(#{return_type := ok}) -> true; (_) -> false end),
        ok = meck:expect(damage_schedule_v2_contract, create_schedule, fun(_, Draft) ->
            Parent ! {fixture_backend, self(), maps:get(id, Draft)},
            receive {fixture_reply, Reply} -> Reply after 3000 -> error(fixture_release_missing) end
        end),
        ok = meck:expect(damage_schedule_v2_contract, approve_allowance, fun(_, _) -> {ok, #{return_type => ok}} end),
        ok = meck:expect(damage_schedule_v2_contract, fund_schedule, fun(_, _, _) -> {ok, #{return_type => ok}} end),
        ok = meck:expect(damage_config, get_default_config, fun(X) -> X end),
        ok = meck:expect(damage_context, get_global_template_context, fun(_) -> #{} end),
        ok = meck:expect(damage_context, get_context, fun(_) -> #{} end),
        ok = meck:expect(damage, execute_data, fun(_, _, _) ->
            #{cost => 100, feature_hash => <<"fixture_hash">>, feature_title => <<"Feature: Fixture">>}
        end),
        {ok, Pid} = damage_schedule_v2:start_link(), unlink(Pid),
        Fun()
    after
        case whereis(damage_schedule_v2) of undefined -> ok; S -> gen_server:stop(S) end,
        meck:unload(Mods),
        case Saved of undefined -> application:unset_env(damage, schedule_v2_data_dir);
            {ok, Value} -> application:set_env(damage, schedule_v2_data_dir, Value) end,
        file:del_dir_r(Dir)
    end.

spec() ->
    Now = erlang:system_time(second),
    #{feature => <<"Feature: Fixture\nScenario: fixture\nGiven test\n">>,
      cron_spec => <<"*/15 * * * *">>, start_at => Now, end_at => Now + 3600,
      lock_amount => 10000, concurrency => 1}.

await_backend() ->
    receive {fixture_backend, Worker, Id} -> {Worker, Id}
    after 1500 -> error(fixture_backend_not_entered)
    end.

await_status(_Id, _Status, 0) -> error(operation_did_not_finish);
await_status(Id, Status, Left) ->
    case damage_schedule_v2:operation(?OWNER, Id) of
        {ok, #{status := Status} = Op} -> Op;
        _ -> timer:sleep(10), await_status(Id, Status, Left - 1)
    end.
