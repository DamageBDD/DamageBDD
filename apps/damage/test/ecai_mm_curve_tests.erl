-module(ecai_mm_curve_tests).
-include_lib("eunit/include/eunit.hrl").

book() -> #{bid => 0.0099, ask => 0.0101, btc_usdt => 95000.0,
            volatility_bps => 4.0}.
assets() -> #{damage => 10000.0, usdt => 250.0}.

quotes_funded_and_postonly_test() ->
    {ok, Result} = ecai_mm_curve:quotes(book(), assets(), #{}),
    Qs = maps:get(quotes, Result),
    ?assert(length(Qs) > 0),
    Buys = [Q || Q <- Qs, maps:get(side, Q) =:= buy],
    Sells = [Q || Q <- Qs, maps:get(side, Q) =:= sell],
    ?assert(lists:all(fun(Q) -> maps:get(price, Q) < 0.0101 end, Buys)),
    ?assert(lists:all(fun(Q) -> maps:get(price, Q) > 0.0099 end, Sells)),
    ?assert(lists:sum([maps:get(price,Q) * maps:get(qty,Q) || Q <- Buys]) =< 150.001),
    ?assert(lists:sum([maps:get(qty,Q) || Q <- Sells]) =< 10000.001),
    ?assertEqual(Result, element(2, ecai_mm_curve:quotes(book(), assets(), #{}))).

skew_reacts_to_inventory_test() ->
    {ok, H} = ecai_mm_curve:quotes(book(), #{damage => 100000.0, usdt => 10.0}, #{}),
    {ok, L} = ecai_mm_curve:quotes(book(), #{damage => 1.0, usdt => 1000.0}, #{}),
    ?assert(maps:get(reservation, H) < maps:get(reservation, L)).

invalid_crossed_market_test() ->
    ?assertMatch({error, _}, ecai_mm_curve:quotes(#{bid => 1.0, ask => 0.8,
       btc_usdt => 95000.0}, assets(), #{})).

point_and_chain_determinism_test() ->
    P = ecai_mm_curve:state_point(#{a=>1, b=>2}),
    ?assertEqual(65, byte_size(P)),
    ?assertMatch(<<4, _/binary>>, P),
    ?assertEqual(P, ecai_mm_curve:state_point(#{b=>2,a=>1})),
    Zero = <<0:256>>,
    A = ecai_mm_curve:chain_event(Zero, #{mid => 1}),
    B = ecai_mm_curve:chain_event(Zero, #{mid => 2}),
    ?assertNotEqual(maps:get(digest, A), maps:get(digest, B)),
    ?assertEqual(130, byte_size(maps:get(state_point_hex, A))).
