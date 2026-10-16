%% Mathematical Pathfinder v1: directed rational-isogeny graph over Q.
%% Candidate storage is NOT mathematical verification. Every traversed edge
%% is checked, and every returned path can be replayed without the graph.
-module(ecai_math_pathfinder).
-export([new/0, add_curve/2, add_isogeny/2, add_isogeny/3,
         find/3, find/4, verify_path/1, stats/1, demo/0, to_relation/1,
         expand_two/3, solve_two/3, apply_path/2]).
-define(C,ecai_math_curve).
-define(I,ecai_math_isogeny).
-define(MAX_CURVES,4000).
-define(MAX_EDGES,10000).

-spec new() -> map().
new() -> #{schema=>1,kind=>math_graph,curves=>#{},edges=>#{},outgoing=>#{}}.
-spec stats(map()) -> map().
stats(#{curves:=C,edges:=E}) -> #{curves=>map_size(C),candidate_edges=>map_size(E)}.

-spec add_curve(map(),map()) -> {ok,map()} | {error,term()}.
add_curve(#{schema:=1,kind:=math_graph,curves:=Cs}=G,Input) ->
    try
        C = must(?C:normalize(Input)), Id = ?C:id(C),
        need(maps:is_key(Id,Cs) orelse map_size(Cs) < ?MAX_CURVES,curve_limit),
        {ok,G#{curves:=Cs#{Id=>C}}}
    catch error:R -> {error,R} end;
add_curve(_,_) -> {error,invalid_graph}.

-spec add_isogeny(map(),map()) -> {ok,map()} | {error,term()}.
add_isogeny(G,E) -> add_isogeny(G,E,#{}).
-spec add_isogeny(map(),map(),map()) -> {ok,map()} | {error,term()}.
add_isogeny(G,E,Opts) ->
    ecai_math_job:run(fun() -> add_edge(G,E,Opts) end,5000).
add_edge(#{schema:=1,kind:=math_graph,edges:=Edges,outgoing:=Out}=G,Input,Opts)
    when is_map(Opts) ->
    E = must(?I:normalize(Input)),
    need(maps:without([cost,source],Opts) =:= #{},unknown_edge_option),
    Cost = maps:get(cost,Opts,1), Origin = maps:get(source,Opts,<<"local">>),
    need(is_integer(Cost) andalso Cost > 0 andalso Cost =< 1000000,invalid_cost),
    need(is_binary(Origin) andalso byte_size(Origin) =< 1024,invalid_source),
    Id = ?I:id(E), From = ?C:id(maps:get(domain,E)), To = ?C:id(maps:get(codomain,E)),
    need(maps:is_key(Id,Edges) orelse map_size(Edges) < ?MAX_EDGES,edge_limit),
    Entry = case maps:find(Id,Edges) of
        error -> #{id=>Id,from=>From,to=>To,map=>E,cost=>Cost,origins=>[Origin]};
        {ok,Old} ->
            need(maps:get(cost,Old) =:= Cost,duplicate_cost_conflict),
            Origins = lists:usort([Origin|maps:get(origins,Old)]),
            need(length(Origins) =< 16,provenance_limit),
            Old#{origins:=Origins}
    end,
    G1 = must(add_curve(must(add_curve(G,maps:get(domain,E))),maps:get(codomain,E))),
    {ok,G1#{edges:=Edges#{Id=>Entry},outgoing:=Out#{From=>ordsets:add_element(Id,maps:get(From,Out,[]))}}};
add_edge(_,_,_) -> {error,invalid_graph_or_edge_options}.

-spec find(map(),binary() | map(),binary() | map()) -> {ok,map()} | {error,term()}.
find(G,From,To) -> find(G,From,To,#{}).
-spec find(map(),binary() | map(),binary() | map(),map()) -> {ok,map()} | {error,term()}.
find(G,From,To,Options) ->
    try
        Opts = options(Options),
        ecai_math_job:run(fun() -> search(G,From,To,Opts) end,maps:get(timeout_ms,Opts))
    catch error:R -> {error,R} end.
options(Options) when is_map(Options) ->
    Defaults = #{max_depth=>8,max_states=>10000,max_frontier=>10000,timeout_ms=>5000},
    need(maps:without(maps:keys(Defaults),Options) =:= #{},unknown_search_option),
    O = maps:merge(Defaults,Options),
    bound(maps:get(max_depth,O),0,64,max_depth),
    bound(maps:get(max_states,O),1,100000,max_states),
    bound(maps:get(max_frontier,O),1,100000,max_frontier),
    bound(maps:get(timeout_ms,O),1,60000,timeout_ms), O;
options(_) -> error(invalid_search_options).
bound(V,Min,Max,Name) -> need(is_integer(V) andalso V >= Min andalso V =< Max,{invalid_option,Name}).
search(#{schema:=1,kind:=math_graph,curves:=Curves}=G,From,To,Opts) ->
    S = resolve(From,Curves), T = resolve(To,Curves),
    Queue = gb_sets:singleton({0,0,0,S,[]}),
    State = #{queue=>Queue,dist=>#{{S,0}=>0},serial=>0,expanded=>0,
              checked=>#{},rejected=>0,depth_pruned=>0},
    loop(G,S,T,Opts,State);
search(_,_,_,_) -> {error,invalid_graph}.
resolve(Id,Curves) when is_binary(Id) ->
    need(maps:is_key(Id,Curves),{curve_not_indexed,Id}), Id;
resolve(C,Curves) -> resolve(?C:id(must(?C:normalize(C))),Curves).

loop(G,Source,Target,Opts,State) ->
    Q = maps:get(queue,State),
    case gb_sets:is_empty(Q) of
        true -> {error,#{reason=>not_found_within_bounds,stats=>search_stats(State),bounds=>Opts}};
        false ->
            {{Cost,Depth,_Serial,Node,Rev},Q1} = gb_sets:take_smallest(Q),
            S1 = State#{queue:=Q1},
            case maps:get({Node,Depth},maps:get(dist,S1)) =:= Cost of
                false -> loop(G,Source,Target,Opts,S1);
                true when Node =:= Target ->
                    Path = make_path(G,Source,Target,lists:reverse(Rev),Cost),
                    {ok,Path#{search=>search_stats(S1),bounds=>Opts}};
                true ->
                    Expanded = maps:get(expanded,S1)+1,
                    S2 = S1#{expanded:=Expanded},
                    case Depth >= maps:get(max_depth,Opts) of
                        true -> loop(G,Source,Target,Opts,S2#{depth_pruned:=maps:get(depth_pruned,S2)+1});
                        false ->
                            Ids = lists:usort(maps:get(Node,maps:get(outgoing,G),[])),
                            S3 = lists:foldl(fun(Id,Acc) ->
                                relax(G,Id,Node,Depth,Cost,Rev,Opts,Acc)
                            end,S2,Ids),
                            loop(G,Source,Target,Opts,S3)
                    end
            end
    end.

relax(G,Id,Node,Depth,Cost,Rev,Opts,State) ->
    {Checked,S1} = check_edge(G,Id,State),
    case Checked of
        {error,_} -> S1;
        {ok,Entry} ->
            %% A tampered adjacency index cannot manufacture a connection.
            case maps:get(from,Entry) =:= Node of
                false -> S1;
                true ->
                    Next = maps:get(to,Entry), NewCost = Cost+maps:get(cost,Entry),
                    Key = {Next,Depth+1}, Dist = maps:get(dist,S1),
                    case maps:find(Key,Dist) of
                        {ok,OldCost} when OldCost =< NewCost -> S1;
                        Previous ->
                            need(Previous =/= error orelse map_size(Dist) < maps:get(max_states,Opts),
                                 {search_limit,max_states}),
                            Q = maps:get(queue,S1),
                            need(gb_sets:size(Q) < maps:get(max_frontier,Opts),{search_limit,max_frontier}),
                            Serial = maps:get(serial,S1)+1,
                            Item = {NewCost,Depth+1,Serial,Next,[Id|Rev]},
                            S1#{queue:=gb_sets:add(Item,Q),dist:=Dist#{Key=>NewCost},serial:=Serial}
                    end
            end
    end.
check_edge(G,Id,State) ->
    Cache = maps:get(checked,State),
    case maps:find(Id,Cache) of
        {ok,Result} -> {Result,State};
        error ->
            Result = try
                Entry = maps:get(Id,maps:get(edges,G)),
                #{map:=Map,cost:=Cost,from:=From,to:=To,origins:=Origins} = Entry,
                _ = must(?I:check(Map)),
                need(?I:id(Map) =:= Id andalso maps:get(id,Entry) =:= Id,edge_id_mismatch),
                need(?C:id(maps:get(domain,Map)) =:= From,source_id_mismatch),
                need(?C:id(maps:get(codomain,Map)) =:= To,target_id_mismatch),
                need(maps:is_key(From,maps:get(curves,G)) andalso maps:is_key(To,maps:get(curves,G)),missing_curve),
                valid_metadata(Cost,Origins),
                {ok,Entry}
            catch error:R -> {error,R} end,
            Bad = case Result of {ok,_} -> 0; {error,_} -> 1 end,
            {Result,State#{checked:=Cache#{Id=>Result},rejected:=maps:get(rejected,State)+Bad}}
    end.
search_stats(State) ->
    #{expanded_states=>maps:get(expanded,State),discovered_states=>map_size(maps:get(dist,State)),
      checked_edges=>map_size(maps:get(checked,State)),rejected_edges=>maps:get(rejected,State),
      depth_pruned=>maps:get(depth_pruned,State)}.

make_path(G,From,To,Ids,Cost) ->
    Curves = maps:get(curves,G), Edges = maps:get(edges,G),
    Steps = [maps:with([map,cost,origins],maps:get(Id,Edges)) || Id <- Ids],
    Degree = lists:foldl(fun(#{map:=E},A) -> A*maps:get(degree,E) end,1,Steps),
    P0 = #{schema=>1,kind=>mathematical_path,source=>maps:get(From,Curves),
           target=>maps:get(To,Curves),steps=>Steps,total_cost=>Cost,
           total_degree=>Degree,hops=>length(Steps)},
    P = P0#{id=>path_id(P0)},
    Proof = must(replay(P)), P#{verification=>Proof}.
path_id(#{source:=S,target:=T,steps:=Steps}) ->
    Keys = [{?I:id(E),C,O} || #{map:=E,cost:=C,origins:=O} <- Steps],
    ?C:hash(<<"ECAI-MATH-PATH-V1">>,{?C:id(S),?C:id(T),Keys}).

-spec verify_path(map()) -> {ok,map()} | {error,term()}.
verify_path(Path) -> ecai_math_job:run(fun() -> replay(Path) end,5000).
replay(#{schema:=1,kind:=mathematical_path,source:=Source,target:=Target,
         steps:=Steps,total_cost:=ExpectedCost,total_degree:=ExpectedDegree,hops:=Hops,id:=Id}=Path)
    when is_list(Steps), length(Steps) =< 64 ->
    S = must(?C:normalize(Source)), T = must(?C:normalize(Target)),
    {End,Degree,Cost,Checks} = lists:foldl(fun(Step,{Current,D,C,Acc}) ->
        #{map:=Raw,cost:=W,origins:=Origins} = Step,
        need(map_size(Step) =:= 3,invalid_step_fields),
        valid_metadata(W,Origins),
        E = must(?I:normalize(Raw)),
        need(maps:get(domain,E) =:= Current,disconnected_path),
        Check = must(?I:check(E)),
        {maps:get(codomain,E),D*maps:get(degree,E),C+W,[Check|Acc]}
    end,{S,1,0,[]},Steps),
    need(End =:= T,target_mismatch),
    need(Degree =:= ExpectedDegree,composite_degree_mismatch),
    need(Cost =:= ExpectedCost,total_cost_mismatch),
    need(Hops =:= length(Steps),hop_count_mismatch),
    need(Id =:= path_id(Path),path_id_mismatch),
    {ok,#{schema=>1,status=>verified,checker=><<"ecai_exact_q_path_v1">>,
          scope=>composed_rational_isogenies,formal_proof=>false,path_id=>Id,
          source_id=>?C:id(S),target_id=>?C:id(T),total_degree=>Degree,
          steps=>lists:reverse(Checks)}};
replay(_) -> {error,invalid_path_schema}.
valid_metadata(Cost,Origins) ->
    need(is_integer(Cost) andalso Cost > 0 andalso Cost =< 1000000,invalid_cost),
    need(is_list(Origins) andalso length(Origins) =< 16 andalso
         lists:all(fun(O) -> is_binary(O) andalso byte_size(O) =< 1024 end,Origins),invalid_origins).


-spec apply_path(map(),term()) -> {ok,term()} | {error,term()}.
apply_path(Path,Point) ->
    ecai_math_job:run(fun() ->
        _ = must(replay(Path)),
        P0 = case Point of
            infinity -> infinity;
            {X,Y} -> {ecai_math_q:new(X),ecai_math_q:new(Y)};
            _ -> error(invalid_point)
        end,
        need(?C:contains(maps:get(source,Path),P0),point_not_on_source),
        Image = lists:foldl(fun(#{map:=Map},P) -> must(?I:evaluate(Map,P)) end,
                           P0,maps:get(steps,Path)),
        {ok,Image}
    end,5000).

%% Bridge to the existing ECAI relation layer. Does not call a curve NIF or
%% infer semantic relationships from distances between hashed points.
-spec to_relation(map()) -> {ok,map()} | {error,term()}.
to_relation(Path) ->
    case verify_path(Path) of
        {error,_}=Error -> Error;
        {ok,Proof} ->
            try
                {ok,R} = ecai_relation:new(maps:get(source,Path),{isogenous_over,q},maps:get(target,Path),
                    #{source=>ecai_math_pathfinder,path_id=>maps:get(id,Path),
                      total_degree=>maps:get(total_degree,Path)}),
                {ok,ecai_relation:with_proof(R,Proof#{path=>Path})}
            catch error:undef -> {error,ecai_relation_unavailable};
                  error:Reason -> {error,Reason}
            end
    end.


%% Discover a bounded graph of actual degree-2 maps, starting from a curve.
%% root enumeration is explicit and incomplete outside the stated bounds.
-spec expand_two(map(),map(),map()) -> {ok,map()} | {error,term()}.
expand_two(Graph,Seed,Options) when is_map(Options) ->
    ecai_math_job:run(fun() ->
        need(maps:without([max_depth,max_curves,numerator_bound,denominator_bound],Options) =:= #{},
             unknown_expansion_option),
        Depth = maps:get(max_depth,Options,2), Limit = maps:get(max_curves,Options,64),
        bound(Depth,0,4,max_depth), bound(Limit,1,256,max_curves),
        RootOptions = maps:with([numerator_bound,denominator_bound],Options),
        E = must(?C:normalize(Seed)), G = must(add_curve(Graph,E)),
        expand_loop(queue:from_list([{E,0}]),#{?C:id(E)=>true},G,Depth,Limit,RootOptions)
    end,30000);
expand_two(_,_,_) -> {error,invalid_expansion_options}.
expand_loop(Queue,Seen,Graph,MaxDepth,Limit,RootOptions) ->
    case queue:out(Queue) of
        {empty,_} -> {ok,Graph};
        {{value,{_E,Depth}},Rest} when Depth >= MaxDepth ->
            expand_loop(Rest,Seen,Graph,MaxDepth,Limit,RootOptions);
        {{value,{E,Depth}},Rest} ->
            Maps = must(?I:discover_two(E,RootOptions)),
            {Q1,S1,G1} = lists:foldl(fun(Map,{Q,S,G}) ->
                Target = maps:get(codomain,Map), Id = ?C:id(Target),
                GNext = must(add_isogeny(G,Map,#{source=><<"native bounded rational 2-torsion search">>})),
                case maps:is_key(Id,S) of
                    true -> {Q,S,GNext};
                    false ->
                        need(map_size(S) < Limit,{expansion_limit,max_curves}),
                        {queue:in({Target,Depth+1},Q),S#{Id=>true},GNext}
                end
            end,{Rest,Seen,Graph},Maps),
            expand_loop(Q1,S1,G1,MaxDepth,Limit,RootOptions)
    end.
-spec solve_two(map(),map(),map()) -> {ok,map()} | {error,term()}.
solve_two(Source,Target,Options) ->
    case expand_two(new(),Source,Options) of
        {ok,G} ->
            case add_curve(G,Target) of
                {ok,G1} -> find(G1,Source,Target,#{max_depth=>maps:get(max_depth,Options,2)});
                {error,_}=Error -> Error
            end;
        {error,_}=Error -> Error
    end.

-spec demo() -> {ok,map()} | {error,term()}.
demo() ->
    {ok,E0} = ?C:new(0,-1,0),
    {ok,Phi} = ?I:two(E0,0), E1 = maps:get(codomain,Phi),
    {ok,Psi} = ?I:two(E1,0), E2 = maps:get(codomain,Psi),
    {ok,G1} = add_isogeny(new(),Phi),
    {ok,G2} = add_isogeny(G1,Psi),
    find(G2,E0,E2).
must({ok,V}) -> V;
must({error,R}) -> error(R).
need(true,_) -> ok;
need(false,R) -> error(R).
