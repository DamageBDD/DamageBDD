-module(ecai_index_pool_budget_tests).
-include_lib("eunit/include/eunit.hrl").

exact_equal_satoshi_split_test() ->
    Us = units([1,1,1]),
    {ok, Q} = ecai_index_pool_budget:quote(Us, 100, 0, 1),
    ?assertEqual(3, maps:get(fee_reserve_sats, Q)),
    ?assertEqual(97, maps:get(indexing_sats, Q)),
    ?assertEqual([32000,32000,33000], lists:sort([maps:get(index_msat,P) || P <- maps:values(maps:get(unit_prices,Q))])).

weighted_split_is_not_per_node_test() ->
    [A,B,C] = Us = units([1,2,7]),
    {ok, Q} = ecai_index_pool_budget:quote(Us, 1000, 0, 0),
    Prices = maps:get(unit_prices,Q),
    ?assertEqual([100000,200000,700000], [maps:get(index_msat,maps:get(maps:get(id,U),Prices)) || U <- [A,B,C]]).

input_order_does_not_change_reward_test() ->
    Us = units([8,8,2]),
    ?assertEqual(ecai_index_pool_budget:quote(Us, 1001, 20, 1), ecai_index_pool_budget:quote(lists:reverse(Us), 1001, 20, 1)).

lexicographic_tie_break_test() ->
    ?assertEqual(#{<<"a">> => 1, <<"b">> => 0}, ecai_index_pool_budget:apportion(1,[{<<"b">>,1},{<<"a">>,1}])).

paid_verification_reserves_two_fees_test() ->
    {ok, Q} = ecai_index_pool_budget:quote(units([1,1]), 1000, 20, 1),
    ?assertEqual(4, maps:get(fee_reserve_sats,Q)),
    ?assertEqual(199, maps:get(verification_sats,Q)),
    ?assertEqual(797, maps:get(indexing_sats,Q)).

conservation_for_many_workloads_test() ->
    lists:foreach(fun(N) ->
        lists:foreach(fun(V) ->
            {ok, Q} = ecai_index_pool_budget:quote(units(lists:seq(1,N)), 1000000+N, V, 2),
            Rewards = lists:sum([maps:get(index_msat,P)+maps:get(verify_msat,P) || P <- maps:values(maps:get(unit_prices,Q))]),
            ?assertEqual(maps:get(budget_msat,Q), Rewards + 1000*maps:get(fee_reserve_sats,Q))
        end,[0,20,50])
    end,lists:seq(1,20)).

small_budget_fails_closed_test() ->
    ?assertEqual({error,budget_too_small_for_fees},ecai_index_pool_budget:quote(units([1,1]),2,0,1)),
    ?assertEqual({error,budget_too_small_for_segments},ecai_index_pool_budget:quote(units([1,1000]),3,0,0)).

invalid_inputs_test() ->
    ?assertEqual({error,invalid_budget_sats},ecai_index_pool_budget:quote(units([1]),1.5,0,0)),
    ?assertEqual({error,invalid_verifier_percent},ecai_index_pool_budget:quote(units([1]),100,51,0)),
    ?assertEqual({error,invalid_fee_sats},ecai_index_pool_budget:quote(units([1]),100,0,-1)),
    ?assertEqual({error,invalid_segment_count},ecai_index_pool_budget:quote([],100,0,0)),
    [U] = units([1]),
    ?assertEqual({error,duplicate_segment},ecai_index_pool_budget:quote([U,U],100,0,0)),
    ?assertEqual({error,invalid_segment_weight},ecai_index_pool_budget:quote([U#{bytes=>0}],100,0,0)).

units(Weights) -> [#{id=>ecai_index_reward_ledger:digest({test_unit,N}),bytes=>W} || {N,W} <- lists:zip(lists:seq(1,length(Weights)),Weights)].
