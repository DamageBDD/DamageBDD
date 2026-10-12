-module(ecai_mm_ledger_tests).
-include_lib("eunit/include/eunit.hrl").

accounting_test() ->
    L0 = ecai_mm_ledger:new(#{damage => 100.0, usdt => 200.0}),
    L1 = ecai_mm_ledger:mark(L0, 1.0, 50000.0),
    Q = #{
        client_id => <<"own-1">>,
        side => buy,
        price => 0.9,
        qty => 10.0,
        remaining_qty => 10.0,
        fee_bps => 10.0
    },
    L2 = ecai_mm_ledger:replace_quotes(L1, [Q]),
    ?assertMatch(
        {error, unknown_or_expired_quote},
        ecai_mm_ledger:paper_fill(L2, <<"unowned">>, 1.0)
    ),
    ?assertMatch(
        {error, overfill},
        ecai_mm_ledger:paper_fill(L2, <<"own-1">>, 11.0)
    ),
    {ok, L3, Fill} = ecai_mm_ledger:paper_fill(L2, <<"own-1">>, 5.0),
    ?assert(abs(0.0045 - maps:get(fee_usdt, Fill)) < 1.0e-10),
    ?assertEqual(105.0, maps:get(damage, maps:get(balances, L3))),
    L4 = ecai_mm_ledger:mark(L3, 1.0, 50000.0),
    ?assert(maps:get(pnl_usdt, L4) > 0.0),
    ?assertEqual(1, maps:get(fill_count, L4)).

unfunded_sell_rejected_test() ->
    L = ecai_mm_ledger:new(#{damage => 0.0, usdt => 100.0}),
    Q = #{
        client_id => <<"sell">>,
        side => sell,
        price => 1.0,
        remaining_qty => 10.0,
        fee_bps => 10.0
    },
    ?assertMatch(
        {error, insufficient_paper_inventory},
        ecai_mm_ledger:paper_fill(ecai_mm_ledger:replace_quotes(L, [Q]), <<"sell">>, 2.0)
    ).
