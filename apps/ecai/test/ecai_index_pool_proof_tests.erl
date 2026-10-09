-module(ecai_index_pool_proof_tests).
-include_lib("eunit/include/eunit.hrl").

canonical_snapshot_ignores_ets_order_test() ->
    M=snapshot_term(), P=maps:get(postings,M),
    ?assertEqual(ecai_index_pool_proof:canonical(M), ecai_index_pool_proof:canonical(M#{postings=>lists:reverse(P)})).

changed_index_is_not_equivalent_test() ->
    M=snapshot_term(), Other=M#{postings=>[{<<"different">>,[1]}]},
    A=ecai_index_reward_ledger:digest(ecai_index_pool_proof:canonical(M)),
    B=ecai_index_reward_ledger:digest(ecai_index_pool_proof:canonical(Other)),
    ?assertNot(ecai_index_pool_proof:compare(#{semantic_sha256=>A,records=>1},#{semantic_sha256=>B,records=>1})).

duplicate_table_rows_rejected_test() ->
    M=snapshot_term(),
    ?assertThrow({pool,duplicate_snapshot_rows},ecai_index_pool_proof:canonical(M#{df=>[{<<"x">>,1},{<<"x">>,2}]})).

compressed_and_uncompressed_equivalence_test() ->
    with_root(fun(R) ->
        M=snapshot_term(), A=term_to_binary(M), B=term_to_binary(M,[compressed]),
        P=write_snapshot(R,"a.etf",A), Q=write_snapshot(R,"b.etf",B),
        {ok,X}=ecai_index_pool_proof:snapshot(P,sha(A)),
        {ok,Y}=ecai_index_pool_proof:snapshot(Q,sha(B)),
        ?assert(ecai_index_pool_proof:compare(X,Y)),
        ?assertEqual({error,snapshot_bytes_changed},ecai_index_pool_proof:snapshot(P,sha(<<"wrong">>)))
    end).

compressed_expansion_limit_rejected_test() ->
    with_root(fun(R) ->
        B = <<131,80,268435457:32/unsigned-big,1,2,3>>,
        P=write_snapshot(R,"too-big.etf",B),
        ?assertEqual({error,expanded_snapshot_too_large},ecai_index_pool_proof:snapshot(P,sha(B)))
    end).

unknown_snapshot_schema_rejected_test() ->
    ?assertThrow({pool,unsupported_snapshot_schema},ecai_index_pool_proof:canonical(#{version=>2})).

source_path_escape_rejected_test() ->
    with_root(fun(_) ->
        ?assertThrow({pool,path_outside_shared_root},ecai_index_pool_util:shared_path("/etc/passwd"))
    end).

unregistered_node_does_not_create_atoms_test() ->
    K=indexing_worker_nodes, Old=application:get_env(ecai,K),
    try
        ok=application:set_env(ecai,K,['damage@worker-a']),
        ?assertEqual('damage@worker-a',ecai_index_pool_util:node_named(<<"damage@worker-a">>)),
        ?assertThrow({pool,node_not_operator_allowlisted},ecai_index_pool_util:node_named(<<"unknown@not-a-cluster-member">>))
    after restore(K,Old) end.

snapshot_term() -> #{version=>1,opts=>#{root_mode=>deferred},seq=>1,
    postings=>[{<<"b">>,[{1,1.0}]},{<<"a">>,[{1,2.0}]}],df=>[{<<"a">>,1},{<<"b">>,1}],tag=>[],root=>[],
    rec=>[{1,#{text=>binary:copy(<<"a">>,10000)}}],i2d=>[{1,<<"doc">>}],d2i=>[{<<"doc">>,1}]}.
sha(B) -> ecai_index_job_codec:id_hex(crypto:hash(sha256,B)).
write_snapshot(R,N,B) -> P=filename:join(R,N),ok=file:write_file(P,B),P.
with_root(F) ->
    Root=filename:join("/tmp","ecai-pool-proof-"++integer_to_list(erlang:unique_integer([positive,monotonic]))),
    K=index_pool_shared_root, Old=application:get_env(ecai,K),
    ok=file:make_dir(Root),ok=application:set_env(ecai,K,Root),
    try F(Root) after restore(K,Old), file:del_dir_r(Root) end.
restore(K,undefined) -> application:unset_env(ecai,K);
restore(K,{ok,V}) -> application:set_env(ecai,K,V).
