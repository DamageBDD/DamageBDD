-module(ecai_live_disk_search_tests).
-include_lib("eunit/include/eunit.hrl").

canonical_query_reads_unclosed_published_batch_test() ->
    with_tmp(fun(Dir) ->
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,[#{text => <<"uniqueneedle searchable now">>}]),
        try
            [Hit] = ecai_ollama_rag:retrieve_sources_lexical(Dir,<<"uniqueneedle">>,5),
            ?assertEqual(1,maps:get(docint,Hit))
        after ecai_disk_indexer:close(S1) end
    end).

cache_observes_new_generation_and_separates_corpora_test() ->
    with_tmp(fun(Dir) ->
        A = filename:join(Dir,"a"), B = filename:join(Dir,"b"),
        S0 = ecai_disk_indexer:new(A,#{max_docs => 30,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,lists:duplicate(30,#{text => <<"cacheword">>})),
        Hot = ecai_hot_terms:new(200),
        try
            ?assertEqual(lists:seq(1,30),ecai_disk_search:term_postings(A,Hot,<<"text:cacheword">>)),
            %% Thirty postings trigger caching. A second publication must bypass it.
            S2 = ecai_disk_indexer:add_records(S1,[#{text => <<"cacheword">>}]),
            S3 = ecai_disk_indexer:flush(S2),
            try
                ?assertEqual(lists:seq(1,31),ecai_disk_search:term_postings(A,Hot,<<"text:cacheword">>)),
                ?assertEqual([],ecai_disk_search:term_postings(B,Hot,<<"text:cacheword">>))
            after ecai_disk_indexer:close(S3) end
        after ets:delete(Hot), catch ecai_disk_indexer:abort(S1) end
    end).

query_owned_hot_tables_are_released_test() ->
    with_tmp(fun(Dir) ->
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1}),
        S1 = ecai_disk_indexer:add_records(S0,[#{text => <<"needle">>}]),
        ok = ecai_disk_indexer:close(S1),
        Before = owned_tables(),
        lists:foreach(fun(_) -> [_] = ecai_ollama_rag:retrieve_sources_lexical(Dir,<<"needle">>,5) end,lists:seq(1,20)),
        ?assertEqual(Before,owned_tables())
    end).

pending_tail_is_not_searchable_until_flush_test() ->
    with_tmp(fun(Dir) ->
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 100,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,[#{text => <<"pendingtail">>}]),
        ?assertEqual([],ecai_ollama_rag:retrieve_sources_lexical(Dir,<<"pendingtail">>,5)),
        S2 = ecai_disk_indexer:flush(S1),
        try [_] = ecai_ollama_rag:retrieve_sources_lexical(Dir,<<"pendingtail">>,5)
        after ecai_disk_indexer:close(S2) end
    end).

source_ref_rejects_replaced_pin_test() ->
    with_tmp(fun(Dir) ->
        Saved = application:get_env(ecai,knowledge_disk_indexes),
        application:set_env(ecai,knowledge_disk_indexes,[#{id => <<"test-disk">>,dir => Dir}]),
        try
            {ok,Ref} = ecai_source_retrieval:retain(Dir,<<"exact source">>,<<"test">>,<<"v1">>),
            S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1}),
            S1 = ecai_disk_indexer:add_records(S0,[#{text => <<"exact">>,source_blob => Ref}]),
            ok = ecai_disk_indexer:close(S1),
            Good = #{index => <<"test-disk">>,doc_id => 1,sha256 => maps:get(sha256,Ref)},
            ?assertMatch({ok,#{complete := true}},ecai_knowledge:source(Good,undefined)),
            Bad = Good#{sha256 => binary:copy(<<"0">>,64)},
            ?assertEqual({error,source_version_changed},ecai_knowledge:source(Bad,undefined)),
            ?assertEqual([],ecai_index_pool:knowledge_manifests(undefined)),
            ?assertEqual({error,source_not_found},ecai_knowledge:source(#{index => <<"pool:other">>,doc_id => <<"doc">>,shard_ordinal => 1},undefined))
        after restore(knowledge_disk_indexes,Saved) end
    end).
owned_tables() -> lists:sort([T || T <- ets:all(),ets:info(T,owner) =:= self()]).
restore(K,undefined) -> application:unset_env(ecai,K);
restore(K,{ok,V}) -> application:set_env(ecai,K,V).
with_tmp(Fun) ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; P -> P end,
    Dir = filename:join(Root,"ecai-live-tests-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok = file:make_dir(Dir),try Fun(Dir) after file:del_dir_r(Dir) end.
