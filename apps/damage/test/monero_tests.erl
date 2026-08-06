-module(monero_tests).

-include_lib("eunit/include/eunit.hrl").

xmr_to_atomic_test_() ->
    [
        ?_assertEqual({ok, 1000000000000}, monero:xmr_to_atomic("1")),
        ?_assertEqual({ok, 1}, monero:xmr_to_atomic("0.000000000001")),
        ?_assertEqual({ok, 1234567890123}, monero:xmr_to_atomic("1.234567890123")),
        ?_assertEqual({error, too_many_decimal_places}, monero:xmr_to_atomic("0.0000000000001")),
        ?_assertEqual({error, negative_amount}, monero:xmr_to_atomic("-1")),
        ?_assertEqual({error, negative_amount}, monero:xmr_to_atomic(-1)),
        ?_assertEqual(
            {error, floating_point_amount_not_supported},
            monero:xmr_to_atomic(0.001)
        ),
        ?_assertEqual({error, invalid_decimal}, monero:xmr_to_atomic("1e-3"))
    ].

atomic_to_xmr_test_() ->
    [
        ?_assertEqual(<<"0">>, monero:atomic_to_xmr(0)),
        ?_assertEqual(<<"1">>, monero:atomic_to_xmr(1000000000000)),
        ?_assertEqual(<<"0.000000000001">>, monero:atomic_to_xmr(1)),
        ?_assertEqual(<<"1.2345">>, monero:atomic_to_xmr(1234500000000))
    ].

paid_split_invoice_test() ->
    Result = #{
        'in' => [
            transfer(<<"tx-a">>, 700000000000, 12, 0, false),
            transfer(<<"tx-b">>, 300000000000, 10, 0, false)
        ],
        pool => []
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(paid, maps:get(payment_state, Summary)),
    ?assertEqual(true, maps:get(paid, Summary)),
    ?assertEqual(1000000000000, maps:get(confirmed_atomic, Summary)).

pool_payment_is_confirming_test() ->
    Result = #{
        'in' => [],
        pool => [(transfer(<<"tx-pool">>, 1000000000000, 0, 0, false))#{locked => true}]
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(confirming, maps:get(payment_state, Summary)),
    ?assertEqual(true, maps:get(seen, Summary)),
    ?assertEqual(false, maps:get(paid, Summary)).

locked_payment_is_rejected_test() ->
    Result = #{
        'in' => [transfer(<<"tx-locked">>, 1000000000000, 20, 5000000, false)],
        pool => []
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(unpaid, maps:get(payment_state, Summary)),
    ?assertEqual(0, maps:get(received_atomic, Summary)).

locked_output_is_rejected_test() ->
    Locked = (transfer(<<"tx-locked-flag">>, 1000000000000, 20, 0, false))#{locked => true},
    Result = #{'in' => [Locked], pool => []},
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(confirming, maps:get(payment_state, Summary)),
    ?assertEqual(1000000000000, maps:get(received_atomic, Summary)),
    ?assertEqual(0, maps:get(confirmed_atomic, Summary)),
    ?assertEqual(false, maps:get(paid, Summary)).

double_spend_seen_is_rejected_test() ->
    Result = #{
        'in' => [transfer(<<"tx-ds">>, 1000000000000, 20, 0, true)],
        pool => []
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(unpaid, maps:get(payment_state, Summary)),
    ?assertEqual(false, maps:get(paid, Summary)).

confirmed_copy_replaces_pool_copy_test() ->
    Result = #{
        pool => [transfer(<<"same-tx">>, 1000000000000, 0, 0, false)],
        'in' => [transfer(<<"same-tx">>, 1000000000000, 11, 0, false)]
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(1000000000000, maps:get(received_atomic, Summary)),
    ?assertEqual(1000000000000, maps:get(confirmed_atomic, Summary)),
    ?assertEqual(1, length(maps:get(transactions, Summary))).

confirmed_copy_with_global_index_replaces_pool_copy_test() ->
    Pool = (transfer(<<"same-tx-global">>, 1000000000000, 0, 0, false))#{
        global_index => undefined
    },
    Confirmed = (transfer(<<"same-tx-global">>, 1000000000000, 11, 0, false))#{
        global_index => 123456
    },
    Result = #{pool => [Pool], 'in' => [Confirmed]},
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(1000000000000, maps:get(received_atomic, Summary)),
    ?assertEqual(1000000000000, maps:get(confirmed_atomic, Summary)),
    ?assertEqual(1, length(maps:get(transactions, Summary))).

paid_invoice_ignores_extra_low_confirmation_value_test() ->
    Result = #{
        'in' => [
            transfer(<<"tx-required">>, 1000000000000, 12, 0, false),
            transfer(<<"tx-extra">>, 100000000000, 1, 0, false)
        ],
        pool => []
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(paid, maps:get(payment_state, Summary)),
    ?assertEqual(true, maps:get(paid, Summary)),
    ?assertEqual(12, maps:get(confirmations, Summary)).

paid_invoice_ignores_extra_pool_value_test() ->
    Result = #{
        'in' => [transfer(<<"tx-required-pool">>, 1000000000000, 12, 0, false)],
        pool => [(transfer(<<"tx-extra-pool">>, 100000000000, 0, 0, false))#{locked => true}]
    },
    Summary = monero:summarize_transfers(Result, 1000000000000, 10),
    ?assertEqual(paid, maps:get(payment_state, Summary)),
    ?assertEqual(12, maps:get(confirmations, Summary)).

transfer(TxId, Amount, Confirmations, UnlockTime, DoubleSpendSeen) ->
    #{
        txid => TxId,
        amount => Amount,
        confirmations => Confirmations,
        unlock_time => UnlockTime,
        double_spend_seen => DoubleSpendSeen,
        subaddr_index => #{major => 0, minor => 1}
    }.
