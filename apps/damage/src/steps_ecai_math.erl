%% DamageBDD scenarios exercise the actual Erlang checker and path engine.
-module(steps_ecai_math).
-export([step/6]).
-define(DEMO,["the ECAI mathematical pathfinder demo graph"]).
-define(FIND,["I find the mathematical path"]).
-define(DISCOVER,["I discover the mathematical path"]).
-define(DEGREE,["the mathematical path has composite degree",Expected]).
-define(REPLAY,["every mathematical path step replays successfully"]).

step(_,_,documentation,_,?DEMO,_) ->
    "GIVEN: Build two explicit degree-2 isogenies over Q; no network or SageMath required.";
step(_,_,documentation,_,?FIND,_) ->
    "WHEN: Find a bounded verified path through the candidate graph.";
step(_,_,documentation,_,?DISCOVER,_) ->
    "WHEN: Generate a fresh bounded 2-isogeny graph from the source curve and solve.";
step(_,_,documentation,_,?DEGREE,_) ->
    _ = Expected, "THEN: Assert the independently rechecked product of map degrees.";
step(_,_,documentation,_,?REPLAY,_) ->
    "THEN: Replay every map identity and endpoint without trusting prior verification flags.";
step(_,Ctx,_,_,?DEMO,_) ->
    {ok,E0} = ecai_math_curve:new(0,-1,0),
    {ok,Phi} = ecai_math_isogeny:two(E0,0),
    {ok,Psi} = ecai_math_isogeny:two(maps:get(codomain,Phi),0),
    {ok,G1} = ecai_math_pathfinder:add_isogeny(ecai_math_pathfinder:new(),Phi),
    {ok,G2} = ecai_math_pathfinder:add_isogeny(G1,Psi),
    Ctx#{ecai_math_graph=>G2,ecai_math_source=>E0,ecai_math_target=>maps:get(codomain,Psi)};
step(_,Ctx,_,_,?FIND,_) ->
    attempt(Ctx,fun() ->
        ecai_math_pathfinder:find(maps:get(ecai_math_graph,Ctx),
            maps:get(ecai_math_source,Ctx),maps:get(ecai_math_target,Ctx))
    end);
step(_,Ctx,_,_,?DISCOVER,_) ->
    attempt(Ctx,fun() -> ecai_math_pathfinder:solve_two(
        maps:get(ecai_math_source,Ctx),maps:get(ecai_math_target,Ctx),#{max_depth=>2}) end);
step(_,Ctx,_,_,?DEGREE,_) ->
    try
        N = case Expected of B when is_binary(B) -> binary_to_integer(B);
                             L when is_list(L) -> list_to_integer(L) end,
        Path = maps:get(ecai_math_path,Ctx),
        {ok,Proof} = ecai_math_pathfinder:verify_path(Path),
        case maps:get(total_degree,Proof) =:= N of
            true -> Ctx;
            false -> failure(Ctx,composite_degree_mismatch)
        end
    catch error:CatchReason -> failure(Ctx,CatchReason) end;
step(_,Ctx,_,_,?REPLAY,_) ->
    try ecai_math_pathfinder:verify_path(maps:get(ecai_math_path,Ctx)) of
        {ok,Proof} -> Ctx#{ecai_math_receipt=>Proof};
        {error,R} -> failure(Ctx,R)
    catch error:CatchReason -> failure(Ctx,CatchReason) end.
attempt(Ctx,Fun) ->
    try Fun() of
        {ok,Path} -> Ctx#{ecai_math_path=>Path};
        {error,R} -> failure(Ctx,R)
    catch error:CatchReason -> failure(Ctx,CatchReason) end.
failure(Ctx,R) -> Ctx#{fail=>iolist_to_binary(io_lib:format("ECAI mathematical pathfinder: ~p",[R]))}.
