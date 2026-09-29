-module(ecai_learning_store_tests).

-include_lib("eunit/include/eunit.hrl").

relation_records_do_not_corrupt_repair_fold_test() ->
    Base = temp_dir("relations"),
    File = filename:join(Base, "store.dets"),
    Tab = ecai_learning_store_regression_dets,
    try dets:close(Tab) catch _:_:_ -> ok end,
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
    try dets:close(Tab) catch _:_:_ -> ok end,
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

temp_dir(Suffix) ->
    Base = filename:join(
        "/tmp",
        "ecai-learning-store-" ++ Suffix ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.
