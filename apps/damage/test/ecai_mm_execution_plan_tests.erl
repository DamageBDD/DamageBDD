-module(ecai_mm_execution_plan_tests).
-include_lib("eunit/include/eunit.hrl").

post_only_and_owned_reconcile_test() ->
    Q = #{
        side => buy,
        price => 0.01,
        remaining_qty => 100.0,
        client_id => <<"ecai-abc">>
    },
    {ok, [Planned]} = ecai_mm_execution_plan:build([Q], #{}),
    ?assertEqual(<<"POST_ONLY">>, maps:get(ordType, Planned)),
    Delta = ecai_mm_execution_plan:reconcile(
        [<<"ecai-old">>], [<<"ecai-old">>, <<"manual-order">>], [Planned]
    ),
    ?assertEqual([<<"ecai-old">>], maps:get(cancel_ids, Delta)),
    ?assertEqual([Planned], maps:get(create, Delta)).
