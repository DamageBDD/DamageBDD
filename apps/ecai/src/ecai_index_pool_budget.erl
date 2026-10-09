%% Deterministic integer-satoshi apportionment. Weights come from a frozen
%% source plan, NEVER from a worker's claimed CPU time or segment count.
-module(ecai_index_pool_budget).
-export([quote/4, apportion/2]).

-spec quote([map()], pos_integer(), non_neg_integer(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
quote(Units, Sats, VerifyPercent, FeeSats) ->
    try
        ensure(is_list(Units) andalso Units =/= [] andalso length(Units) =< 256, invalid_segment_count),
        ensure(is_integer(Sats) andalso Sats > 0 andalso Sats =< 100000000, invalid_budget_sats),
        ensure(is_integer(VerifyPercent) andalso VerifyPercent >= 0 andalso VerifyPercent =< 50, invalid_verifier_percent),
        ensure(is_integer(FeeSats) andalso FeeSats >= 0 andalso FeeSats =< 1000, invalid_fee_sats),
        Weights = [{maps:get(id, U), maps:get(bytes, U)} || U <- Units],
        ensure(lists:all(fun({Id, W}) -> is_binary(Id) andalso byte_size(Id) =:= 64
            andalso is_integer(W) andalso W > 0 end, Weights), invalid_segment_weight),
        ensure(length(lists:usort([Id || {Id, _} <- Weights])) =:= length(Units), duplicate_segment),
        N = length(Units),
        Roles = case VerifyPercent of 0 -> 1; _ -> 2 end,
        FeeReserve = N * Roles * FeeSats,
        Reward = Sats - FeeReserve,
        ensure(Reward > 0, budget_too_small_for_fees),
        V = Reward * VerifyPercent div 100,
        I = Reward - V,
        Index = apportion(I, Weights),
        Verify = apportion(V, Weights),
        Prices = maps:from_list([{Id, #{index_msat => maps:get(Id, Index) * 1000,
            verify_msat => maps:get(Id, Verify) * 1000}} || {Id, _} <- Weights]),
        ensure(lists:all(fun({Id, _}) -> maps:get(Id, Index) > 0 andalso
            (VerifyPercent =:= 0 orelse maps:get(Id, Verify) > 0) end, Weights), budget_too_small_for_segments),
        Summary = #{schema => <<"ecai-index-budget/v1">>, policy => <<"source-bytes-largest-remainder/v1">>,
            total_sats => Sats, indexing_sats => I, verification_sats => V,
            fee_reserve_sats => FeeReserve, fee_cap_sats => FeeSats,
            verification_percent => VerifyPercent, segments => N,
            source_bytes => lists:sum([W || {_, W} <- Weights]),
            minimum_index_reward_sats => lists:min(maps:values(Index)),
            maximum_index_reward_sats => lists:max(maps:values(Index))},
        {ok, Summary#{budget_msat => Sats * 1000, index_msat => 0, verify_msat => 0,
                      fee_cap_msat => FeeSats * 1000, unit_prices => Prices}}
    catch throw:{budget, R} -> {error, R}; error:{badkey, K} -> {error, {missing_field, K}};
          error:badarg -> {error, invalid_budget_input}; error:{badmap, _} -> {error, invalid_segment} end.

%% Largest remainder, with lexicographic segment-ID tie breaking. Exact total,
%% input-order independent, no floating-point rounding and no remainder leakage.
apportion(Amount, Weights) when is_integer(Amount), Amount >= 0 ->
    Total = lists:sum([W || {_, W} <- Weights]),
    ensure(Total > 0, invalid_segment_weight),
    Floor = maps:from_list([{Id, Amount * W div Total} || {Id, W} <- Weights]),
    Left = Amount - lists:sum(maps:values(Floor)),
    Ranked = lists:sort([{-((Amount * W) rem Total), Id} || {Id, W} <- Weights]),
    lists:foldl(fun({_, Id}, M) -> M#{Id => maps:get(Id, M) + 1} end,
                Floor, lists:sublist(Ranked, Left)).
ensure(true, _) -> ok;
ensure(false, R) -> throw({budget, R}).
