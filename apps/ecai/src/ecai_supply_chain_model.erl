%% Bounded pre-dispatch fresh-food sandbox. Playback is a forecast, not dispatch.
%% No live traffic, transfers, external compute, or real inventory side effects.
-module(ecai_supply_chain_model).
-export([scenario/1, event/2, distances/1, distance/3, schedule/5,
         fingerprint/1, skeleton/1, by_id/2, summary/1, impact/2]).

scenario(Seed) ->
    ecai_supply_chain_util:integer(Seed, 1, 999999),
    Shops = [#{id => shop(C,R), kind => shop, x => 175+(C-1)*110,
               y => 70+(R-1)*105, label => shop(C,R)} || R <- lists:seq(1,4), C <- lists:seq(1,6)],
    Nodes = [#{id => <<"W1">>, kind => warehouse, x => 65, y => 225, label => <<"West depot">>},
             #{id => <<"W2">>, kind => warehouse, x => 835, y => 225, label => <<"East depot">>} | Shops],
    Horizontal = [edge(edge_id(C,R), shop(C,R), shop(C+1,R),
                       case {C,R} of {3,4} -> 17; _ -> 8 end)
                  || R <- lists:seq(1,4), C <- lists:seq(1,5), C =/= 3 orelse R =:= 2 orelse R =:= 4],
    Vertical = [edge(ecai_supply_chain_util:id(<<"v">>, C*10+R), shop(C,R), shop(C,R+1), 7)
                || R <- lists:seq(1,3), C <- lists:seq(1,6)],
    Edges = Horizontal ++ Vertical ++ [edge(<<"west-north">>, <<"W1">>, shop(1,2), 10),
        edge(<<"west-south">>, <<"W1">>, shop(1,3), 10),
        edge(<<"east-north">>, <<"W2">>, shop(6,2), 10),
        edge(<<"east-south">>, <<"W2">>, shop(6,3), 10)],
    Warehouses = [#{id => <<"W1">>, stock => #{<<"chilled">> => 26, <<"produce">> => 18, <<"ambient">> => 25},
                    expiry => #{<<"chilled">> => 205, <<"produce">> => 240, <<"ambient">> => 999}},
                  #{id => <<"W2">>, stock => #{<<"chilled">> => 18, <<"produce">> => 26, <<"ambient">> => 25},
                    expiry => #{<<"chilled">> => 205, <<"produce">> => 240, <<"ambient">> => 999}}],
    Vehicles = [#{id => ecai_supply_chain_util:id(<<"T">>, I),
                  home => case I =< 3 of true -> <<"W1">>; false -> <<"W2">> end,
                  capacity => 22, refrigerated => I rem 3 =/= 0, available => true,
                  shift_end => 240} || I <- lists:seq(1,6)],
    Orders = [order(I, Seed) || I <- lists:seq(1,48)],
    #{schema => <<"ecai-supply-chain/scenario-v1">>, seed => Seed,
      horizon => 240, loading_minutes => 6, service_minutes => 3,
      nodes => Nodes, edges => Edges, warehouses => Warehouses,
      vehicles => Vehicles, orders => Orders, stability_weight => 8}.

shop(C,R) -> ecai_supply_chain_util:id(<<"S">>, (R-1)*6+C).
edge_id(3,2) -> <<"bridge-central">>;
edge_id(3,4) -> <<"bridge-south">>;
edge_id(C,R) -> ecai_supply_chain_util:id(<<"h">>, R*10+C).
edge(Id,A,B,Time) -> #{id => Id, from => A, to => B, minutes => Time, closed => false}.
order(I, Seed) ->
    Product = lists:nth(1+(I+Seed) rem 3, [<<"chilled">>, <<"produce">>, <<"ambient">>]),
    #{id => ecai_supply_chain_util:id(<<"O">>, I), node => ecai_supply_chain_util:id(<<"S">>, (I-1) div 2+1),
      product => Product, quantity => 1+(I*7+Seed) rem 3,
      earliest => ((I+Seed) rem 3)*10, latest => 135+(I*11+Seed) rem 65,
      priority => 1+(I+Seed) rem 3}.

%% A mutation accepts only a fixed schema; client text never becomes an atom.
event(S, #{<<"kind">> := <<"road">>, <<"id">> := Id, <<"closed">> := Closed} = E)
  when is_boolean(Closed) ->
    ecai_supply_chain_util:keys(E, [<<"kind">>,<<"id">>,<<"closed">>]),
    _ = by_id(Id, maps:get(edges,S)),
    S#{edges := [case maps:get(id,X) =:= Id of true -> X#{closed := Closed}; false -> X end || X <- maps:get(edges,S)]};
event(S, #{<<"kind">> := <<"vehicle">>, <<"id">> := Id, <<"available">> := Available} = E)
  when is_boolean(Available) ->
    ecai_supply_chain_util:keys(E, [<<"kind">>,<<"id">>,<<"available">>]),
    _ = by_id(Id, maps:get(vehicles,S)),
    S#{vehicles := [case maps:get(id,X) =:= Id of true -> X#{available := Available}; false -> X end || X <- maps:get(vehicles,S)]};
event(S, #{<<"kind">> := <<"urgent_order">>} = E) ->
    ecai_supply_chain_util:keys(E, [<<"kind">>]),
    Orders = maps:get(orders,S), ecai_supply_chain_util:require(length(Orders) < 60, order_limit),
    I = length(Orders)+1,
    S#{orders := Orders ++ [#{id => ecai_supply_chain_util:id(<<"O">>,I),
        node => <<"S10">>, product => <<"chilled">>, quantity => 3,
        earliest => 0, latest => 75, priority => 5}]};
event(S, #{<<"kind">> := <<"demand">>, <<"id">> := Id, <<"quantity">> := Q} = E) ->
    ecai_supply_chain_util:keys(E, [<<"kind">>,<<"id">>,<<"quantity">>]),
    ecai_supply_chain_util:integer(Q,1,22), _ = by_id(Id,maps:get(orders,S)),
    S#{orders := [case maps:get(id,X) =:= Id of true -> X#{quantity := Q}; false -> X end || X <- maps:get(orders,S)]};
event(S, #{<<"kind">> := <<"policy">>, <<"stability_weight">> := W} = E) ->
    ecai_supply_chain_util:keys(E, [<<"kind">>,<<"stability_weight">>]),
    S#{stability_weight := ecai_supply_chain_util:integer(W,0,100)};
event(_, _) -> throw({supply_chain, invalid_event}).

by_id(Id, List) ->
    case [X || X <- List, maps:get(id,X) =:= Id] of
        [X] -> X;
        _ -> throw({supply_chain, unknown_id})
    end.
fingerprint(S) -> ecai_supply_chain_util:hash(<<"ecai-supply-chain/state-v1">>,S).
skeleton(#{routes := Routes}) -> [maps:with([vehicle,warehouse,orders],R) || R <- Routes];
skeleton(null) -> [].
summary(S) -> #{warehouses => length(maps:get(warehouses,S)), shops => 24,
    vehicles => length(maps:get(vehicles,S)), orders => length(maps:get(orders,S)),
    closed_roads => [maps:get(id,E) || E <- maps:get(edges,S),maps:get(closed,E)],
    unavailable_vehicles => [maps:get(id,V) || V <- maps:get(vehicles,S),not maps:get(available,V)]}.

%% Floyd-Warshall with explicit paths; 26 vertices and positive integer weights.
%% Closed roads are unavailable for the entire planning horizon in v1.
distances(S) ->
    Ids = [maps:get(id,N) || N <- maps:get(nodes,S)],
    Self = maps:from_list([{{I,I},{0,[I]}} || I <- Ids]),
    D0 = lists:foldl(fun(E,D) ->
        case maps:get(closed,E) of
            true -> D;
            false -> A=maps:get(from,E),B=maps:get(to,E),T=maps:get(minutes,E),
                     D#{{A,B} => {T,[A,B]}, {B,A} => {T,[B,A]}}
        end end,Self,maps:get(edges,S)),
    lists:foldl(fun(K,D) -> lists:foldl(fun(I,DI) ->
        lists:foldl(fun(J,DJ) ->
            case {maps:find({I,K},DJ),maps:find({K,J},DJ)} of
                {{ok,{A,P}},{ok,{B,Q}}} ->
                    case maps:get({I,J},DJ,{1000000,[]}) of
                        {Old,_} when A+B < Old -> DJ#{{I,J} => {A+B,P++tl(Q)}};
                        _ -> DJ
                    end;
                _ -> DJ
            end end,DI,Ids) end,D,Ids) end,D0,Ids).
distance(D,A,B) -> maps:get({A,B},D,{1000000,[]}).

%% Schedules one vehicle's one-pickup trip. All load precedes every delivery.
schedule(S,D,VehicleId,WarehouseId,OrderIds) ->
    try
        V=by_id(VehicleId,maps:get(vehicles,S)), W=by_id(WarehouseId,maps:get(warehouses,S)),
        Os=[by_id(I,maps:get(orders,S)) || I <- OrderIds],
        need(maps:get(available,V),vehicle_unavailable),
        need(lists:all(fun(O) -> maps:get(product,O) =/= <<"chilled">> orelse maps:get(refrigerated,V) end,Os),refrigeration_required),
        Load=lists:sum([maps:get(quantity,O) || O <- Os]),
        need(Load =< maps:get(capacity,V),capacity_exceeded),
        {PickupTime,PickupPath}=distance(D,maps:get(home,V),WarehouseId),
        need(PickupPath =/= [],unreachable),
        Start=PickupTime+maps:get(loading_minutes,S),
        {Finish,Last,Stops,Legs,Travel}=lists:foldl(fun(O,{Time,From,Acc,LA,TM}) ->
            To=maps:get(node,O), {M,Path}=distance(D,From,To), need(Path =/= [],unreachable),
            Arrival=Time+M, Begin=max(Arrival,maps:get(earliest,O)), End=Begin+maps:get(service_minutes,S),
            need(End =< maps:get(latest,O),deadline_missed),
            need(End =< maps:get(maps:get(product,O),maps:get(expiry,W)),inventory_expired),
            Stop=#{order => maps:get(id,O), arrival => Arrival, service_start => Begin, finish => End},
            Leg=#{kind => delivery, order => maps:get(id,O), from => From, to => To,
                  path => Path, depart => Time, arrive => Arrival},
            {End,To,Acc++[Stop],LA++[Leg],TM+M}
        end,{Start,WarehouseId,[],[],PickupTime},Os),
        {ReturnTime,ReturnPath}=distance(D,Last,maps:get(home,V)),need(ReturnPath =/= [],unreachable),
        need(Finish+ReturnTime =< maps:get(shift_end,V),shift_exceeded),
        {ok,#{vehicle => VehicleId, warehouse => WarehouseId, orders => OrderIds,
              load => Load, load_start => PickupTime, load_end => Start, stops => Stops,
              legs => [#{kind => pickup,order => null,from => maps:get(home,V),to => WarehouseId,
                          path => PickupPath,depart => 0,arrive => PickupTime}]++Legs++
                      [#{kind => return,order => null,from => Last,to => maps:get(home,V),
                          path => ReturnPath,depart => Finish,arrive => Finish+ReturnTime}],
              return_at => Finish+ReturnTime,travel_minutes => Travel+ReturnTime}}
    catch throw:{route,Why} -> {error,Why} end.
need(true,_) -> ok;
need(false,Why) -> throw({route,Why}).

%% Assess the approved assignments against NEW inputs without pretending they
%% still work. Independent validation provides concrete broken constraints.
impact(_S,null) -> null;
impact(S,Plan) ->
    Check=ecai_supply_chain_validator:validate(S,Plan),
    #{valid => maps:get(valid,Check), violations => maps:get(violations,Check),
      affected_orders => lists:usort(lists:append([affected(S,R) || R <- maps:get(routes,Plan)]))}.
affected(S,R) ->
    V=by_id(maps:get(vehicle,R),maps:get(vehicles,S)),
    Closed=[maps:get(id,E) || E <- maps:get(edges,S),maps:get(closed,E)],
    UsedBlocked=lists:any(fun(L) ->
        P=maps:get(path,L), lists:any(fun({A,B}) ->
            lists:any(fun(E) -> lists:member(maps:get(id,E),Closed) andalso
              ((maps:get(from,E)=:=A andalso maps:get(to,E)=:=B) orelse
               (maps:get(from,E)=:=B andalso maps:get(to,E)=:=A)) end,maps:get(edges,S))
        end,pairs(P)) end,maps:get(legs,R)),
    case not maps:get(available,V) orelse UsedBlocked of true -> maps:get(orders,R); false -> [] end.
pairs([A,B|Rest]) -> [{A,B}|pairs([B|Rest])];
pairs(_) -> [].
