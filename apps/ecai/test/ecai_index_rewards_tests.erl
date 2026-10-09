-module(ecai_index_rewards_tests).
-include_lib("eunit/include/eunit.hrl").

funded_ledger_survives_restart_test() -> with_service(fun(Cfg) ->
    {Id, _} = fund(),
    stop_service(),
    {ok, _} = start_service(Cfg),
    {ok, C} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, C)),
    ?assertEqual(false, maps:get(cln_operation_in_flight, ecai_index_rewards:status()))
end).

invoice_notification_is_only_a_requery_hint_test() -> with_service(fun(_Cfg) ->
    {ok, C} = ecai_index_rewards:create(<<"creator">>, <<"event-test">>, ecai_index_reward_ledger_tests:terms(500000)),
    Id = maps:get(id, C),
    {ok, _} = ecai_index_rewards:funding_invoice(<<"creator">>, Id), wait_idle(100),
    whereis(ecai_index_rewards) ! {cln_event, invoice_paid,
        #{label => maps:get(funding_label, C), amount_received_msat => 999999999}},
    wait_idle(100),
    {ok, Checked} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, Checked))
end).

crash_during_payment_requires_reconciliation_test() -> with_service(fun(Cfg) ->
    {Id, _} = fund(), H = fun ecai_index_reward_ledger_tests:hash/1, U = H(<<"unit1">>),
    {ok, _} = ecai_index_rewards:allocate(<<"creator">>, Id, U, <<"indexer">>, <<"verifier">>),
    {ok, _} = ecai_index_rewards:submit(<<"indexer">>, Id, U, H(<<"artifact">>), H(<<"evidence">>)),
    {ok, _} = ecai_index_rewards:attest(<<"verifier">>, Id, U, H(<<"artifact">>), accept, H(<<"report">>)),
    {ok, Accepted} = ecai_index_rewards:accept_work(<<"creator">>, Id, U, H(<<"artifact">>), accept),
    [P] = [X || X <- maps:get(payouts, Accepted), maps:get(role, X) =:= index],
    Pid = maps:get(id, P),
    D0 = ecai_index_reward_ledger_tests:invoice(Id, P, 17),
    D = D0#{created_at => erlang:system_time(second)},
    persistent_term:put({ecai_index_rewards_test_backend, decoded}, D),
    {ok, _} = ecai_index_rewards:submit_invoice(<<"indexer">>, Id, Pid, <<"mock-invoice">>),
    ?assertEqual({error, explicit_payment_confirmation_required}, ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"yes">>)),
    {ok, _} = ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"pay indexing reward">>),
    Worker = receive {fake_payment_started, W, _} -> W after 1000 -> error(payment_not_started) end,
    try
        stop_service(),
        exit(Worker, kill),
        {ok, _} = start_service(Cfg),
        {ok, Recovered} = ecai_index_rewards:campaign(Id),
        [R] = [X || X <- maps:get(payouts, Recovered), maps:get(id, X) =:= Pid],
        ?assertEqual(uncertain, maps:get(state, R)),
        ?assertEqual(122000, maps:get(reserved_msat, Recovered)),
        ?assertEqual({error, payout_not_ready}, ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"pay indexing reward">>)),
        {ok, _} = ecai_index_rewards:reconcile(<<"creator">>, Id, Pid),
        wait_idle(100),
        {ok, Settled} = ecai_index_rewards:campaign(Id),
        ?assertEqual(100250, maps:get(spent_msat, Settled)),
        receive {fake_payment_started, _, _} -> error(payment_was_resent) after 0 -> ok end
    after
        exit(Worker, kill)
    end
end).

%% Startup errors are tested with an unlinked gen_server. A failed init must
%% produce an assertion result rather than an EXIT cancelling the EUnit group.
corrupt_dets_lookup_is_reported_without_reset_test() -> with_fixture(fun(Cfg) ->
    Object = {pool_participants, #{}},
    seed_storage(Cfg, [Object, {ledger, ecai_index_reward_ledger:new()}]),
    File = maps:get(ledger_file, Cfg),
    {ok, Bytes} = file:read_file(File),
    %% Locate this fixture's ETF object rather than assuming DETS byte offsets.
    %% Damage only its version byte; retain the table header and total length.
    [{Offset, _}] = binary:matches(Bytes, term_to_binary(Object)),
    <<Prefix:Offset/binary, 131, Suffix/binary>> = Bytes,
    Corrupt = <<Prefix/binary, 0, Suffix/binary>>,
    ok = file:write_file(File, Corrupt),
    ?assertMatch(
        {error, {reward_ledger_unavailable,
                 {lookup, pool_participants, {{bad_object, _}, _}}}},
        start_service(Cfg)
    ),
    assert_storage_released(),
    ?assertEqual({ok, Corrupt}, file:read_file(File))
end).

non_dets_file_is_not_recreated_test() -> with_fixture(fun(Cfg) ->
    File = maps:get(ledger_file, Cfg),
    Bytes = <<"not a DETS ledger; preserve this evidence">>,
    ok = file:write_file(File, Bytes),
    ?assertMatch({error, {reward_ledger_unavailable, {open, _}}}, start_service(Cfg)),
    assert_storage_released(),
    ?assertEqual({ok, Bytes}, file:read_file(File))
end).

invalid_participants_record_is_rejected_test() -> with_fixture(fun(Cfg) ->
    seed_storage(Cfg, [{ledger, ecai_index_reward_ledger:new()},
                       {pool_participants, not_a_map}]),
    assert_failed_start_preserves(Cfg, {invalid_record, pool_participants})
end).

unknown_ledger_schema_is_rejected_test() -> with_fixture(fun(Cfg) ->
    seed_storage(Cfg, [{ledger, #{schema => 999}}]),
    assert_failed_start_preserves(Cfg, {invalid_record, ledger})
end).

incomplete_ledger_record_is_rejected_test() -> with_fixture(fun(Cfg) ->
    seed_storage(Cfg, [{ledger, #{schema => 1, campaigns => #{}}}]),
    assert_failed_start_preserves(Cfg, {invalid_record, ledger})
end).

missing_ledger_with_participants_is_not_reset_test() -> with_fixture(fun(Cfg) ->
    seed_storage(Cfg, [{pool_participants, maps:get(participants, Cfg)}]),
    assert_failed_start_preserves(Cfg, {missing_record, ledger})
end).

existing_empty_dets_is_not_a_new_ledger_test() -> with_fixture(fun(Cfg) ->
    seed_storage(Cfg, []),
    assert_failed_start_preserves(Cfg, {missing_record, ledger})
end).

saved_participant_identities_are_restored_and_pinned_test() -> with_fixture(fun(Cfg) ->
    Account = <<"enrolled-worker">>,
    Node = ecai_index_reward_ledger_tests:node_id(9),
    seed_storage(Cfg, [{ledger, ecai_index_reward_ledger:new()},
                       {pool_participants, #{Account => Node}}]),
    {ok, _} = start_service(Cfg),
    {Restored, _} = gen_server:call(ecai_index_rewards, adapter),
    ?assertEqual(Node, maps:get(Account, maps:get(participants, Restored))),
    stop_service(),
    Conflicting = Cfg#{participants => (maps:get(participants, Cfg))#{
        Account => ecai_index_reward_ledger_tests:node_id(10)}},
    assert_failed_start_preserves(Conflicting, participant_identity_mismatch),
    {ok, _} = start_service(Cfg),
    ?assertEqual([], maps:get(campaigns, ecai_index_rewards:status()))
end).

treasury_mismatch_does_not_overwrite_funded_ledger_test() -> with_service(fun(Cfg) ->
    {Id, _} = fund(),
    stop_service(),
    Wrong = Cfg#{treasury_node => ecai_index_reward_ledger_tests:node_id(8)},
    assert_failed_start_preserves(Wrong, {validate, ledger_or_treasury_mismatch}),
    {ok, _} = start_service(Cfg),
    {ok, C} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, C))
end).

missing_storage_config_returns_error_test() -> with_fixture(fun(_Cfg) ->
    ?assertEqual({error, {reward_ledger_unavailable, {invalid_config, ledger_file}}},
                 start_service(#{})),
    assert_storage_released()
end).

fixtures_use_distinct_directories_and_clean_up_test() ->
    A = with_fixture(fun(Cfg) -> filename:dirname(maps:get(ledger_file, Cfg)) end),
    B = with_fixture(fun(Cfg) -> filename:dirname(maps:get(ledger_file, Cfg)) end),
    ?assertNotEqual(A, B),
    ?assertNot(filelib:is_dir(A)),
    ?assertNot(filelib:is_dir(B)).

fixture_cleans_up_after_assertion_error_test() ->
    ?assertError(injected_assertion_failure,
                 with_service(fun(_) -> error(injected_assertion_failure) end)),
    assert_storage_released(),
    %% A subsequent test can start a fresh coordinator, not an already_started one.
    with_service(fun(_) ->
        ?assertEqual([], maps:get(campaigns, ecai_index_rewards:status()))
    end).

assert_failed_start_preserves(Cfg, Reason) ->
    File = maps:get(ledger_file, Cfg),
    {ok, Before} = file:read_file(File),
    ?assertEqual({error, {reward_ledger_unavailable, Reason}}, start_service(Cfg)),
    assert_storage_released(),
    ?assertEqual({ok, Before}, file:read_file(File)).

assert_storage_released() ->
    ?assertEqual(undefined, whereis(ecai_index_rewards)),
    ?assertEqual(undefined, dets:info(ecai_index_reward_dets)).

seed_storage(Cfg, Objects) ->
    %% The seeder owns and closes a separate handle before starting the service.
    {ok, Tab} = dets:open_file(?MODULE, [{file, maps:get(ledger_file, Cfg)},
                                       {type, set}, {repair, false}]),
    try
        ok = dets:insert(Tab, Objects),
        ok = dets:sync(Tab)
    after
        ok = dets:close(Tab)
    end.

fund() ->
    {ok, C} = ecai_index_rewards:create(<<"creator">>, <<"service-test">>, ecai_index_reward_ledger_tests:terms(500000)),
    Id = maps:get(id, C),
    {ok, _} = ecai_index_rewards:funding_invoice(<<"creator">>, Id), wait_idle(100),
    {ok, _} = ecai_index_rewards:refresh_funding(<<"creator">>, Id), wait_idle(100),
    {ok, Funded} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, Funded)), {Id, Funded}.
wait_idle(0) -> error(operation_timeout);
wait_idle(N) ->
    case maps:get(cln_operation_in_flight, ecai_index_rewards:status()) of
        false -> ok; true -> timer:sleep(10), wait_idle(N-1)
    end.
with_service(F) ->
    with_fixture(fun(Cfg) ->
        {ok, _} = start_service(Cfg),
        F(Cfg)
    end).

with_fixture(F) ->
    %% Never stop a node's actual service, or reuse a ledger opened by another test.
    assert_storage_released(),
    Dir = make_tmp_dir(),
    try
        Cfg = (ecai_index_reward_ledger_tests:config())#{
            ledger_file => filename:join(Dir, "ledger.dets"),
            adapter => ecai_index_rewards_test_backend, test_pid => self()},
        F(Cfg)
    after
        try stop_service()
        after
            persistent_term:erase({ecai_index_rewards_test_backend, invoice}),
            persistent_term:erase({ecai_index_rewards_test_backend, decoded}),
            ok = file:del_dir_r(Dir)
        end
    end.

start_service(Cfg) ->
    %% Production start_link/1 is unchanged. Unlinked test startup keeps an
    %% unexpected init failure from killing the entire EUnit test process.
    Result = gen_server:start({local, ecai_index_rewards}, ecai_index_rewards, Cfg, []),
    case Result of
        {ok, Pid} -> put({?MODULE, service_pid}, Pid);
        _ -> ok
    end,
    Result.

stop_service() ->
    %% Stop only the exact PID started by this fixture, never an arbitrary
    %% replacement obtained through whereis/1.
    case erase({?MODULE, service_pid}) of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            Ref = erlang:monitor(process, Pid),
            try
                try gen_server:stop(Pid, normal, 1000)
                catch
                    exit:noproc -> ok;
                    exit:{noproc, _} -> ok
                end
            after
                %% Bound cleanup even when a broken test leaves the service busy.
                exit(Pid, kill),
                receive {'DOWN', Ref, process, Pid, _} -> ok
                after 1000 ->
                    erlang:demonitor(Ref, [flush]),
                    error(test_service_cleanup_timeout)
                end
            end
    end.

make_tmp_dir() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end,
    %% A VM-local unique_integer/1 is not unique across rebar3 invocations.
    %% Randomize and claim the directory atomically; never reuse an old one.
    Token = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Dir = filename:join(filename:absname(Base), "ecai-rewards-" ++ Token),
    ok = filelib:ensure_dir(filename:join(filename:absname(Base), ".keep")),
    case file:make_dir(Dir) of
        ok -> Dir;
        {error, eexist} -> make_tmp_dir();
        {error, Reason} -> error({test_tmp_dir, Reason})
    end.
