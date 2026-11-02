%% Source-only exploration. No destination, catalogue, network or learned hints.
%% Every accepted model has a checked path; model identity is not Q-isomorphism.
%% Coordinate bounds are model-dependent: DO NOT prune by isomorphism class.
-module(ecai_math_explorer).
-export([explore/2, encode/1, wire/1]).
-define(C,ecai_math_curve).
-define(F,ecai_math_pathfinder).
-define(I,ecai_math_isogeny).
-define(Q,ecai_math_q).
-define(ISO,ecai_math_isomorphism).
-define(ROW_BYTES,229376).

-spec explore(map(),map()) -> {ok,map()} | {error,term()}.
explore(Source,Options) ->
    ecai_math_job:run(fun() -> run(Source,options(Options)) end,45000).
options(M) when is_map(M) ->
    D = #{max_depth=>2,max_curves=>24,numerator_bound=>8,denominator_bound=>4,timeout_ms=>8000},
    need(maps:without(maps:keys(D),M) =:= #{},unknown_exploration_option), O=maps:merge(D,M),
    bound(O,max_depth,0,3),bound(O,max_curves,1,32),bound(O,numerator_bound,0,32),
    bound(O,denominator_bound,1,16),bound(O,timeout_ms,1,20000), O;
options(_) -> error(invalid_exploration_options).
bound(O,K,L,H) -> V=maps:get(K,O),need(is_integer(V) andalso V>=L andalso V=<H,{invalid_option,K}).
run(Source,O) ->
    Seed=must(?C:normalize(Source)), Start=now_ms(),
    RootPath=must(?F:from_steps(Seed,[])),
    Self=must(?ISO:compare(Seed,Seed)),
    Root=make_row(Seed,RootPath,Self,1,?C:id(Seed),Self),
    Roots=lists:usort([?Q:new({N,D}) || N<-lists:seq(-maps:get(numerator_bound,O),maps:get(numerator_bound,O)),
                                      D<-lists:seq(1,maps:get(denominator_bound,O))]),
    S=#{source=>Seed,options=>O,start=>Start,deadline=>Start+maps:get(timeout_ms,O),
        rows=>[Root],seen=>#{?C:id(Seed)=>Seed},classes=>[Root],
        queue=>queue:from_list([Root]),roots=>Roots,bytes=>row_bytes(Root),
        stats=>#{expanded_models=>0,root_evaluations=>0,kernels_found=>0,
                 checked_maps=>0,revisited_models=>0,depth_frontier_models=>0}},
    finish(loop(S)).
loop(S) ->
    case now_ms() >= maps:get(deadline,S) of
        true -> stopped(time_budget,S);
        false ->
            case queue:out(maps:get(queue,S)) of
                {empty,_} -> S#{stop=>bounded_search_exhausted};
                {{value,R},Rest} ->
                    S1=S#{queue:=Rest},
                    case maps:get(depth,R) >= maps:get(max_depth,maps:get(options,S)) of
                        true -> loop(inc(depth_frontier_models,S1));
                        false ->
                            S2=inc(expanded_models,S1),
                            case scan(maps:get(roots,S2),R,S2) of
                                #{stop:=_}=Done -> Done;
                                Next -> loop(Next)
                            end
                    end
            end
    end.
scan([],_,S) -> S;
scan([Root|Rest],Parent,S) ->
    case now_ms() >= maps:get(deadline,S) of
        true -> stopped(time_budget,S);
        false ->
            S1=inc(root_evaluations,S), E=maps:get(curve,Parent),
            try ?Q:zero(ecai_math_poly:eval(?C:polynomial(E),Root)) of
                false -> scan(Rest,Parent,S1);
                true ->
                    case candidate(E,Root,Parent,inc(kernels_found,S1)) of
                        #{stop:=_}=Done -> Done;
                        Next -> scan(Rest,Parent,Next)
                    end
            catch error:Reason -> stopped(algebra_resource_limit,S1#{detail=>detail(Reason)}) end
    end.
candidate(E,Root,Parent,S) ->
    %% Each candidate commits atomically: a failure keeps only preceding checked rows.
    try
        M=must(?I:two(E,Root)), _=must(?I:check(M)),
        S1=inc(checked_maps,S), T=maps:get(codomain,M), Id=?C:id(T),
        case maps:find(Id,maps:get(seen,S)) of
            {ok,T} -> inc(revisited_models,S1);
            {ok,_} -> stopped(model_identifier_collision,S1);
            error ->
                case length(maps:get(rows,S)) >= maps:get(max_curves,maps:get(options,S)) of
                    true -> stopped(model_budget,S1);
                    false -> accept_candidate(T,M,Parent,S1)
                end
        end
    catch error:Reason -> stopped(candidate_check_failed,S#{detail=>detail(Reason)}) end.
accept_candidate(T,M,Parent,S) ->
    Steps=maps:get(steps,maps:get(path,Parent))++[#{map=>M,cost=>1,
                    origins=>[<<"native source-only bounded rational 2-torsion search">>]}],
    P=must(?F:from_steps(maps:get(source,S),Steps)),
    Comparison=must(?ISO:compare(maps:get(source,S),T)),
    {Class,Representative,ClassCheck,IsNew}=classify(T,maps:get(classes,S),1),
    R=make_row(T,P,Comparison,Class,Representative,ClassCheck),
    Bytes=maps:get(bytes,S)+row_bytes(R),
    case {Bytes =< ?ROW_BYTES,now_ms() < maps:get(deadline,S)} of
        {false,_} -> stopped(export_byte_budget,S);
        {_,false} -> stopped(time_budget,S);
        {true,true} ->
            Classes=case IsNew of true -> maps:get(classes,S)++[R]; false -> maps:get(classes,S) end,
            S#{rows:=maps:get(rows,S)++[R],classes:=Classes,
               seen:=(maps:get(seen,S))#{maps:get(model_id,R)=>T},bytes:=Bytes,
               queue:=queue:in(R,maps:get(queue,S))}
    end.
classify(T,[],N) -> {N,?C:id(T),must(?ISO:compare(T,T)),true};
classify(T,[R|Rest],N) ->
    Cert=must(?ISO:compare(maps:get(curve,R),T)),
    case maps:get(relation,Cert) of
        isomorphic -> {N,maps:get(model_id,R),Cert,false};
        non_isomorphic -> classify(T,Rest,N+1)
    end.
make_row(E,P,Comparison,Class,Rep,Cert) ->
    Bin=must(ecai_math_codec:encode(P)),
    #{model_id=>?C:id(E),curve=>E,depth=>maps:get(hops,P),path=>P,path_json=>Bin,
      path_id=>maps:get(id,P),artifact_sha256=>binary:encode_hex(crypto:hash(sha256,Bin)),
      comparison_to_source=>Comparison,local_class=>Class,representative_id=>Rep,
      class_certificate=>Cert}.
inc(Key,S) -> Stats=maps:get(stats,S),S#{stats:=Stats#{Key:=maps:get(Key,Stats)+1}}.
stopped(Why,S) -> S#{stop=>Why}.
finish(S) ->
    Rows=maps:get(rows,S), Stop=maps:get(stop,S),
    NonIso=[R || R<-Rows,maps:get(relation,maps:get(comparison_to_source,R))=:=non_isomorphic],
    ClassCount=length(maps:get(classes,S)),
    Summary=#{retained_models=>length(Rows),reachable_other_models=>length(Rows)-1,
              non_isomorphic_to_source_models=>length(NonIso),
              isomorphic_to_source_other_models=>length(Rows)-length(NonIso)-1,
              local_q_classes=>ClassCount,non_source_q_classes=>ClassCount-1},
    Report=#{schema=>1,kind=>mathematical_exploration,source=>maps:get(source,S),
             bounds=>maps:get(options,S),stop_reason=>Stop,
             completed_within_declared_bounds=>(Stop=:=bounded_search_exhausted),
             global_completeness=>not_claimed,novel_to_mathematics=>not_claimed,
             elapsed_ms=>now_ms()-maps:get(start,S),summary=>Summary,stats=>maps:get(stats,S),
             results=>Rows,formal_proof=>false,
             note=><<"Source-only degree-2 search. Local classes are exact Q-isomorphism groups among retained models, not a complete isogeny class. Bounds depend on coordinates; no isomorphic model was pruned. Every retained path is independently replayable.">>},
    {ok,case maps:find(detail,S) of {ok,D}->Report#{detail=>D};error->Report end}.
row_bytes(R) -> iolist_size(json:encode(wire(maps:remove(path,R)))).
-spec encode(map()) -> {ok,binary()} | {error,term()}.
encode(#{kind:=mathematical_exploration,results:=Rows}=R) ->
    try
        %% Path JSON was generated by the checked native codec when accepted.
        W=wire(R#{results:=[maps:remove(path,Row)||Row<-Rows]}),
        Bin=iolist_to_binary(json:encode(W)),
        need(byte_size(Bin)=<262144,exploration_document_size_limit),{ok,Bin}
    catch error:Reason -> {error,Reason} end;
encode(_) -> {error,invalid_exploration_document}.
wire({N,D}) when is_integer(N),is_integer(D) -> [integer_to_binary(N),integer_to_binary(D)];
wire(M) when is_map(M) -> maps:from_list([{key(K),wire(V)}||{K,V}<-maps:to_list(M)]);
wire(L) when is_list(L) -> [wire(V)||V<-L];
wire(true) -> true;
wire(false) -> false;
wire(null) -> null;
wire(A) when is_atom(A) -> atom_to_binary(A,utf8);
wire(N) when is_integer(N),abs(N)>9007199254740991 -> integer_to_binary(N);
wire(V) when is_integer(V);is_binary(V) -> V.
key(A) when is_atom(A) -> atom_to_binary(A,utf8);
key(B) when is_binary(B) -> B.
now_ms() -> erlang:monotonic_time(millisecond).
detail(R) -> iolist_to_binary(io_lib:format("~0P",[R,4])).
must({ok,V}) -> V;
must({error,R}) -> error(R).
need(true,_) -> ok;
need(false,R) -> error(R).
