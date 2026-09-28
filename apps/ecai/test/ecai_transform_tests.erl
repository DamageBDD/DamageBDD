-module(ecai_transform_tests).

-include_lib("eunit/include/eunit.hrl").

same_delta_distance_zero_test() ->
    D = #{dx => 10, dy => 20},
    ?assertEqual(0, ecai_transform:delta_distance(D, D)).

field_wraparound_test() ->
    P = (1 bsl 255) - 19,
    ?assertEqual(1, ecai_transform:circular_distance(0, P - 1)).
