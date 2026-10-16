%% Rational elliptic curves y^2 = x^3 + a2*x^2 + a4*x + a6.
%% Identities distinguish exact models, NOT isomorphism classes.
-module(ecai_math_curve).
-export([new/3, normalize/1, id/1, discriminant/1, polynomial/1,
         contains/2, hash/2]).
-export_type([curve/0]).
-type curve() :: #{kind := elliptic_curve, field := q,
                   a2 := ecai_math_q:q(), a4 := ecai_math_q:q(), a6 := ecai_math_q:q()}.
-define(Q, ecai_math_q).
-define(P, ecai_math_poly).
-spec new(term(), term(), term()) -> {ok,curve()} | {error,term()}.
new(A,B,C) -> normalize(#{kind=>elliptic_curve,field=>q,a2=>A,a4=>B,a6=>C}).
-spec normalize(term()) -> {ok,curve()} | {error,term()}.
normalize(#{kind:=elliptic_curve,field:=q,a2:=A,a4:=B,a6:=C}=Input)
    when map_size(Input) =:= 5 ->
    try
        E = #{kind=>elliptic_curve,field=>q,
              a2=>input_q(A),a4=>input_q(B),a6=>input_q(C)},
        case ?Q:zero(discriminant(E)) of
            true -> {error,singular_curve};
            false -> {ok,E}
        end
    catch error:Reason -> {error,Reason} end;
normalize(_) -> {error,unsupported_curve_model}.
input_q(X) ->
    {N,D} = ?Q:new(X),
    case abs(N) < (1 bsl 1024) andalso D < (1 bsl 1024) of
        true -> {N,D}; false -> error(curve_coefficient_limit)
    end.
-spec polynomial(curve()) -> ecai_math_poly:poly().
polynomial(#{a2:=A,a4:=B,a6:=C}) -> ?P:new([C,B,A,1]).
-spec discriminant(curve()) -> ecai_math_q:q().
discriminant(#{a2:=A,a4:=B,a6:=C}) ->
    %% 16 times the discriminant of the monic cubic.
    Terms = [?Q:mul(?Q:pow(A,2),?Q:pow(B,2)),
             ?Q:mul(-4,?Q:pow(B,3)),
             ?Q:mul(-4,?Q:mul(?Q:pow(A,3),C)),
             ?Q:mul(-27,?Q:pow(C,2)),
             ?Q:mul(18,?Q:mul(A,?Q:mul(B,C)))],
    ?Q:mul(16,lists:foldl(fun ?Q:add/2,{0,1},Terms)).
-spec contains(curve(), infinity | {term(),term()}) -> boolean().
contains(_E,infinity) -> true;
contains(E,{X,Y}) -> ?Q:pow(Y,2) =:= ?P:eval(polynomial(E),X);
contains(_,_) -> false.
-spec id(curve()) -> binary().
id(E) ->
    {ok,#{a2:=A,a4:=B,a6:=C}} = normalize(E),
    hash(<<"ECAI-MATH-CURVE-V1">>,{q,A,B,C}).
-spec hash(binary(),term()) -> binary().
hash(Domain,Term) ->
    %% Length-prefixed domain and deterministic ETF; never hashes floats.
    Digest = crypto:hash(sha256, [<<(byte_size(Domain)):32>>,Domain,
                                  term_to_binary(Term,[deterministic])]),
    binary:encode_hex(Digest).
