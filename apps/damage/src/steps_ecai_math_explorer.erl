%% Source-only acceptance steps; no hard-coded target or stored graph is passed.
-module(steps_ecai_math_explorer).
-export([step/6]).
-define(SEED,["the source-only mathematical exploration seed"]).
-define(EXPLORE,["I explore from the mathematical source without a target"]).
-define(LIMIT,["I explore with a two-model mathematical budget"]).
-define(CLASSES,["the exploration has four rational isomorphism classes"]).
-define(PARTIAL,["the exploration retains two checked models and reports its limit"]).
-define(REPLAY,["every retained exploration path replays successfully"]).
-define(CLASSIFY,["every retained source-isomorphism certificate rechecks successfully"]).
step(_,_,documentation,_,?SEED,_) -> "GIVEN: One exact rational curve and finite budgets; no destination or graph.";
step(_,_,documentation,_,?EXPLORE,_) -> "WHEN: Enumerate degree-2 kernels and retain independently replayable paths.";
step(_,_,documentation,_,?LIMIT,_) -> "WHEN: Explore with a two-model retention budget, including the seed.";
step(_,_,documentation,_,?CLASSES,_) -> "THEN: Check seven models in four local Q-isomorphism classes; three are non-isomorphic to the source.";
step(_,_,documentation,_,?PARTIAL,_) -> "THEN: Two retained models remain verified after the model-budget stop.";
step(_,_,documentation,_,?REPLAY,_) -> "THEN: Recheck every retained map and path without trusting prior flags.";
step(_,_,documentation,_,?CLASSIFY,_) -> "THEN: Recompute exact Q-isomorphism certificates from endpoint equations.";
step(_,Ctx,_,_,?SEED,_) ->
    attempt(Ctx,fun()->
        {ok,E}=ecai_math_curve:new(0,-1,0),
        Ctx#{ecai_explore_source=>E,ecai_explore_bounds=>#{max_depth=>2,max_curves=>24,
             numerator_bound=>8,denominator_bound=>4,timeout_ms=>20000}}
    end);
step(_,Ctx,_,_,?EXPLORE,_) -> execute(Ctx,maps:get(ecai_explore_bounds,Ctx));
step(_,Ctx,_,_,?LIMIT,_) -> execute(Ctx,(maps:get(ecai_explore_bounds,Ctx))#{max_curves=>2});
step(_,Ctx,_,_,?CLASSES,_) ->
    attempt(Ctx,fun()->
        #{summary:=#{retained_models:=7,local_q_classes:=4,non_isomorphic_to_source_models:=3},
          completed_within_declared_bounds:=true}=maps:get(ecai_exploration,Ctx),Ctx
    end);
step(_,Ctx,_,_,?PARTIAL,_) ->
    attempt(Ctx,fun()->
        #{summary:=#{retained_models:=2},stop_reason:=model_budget,
          completed_within_declared_bounds:=false}=maps:get(ecai_exploration,Ctx),Ctx
    end);
step(_,Ctx,_,_,?REPLAY,_) ->
    attempt(Ctx,fun()->
        R=maps:get(ecai_exploration,Ctx),
        lists:foreach(fun(Row)->{ok,_}=ecai_math_pathfinder:verify_path(maps:get(path,Row)) end,maps:get(results,R)),Ctx
    end);
step(_,Ctx,_,_,?CLASSIFY,_) ->
    attempt(Ctx,fun()->
        R=maps:get(ecai_exploration,Ctx),S=maps:get(source,R),
        lists:foreach(fun(Row)->
            {ok,_}=ecai_math_isomorphism:verify(S,maps:get(curve,Row),maps:get(comparison_to_source,Row))
        end,maps:get(results,R)),Ctx
    end).
execute(Ctx,Options) ->
    attempt(Ctx,fun()->
        false=maps:is_key(target,Options),
        {ok,R}=ecai_math_explorer:explore(maps:get(ecai_explore_source,Ctx),Options),
        {ok,B}=ecai_math_explorer:encode(R),
        Ctx#{ecai_exploration=>R,ecai_exploration_json=>B}
    end).
attempt(Ctx,Fun) ->
    try Fun() catch error:Reason ->
        Ctx#{fail=>iolist_to_binary(io_lib:format("Source-only mathematical exploration: ~0P",[Reason,5]))}
    end.
