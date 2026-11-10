%% Account-local ECAI canonical-term postings, exact state digests and retained
%% plan fragments. The scan comparator uses the SAME features and ranking.
-module(ecai_supply_chain_cases).
-export([put/4, retrieve/3, summaries/1, features/1, index/1]).

features(S) ->
    Closed=[<<"closed",(maps:get(id,E))/binary>> || E <- maps:get(edges,S),maps:get(closed,E)],
    Down=[<<"down",(maps:get(id,V))/binary>> || V <- maps:get(vehicles,S),not maps:get(available,V)],
    Os=maps:get(orders,S),
    Text=iolist_to_binary(lists:join(<<" ">>,
        [<<"supplychain">>,ecai_supply_chain_util:id(<<"orders">>,length(Os)),
         ecai_supply_chain_util:id(<<"demand">>,lists:sum([maps:get(quantity,O) || O <- Os]) div 5),
         ecai_supply_chain_util:id(<<"stability">>,maps:get(stability_weight,S))]++Closed++Down)),
    ecai_terms:terms_from_record(#{text => Text}).

put(S,P,Cases,Sequence) ->
    Check=ecai_supply_chain_validator:validate(S,P),
    ecai_supply_chain_util:require(maps:get(valid,Check),case_validation_failed),
    Fingerprint=ecai_supply_chain_model:fingerprint(S),
    Skel=ecai_supply_chain_model:skeleton(P),
    Id=ecai_supply_chain_util:hash(<<"ecai-supply-chain/case-id-v1">>,#{state => Fingerprint,routes => Skel}),
    Data=#{id => Id, state_hash => Fingerprint, scenario => S,
           plan => maps:with([routes,unserved,rejected],P),
           terms => features(S), terms_version => ecai_terms:version(), sequence => Sequence,
           metrics => maps:get(metrics,P),
           validation_status => validated_simulation_plan},
    Digest=ecai_supply_chain_util:hash(<<"ecai-supply-chain/case-v1">>,Data),
    Case=Data#{digest => Digest,curve_address => curve_address(Digest)},
    Ordered=lists:sort(fun(A,B) -> {maps:get(sequence,A),maps:get(id,A)} >
                                {maps:get(sequence,B),maps:get(id,B)} end,
                       [Case|[C || C <- Cases,maps:get(id,C)=/=Id]]),
    {lists:sublist(Ordered,64),Id}.

%% Optional identity binding to the existing ECAI NIF, never a similarity metric
%% or a claim of signing, standards-conformant hash-to-curve, or PQ security.
curve_address(Digest) ->
    case application:get_env(ecai,supply_chain_curve_addresses,false) of
        true ->
            try ecai:hash_to_curve("ecai-supply-chain/case-v1",binary_to_list(Digest)) of
                {X,Y,Counter} when is_binary(X),is_binary(Y),is_integer(Counter) ->
                    #{status => available,mapping => <<"ecai-existing-nif">>,
                      x_hex => ecai_supply_chain_util:hex(X),y_hex => ecai_supply_chain_util:hex(Y),counter => Counter};
                _ -> #{status => unavailable}
            catch _:_ -> #{status => unavailable} end;
        _ -> #{status => disabled}
    end.
valid(C) ->
    try maps:get(terms_version,C,undefined)=:=ecai_terms:version() andalso
        maps:get(digest,C,undefined)=:=ecai_supply_chain_util:hash(<<"ecai-supply-chain/case-v1">>,maps:without([digest,curve_address],C))
    catch _:_ -> false end.
index(Cases) ->
    Good=[C || C <- Cases,valid(C)],
    Exact=maps:from_list([{maps:get(state_hash,C),C} || C <- lists:reverse(Good)]),
    Postings=lists:foldl(fun(C,Acc) -> lists:foldl(fun(T,M) ->
        M#{T => [maps:get(id,C)|maps:get(T,M,[])]} end,Acc,maps:get(terms,C)) end,#{},Good),
    #{exact => Exact,postings => Postings,records => maps:from_list([{maps:get(id,C),C} || C <- Good])}.
retrieve(S,Cases,Method) ->
    Start=erlang:monotonic_time(microsecond), Terms=features(S), Hash=ecai_supply_chain_model:fingerprint(S),
    %% Includes index construction/integrity checks in the reported retrieval time.
    %% A future persistent-index implementation must still benchmark build cost.
    {Exact,Candidates}=case Method of
        ecai ->
            I=index(Cases), Records=maps:get(records,I),
            Ids=lists:usort(lists:append([maps:get(T,maps:get(postings,I),[]) || T <- Terms])),
            {maps:get(Hash,maps:get(exact,I),null),[maps:get(Id,Records) || Id <- Ids]};
        lookup ->
            Good=[C || C <- Cases,valid(C)],
            Match=[C || C <- Good,maps:get(state_hash,C)=:=Hash],
            {case Match of [ExactMatch|_] -> ExactMatch;[] -> null end,Good}
    end,
    {Kind,Result}=case Exact of
        null ->
            Ranked=lists:sort([{-overlap(Terms,maps:get(terms,C)), -maps:get(sequence,C),maps:get(id,C),C} || C <- Candidates]),
            case Ranked of [{Score,_,_,NearCase}|_] when Score < 0 -> {near,NearCase}; _ -> {miss,null} end;
        ExactCase -> {exact,ExactCase}
    end,
    #{kind => Kind,case_record => Result,candidates => length(Candidates),
      retrieval_us => max(1,erlang:monotonic_time(microsecond)-Start),method => Method}.
overlap(A,B) -> length(ordsets:intersection(lists:usort(A),lists:usort(B))).
summaries(Cases) -> [maps:with([id,state_hash,digest,sequence,metrics,terms_version,curve_address,validation_status],C) || C <- Cases].
