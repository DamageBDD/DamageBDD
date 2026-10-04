-module(ecai_code_graph_tests).

-include_lib("eunit/include/eunit.hrl").

build_and_neighborhood_test() ->
    A = #{
        module => a,
        remote_calls => [#{module => b, function => f, arity => 0}],
        behaviours => [],
        security_boundaries => [],
        test_module => false
    },
    B = #{
        module => b,
        remote_calls => [#{module => c, function => g, arity => 1}],
        behaviours => [gen_server],
        security_boundaries => [network],
        test_module => false
    },
    C = #{
        module => c,
        remote_calls => [],
        behaviours => [],
        security_boundaries => [],
        test_module => true
    },
    Graph = ecai_code_graph:build([A, B, C]),
    ?assertEqual([b], ecai_code_graph:outgoing(Graph, a)),
    ?assertEqual([a], ecai_code_graph:incoming(Graph, b)),
    ?assertEqual([{a, 0}, {b, 1}, {c, 2}], ecai_code_graph:neighborhood(Graph, a, 2)).
