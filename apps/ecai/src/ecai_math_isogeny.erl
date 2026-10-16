%% Explicit rational isogenies over Q. No statistical or point-sampling test.
%% Chart: X=N(x)/D(x), Y=y*M(x)/L(x), a1=a3=0 on both curves.
-module(ecai_math_isogeny).
-export([new/3, normalize/1, id/1, check/1, verify/1,
         two/2, scale/2, evaluate/2, discover_two/2]).
-define(Q, ecai_math_q).
-define(P, ecai_math_poly).
-define(C, ecai_math_curve).
-define(MAX_DEGREE,32).

-spec new(map(),map(),map()) -> {ok,map()} | {error,term()}.
new(Source,Target,Spec) when is_map(Spec) ->
    normalize(Spec#{kind=>isogeny,domain=>Source,codomain=>Target});
new(_,_,_) -> {error,invalid_isogeny}.

-spec normalize(term()) -> {ok,map()} | {error,term()}.
normalize(#{kind:=isogeny,domain:=Source,codomain:=Target,degree:=Degree,
            x_num:=N,x_den:=D,y_num:=M,y_den:=L}=Input)
    when map_size(Input) =:= 8, is_integer(Degree), Degree >= 1, Degree =< ?MAX_DEGREE ->
    try
        S = must(?C:normalize(Source)), T = must(?C:normalize(Target)),
        {NN,DD} = ?P:fraction(input_poly(N),input_poly(D)),
        {MM,LL} = ?P:fraction(input_poly(M),input_poly(L)),
        lists:foreach(fun(P) -> _ = input_poly(P) end,[NN,DD,MM,LL]),
        {ok,#{kind=>isogeny,domain=>S,codomain=>T,degree=>Degree,
              x_num=>NN,x_den=>DD,y_num=>MM,y_den=>LL}}
    catch error:Reason -> {error,Reason} end;
normalize(_) -> {error,invalid_isogeny_schema_or_degree}.
input_poly(P) when is_list(P), length(P) =< 65 ->
    N = ?P:new(P),
    case lists:all(fun({A,B}) -> abs(A) < (1 bsl 1024) andalso B < (1 bsl 1024) end,N) of
        true -> N; false -> error(map_coefficient_limit)
    end;
input_poly(_) -> error(map_polynomial_degree_limit).
must({ok,V}) -> V;
must({error,R}) -> error(R).

-spec id(map()) -> binary().
id(Map) ->
    E = must(normalize(Map)),
    ?C:hash(<<"ECAI-MATH-ISOGENY-V1">>,
        {?C:id(maps:get(domain,E)),?C:id(maps:get(codomain,E)),
         maps:get(degree,E),maps:get(x_num,E),maps:get(x_den,E),
         maps:get(y_num,E),maps:get(y_den,E)}).

%% check/1 is pure, bounded by coefficient and degree limits. Use verify/1
%% at an external boundary for a deadline and isolated BEAM heap as well.
-spec check(map()) -> {ok,map()} | {error,term()}.
check(Input) ->
    try
        E = must(normalize(Input)),
        #{domain:=S,codomain:=T,degree:=Degree,x_num:=N,x_den:=D,
          y_num:=M,y_den:=L} = E,
        require(?P:degree(N)-?P:degree(D) =:= 1, infinity_not_preserved),
        require(M =/= [] andalso ?P:degree(M) =:= ?P:degree(L), invalid_y_pole_order),
        require(erlang:max(?P:degree(N),?P:degree(D)) =:= Degree, degree_mismatch),
        %% Clear denominators and reduce using y^2=f_source(x):
        %% f_source M^2 D^3 = (N^3+a2' N^2D+a4' ND^2+a6' D^3)L^2.
        #{a2:=A,a4:=B,a6:=C} = T,
        D2 = ?P:pow(D,2), D3 = ?P:mul(D2,D),
        TargetNumerator = ?P:add(?P:add(?P:pow(N,3),?P:scale(?P:mul(?P:pow(N,2),D),A)),
                                ?P:add(?P:scale(?P:mul(N,D2),B),?P:scale(D3,C))),
        Left = ?P:mul(?P:mul(?C:polynomial(S),?P:pow(M,2)),D3),
        Right = ?P:mul(TargetNumerator,?P:pow(L,2)),
        require(?P:sub(Left,Right) =:= [],curve_identity_failed),
        {ok,#{schema=>1,status=>verified,checker=><<"ecai_exact_q_map_v1">>,
              scope=>rational_map_identity,field=>q,map_id=>id(E),degree=>Degree,
              source_id=>?C:id(S),target_id=>?C:id(T),
              polynomial_identity=>zero,origin_preserved=>true,
              degree_checked=>true,formal_proof=>false}}
    catch error:Reason -> {error,Reason} end.
require(true,_) -> ok;
require(false,Reason) -> error(Reason).
-spec verify(map()) -> {ok,map()} | {error,term()}.
verify(E) -> ecai_math_job:run(fun() -> check(E) end,5000).

%% Quotient by {O,(r,0)}. r must be an exact rational root of the cubic.
%% Translate u=x-r; write source as y^2=u^3+a*u^2+b*u.
%% Then X=(u^2+a*u+b)/u, Y=y*(u^2-b)/u^2.
-spec two(map(),term()) -> {ok,map()} | {error,term()}.
two(Source,Root) ->
    try
        S = must(?C:normalize(Source)), R = ?Q:new(Root),
        require(?Q:zero(?P:eval(?C:polynomial(S),R)),kernel_not_rational_two_torsion),
        #{a2:=A0,a4:=B0} = S,
        A = ?Q:add(A0,?Q:mul(3,R)),
        B = ?Q:add(B0,?Q:add(?Q:mul(2,?Q:mul(A0,R)),?Q:mul(3,?Q:pow(R,2)))),
        T = must(?C:new(?Q:mul(-2,A),?Q:sub(?Q:pow(A,2),?Q:mul(4,B)),0)),
        U = ?P:new([?Q:neg(R),1]), U2 = ?P:pow(U,2),
        new(S,T,#{degree=>2,x_num=>?P:add(?P:add(U2,?P:scale(U,A)),?P:new([B])),
                  x_den=>U,y_num=>?P:sub(U2,?P:new([B])),y_den=>U2})
    catch error:Reason -> {error,Reason} end.

%% Degree-one isomorphism (x,y) -> (u^2*x,u^3*y).
-spec scale(map(),term()) -> {ok,map()} | {error,term()}.
scale(Source,Factor) ->
    try
        S = must(?C:normalize(Source)), U = ?Q:new(Factor),
        require(not ?Q:zero(U),zero_scale),
        #{a2:=A,a4:=B,a6:=C} = S,
        T = must(?C:new(?Q:mul(A,?Q:pow(U,2)),?Q:mul(B,?Q:pow(U,4)),?Q:mul(C,?Q:pow(U,6)))),
        new(S,T,#{degree=>1,x_num=>[0,?Q:pow(U,2)],x_den=>[1],
                  y_num=>[?Q:pow(U,3)],y_den=>[1]})
    catch error:Reason -> {error,Reason} end.

-spec evaluate(map(),term()) -> {ok,term()} | {error,term()}.
evaluate(Input,Point) ->
    ecai_math_job:run(fun() ->
        _ = must(check(Input)), E = must(normalize(Input)),
        evaluate_checked(E,Point)
    end,5000).
evaluate_checked(_E,infinity) -> {ok,infinity};
evaluate_checked(#{domain:=S,codomain:=T,x_num:=N,x_den:=D,y_num:=M,y_den:=L},{X0,Y0}) ->
    X = ?Q:new(X0), Y = ?Q:new(Y0),
    require(?C:contains(S,{X,Y}),point_not_on_source),
    DX = ?P:eval(D,X), LX = ?P:eval(L,X),
    case ?Q:zero(DX) of
        true -> {ok,infinity};
        false ->
            require(not ?Q:zero(LX),requires_projective_evaluation),
            Image = {?Q:divide(?P:eval(N,X),DX),?Q:mul(Y,?Q:divide(?P:eval(M,X),LX))},
            require(?C:contains(T,Image),image_not_on_target),
            {ok,Image}
    end;
evaluate_checked(_,_) -> {error,invalid_point}.

%% Bounded root enumeration, not a complete solver for rational roots.
-spec discover_two(map(),map()) -> {ok,[map()]} | {error,term()}.
discover_two(Source,Opts) when is_map(Opts) ->
    ecai_math_job:run(fun() ->
        S = must(?C:normalize(Source)),
        N = maps:get(numerator_bound,Opts,8), D = maps:get(denominator_bound,Opts,4),
        require(is_integer(N) andalso N >= 0 andalso N =< 64,invalid_numerator_bound),
        require(is_integer(D) andalso D >= 1 andalso D =< 32,invalid_denominator_bound),
        require(maps:without([numerator_bound,denominator_bound],Opts) =:= #{},unknown_discovery_option),
        Roots = lists:usort([?Q:new({A,B}) || A <- lists:seq(-N,N), B <- lists:seq(1,D)]),
        Maps = [must(two(S,R)) || R <- Roots, ?Q:zero(?P:eval(?C:polynomial(S),R))],
        lists:foreach(fun(E) -> _ = must(check(E)) end,Maps),
        {ok,Maps}
    end,5000);
discover_two(_,_) -> {error,invalid_discovery_options}.
