%% Read-only BDD assertions over the controller's real evidence. No feature
%% text can invoke a restart, retrieve AWSPENDING or manufacture acceptance.
-module(steps_nsecbunker_handoff).
-damage_roles([node_admin]).
-export([step/6, step_dry/6]).
step_dry(C, X, K, L, B, A) -> steps_utils:step_dry(C, X, K, L, B, A).
step(_, Context, _, _, ["the bunker handoff health evidence MUST be fresh"], _) ->
    S = damage_nsecbunker_handoff:status(),
    H = maps:get(health,S,#{}),
    true = maps:get(status,H,not_checked) =:= passed,
    true = damage_nsecbunker_handoff:fresh(H,erlang:system_time(second),60),
    Context;
step(_, Context, _, _, ["the bunker handoff technical checks MUST be complete"], _) ->
    S = damage_nsecbunker_handoff:status(),
    true = lists:member(maps:get(closure,S),[awaiting_acceptance,accepted]),
    Context;
step(_, Context, _, _, ["the bunker handoff MUST have an operator acceptance"], _) ->
    #{closure := accepted} = damage_nsecbunker_handoff:status(),
    Context.
