%%%-------------------------------------------------------------------
%%% A typed bridge from ECAI node Settings to the opt-in paper market maker.
%%% Only reviewed, non-secret controls are translated; no live execution mode
%%% or paper wallet funding can be edited from the dashboard.
%%%-------------------------------------------------------------------
-module(ecai_mm_settings).
-export([fields/0, settings_config/2, validate_effective/1, desired/0]).

fields() ->
    [#{
        key => market_maker_enabled,
        label => <<"Enable ECAI paper market maker">>,
        type => boolean,
        apply => hot,
        default => false,
        help => <<"Start or stop the supervised DAMAGEUSDT paper-observation engine. No exchange orders are submitted; the marketplace has a separate switch.">>
    } | [
        #{key => Key, label => Label, type => Type, min => Min, max => Max,
          default => maps:get(Core, ecai_mm_config:defaults()), apply => hot, help => Help}
     || {Key, Core, Label, Type, Min, Max, Help} <- parameter_specs()
    ]] ++ ecai_mm_price_cache:fields().

%% The tuple list is the ONLY translation from public settings names into
%% the runtime engine's existing bounded configuration fields.
parameter_specs() ->
    [
        {market_maker_poll_interval_ms, poll_interval_ms, <<"Feed polling interval (ms)">>, integer, 2000, 120000,
         <<"Frequency of public Coinstore book checks; must not exceed maximum feed age.">>},
        {market_maker_levels, levels, <<"Quote levels per side">>, integer, 1, 16,
         <<"Maximum simulated bid and ask ladder levels.">>},
        {market_maker_base_half_spread_bps, base_half_spread_bps, <<"Base half spread (bps)">>, number, 0.1, 1500,
         <<"Minimum half-spread before volatility and transaction-fee adjustments.">>},
        {market_maker_level_step_bps, level_step_bps, <<"Level spacing (bps)">>, number, 0.1, 1000,
         <<"Additional spread between adjacent simulated quote levels.">>},
        {market_maker_volatility_weight, volatility_weight, <<"Volatility spread weight">>, number, 0, 5,
         <<"Sensitivity of quoted spread to observed EWMA volatility.">>},
        {market_maker_target_inventory_ratio, target_inventory_ratio, <<"Target DAMAGE inventory ratio">>, number, 0.01, 0.95,
         <<"Desired value share allocated to DAMAGE; must remain below maximum inventory ratio.">>},
        {market_maker_max_inventory_ratio, max_inventory_ratio, <<"Maximum DAMAGE inventory ratio">>, number, 0.05, 0.99,
         <<"Upper bound used by the inventory-skew model.">>},
        {market_maker_max_skew_bps, max_skew_bps, <<"Maximum inventory skew (bps)">>, number, 0, 1500,
         <<"Maximum simulated reservation-price adjustment due to inventory.">>},
        {market_maker_maker_fee_bps, maker_fee_bps, <<"Maker fee assumption (bps)">>, number, 0, 250,
         <<"Fee charged on simulated fills; not a live exchange fee setting.">>},
        {market_maker_fee_buffer_bps, fee_buffer_bps, <<"Fee safety buffer (bps)">>, number, 0, 250,
         <<"Spread protection beyond the simulated maker fee.">>},
        {market_maker_max_order_notional, max_order_notional, <<"Maximum paper quote value (USDT)">>, number, 1, 10000,
         <<"Per-quote exposure ceiling, subject to funded simulated balances.">>},
        {market_maker_max_side_notional, max_side_notional, <<"Maximum paper side value (USDT)">>, number, 1, 100000,
         <<"Total per-side exposure; must be at least the per-quote ceiling.">>},
        {market_maker_max_price_jump_pct, max_price_jump_pct, <<"Maximum price jump (%)">>, number, 0.1, 100,
         <<"Pause simulated quotes when this book-to-book price change is exceeded.">>},
        {market_maker_max_drawdown_pct, max_drawdown_pct, <<"Maximum paper drawdown (%)">>, number, 0.1, 50,
         <<"Stop quoting after this simulated portfolio drawdown is reached.">>},
        {market_maker_max_feed_age_ms, max_feed_age_ms, <<"Maximum feed age (ms)">>, integer, 2000, 300000,
         <<"Reject stale market receipts; must be at least the polling interval.">>}
    ].

%% Preserve private, operator-controlled legacy options such as state_dir and
%% paper_balances. ECAI dashboard settings override ONLY the allowlisted subset.
settings_config(Ecai, Base) when is_map(Ecai), is_map(Base) ->
    case maps:get(mode, Base, paper) of
        paper ->
            Overrides = maps:from_list([
                {Core, Value}
             || {Key, Core, _Label, _Type, _Min, _Max, _Help} <- parameter_specs(),
                {ok, Value} <- [maps:find(Key, Ecai)]
            ]),
            Config = maps:merge(maps:merge(ecai_mm_config:defaults(), Base), Overrides),
            case ecai_mm_config:validate(ecai_mm_config:public(Config), Config) of
                {ok, _} -> {ok, Config#{mode => paper, settings_managed => true}};
                {error, Why} -> {error, Why}
            end;
        _ ->
            {error, live_execution_not_implemented}
    end;
settings_config(_, _) ->
    {error, invalid_market_maker_settings}.

validate_effective(Ecai) when is_map(Ecai) ->
    case settings_config(Ecai, #{}) of
        {ok, _} -> ecai_mm_price_cache:validate_settings(Ecai);
        {error, Why} -> {error, {invalid_market_maker_settings, Why}}
    end;
validate_effective(_) ->
    {error, invalid_market_maker_settings}.

%% Read the already-validated, published application environment. This runs
%% after node Settings has completed its versioned, atomic save.
desired() ->
    Enabled = application:get_env(ecai, market_maker_enabled, false),
    case is_boolean(Enabled) of
        false -> {error, invalid_market_maker_enabled};
        true ->
            Ecai = maps:from_list([
                {Key, Value}
             || {Key, _Core, _Label, _Type, _Min, _Max, _Help} <- parameter_specs(),
                {ok, Value} <- [application:get_env(ecai, Key)]
            ]),
            case application:get_env(damage, ecai_market_maker, #{}) of
                Base when is_map(Base) ->
                    case settings_config(Ecai, with_default_state_dir(Base)) of
                        {ok, Config} -> {ok, Enabled, Config};
                        Error -> Error
                    end;
                _ -> {error, invalid_legacy_market_maker_config}
            end
    end.

%% Preserve an existing legacy DETS ledger instead of silently starting a
%% second paper history. New settings-managed deployments use the node's XDG
%% state root. An explicit operator state_dir always takes precedence.
with_default_state_dir(Base) ->
    case maps:is_key(state_dir, Base) of
        true -> Base;
        false ->
            Legacy = "/var/lib/damage/ecai-mm",
            Root = case filelib:is_dir(Legacy) of
                true -> Legacy;
                false -> filename:join(damage_config:state_dir(), "ecai-mm")
            end,
            Base#{state_dir => Root}
    end.
