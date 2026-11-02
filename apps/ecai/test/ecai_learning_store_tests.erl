-module(ecai_learning_store_tests).

-include_lib("eunit/include/eunit.hrl").

relation_records_do_not_corrupt_repair_fold_test() ->
    Base = temp_dir("relations"),
    File = filename:join(Base, "store.dets"),
    Tab = ecai_learning_store_regression_dets,
    try
        dets:close(Tab)
    catch
        _:_:_ -> ok
    end,
    {ok, Tab} = dets:open_file(Tab, [{file, File}, {type, set}]),
    try
        ok = dets:insert(Tab, [
            {{repair, <<"fp">>, <<"v1">>}, #{status => failed, application => ecai}},
            {{relation_keys, all}, [<<"r1">>, <<"r2">>]},
            {{relation_benchmark, all}, #{
                sampled => 2,
                recovered => 1,
                recovered_keys => [<<"r1">>],
                missing_keys => [<<"r2">>]
            }}
        ]),
        ok = dets:sync(Tab),
        Repairs = ecai_learning_store:collect_repairs(Tab, all),
        ?assertEqual(1, length(Repairs)),
        [Repair] = Repairs,
        ?assertEqual(<<"fp">>, maps:get(fingerprint, Repair)),
        Snapshot = ecai_learning_store:build_snapshot_data(Tab),
        RelationSets = maps:get(relation_sets, Snapshot),
        ?assertEqual(2, maps:get(count, maps:get(all, RelationSets))),
        Benchmark = maps:get(all, maps:get(relation_benchmarks, Snapshot)),
        ?assertEqual(false, maps:is_key(recovered_keys, Benchmark)),
        ?assertEqual(false, maps:is_key(missing_keys, Benchmark))
    after
        _ = dets:close(Tab),
        _ = file:del_dir_r(Base)
    end.

malformed_repair_record_is_ignored_test() ->
    Base = temp_dir("malformed"),
    File = filename:join(Base, "store.dets"),
    Tab = ecai_learning_store_malformed_dets,
    try
        dets:close(Tab)
    catch
        _:_:_ -> ok
    end,
    {ok, Tab} = dets:open_file(Tab, [{file, File}, {type, set}]),
    try
        ok = dets:insert(Tab, [
            {{repair, <<"bad">>, <<"v1">>}, [#{status => failed}]},
            {{repair, <<"good">>, <<"v1">>}, #{status => validated}}
        ]),
        ok = dets:sync(Tab),
        ?assertEqual(1, length(ecai_learning_store:collect_repairs(Tab, all))),
        Snapshot = ecai_learning_store:build_snapshot_data(Tab),
        ?assertEqual(1, length(maps:get(repairs, Snapshot)))
    after
        _ = dets:close(Tab),
        _ = file:del_dir_r(Base)
    end.

log_incidents_are_sorted_filterable_and_thinned_in_snapshot_test() ->
    Base = temp_dir("log-incidents"),
    File = filename:join(Base, "store.dets"),
    Tab = ecai_learning_store_log_incident_dets,
    try
        dets:close(Tab)
    catch
        _:_:_ -> ok
    end,
    {ok, Tab} = dets:open_file(Tab, [{file, File}, {type, set}]),
    try
        ok = dets:insert(Tab, [
            {{log_incident, <<"older">>}, #{
                application => damage,
                module => damage_worker,
                status => learned,
                persist_seq => 10,
                observed_event => #{message => <<"redacted">>},
                inference => #{provider => ollama}
            }},
            {{log_incident, <<"newer">>}, #{
                application => ecai,
                module => ecai_patch_worker,
                status => failed,
                persist_seq => 11,
                observed_event => #{message => <<"redacted">>},
                inference => #{provider => ollama}
            }},
            {{log_incident, <<"malformed">>}, not_a_map},
            {{checkpoint, ecai_log_learning}, #{
                schema_version => 1,
                queue => [#{event => #{message => <<"redacted">>}}],
                current_item => #{event => #{message => <<"redacted">>}},
                counters => #{queued => 1}
            }},
            {{checkpoint, ecai_health_monitor}, #{
                schema => <<"ecai.health-monitor-checkpoint">>,
                version => 1,
                cycles => 2,
                latest_report => #{
                    checked_at => <<"2026-10-02T00:00:00Z">>,
                    status => degraded,
                    diagnostics => #{secret => <<"not-for-snapshot">>},
                    recent_logs => [#{message => <<"not-for-snapshot">>}],
                    resolution_source => guarded_inference,
                    automatic_execution => false,
                    resolution => #{
                        summary => <<"recover the pool">>,
                        steps => [#{id => <<"refresh-inference-pool">>, commands => []}],
                        automatic_execution => false
                    }
                }
            }}
        ]),
        ok = dets:sync(Tab),
        [Newest, Older] = ecai_learning_store:collect_log_incidents(Tab, all),
        ?assertEqual(<<"newer">>, maps:get(fingerprint, Newest)),
        ?assertEqual(<<"older">>, maps:get(fingerprint, Older)),
        [Filtered] = ecai_learning_store:collect_log_incidents(
            Tab,
            {damage, damage_worker}
        ),
        ?assertEqual(<<"older">>, maps:get(fingerprint, Filtered)),
        Snapshot = ecai_learning_store:build_snapshot_data(Tab),
        Incidents = maps:get(log_incidents, Snapshot),
        ?assertEqual(2, length(Incidents)),
        ?assert(
            lists:all(
                fun(Incident) ->
                    not maps:is_key(observed_event, Incident) andalso
                        not maps:is_key(inference, Incident)
                end,
                Incidents
            )
        ),
        Checkpoints = maps:get(runtime_checkpoints, Snapshot),
        LogCheckpoint = maps:get(ecai_log_learning, Checkpoints),
        ?assertNot(maps:is_key(queue, LogCheckpoint)),
        ?assertNot(maps:is_key(current_item, LogCheckpoint)),
        HealthCheckpoint = maps:get(ecai_health_monitor, Checkpoints),
        ThinReport = maps:get(latest_report, HealthCheckpoint),
        ?assertNot(maps:is_key(diagnostics, ThinReport)),
        ?assertNot(maps:is_key(recent_logs, ThinReport)),
        ThinResolution = maps:get(resolution, ThinReport),
        ?assertEqual(
            [<<"refresh-inference-pool">>],
            maps:get(step_ids, ThinResolution)
        )
    after
        _ = dets:close(Tab),
        _ = file:del_dir_r(Base)
    end.


release_memory_is_summarized_without_copying_full_history_test() ->
    Base = temp_dir("release-memory"),
    File = filename:join(Base, "store.dets"),
    Tab = ecai_learning_store_release_memory_dets,
    try dets:close(Tab) catch _:_:_ -> ok end,
    {ok, Tab} = dets:open_file(Tab, [{file, File}, {type, set}]),
    try
        ok = dets:insert(Tab, [
            {{release_change, <<"aaa">>}, #{
                authored_at => <<"2026-10-13T00:00:00Z">>,
                subject => <<"older">>,
                evidence_sha256 => <<"oldhash">>,
                config_changes => [#{key => <<"secret">>, old => <<"not-for-snapshot">>}]
            }},
            {{release_change, <<"bbb">>}, #{
                authored_at => <<"2026-10-14T00:00:00Z">>,
                subject => <<"newer">>,
                evidence_sha256 => <<"newhash">>,
                breaking_changes => [#{kind => exported_api_removed}]
            }},
            {{release_baseline, <<"production">>}, #{
                ref => <<"v1.2.3">>,
                commit => <<"aaa">>
            }}
        ]),
        ok = dets:sync(Tab),
        Snapshot = ecai_learning_store:build_snapshot_data(Tab),
        Release = maps:get(release_memory, Snapshot),
        ?assertEqual(2, maps:get(change_count, Release)),
        Latest = maps:get(latest, Release),
        ?assertEqual(<<"bbb">>, maps:get(commit, Latest)),
        ?assertEqual(false, maps:is_key(breaking_changes, Latest)),
        Production = maps:get(<<"production">>, maps:get(baselines, Release)),
        ?assertEqual(<<"v1.2.3">>, maps:get(ref, Production))
    after
        _ = dets:close(Tab),
        _ = file:del_dir_r(Base)
    end.

temp_dir(Suffix) ->
    Base = filename:join(
        "/tmp",
        "ecai-learning-store-" ++ Suffix ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

%% Keep in sync with the store record. Callback tests exercise asynchronous
%% replies without relying on wall-clock scheduling of a particular disk.
-record(state, {tab, state_root, file, event_seq = 0, index, queries = #{}, pending = [], write_revision = 0}).

indexed_queries_do_not_hold_the_store_callback_test() ->
    Root = temp_dir("indexed-callback"), OldTrap = process_flag(trap_exit, true),
    {ok, S0} = ecai_learning_store:init(#{state_root => Root}),
    try
        From = {self(), make_ref()}, Graph = #{modules => #{}},
        {reply, ok, S1} = ecai_learning_store:handle_call({put, {graph, damage}, Graph}, From, S0),
        {reply, ok, S2} = ecai_learning_store:handle_call(
            {put_transition, {repair, <<"fp">>, <<"v">>}, repair, {<<"fp">>, <<"v">>}, #{status => queued}}, From, S1),
        %% Populate a large unrelated value. It must not be visited by repairs.
        {reply, ok, S3} = ecai_learning_store:handle_call(
            {put, {relations, all}, binary:copy(<<0>>, 1024 * 1024)}, From, S2),
        Tag = make_ref(),
        {noreply, S4} = ecai_learning_store:handle_call(repairs, {self(), Tag}, S3),
        ?assertEqual(1, map_size(S4#state.queries)),
        %% The collection has not replied/been checked in, yet point reads work.
        ?assertMatch({reply, {ok, Graph}, _}, ecai_learning_store:handle_call(
            {get, {graph, damage}}, From, S4)),
        receive
            Done = {query_result, _Ref, [Repair]} ->
                ?assertEqual(<<"fp">>, maps:get(fingerprint, Repair)),
                {noreply, S5} = ecai_learning_store:handle_info(Done, S4),
                ?assertEqual(0, map_size(S5#state.queries)),
                receive {Tag, [Repair]} -> ok after 1000 -> error(no_query_reply) end
        after 5000 -> error(collection_timed_out)
        end
    after
        ecai_learning_store:terminate(normal, S0),
        ets:delete(S0#state.index),
        file:del_dir_r(Root), process_flag(trap_exit, OldTrap)
    end.

indexed_store_rebuild_and_cas_test_() -> {timeout, 30, fun indexed_store_rebuild_and_cas/0}.
indexed_store_rebuild_and_cas() ->
    Root = temp_dir("indexed-restart"),
    ?assertEqual(undefined, whereis(ecai_learning_store)),
    try
        {ok, _} = ecai_learning_store:start_link(#{state_root => Root}),
        ok = ecai_learning_store:put_repair(<<"fp">>, <<"v1">>, #{status => queued}),
        {ok, Before} = ecai_learning_store:get_repair(<<"fp">>, <<"v1">>),
        {ok, After} = ecai_learning_store:compare_and_put_repair(
            <<"fp">>, <<"v1">>, Before, #{status => validated}),
        ?assert(maps:get(persist_seq, After) > maps:get(persist_seq, Before)),
        ?assertEqual({error, conflict}, ecai_learning_store:compare_and_put_repair(
            <<"fp">>, <<"v1">>, Before, #{status => failed})),
        ok = ecai_learning_store:put_repair(<<"other">>, <<"v1">>, #{status => queued}),
        ?assertEqual(2, length(ecai_learning_store:repairs())),
        [Filtered] = ecai_learning_store:repairs(<<"fp">>),
        ?assertEqual(validated, maps:get(status, Filtered)),
        ?assertEqual(1, length(ecai_learning_store:events(repair, {<<"fp">>, <<"v1">>}, 1))),
        ok = ecai_learning_store:put_checkpoint(example, #{}),
        ok = ecai_learning_store:delete_checkpoint(example),
        ?assertEqual(not_found, ecai_learning_store:get_checkpoint(example)),
        Snapshot = ecai_learning_store:snapshot_data(),
        ?assertEqual(false, maps:is_key(example, maps:get(runtime_checkpoints, Snapshot))),
        ok = ecai_learning_store:stop(),
        {ok, _} = ecai_learning_store:start_link(#{state_root => Root}),
        ?assertEqual(2, length(ecai_learning_store:repairs())),
        ?assertEqual(1, length(ecai_learning_store:repairs(<<"fp">>))),
        ?assertEqual(2, length(ecai_learning_store:events(repair, {<<"fp">>, <<"v1">>}, 10))),
        #{active_queries := 0, queued_queries := 0} = ecai_learning_store:status()
    after
        case whereis(ecai_learning_store) of undefined -> ok; _ -> ecai_learning_store:stop() end,
        file:del_dir_r(Root)
    end.

collection_admission_is_bounded_test() ->
    S = #state{queries = maps:from_list([{I, #{}} || I <- lists:seq(1, 32)])},
    ?assertEqual({reply, {error, learning_store_busy}, S},
        ecai_learning_store:handle_call(repairs, {self(), make_ref()}, S)).

concurrent_mutation_rejects_snapshot_test() ->
    Root = temp_dir("snapshot-fence"), OldTrap = process_flag(trap_exit, true),
    {ok, S0} = ecai_learning_store:init(#{state_root => Root}),
    try
        Tag = make_ref(),
        {noreply, S1} = ecai_learning_store:handle_call(snapshot_data, {self(), Tag}, S0),
        {reply, ok, S2} = ecai_learning_store:handle_call(
            {put, {graph, damage}, #{modules => #{}}}, {self(), make_ref()}, S1),
        receive
            Done = {query_result, _, Data} when is_map(Data) ->
                {noreply, S3} = ecai_learning_store:handle_info(Done, S2),
                ?assertEqual(0, map_size(S3#state.queries)),
                receive
                    {Tag, Reply} -> ?assertEqual({error, learning_store_snapshot_busy}, Reply)
                after 1000 -> error(no_fenced_reply)
                end
        after 5000 -> error(no_snapshot_result)
        end
    after
        ecai_learning_store:terminate(normal, S0), ets:delete(S0#state.index),
        file:del_dir_r(Root), process_flag(trap_exit, OldTrap)
    end.
