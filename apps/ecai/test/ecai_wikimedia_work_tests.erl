-module(ecai_wikimedia_work_tests).
-include_lib("eunit/include/eunit.hrl").

separate_units_preserve_global_dependency_order_test() ->
    {Spec, Cat} = fixture(),
    {ok, P} = ecai_wikimedia_work:build(Spec, Cat, #{partitions => 8}),
    Units = maps:get(units, P),
    ?assertEqual(14, length(Units)),
    ?assertEqual(14, length(lists:usort([maps:get(id, U) || U <- Units]))),
    Ms = stage(pageviews, P), As = stage(aggregate, P), [Sel] = stage(selection, P),
    Cs = stage(content, P), [Final] = stage(ranked, P),
    ?assertEqual(2, length(Ms)), ?assertEqual(8, length(As)), ?assertEqual(2, length(Cs)),
    ?assert(lists:all(fun(U) -> maps:get(dependencies, U) =:= [] end, Ms)),
    ?assert(lists:all(fun(U) -> maps:get(dependencies, U) =:= ids(Ms) end, As)),
    ?assertEqual(ids(As), maps:get(dependencies, Sel)),
    ?assert(lists:all(fun(U) -> maps:get(dependencies, U) =:= [maps:get(id, Sel)] end, Cs)),
    ?assertEqual(ids(Cs), maps:get(dependencies, Final)).

plan_identity_is_deterministic_and_resource_policy_bound_test() ->
    {S, C} = fixture(),
    {ok, P1} = ecai_wikimedia_work:build(S, C, #{partitions => 8}),
    {ok, P2} = ecai_wikimedia_work:build(S, C, #{partitions => 8}),
    {ok, P3} = ecai_wikimedia_work:build(S, C, #{partitions => 16}),
    ?assertEqual(P1, P2),
    ?assertNotEqual(maps:get(root, P1), maps:get(root, P3)).

candidate_memory_budget_is_enforced_test() ->
    {S, C} = fixture(), O = maps:get(options, S),
    ?assertEqual({error, candidate_memory_budget_exceeded},
        ecai_wikimedia_work:build(S#{options => O#{limit => 500000}}, C, #{})).

catalog_coordinates_and_names_are_checked_test() ->
    {S, C} = fixture(), [First | More] = maps:get(content_shards, C),
    ?assertEqual({error, catalog_mismatch}, ecai_wikimedia_work:build(S, C#{project => <<"otherwiki">>}, #{})),
    ?assertEqual({error, unsafe_source_name}, ecai_wikimedia_work:build(S,
        C#{content_shards => [First#{name => <<"../outside.json.bz2">>} | More]}, #{})).

intermediate_jobs_cannot_mint_test() ->
    H = ecai_index_job_codec:id_hex(crypto:hash(sha256, <<"unit">>)),
    Spec = #{kind => wikimedia_unit, source => #{plan_root => H, unit_id => H},
        target => #{mode => ledger_only, base_dir => <<"/tmp/ecai-work-test">>}},
    ?assertEqual({error, work_requires_deferred_finalization}, ecai_index_job_codec:normalize_spec(Spec)),
    ?assertMatch({ok, _}, ecai_index_job_codec:normalize_spec(Spec#{finalize => #{build_nft_manifest => false}})),
    ?assertEqual({ok, ecai_index_job_wikimedia_unit}, ecai_index_job_adapter:module_for(wikimedia_unit)).

partition_cap_fails_instead_of_silently_dropping_pages_test() ->
    with_tmp(fun(Dir) ->
        {_, C0} = fixture(), C = C0#{pageview_months => [<<"2026-06">>]},
        {ok, R} = ecai_wikimedia_selector:prepare(Dir, C,
            #{selection_shards => 8, minimum_active_months => 1, limit => 10,
              max_partition_pages => 2, max_partition_memory_bytes => 1048576}),
        Spool = filename:join([maps:get(spool_dir, R), "2026-06", "part-0001.bin"]),
        ok = filelib:ensure_dir(Spool),
        B = iolist_to_binary([<<N:64, 10:64, 1:16, 1:16, "x">> || N <- [1,9,17]]),
        ok = file:write_file(Spool, B),
        ?assertMatch({error, {partition_resource_limit, _, 2, 1048576}},
            ecai_wikimedia_selector:aggregate_partition(R, 1, fun(_) -> ok end)),
        ?assertEqual(false, filelib:is_regular(filename:join(maps:get(top_dir, R), "top-0001.jsonl.complete.json")))
    end).

receipt_rejects_changed_artifact_bytes_test() ->
    with_tmp(fun(Dir) ->
        Old = application:get_env(ecai, wikimedia_work_dir),
        application:set_env(ecai, wikimedia_work_dir, Dir),
        try
            Root = digest(<<"root">>), Id = digest(<<"unit">>),
            Work = filename:join(Dir, binary_to_list(Root)),
            File = filename:join(Work, "output.jsonl"), ok = filelib:ensure_dir(File),
            ok = file:write_file(File, <<"one\n">>),
            {ok, Identity} = ecai_index_source:describe_paths([File]),
            Record = #{root => Root, unit_id => Id, files => [File], source_identity => Identity},
            Receipt = Record#{receipt_sha256 => digest(Record)},
            RF = filename:join(Work, binary_to_list(Id) ++ ".receipt.etf"),
            ok = file:write_file(RF, term_to_binary(Receipt)),
            ?assertMatch({ok, _}, ecai_wikimedia_work:verify_receipt(Root, Id)),
            ok = file:write_file(File, <<"changed\n">>),
            ?assertMatch({error, {source_changed, _, _}}, ecai_wikimedia_work:verify_receipt(Root, Id))
        after
            case Old of {ok, V} -> application:set_env(ecai, wikimedia_work_dir, V); undefined -> application:unset_env(ecai, wikimedia_work_dir) end
        end
    end).

aggregation_verifies_only_consumed_partition_test() ->
    partition_fixture(fun(Root, Plan, Dep, File, Other) ->
        %% A second partition is not this task's input; it is checked by its
        %% own consumer. Rehashing every spool here would multiply disk I/O.
        ok = file:write_file(Other, <<"changed but not consumed here">>),
        ?assertMatch({ok, _}, ecai_wikimedia_work:verify_input(Root, Plan,
            #{stage => aggregate, partition => 1}, Dep)),
        ok = file:write_file(File, <<"changed consumed bytes">>),
        ?assertMatch({error, {source_changed, _, _}}, ecai_wikimedia_work:verify_input(Root, Plan,
            #{stage => aggregate, partition => 1}, Dep))
    end).

aggregation_rejects_uncommitted_partition_test() ->
    partition_fixture(fun(Root, Plan, Dep, File, _Other) ->
        Empty = filename:join(filename:dirname(File), "part-0003.bin"),
        ?assertMatch({ok, _}, ecai_wikimedia_work:verify_input(Root, Plan,
            #{stage => aggregate, partition => 3}, Dep)),
        ok = file:write_file(Empty, <<"not in the producing receipt">>),
        ?assertEqual({error, uncommitted_partition_file}, ecai_wikimedia_work:verify_input(Root, Plan,
            #{stage => aggregate, partition => 3}, Dep))
    end).

partition_fixture(F) -> with_tmp(fun(Dir) ->
    Old = application:get_env(ecai, wikimedia_work_dir),
    application:set_env(ecai, wikimedia_work_dir, Dir),
    try
        Root = digest(<<"partition-root">>), Dep = digest(<<"month">>),
        Work = filename:join(Dir, binary_to_list(Root)),
        Spool = filename:join([Work, "selection", "spool", "2026-06"]),
        File = filename:join(Spool, "part-0001.bin"), Other = filename:join(Spool, "part-0002.bin"),
        ok = filelib:ensure_dir(File), ok = file:write_file(File, <<"one">>),
        ok = file:write_file(Other, <<"two">>),
        {ok, Identity} = ecai_index_source:describe_paths([File, Other]),
        R = #{root => Root, unit_id => Dep, files => [File, Other], source_identity => Identity},
        ok = file:write_file(filename:join(Work, binary_to_list(Dep) ++ ".receipt.etf"),
            term_to_binary(R#{receipt_sha256 => digest(R)})),
        Plan = #{units => [#{id => Dep, stage => pageviews, source => #{month => <<"2026-06">>}}]},
        F(Root, Plan, Dep, File, Other)
    after
        case Old of {ok, V} -> application:set_env(ecai, wikimedia_work_dir, V); undefined -> application:unset_env(ecai, wikimedia_work_dir) end
    end
end).

fixture() ->
    Months = [<<"2026-06">>, <<"2026-07">>],
    Source = #{project => <<"enwiki">>, pageview_project => <<"en.wikipedia">>,
        content_release => <<"20260928">>, pageview_months => Months},
    Spec = #{kind => wikimedia_visibility, owner => <<"operator">>, source => Source,
        options => #{limit => 10, oversample_percent => 125, minimum_active_months => 1}},
    Cat = #{project => <<"enwiki">>, pageview_project => <<"en.wikipedia">>, cirrus_release => <<"20260928">>,
        pageview_months => Months,
        pageview_sources => [#{month => M, name => <<"pv-", M/binary, ".bz2">>, url => <<"https://example.invalid/", M/binary>>} || M <- Months],
        content_shards => [#{name => <<"content-", (integer_to_binary(I))/binary, ".json.bz2">>,
                            url => <<"https://example.invalid/content/", (integer_to_binary(I))/binary>>} || I <- [1,2]]},
    {Spec, Cat}.
stage(S, P) -> [U || U <- maps:get(units, P), maps:get(stage, U) =:= S].
ids(Us) -> [maps:get(id, U) || U <- Us].
digest(T) -> ecai_index_reward_ledger:digest(T).
with_tmp(F) ->
    D = filename:join("/tmp", "ecai-work-test-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok = filelib:ensure_dir(filename:join(D,"x")),
    try F(D) after file:del_dir_r(D) end.
