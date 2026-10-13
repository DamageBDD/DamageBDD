-module(ecai_relation_learning_tests).

-include_lib("eunit/include/eunit.hrl").

indexed_uses_holdout_test() ->
    A = #{
        application => erm,
        module => erm_mpv,
        exports => [],
        remote_calls => [#{module => jsx, function => encode, arity => 1}],
        behaviours => [],
        includes => []
    },
    Graph = ecai_code_graph:build([A]),
    Relations = ecai_relation:from_code_graph(Graph),
    Truth = ecai_relation_learning:ground_truth_uses(Graph),
    Result = ecai_relation_learning:benchmark_relations(Relations, Truth, 1000),
    ?assertEqual(1, maps:get(sampled, Result)),
    ?assertEqual(1, maps:get(recovered, Result)),
    ?assertEqual(1.0, maps:get(sample_recall, Result)),
    ?assertEqual(1.0, maps:get(precision, Result)),
    ?assertEqual(0, maps:get(false_positives, Result)),
    ?assertEqual(0, maps:get(llm_calls, Result)).

cross_application_uses_test() ->
    DamageAnalysis = #{
        application => damage,
        module => damage_http,
        exports => [],
        remote_calls => [#{module => ecai_api, function => query, arity => 1}],
        behaviours => [],
        includes => []
    },
    EcaiAnalysis = #{
        application => ecai,
        module => ecai_api,
        exports => [{query, 1}],
        remote_calls => [],
        behaviours => [],
        includes => []
    },
    DamageGraph = ecai_code_graph:build([DamageAnalysis]),
    EcaiGraph = ecai_code_graph:build([EcaiAnalysis]),
    Relations = ecai_relation:dedupe(
        ecai_relation:from_code_graph(DamageGraph) ++
            ecai_relation:from_code_graph(EcaiGraph)
    ),
    Truth = ecai_relation_learning:ground_truth_uses(DamageGraph),
    Result = ecai_relation_learning:benchmark_relations(Relations, Truth, 1000),
    ?assertEqual(1, maps:get(recovered, Result)),
    ?assertEqual(1.0, maps:get(sample_recall, Result)).
