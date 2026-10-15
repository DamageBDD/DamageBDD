-module(ecai_mm_settings_tests).
-include_lib("eunit/include/eunit.hrl").

schema_fields_are_explicit_and_bounded_test() ->
    Fields = ecai_mm_settings:fields(),
    ?assertEqual(16, length(Fields)),
    ?assertEqual(market_maker_enabled, maps:get(key, hd(Fields))),
    ?assertEqual(false, maps:get(default, hd(Fields))),
    ?assertEqual(true, lists:all(fun(F) -> maps:get(apply, F) =:= hot end, Fields)),
    ?assertEqual(
        lists:sort(ecai_mm_config:editable()),
        lists:sort(lists:map(
            fun(K) -> maps:get(K, field_key_map()) end,
            [maps:get(key, F) || F <- tl(Fields)]
        ))
    ).

field_key_map() ->
    #{market_maker_poll_interval_ms => poll_interval_ms,
      market_maker_levels => levels,
      market_maker_base_half_spread_bps => base_half_spread_bps,
      market_maker_level_step_bps => level_step_bps,
      market_maker_volatility_weight => volatility_weight,
      market_maker_target_inventory_ratio => target_inventory_ratio,
      market_maker_max_inventory_ratio => max_inventory_ratio,
      market_maker_max_skew_bps => max_skew_bps,
      market_maker_maker_fee_bps => maker_fee_bps,
      market_maker_fee_buffer_bps => fee_buffer_bps,
      market_maker_max_order_notional => max_order_notional,
      market_maker_max_side_notional => max_side_notional,
      market_maker_max_price_jump_pct => max_price_jump_pct,
      market_maker_max_drawdown_pct => max_drawdown_pct,
      market_maker_max_feed_age_ms => max_feed_age_ms}.

settings_cross_validation_test() ->
    ?assertEqual(ok, ecai_mm_settings:validate_effective(#{})),
    ?assertMatch(
        {error, {invalid_market_maker_settings, poll_interval_exceeds_feed_age}},
        ecai_mm_settings:validate_effective(#{market_maker_poll_interval_ms => 50000})
    ),
    %% Both fields must pass their individual bounds so this assertion
    %% exercises the cross-field Target < Max constraint, not field validation.
    ?assertMatch(
        {error, {invalid_market_maker_settings, inconsistent_inventory_or_notional_limits}},
        ecai_mm_settings:validate_effective(#{
            market_maker_target_inventory_ratio => 0.90,
            market_maker_max_inventory_ratio => 0.85
        })
    ),
    ?assertMatch(
        {error, {invalid_market_maker_settings, inconsistent_inventory_or_notional_limits}},
        ecai_mm_settings:validate_effective(#{market_maker_max_side_notional => 10})
    ).

%% Out-of-range fields must retain their specific errors. Keep the other
%% ratio compatible so a separate constraint does not explain the rejection.
settings_inventory_field_bounds_test() ->
    ?assertMatch(
        {error, {invalid_market_maker_settings, {invalid_value, target_inventory_ratio}}},
        ecai_mm_settings:validate_effective(#{
            market_maker_target_inventory_ratio => 0.98,
            market_maker_max_inventory_ratio => 0.99
        })
    ),
    ?assertMatch(
        {error, {invalid_market_maker_settings, {invalid_value, max_inventory_ratio}}},
        ecai_mm_settings:validate_effective(#{
            market_maker_target_inventory_ratio => 0.50,
            market_maker_max_inventory_ratio => 1.0
        })
    ),
    ?assertEqual(ok, ecai_mm_settings:validate_effective(#{
        market_maker_target_inventory_ratio => 0.01,
        market_maker_max_inventory_ratio => 0.05
    })),
    ?assertEqual(ok, ecai_mm_settings:validate_effective(#{
        market_maker_target_inventory_ratio => 0.95,
        market_maker_max_inventory_ratio => 0.99
    })).

settings_inventory_target_must_be_strictly_below_max_test() ->
    ?assertMatch(
        {error, {invalid_market_maker_settings, inconsistent_inventory_or_notional_limits}},
        ecai_mm_settings:validate_effective(#{
            market_maker_target_inventory_ratio => 0.85,
            market_maker_max_inventory_ratio => 0.85
        })
    ),
    ?assertEqual(ok, ecai_mm_settings:validate_effective(#{
        market_maker_target_inventory_ratio => 0.84,
        market_maker_max_inventory_ratio => 0.85
    })).

settings_preserve_private_options_but_never_enable_execution_test() ->
    Base = #{state_dir => "/tmp/market-maker-ledger", auto_poll => false,
             paper_balances => #{usdt => 300.0, damage => 1000.0}},
    {ok, Config} = ecai_mm_settings:settings_config(
        #{market_maker_levels => 7, market_maker_maker_fee_bps => 5.25}, Base
    ),
    ?assertEqual(7, maps:get(levels, Config)),
    ?assertEqual(5.25, maps:get(maker_fee_bps, Config)),
    ?assertEqual(paper, maps:get(mode, Config)),
    ?assertEqual(false, maps:get(auto_poll, Config)),
    ?assertEqual(maps:get(paper_balances, Base), maps:get(paper_balances, Config)),
    ?assertEqual({error, live_execution_not_implemented},
        ecai_mm_settings:settings_config(#{}, #{mode => live})).
