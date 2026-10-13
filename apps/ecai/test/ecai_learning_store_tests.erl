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

temp_dir(Suffix) ->
    Base = filename:join(
        "/tmp",
        "ecai-learning-store-" ++ Suffix ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.
