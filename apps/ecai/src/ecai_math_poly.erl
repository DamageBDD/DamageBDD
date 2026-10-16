%% Q[x], coefficients in ascending order. Zero is the empty list.
-module(ecai_math_poly).
-export([new/1, add/2, sub/2, mul/2, scale/2, pow/2, degree/1,
         eval/2, divmod/2, gcd/2, fraction/2, derivative/1]).
-export_type([poly/0]).
-type poly() :: [ecai_math_q:q()].
-define(Q, ecai_math_q).

-spec new(list()) -> poly().
new(L) when is_list(L), length(L) =< 513 ->
    trim([?Q:new(C) || C <- L]);
new(_) -> error(invalid_or_oversized_polynomial).
trim(L) -> lists:reverse(drop_zeros(lists:reverse(L))).
drop_zeros([{0,1}|T]) -> drop_zeros(T);
drop_zeros(L) -> L.
-spec degree(poly()) -> integer().
degree(P) -> length(P) - 1.
-spec add(poly(), poly()) -> poly().
add(A, B) -> trim(sum(A, B)).
sum([], B) -> B;
sum(A, []) -> A;
sum([A|AT], [B|BT]) -> [?Q:add(A,B)|sum(AT,BT)].
-spec sub(poly(), poly()) -> poly().
sub(A, B) -> add(A, scale(B, -1)).
-spec scale(poly(), integer() | ecai_math_q:q()) -> poly().
scale(P, C) -> trim([?Q:mul(X,C) || X <- P]).
-spec mul(poly(), poly()) -> poly().
mul([], _) -> [];
mul(_, []) -> [];
mul(A, B) when length(A) + length(B) =< 514 -> product(A, B, 0, []);
mul(_, _) -> error(polynomial_degree_limit).
product([], _, _, Acc) -> Acc;
product([C|T], B, N, Acc) ->
    product(T, B, N+1, add(Acc, lists:duplicate(N,{0,1}) ++ scale(B,C))).
-spec pow(poly(), non_neg_integer()) -> poly().
pow(_P, 0) -> [{1,1}];
pow(P, N) when is_integer(N), N > 0, N =< 8 -> mul(P, pow(P,N-1));
pow(_, _) -> error(invalid_polynomial_exponent).
-spec eval(poly(), integer() | ecai_math_q:q()) -> ecai_math_q:q().
eval(P, X) -> lists:foldr(fun(C,A) -> ?Q:add(C,?Q:mul(X,A)) end, {0,1}, P).
-spec divmod(poly(), poly()) -> {poly(), poly()}.
divmod(_, []) -> error(zero_polynomial_denominator);
divmod(A, B) -> divide_loop(A,B,[]).
divide_loop(A,B,Q) when length(A) < length(B) -> {Q,A};
divide_loop(A,B,Q) ->
    N = length(A)-length(B),
    C = ?Q:divide(lists:last(A),lists:last(B)),
    T = lists:duplicate(N,{0,1}) ++ [C],
    divide_loop(sub(A,mul(T,B)), B, add(Q,T)).
-spec gcd(poly(), poly()) -> poly().
gcd([], []) -> [];
gcd(A, []) -> scale(A,?Q:divide(1,lists:last(A)));
gcd(A, B) -> {_,R} = divmod(A,B), gcd(B,R).
%% Reduced numerator/denominator, with monic denominator. Identity is not
%% affected by removable factors or a common nonzero scalar.
-spec fraction(poly(), poly()) -> {poly(), poly()}.
fraction(_, []) -> error(zero_polynomial_denominator);
fraction([], _D) -> {[],[{1,1}]};
fraction(N,D) ->
    G = gcd(N,D), {N1,[]} = divmod(N,G), {D1,[]} = divmod(D,G),
    C = ?Q:divide(1,lists:last(D1)), {scale(N1,C),scale(D1,C)}.
-spec derivative(poly()) -> poly().
derivative([]) -> [];
derivative([_|T]) -> new([?Q:mul(C,I) || {C,I} <- lists:zip(T,lists:seq(1,length(T)))]).
