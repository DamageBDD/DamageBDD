%% ECAI paper market maker: strictly bounded, allowlisted runtime controls.
%% There is deliberately no writable execution mode, API key or paper balance.
-module(ecai_mm_config).
-export([editable/0, public/1, validate/2, from_json/1, defaults/0]).

editable() ->
    [
        poll_interval_ms,
        levels,
        base_half_spread_bps,
        level_step_bps,
        volatility_weight,
        target_inventory_ratio,
        max_inventory_ratio,
        max_skew_bps,
        maker_fee_bps,
        fee_buffer_bps,
        max_order_notional,
        max_side_notional,
        max_price_jump_pct,
        max_drawdown_pct,
        max_feed_age_ms
    ].

defaults() ->
    maps:merge(
        ecai_mm_curve:defaults(),
        #{
            poll_interval_ms => 10000,
            max_price_jump_pct => 25.0,
            max_drawdown_pct => 10.0,
            max_feed_age_ms => 20000
        }
    ).

%% Public config must never include state_dir, paper_balances, credentials,
%% network adapters or any as-yet-introduced private worker option.
public(Config) when is_map(Config) ->
    maps:with(editable(), maps:merge(defaults(), Config)).

from_json(Map) when is_map(Map), map_size(Map) > 0 ->
    case lists:all(fun(K) -> is_binary(K) end, maps:keys(Map)) of
        false -> {error, invalid_config_keys};
        true -> from_json_fields(maps:to_list(Map), #{})
    end;
from_json(_) ->
    {error, empty_or_invalid_patch}.

from_json_fields([], Acc) ->
    {ok, Acc};
from_json_fields([{Key, Val} | Tail], Acc) ->
    %% No conversion of untrusted user input into arbitrary atoms.
    case [Name || Name <- editable(), atom_to_binary(Name, utf8) =:= Key] of
        [Name] -> from_json_fields(Tail, Acc#{Name => Val});
        [] -> {error, {unknown_field, Key}}
    end.

validate(Patch, Existing) when is_map(Patch), is_map(Existing), map_size(Patch) > 0 ->
    case [Key || Key <- maps:keys(Patch), not lists:member(Key, editable())] of
        [Bad | _] ->
            {error, {unknown_field, Bad}};
        [] ->
            Merged = maps:merge(public(Existing), Patch),
            case
                lists:dropwhile(
                    fun(Key) -> field_ok(Key, maps:get(Key, Merged)) end,
                    editable()
                )
            of
                [Bad | _] -> {error, {invalid_value, Bad}};
                [] -> cross_validate(Patch, Merged, Existing)
            end
    end;
validate(_, _) ->
    {error, empty_or_invalid_patch}.

field_ok(poll_interval_ms, V) -> int_between(V, 2000, 120000);
field_ok(max_feed_age_ms, V) -> int_between(V, 2000, 300000);
field_ok(levels, V) -> int_between(V, 1, 16);
field_ok(base_half_spread_bps, V) -> num_between(V, 0.1, 1500);
field_ok(level_step_bps, V) -> num_between(V, 0.1, 1000);
field_ok(volatility_weight, V) -> num_between(V, 0, 5);
field_ok(target_inventory_ratio, V) -> num_between(V, 0.01, 0.95);
field_ok(max_inventory_ratio, V) -> num_between(V, 0.05, 0.99);
field_ok(max_skew_bps, V) -> num_between(V, 0, 1500);
field_ok(maker_fee_bps, V) -> num_between(V, 0, 250);
field_ok(fee_buffer_bps, V) -> num_between(V, 0, 250);
field_ok(max_order_notional, V) -> num_between(V, 1, 10000);
field_ok(max_side_notional, V) -> num_between(V, 1, 100000);
field_ok(max_price_jump_pct, V) -> num_between(V, 0.1, 100);
field_ok(max_drawdown_pct, V) -> num_between(V, 0.1, 50).

cross_validate(Patch, Values, Existing) ->
    Target = maps:get(target_inventory_ratio, Values),
    Max = maps:get(max_inventory_ratio, Values),
    Order = maps:get(max_order_notional, Values),
    Side = maps:get(max_side_notional, Values),
    Min = maps:get(min_notional, Existing, maps:get(min_notional, defaults())),
    Interval = maps:get(poll_interval_ms, Values),
    Age = maps:get(max_feed_age_ms, Values),
    case Interval =< Age of
        false ->
            {error, poll_interval_exceeds_feed_age};
        true ->
            case Target < Max andalso Order >= Min andalso Side >= Order of
                true -> {ok, Patch};
                false -> {error, inconsistent_inventory_or_notional_limits}
            end
    end.

int_between(V, Lo, Hi) -> is_integer(V) andalso V >= Lo andalso V =< Hi.
num_between(V, Lo, Hi) -> is_number(V) andalso V >= Lo andalso V =< Hi.
