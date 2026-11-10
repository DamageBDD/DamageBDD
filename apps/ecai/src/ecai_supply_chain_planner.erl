%% Deterministic bounded insertion heuristic, not an exact VRP solver.
%% Four search starts in every fresh/repair mode; no claim of global optimality.
-module(ecai_supply_chain_planner).
-export([solve/4, cached/3, metrics/3, objective/3]).

solve(S,Reference,Seed,Mode) ->
    Start=erlang:monotonic_time(microsecond), D=ecai_supply_chain_model:distances(S),
    Variants=case Seed of [] -> [{[],I} || I <- lists:seq(0,3)]; _ -> [{Seed,0},{[],1},{[],2},{[],3}] end,
    Results=[{objective(S,P,Reference),I,Skel=/=[],P}
             || {Skel,I} <- Variants,P <- [build(S,D,Reference,Skel,I)]],
    [{_,WinningStart,SeedWon,Best}|_]=lists:sort(Results),
    Finished=finish(S,Best,Reference,Mode,Start,4),
    Finished#{selected_start => case SeedWon of true -> seeded_fragment;false -> WinningStart end,
              seed_candidate_evaluated => Seed=/=[],seeded_start_won => SeedWon}.

cached(S,Reference,P) ->
    Start=erlang:monotonic_time(microsecond),
    Finished=finish(S,maps:with([routes,unserved,rejected],P),Reference,retrieved_revalidated,Start,0),
    Finished#{selected_start => exact_cache,seed_candidate_evaluated => false,seeded_start_won => false}.

finish(S,Plan,Reference,Source,Start,Starts) ->
    Check=ecai_supply_chain_validator:validate(S,Plan),
    ecai_supply_chain_util:require(maps:get(valid,Check),planner_validation_failed),
    Metrics=metrics(S,Plan,Reference),
    Plan#{metrics => Metrics, validation => Check, source => Source,
          planner => <<"native-insertion/v1">>, search_starts => Starts,
          solve_us => max(1,erlang:monotonic_time(microsecond)-Start),
          objective => tuple_to_list(objective(S,Plan,Reference))}.

build(S,D,Reference,Seed,Variant) ->
    {Initial,Rejected}=seed(S,D,Seed),
    Assigned=lists:append([maps:get(orders,R) || R <- Initial]),
    Todo=[O || O <- maps:get(orders,S),not lists:member(maps:get(id,O),Assigned)],
    Sorted=lists:sort(fun(A,B) -> rank(A,Variant) < rank(B,Variant) end,Todo),
    {Routes,Missing,Reasons}=lists:foldl(fun(O,{Rs,U,Why}) ->
        case insert(S,D,Reference,O,Rs) of
            {ok,New} -> {New,U,Why};
            {error,Reason} -> {Rs,[maps:get(id,O)|U],[#{order => maps:get(id,O),reason => Reason}|Why]}
        end end,{Initial,[],Rejected},Sorted),
    #{routes => lists:sort(fun(A,B) -> maps:get(vehicle,A)<maps:get(vehicle,B) end,Routes),
      unserved => lists:sort(Missing), rejected => lists:sublist(lists:reverse(Reasons),60)}.
rank(O,0) -> {-maps:get(priority,O),maps:get(latest,O),maps:get(id,O)};
rank(O,1) -> {maps:get(latest,O),-maps:get(priority,O),maps:get(id,O)};
rank(O,2) -> {maps:get(node,O),maps:get(latest,O),maps:get(id,O)};
rank(O,3) -> {maps:get(product,O),-maps:get(priority,O),maps:get(id,O)}.

%% Reuse fragments only after checking them against the NEW complete state.
%% A failed fragment is omitted; the ordinary insertion pass may place it elsewhere.
seed(S,D,Seed) ->
    lists:foldl(fun(R,{Rs,Rejected}) ->
        lists:foldl(fun(Id,{Acc,Reject}) ->
            case lists:any(fun(O) -> maps:get(id,O)=:=Id end,maps:get(orders,S)) of
                false -> {Acc,Reject};
                true ->
                    Vid=maps:get(vehicle,R), Wid=maps:get(warehouse,R),
                    Existing=route_for(Vid,Acc), Ids=case Existing of null -> []; _ -> maps:get(orders,Existing) end,
                    Already=lists:any(fun(X) -> lists:member(Id,maps:get(orders,X)) end,Acc),
                    case Already of
                        true -> {Acc,Reject};
                        false ->
                            case ecai_supply_chain_model:schedule(S,D,Vid,Wid,Ids++[Id]) of
                                {ok,Route} ->
                                    New=replace(Route,Acc),
                                    case stock_ok(S,New) of
                                        true -> {New,Reject};
                                        false -> {Acc,[#{order => Id,reason => seed_stock_exceeded}|Reject]}
                                    end;
                                {error,Why} -> {Acc,[#{order => Id,reason => Why}|Reject]}
                            end
                    end
            end end,{Rs,Rejected},maps:get(orders,R)) end,{[],[]},Seed).

insert(S,D,Reference,O,Rs) ->
    Options=lists:append([options(S,D,O,Rs,V) || V <- maps:get(vehicles,S),maps:get(available,V)]),
    Good=[{incremental(S,N,Reference),N} || {ok,N} <- Options],
    case lists:sort(Good) of
        [{_,Best}|_] -> {ok,Best};
        [] -> {error,no_feasible_insertion}
    end.
options(S,D,O,Rs,V) ->
    Vid=maps:get(id,V), Current=route_for(Vid,Rs),
    {Warehouses,Ids}=case Current of
        null -> {[maps:get(id,W) || W <- maps:get(warehouses,S)],[]};
        _ -> {[maps:get(warehouse,Current)],maps:get(orders,Current)}
    end,
    [case ecai_supply_chain_model:schedule(S,D,Vid,Wid,insert_at(maps:get(id,O),Ids,I)) of
        {ok,R} -> New=replace(R,Rs),case stock_ok(S,New) of true -> {ok,New};false -> {error,stock_exceeded} end;
        Error -> Error
    end || Wid <- Warehouses, I <- lists:seq(0,length(Ids))].
insert_at(X,List,N) -> {A,B}=lists:split(N,List),A++[X|B].
route_for(Id,Rs) -> case [R || R <- Rs,maps:get(vehicle,R)=:=Id] of [R] -> R;[] -> null end.
replace(R,Rs) -> [X || X <- Rs,maps:get(vehicle,X)=/=maps:get(vehicle,R)]++[R].
stock_ok(S,Rs) ->
    Used=usage(S,Rs),
    lists:all(fun({{W,P},N}) ->
        Warehouse=ecai_supply_chain_model:by_id(W,maps:get(warehouses,S)),
        N=<maps:get(P,maps:get(stock,Warehouse)) end,maps:to_list(Used)).
usage(S,Rs) -> lists:foldl(fun(R,M) -> lists:foldl(fun(Id,A) ->
    O=ecai_supply_chain_model:by_id(Id,maps:get(orders,S)),K={maps:get(warehouse,R),maps:get(product,O)},
    A#{K => maps:get(K,A,0)+maps:get(quantity,O)} end,M,maps:get(orders,R)) end,#{},Rs).
assignments(null) -> #{};
assignments(#{routes := Rs}) -> maps:from_list([{I,{maps:get(vehicle,R),maps:get(warehouse,R)}} || R <- Rs,I <- maps:get(orders,R)]).
changes(P,Reference) ->
    A=assignments(P), B=assignments(Reference),
    %% Unserved/reassigned formerly allocated orders both count as changes.
    length([I || I <- maps:keys(B),maps:get(I,A,unserved)=/=maps:get(I,B)]).
incremental(S,Rs,Ref) ->
    P=#{routes => Rs},
    lists:sum([maps:get(travel_minutes,R) || R <- Rs])+maps:get(stability_weight,S)*changes(P,Ref).
objective(S,P,Ref) ->
    Missing=maps:get(unserved,P),
    Priority=lists:sum([maps:get(priority,ecai_supply_chain_model:by_id(I,maps:get(orders,S))) || I <- Missing]),
    {Priority,length(Missing),incremental(S,maps:get(routes,P),Ref)}.
metrics(S,P,Ref) ->
    Rs=maps:get(routes,P), Missing=maps:get(unserved,P), Used=usage(S,Rs),
    #{on_time => length(maps:get(orders,S))-length(Missing), unserved => length(Missing),
      priority_unserved => element(1,objective(S,P,Ref)),
      travel_minutes => lists:sum([maps:get(travel_minutes,R) || R <- Rs]),
      changed_assignments => changes(P,Ref),
      vehicles_used => length(Rs),
      at_risk_crates => lists:sum([maps:get(quantity,ecai_supply_chain_model:by_id(I,maps:get(orders,S))) || I <- Missing]),
      stock_allocations => [#{warehouse => W,product => Product,quantity => N} || {{W,Product},N} <- lists:sort(maps:to_list(Used))]}.
