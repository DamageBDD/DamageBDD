-module(ecai_transform_tests).

-include_lib("eunit/include/eunit.hrl").

same_delta_distance_zero_test() ->
    D = #{dx => 10, dy => 20},
    ?assertEqual(0, ecai_transform:delta_distance(D, D)).

field_wraparound_test() ->
    P = (1 bsl 255) - 19,
    ?assertEqual(1, ecai_transform:circular_distance(0, P - 1)),
    ?assertEqual(1, ecai_transform:circular_distance(P - 1, 0)),
    ?assertEqual(2, ecai_transform:circular_distance(1, P - 1)).

field_modular_equivalence_test() ->
    P = (1 bsl 255) - 19,
    Cases = [
        {0, P, 0},
        {0, -P, 0},
        {0, 2 * P, 0},
        {1, P + 1, 0},
        {-1, P - 1, 0},
        {0, -1, 1},
        {0, P + 1, 1},
        {-P - 1, P + 1, 2}
    ],
    lists:foreach(fun({A, B, Expected}) ->
        ?assertEqual(Expected, ecai_transform:circular_distance(A, B))
    end, Cases).

field_distance_invariants_test() ->
    P = (1 bsl 255) - 19,
    Points = [-P - 1, -1, 0, 1, P - 1, P, P + 1],
    lists:foreach(fun({A, B}) ->
        D = ecai_transform:circular_distance(A, B),
        ?assert(D >= 0 andalso D =< P div 2),
        ?assertEqual(D, ecai_transform:circular_distance(B, A)),
        ?assertEqual(D, ecai_transform:circular_distance(A + P, B)),
        ?assertEqual(D, ecai_transform:circular_distance(A, B - P))
    end, [{A, B} || A <- Points, B <- Points]).
