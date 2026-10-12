-module(ecai_mm_config_tests).
-include_lib("eunit/include/eunit.hrl").

reject_live_execution_and_funding_test() ->
    ?assertMatch(
        {error, {unknown_field, mode}},
        ecai_mm_config:validate(#{mode => live}, #{})
    ),
    ?assertMatch(
        {error, {unknown_field, paper_balances}},
        ecai_mm_config:validate(#{paper_balances => #{usdt => 1}}, #{})
    ),
    ?assertMatch(
        {error, {unknown_field, _}},
        ecai_mm_config:from_json(#{<<"mode">> => <<"live">>})
    ).

bounded_config_test() ->
    ?assertEqual(
        {ok, #{levels => 8}},
        ecai_mm_config:validate(#{levels => 8}, #{})
    ),
    ?assertMatch(
        {error, {invalid_value, levels}},
        ecai_mm_config:validate(#{levels => 99}, #{})
    ),
    ?assertMatch(
        {error, {invalid_value, poll_interval_ms}},
        ecai_mm_config:validate(#{poll_interval_ms => 5}, #{})
    ),
    ?assertMatch(
        {error, inconsistent_inventory_or_notional_limits},
        ecai_mm_config:validate(#{target_inventory_ratio => 0.9}, #{})
    ),
    ?assertMatch(
        {error, inconsistent_inventory_or_notional_limits},
        ecai_mm_config:validate(#{max_side_notional => 2}, #{})
    ),
    ?assertMatch(
        {error, poll_interval_exceeds_feed_age},
        ecai_mm_config:validate(#{poll_interval_ms => 30000}, #{})
    ).

wire_fields_only_test() ->
    {ok, Patch} = ecai_mm_config:from_json(#{
        <<"levels">> => 5,
        <<"max_drawdown_pct">> => 3.5
    }),
    ?assertEqual({ok, Patch}, ecai_mm_config:validate(Patch, #{})),
    ?assertEqual([levels, max_drawdown_pct], lists:sort(maps:keys(Patch))),
    ?assertEqual(
        false,
        maps:is_key(
            state_dir,
            ecai_mm_config:public(#{state_dir => "/private"})
        )
    ).
