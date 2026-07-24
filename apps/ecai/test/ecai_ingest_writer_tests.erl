-module(ecai_ingest_writer_tests).

-include_lib("eunit/include/eunit.hrl").

submitted_records_survive_restart_with_stable_doc_ids_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2] = ecai_step03_test_support:records(2),
        W1 = start_writer(BaseDir),
        {ok, Ack1} = ecai_ingest_writer:submit_batch(W1, [R1, R2]),
        ?assertEqual(true, maps:get(durable, Ack1)),
        ?assertEqual(false, maps:get(index_searchable, Ack1)),
        ?assertEqual(2, maps:get(durable_new, Ack1)),
        ?assertEqual(1, maps:get(first_doc_id, Ack1)),
        ?assertEqual(2, maps:get(last_doc_id, Ack1)),
        ok = ecai_ingest_writer:stop(W1),

        W2 = start_writer(BaseDir),
        {ok, #{doc_id := 1, record := Recovered1}} =
            ecai_ingest_writer:lookup_event(
                W2,
                ecai_step03_test_support:event_id(R1)
            ),
        {ok, #{doc_id := 2, record := Recovered2}} =
            ecai_ingest_writer:lookup_event(
                W2,
                ecai_step03_test_support:event_id(R2)
            ),
        ?assertEqual(R1, Recovered1),
        ?assertEqual(R2, Recovered2),
        Status = ecai_ingest_writer:status(W2),
        ?assertEqual(2, maps:get(record_count, Status)),
        ?assertEqual(3, maps:get(next_doc_id, Status)),
        ?assertEqual(2, maps:get(recovered_unique, Status)),
        ok = ecai_ingest_writer:stop(W2)
    end).

retry_is_logically_idempotent_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2] = ecai_step03_test_support:records(2),
        W = start_writer(BaseDir),
        {ok, First} = ecai_ingest_writer:submit_batch(W, [R1, R2]),
        Status1 = ecai_ingest_writer:status(W),
        {ok, Retry} = ecai_ingest_writer:submit_batch(W, [R1, R2]),
        Status2 = ecai_ingest_writer:status(W),
        ?assertEqual(2, maps:get(durable_new, First)),
        ?assertEqual(0, maps:get(durable_new, Retry)),
        ?assertEqual(2, maps:get(duplicates, Retry)),
        ?assertEqual(0, maps:get(wal_bytes_written, Retry)),
        ?assertEqual(
            maps:get(wal_bytes, Status1),
            maps:get(wal_bytes, Status2)
        ),
        ?assertEqual(2, maps:get(record_count, Status2)),
        ok = ecai_ingest_writer:stop(W)
    end).

partially_overlapping_batch_appends_only_new_records_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2, R3] = ecai_step03_test_support:records(3),
        W = start_writer(BaseDir),
        {ok, _} = ecai_ingest_writer:submit_batch(W, [R1, R2]),
        {ok, Ack} = ecai_ingest_writer:submit_batch(W, [R2, R3, R3]),
        ?assertEqual(3, maps:get(submitted, Ack)),
        ?assertEqual(1, maps:get(durable_new, Ack)),
        ?assertEqual(2, maps:get(duplicates, Ack)),
        ?assertEqual(3, maps:get(first_doc_id, Ack)),
        ?assertEqual(3, maps:get(last_doc_id, Ack)),
        ?assertEqual(3, maps:get(record_count, ecai_ingest_writer:status(W))),
        ok = ecai_ingest_writer:stop(W)
    end).

invalid_record_is_rejected_before_wal_write_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        Invalid = R1#{title => <<"changed without re-identifying">>},
        W = start_writer(BaseDir),
        ?assertMatch(
            {error, {invalid_record, 1, {identity_mismatch, _}}},
            ecai_ingest_writer:submit_batch(W, [Invalid])
        ),
        Status = ecai_ingest_writer:status(W),
        ?assertEqual(0, maps:get(wal_bytes, Status)),
        ?assertEqual(0, maps:get(record_count, Status)),
        ok = ecai_ingest_writer:stop(W)
    end).

empty_batch_is_a_durable_noop_test() ->
    with_tmp(fun(BaseDir) ->
        W = start_writer(BaseDir),
        {ok, Ack} = ecai_ingest_writer:submit_batch(W, []),
        ?assertEqual(true, maps:get(durable, Ack)),
        ?assertEqual(0, maps:get(submitted, Ack)),
        ?assertEqual(0, maps:get(durable_new, Ack)),
        ?assertEqual(0, maps:get(wal_bytes_written, Ack)),
        ok = ecai_ingest_writer:stop(W)
    end).

supervisor_recovers_commit_after_crash_before_ets_apply_test() ->
    with_tmp(fun(BaseDir) ->
        TestPid = self(),
        Hook = fun(after_wal_sync) ->
            TestPid ! after_wal_sync,
            exit(simulated_crash_after_sync)
        end,
        {ok, Sup} = ecai_ingest_sup:start_link(
            BaseDir,
            #{test_hook => Hook}
        ),
        unlink(Sup),
        {ok, W1} = ecai_ingest_sup:writer(Sup),
        Monitor = erlang:monitor(process, W1),
        R1 = ecai_step03_test_support:record(1),
        _CallResult =
            try ecai_ingest_writer:submit_batch(W1, [R1]) of
                Reply -> Reply
            catch
                exit:Reason -> {exit, Reason}
            end,
        receive
            after_wal_sync -> ok
        after 5000 ->
            error(after_wal_sync_hook_timeout)
        end,
        receive
            {'DOWN', Monitor, process, W1, _Reason} -> ok
        after 5000 ->
            error(writer_crash_timeout)
        end,

        W2 = wait_for_restarted_writer(Sup, W1, 100),
        {ok, #{doc_id := 1, record := Recovered}} =
            ecai_ingest_writer:lookup_event(
                W2,
                ecai_step03_test_support:event_id(R1)
            ),
        ?assertEqual(R1, Recovered),
        Status = ecai_ingest_writer:status(W2),
        ?assertEqual(1, maps:get(record_count, Status)),
        ?assertEqual(1, maps:get(recovered_unique, Status)),

        %% Retrying after the uncertain client outcome must not append again.
        {ok, RetryAck} = ecai_ingest_writer:submit_batch(W2, [R1]),
        ?assertEqual(0, maps:get(durable_new, RetryAck)),
        ?assertEqual(1, maps:get(duplicates, RetryAck)),
        ok = ecai_ingest_sup:stop(Sup)
    end).

list_records_is_doc_id_ordered_and_bounded_test() ->
    with_tmp(fun(BaseDir) ->
        Records = ecai_step03_test_support:records(3),
        W = start_writer(BaseDir),
        {ok, _} = ecai_ingest_writer:submit_batch(W, Records),
        Listed = ecai_ingest_writer:list_records(W, 2),
        ?assertEqual([1, 2], [maps:get(doc_id, Item) || Item <- Listed]),
        ?assertEqual({error, invalid_limit}, ecai_ingest_writer:list_records(W, 0)),
        ok = ecai_ingest_writer:stop(W)
    end).

start_writer(BaseDir) ->
    {ok, Writer} = ecai_ingest_writer:start_link(BaseDir),
    unlink(Writer),
    Writer.

wait_for_restarted_writer(_Sup, _Previous, 0) ->
    error(writer_restart_timeout);
wait_for_restarted_writer(Sup, Previous, Attempts) ->
    case ecai_ingest_sup:writer(Sup) of
        {ok, Writer} when Writer =/= Previous ->
            Writer;
        _ ->
            timer:sleep(20),
            wait_for_restarted_writer(Sup, Previous, Attempts - 1)
    end.

with_tmp(Fun) ->
    BaseDir = ecai_step03_test_support:temp_dir(),
    try Fun(BaseDir)
    after
        ok = ecai_step03_test_support:cleanup(BaseDir)
    end.
