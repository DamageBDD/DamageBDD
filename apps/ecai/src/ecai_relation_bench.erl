%%--------------------------------------------------------------------
%% ecai_relation_bench.erl
%%
%% Small deterministic holdout evaluator for relation reconstruction.
%%--------------------------------------------------------------------
-module(ecai_relation_bench).

-export([
    evaluate/3,
    hidden_keys/1
]).

-spec evaluate(
    [ecai_relation:relation()],
    [ecai_relation:relation()],
    non_neg_integer()
) -> map().
evaluate(TrainingRelations, HiddenRelations, MaxDepth)
    when is_list(TrainingRelations),
         is_list(HiddenRelations),
         is_integer(MaxDepth),
         MaxDepth >= 0 ->
    Closure = ecai_compose:closure(TrainingRelations, MaxDepth),
    ClosureKeys = maps:from_list([{ecai_relation:key(R), true} || R <- Closure]),
    Hidden = ecai_relation:dedupe(HiddenRelations),
    Recovered = [
        R
     || R <- Hidden,
        maps:is_key(ecai_relation:key(R), ClosureKeys)
    ],
    Missing = [
        R
     || R <- Hidden,
        not maps:is_key(ecai_relation:key(R), ClosureKeys)
    ],
    Expected = length(Hidden),
    RecoveredCount = length(Recovered),
    #{
        expected => Expected,
        recovered => RecoveredCount,
        missing => length(Missing),
        recall => ratio(RecoveredCount, Expected),
        recovered_keys => hidden_keys(Recovered),
        missing_keys => hidden_keys(Missing),
        llm_calls => 0,
        deterministic => true,
        max_depth => MaxDepth
    }.

-spec hidden_keys([ecai_relation:relation()]) -> [binary()].
hidden_keys(Relations) ->
    lists:sort([ecai_relation:key(R) || R <- Relations]).

ratio(_Numerator, 0) -> 1.0;
ratio(Numerator, Denominator) -> Numerator / Denominator.
