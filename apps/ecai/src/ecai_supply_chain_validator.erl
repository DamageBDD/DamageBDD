%% Independent feasibility checker. Does NOT call the planner or its scheduler.
%% Walks each declared road path and recomputes timing, load and stock usage.
-module(ecai_supply_chain_validator).
-export([validate/2]).

validate(S,P) ->
    try
        Rs=maps:get(routes,P), U=maps:get(unserved,P),
        true=is_list(Rs), true=is_list(U), true=length(Rs)=<6, true=length(U)=<60,
        All=[maps:get(id,O) || O <- maps:get(orders,S)],
        Served=lists:append([maps:get(orders,R) || R <- Rs]),
        Vehicles=[maps:get(vehicle,R) || R <- Rs],
        Issues=check(length(Vehicles)=:=length(lists:usort(Vehicles)),duplicate_vehicle,#{})++
            check(length(Served)=:=length(lists:usort(Served)),duplicate_delivery,#{})++
            check(length(U)=:=length(lists:usort(U)),duplicate_unserved,#{})++
            check(ordsets:intersection(lists:usort(Served),lists:usort(U))=:=[],served_and_unserved,#{})++
            check(lists:sort(Served++U)=:=lists:sort(All),order_accounting,#{})++
            lists:append([route(S,R) || R <- Rs])++stock(S,Rs),
        #{valid => Issues=:=[], violations => lists:sublist(Issues,100),
          checks => [order_accounting, unique_vehicles, capacity, refrigeration,
                     stock, shelf_life, deadlines, road_paths, timing, return_to_depot],
          guarantee => feasible_only, optimality_proven => false}
    catch _:_ -> #{valid => false, violations => [#{code => malformed_plan}],
                  checks => [], guarantee => none, optimality_proven => false} end.

route(S,R) ->
    Vid=maps:get(vehicle,R),Wid=maps:get(warehouse,R), Ctx=#{vehicle => Vid},
    V=ecai_supply_chain_model:by_id(Vid,maps:get(vehicles,S)),
    W=ecai_supply_chain_model:by_id(Wid,maps:get(warehouses,S)),
    Ids=maps:get(orders,R), Os=[ecai_supply_chain_model:by_id(I,maps:get(orders,S)) || I <- Ids],
    [Pick|Tail]=maps:get(legs,R), [Return|RevDeliveries]=lists:reverse(Tail), Deliveries=lists:reverse(RevDeliveries),
    true=length(Deliveries)=:=length(Ids), Stops=maps:get(stops,R), true=length(Stops)=:=length(Ids),
    Load=lists:sum([maps:get(quantity,O) || O <- Os]),
    Initial=check(Ids=/=[],empty_route,Ctx)++check(maps:get(available,V),vehicle_unavailable,Ctx)++
        check(Load=<maps:get(capacity,V),capacity_exceeded,Ctx)++
        check(maps:get(load,R)=:=Load,load_mismatch,Ctx)++
        check(lists:all(fun(O) -> maps:get(product,O)=/= <<"chilled">> orelse maps:get(refrigerated,V) end,Os),refrigeration_required,Ctx),
    {PickTime,PickIssues}=leg(S,Pick,maps:get(home,V),Wid,0,pickup,null,Ctx),
    Start=PickTime+maps:get(loading_minutes,S),
    StartIssues=Initial++PickIssues++check(maps:get(load_start,R)=:=PickTime,loading_time,Ctx)++
        check(maps:get(load_end,R)=:=Start,loading_time,Ctx),
    Triples=lists:zip3(Os,Deliveries,Stops),
    {End,Last,Errors,Travel}=lists:foldl(fun({O,L,Stop},{Time,From,Acc,TM}) ->
        Oid=maps:get(id,O), To=maps:get(node,O), OC=Ctx#{order => Oid},
        {M,LI}=leg(S,L,From,To,Time,delivery,Oid,OC),
        Arrival=Time+M, Begin=max(Arrival,maps:get(earliest,O)), Finish=Begin+maps:get(service_minutes,S),
        SI=check(maps:get(order,Stop)=:=Oid,stop_order,OC)++
            check(maps:get(arrival,Stop)=:=Arrival andalso maps:get(service_start,Stop)=:=Begin
                  andalso maps:get(finish,Stop)=:=Finish,stop_timing,OC)++
            check(Finish=<maps:get(latest,O),deadline_missed,OC)++
            check(Finish=<maps:get(maps:get(product,O),maps:get(expiry,W)),inventory_expired,OC),
        {Finish,To,Acc++LI++SI,TM+M}
    end,{Start,Wid,StartIssues,PickTime},Triples),
    {Back,BI}=leg(S,Return,Last,maps:get(home,V),End,return,null,Ctx),
    Errors++BI++check(End+Back=<maps:get(shift_end,V),shift_exceeded,Ctx)++
        check(maps:get(return_at,R)=:=End+Back,return_time,Ctx)++
        check(maps:get(travel_minutes,R)=:=Travel+Back,travel_time,Ctx).

leg(S,L,From,To,Depart,Kind,Oid,Ctx) ->
    P=maps:get(path,L), true=is_list(P),true=P=/=[],true=length(P)=<52,
    E0=check(hd(P)=:=From andalso lists:last(P)=:=To,path_endpoints,Ctx)++
        check(maps:get(from,L)=:=From andalso maps:get(to,L)=:=To,leg_endpoints,Ctx)++
        check(maps:get(kind,L)=:=Kind andalso maps:get(order,L)=:=Oid,leg_kind,Ctx),
    {Duration,Errors}=lists:foldl(fun({A,B},{TM,Acc}) ->
        Matches=[E || E <- maps:get(edges,S),
          (maps:get(from,E)=:=A andalso maps:get(to,E)=:=B) orelse
          (maps:get(from,E)=:=B andalso maps:get(to,E)=:=A)],
        case Matches of
            [E] -> {TM+maps:get(minutes,E),Acc++check(not maps:get(closed,E),closed_road,Ctx#{edge => maps:get(id,E)})};
            _ -> {TM,Acc++[Ctx#{code => nonexistent_road}]}
        end end,{0,E0},pairs(P)),
    {Duration,Errors++check(maps:get(depart,L)=:=Depart andalso maps:get(arrive,L)=:=Depart+Duration,leg_timing,Ctx)}.

stock(S,Rs) ->
    Used=lists:foldl(fun(R,M) ->
        lists:foldl(fun(Id,A) ->
            O=ecai_supply_chain_model:by_id(Id,maps:get(orders,S)), K={maps:get(warehouse,R),maps:get(product,O)},
            A#{K => maps:get(K,A,0)+maps:get(quantity,O)} end,M,maps:get(orders,R)) end,#{},Rs),
    lists:append([begin
        W=ecai_supply_chain_model:by_id(Wid,maps:get(warehouses,S)),
        check(N=<maps:get(Product,maps:get(stock,W)),stock_exceeded,#{warehouse => Wid,product => Product})
    end || {{Wid,Product},N} <- maps:to_list(Used)]).
check(true,_,_) -> [];
check(false,Code,Details) -> [Details#{code => Code}].
pairs([A,B|Rest]) -> [{A,B}|pairs([B|Rest])];
pairs(_) -> [].
