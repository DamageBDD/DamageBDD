%% Exact Q-isomorphism decisions for y^2=x^3+a2*x^2+a4*x+a6.
%% Equal j is necessary, NOT sufficient over Q. No factorisation is needed:
%% rational kth powers are decided by exact integer root brackets.
-module(ecai_math_isomorphism).
-export([compare/2, invariants/1, verify/3]).
-define(Q,ecai_math_q).
-define(C,ecai_math_curve).
-define(I,ecai_math_isogeny).

-spec invariants(map()) -> {ok,map()} | {error,term()}.
invariants(Input) ->
    try
        E = must(?C:normalize(Input)),
        #{a2:=A2,a4:=A4,a6:=A6} = E,
        A = ?Q:sub(A4,?Q:divide(?Q:pow(A2,2),3)),
        B = ?Q:add(?Q:sub(A6,?Q:divide(?Q:mul(A2,A4),3)),
                   ?Q:divide(?Q:mul(2,?Q:pow(A2,3)),27)),
        FourA3 = ?Q:mul(4,?Q:pow(A,3)),
        J = ?Q:divide(?Q:mul(1728,FourA3),?Q:add(FourA3,?Q:mul(27,?Q:pow(B,2)))),
        {ok,#{short_a=>A,short_b=>B,j=>J,discriminant=>?C:discriminant(E)}}
    catch error:Reason -> {error,Reason} end.

-spec compare(map(),map()) -> {ok,map()} | {error,term()}.
compare(Source,Target) ->
    try
        S = must(?C:normalize(Source)), T = must(?C:normalize(Target)),
        SI = must(invariants(S)), TI = must(invariants(T)),
        Base = #{schema=>1,scope=>q_isomorphism,checker=><<"ecai_q_isomorphism_v1">>,
                 formal_proof=>false,source_id=>?C:id(S),target_id=>?C:id(T),
                 source_invariants=>SI,target_invariants=>TI},
        Result = case {maps:get(j,SI),maps:get(j,TI)} of
            {J,J} -> same_j(S,T,SI,TI,Base);
            _ -> Base#{relation=>non_isomorphic,reason=>different_j_invariants}
        end,
        {ok,Result}
    catch error:Reason -> {error,Reason} end.

same_j(S,T,#{short_a:=A,short_b:=B},#{short_a:=AA,short_b:=BB},Base) ->
    %% For short models the required forward scale obeys AA=u^4*A,
    %% BB=u^6*B. j=0 and j=1728 have different twist obstructions.
    {Exponent,Ratio,Reason} = case {A,B} of
        {{0,1},_} -> {6,?Q:divide(BB,B),sixth_power_obstruction};
        {_,{0,1}} -> {4,?Q:divide(AA,A),fourth_power_obstruction};
        _ -> {2,?Q:divide(?Q:divide(BB,B),?Q:divide(AA,A)),square_obstruction}
    end,
    Power = rational_power(Ratio,Exponent),
    Evidence = Base#{power_test=>Power},
    case maps:get(exact,Power) of
        false -> Evidence#{relation=>non_isomorphic,reason=>Reason};
        true ->
            U = maps:get(root,Power),
            true = ?Q:mul(?Q:pow(U,4),A) =:= AA,
            true = ?Q:mul(?Q:pow(U,6),B) =:= BB,
            Shift = ?Q:divide(?Q:sub(?Q:mul(?Q:pow(U,2),maps:get(a2,S)),maps:get(a2,T)),3),
            M = must(?I:new(S,T,#{degree=>1,x_num=>[Shift,?Q:pow(U,2)],x_den=>[1],
                                  y_num=>[?Q:pow(U,3)],y_den=>[1]})),
            Check = must(?I:check(M)),
            Evidence#{relation=>isomorphic,reason=>checked_rational_scaling_and_translation,
                      forward_scale=>U,x_shift=>Shift,witness=>M,witness_check=>Check}
    end.

rational_power({N,D}=R,K) when N < 0 ->
    #{exponent=>K,ratio=>R,exact=>false,obstruction=>negative_even_power,
      denominator=>D};
rational_power({N,D}=R,K) ->
    NR = floor_root(N,K), DR = floor_root(D,K),
    Exact = ipow(NR,K) =:= N andalso ipow(DR,K) =:= D,
    Base = #{exponent=>K,ratio=>R,exact=>Exact,
             numerator_floor=>NR,denominator_floor=>DR},
    case Exact of true -> Base#{root=>?Q:new({NR,DR})};
        false -> Base#{obstruction=>non_integral_root_bracket} end.
floor_root(0,_) -> 0;
floor_root(1,_) -> 1;
floor_root(N,K) ->
    Bits = bit_size(binary:encode_unsigned(N)),
    root_search(N,K,0,1 bsl ((Bits+K-1) div K)).
root_search(_N,_K,Lo,Hi) when Hi-Lo =< 1 -> Lo;
root_search(N,K,Lo,Hi) ->
    Mid = (Lo+Hi) div 2,
    case ipow(Mid,K) =< N of
        true -> root_search(N,K,Mid,Hi);
        false -> root_search(N,K,Lo,Mid)
    end.
ipow(_,0) -> 1;
ipow(N,K) -> N*ipow(N,K-1).

%% Recompute, rather than trusting submitted relation/receipt fields.
-spec verify(map(),map(),map()) -> {ok,map()} | {error,term()}.
verify(S,T,Certificate) ->
    case compare(S,T) of
        {ok,Certificate} -> {ok,Certificate};
        {ok,_} -> {error,isomorphism_certificate_mismatch};
        Error -> Error
    end.
must({ok,V}) -> V;
must({error,R}) -> error(R).
