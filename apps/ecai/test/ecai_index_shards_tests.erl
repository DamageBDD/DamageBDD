-module(ecai_index_shards_tests).
-include_lib("eunit/include/eunit.hrl").

bounded_shards_preserve_bytes_test() ->
    with_tmp(fun(Root) ->
        Input = filename:join(Root, "input.ndjson"),
        Lines = [jsx:encode(#{<<"id">> => N, <<"title">> => <<"shard test">>})
                 || N <- lists:seq(1, 17)],
        Content = iolist_to_binary([[Line, <<"\n">>] || Line <- Lines]),
        ok = file:write_file(Input, Content),
        Limits = #{max_shard_bytes => 85, max_line_bytes => 80,
            max_lines_per_shard => 2, max_shards => 30},
        Spec = fixture_spec(Input, Root),
        {ok, File, Plan} = ecai_index_shards:plan(
            Spec, filename:join(Root, "plans"), Limits),
        ?assert(filelib:is_file(File)),
        {ok, Loaded} = ecai_index_shards:read_plan(File),
        ?assertEqual(maps:get(group_id, Plan), maps:get(group_id, Loaded)),
        Entries = maps:get(entries, Plan),
        ?assert(length(Entries) > 2),
        Pieces = lists:append([maps:get(paths, maps:get(source, maps:get(spec, E)))
            || E <- Entries]),
        Actual = iolist_to_binary([begin
            {ok, Bytes} = file:read_file(P),
            ?assert(byte_size(Bytes) =< 85),
            Bytes
        end || P <- Pieces]),
        ?assertEqual(Content, Actual),
        ?assert(lists:all(fun(E) ->
            maps:get(mode, maps:get(target, maps:get(spec, E))) =:= shard_search andalso
            maps:get(build_nft_manifest, maps:get(finalize, maps:get(spec, E))) =:= false
        end, Entries)),
        ?assertMatch({error, {plan_already_exists, _}}, ecai_index_shards:plan(
            Spec, filename:join(Root, "plans"), Limits)),
        ?assertMatch({error, {missing_shard_jobs, _}}, ecai_index_shards:merge(
            File, filename:join(Root, "merged.etf")))
    end).

single_long_line_fails_before_large_allocation_test() ->
    with_tmp(fun(Root) ->
        Input = filename:join(Root, "giant.ndjson"),
        ok = file:write_file(Input, <<(binary:copy(<<"a">>, 150000))/binary, "\n">>),
        ?assertMatch({error, {line_exceeds_limit, _}}, ecai_index_shards:plan(
            fixture_spec(Input, Root), filename:join(Root, "plans"),
            #{max_shard_bytes => 16384, max_line_bytes => 8192,
              max_lines_per_shard => 2}))
    end).

trailing_partial_line_is_preserved_test() ->
    with_tmp(fun(Root) ->
        Input = filename:join(Root, "partial.ndjson"),
        Content = <<"alpha\nbeta">>,
        ok = file:write_file(Input, Content),
        {ok, _PlanFile, Plan} = ecai_index_shards:plan(
            fixture_spec(Input, Root), filename:join(Root, "plans"),
            #{max_shard_bytes => 10, max_line_bytes => 10,
              max_lines_per_shard => 1}),
        Pieces = lists:append([maps:get(paths, maps:get(source, maps:get(spec, E)))
            || E <- maps:get(entries, Plan)]),
        ?assertEqual(2, length(Pieces)),
        ?assertEqual(Content, iolist_to_binary([begin
            {ok, Bytes} = file:read_file(P), Bytes
        end || P <- Pieces]))
    end).

plan_lock_prevents_concurrent_receipt_writes_test() ->
    with_tmp(fun(Root) ->
        Input = filename:join(Root, "one.ndjson"),
        ok = file:write_file(Input, <<"{}\n">>),
        {ok, PlanFile, _} = ecai_index_shards:plan(
            fixture_spec(Input, Root), filename:join(Root, "plans"), #{}),
        Lock = PlanFile ++ ".lock",
        ok = file:write_file(Lock, <<"operator-busy">>),
        ?assertMatch({error, {plan_receipts_locked, _}},
            ecai_index_shards:enqueue_batch(PlanFile, 1, 1)),
        ok = file:delete(Lock)
    end).

shard_mode_rejects_individual_mint_test() ->
    with_tmp(fun(Root) ->
        Input = filename:join(Root, "one.ndjson"),
        ok = file:write_file(Input, <<"{}\n">>),
        Spec = fixture_spec(Input, Root),
        Sharded = Spec#{target => #{mode => shard_search,
                      base_dir => unicode:characters_to_binary(Root)}},
        ?assertMatch({error, shard_requires_deferred_finalization},
            ecai_index_job_codec:normalize_spec(Sharded)),
        Allowed = Sharded#{finalize => #{build_nft_manifest => false}},
        {ok, Normalized} = ecai_index_job_codec:normalize_spec(Allowed),
        ?assertEqual(shard_search, maps:get(mode, maps:get(target, Normalized)))
    end).

read_manifest_rejects_tampered_root_test() ->
    with_tmp(fun(Root) ->
        File = filename:join(Root, "forged.etf"),
        ok = file:write_file(File, term_to_binary(#{
            schema => <<"ecai-shard-index/v1">>, group_id => <<"test">>,
            original_spec_sha256 => <<"bad">>, shards => [],
            index_root => <<"fake-root">>})),
        ?assertEqual({error, invalid_shard_manifest_root},
            ecai_index_shards:read_manifest(File))
    end).

fixture_spec(Input, Root) ->
    #{schema => <<"ecai-index-job/v1">>, kind => yelp_ndjson,
      owner => <<"operator">>,
      source => #{paths => [unicode:characters_to_binary(Input)]},
      target => #{mode => live_search, base_dir => unicode:characters_to_binary(Root)},
      options => #{batch_size => 1, max_retries => 2},
      finalize => #{build_nft_manifest => true, publish_ipfs => false}}.

with_tmp(Fun) ->
    Root = filename:join("/tmp", "ecai-shards-test-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    try Fun(Root)
    after _ = file:del_dir_r(Root) end.
