%% Exact rational arithmetic. No float coercion; bounded bignums.
-module(ecai_math_q).
-export([new/1, add/2, sub/2, mul/2, divide/2, neg/1, pow/2, zero/1]).
-export_type([q/0]).
-type q() :: {integer(), pos_integer()}.
-define(MAX_INTEGER, (1 bsl 8192)).

-spec new(integer() | {integer(), integer()}) -> q().
new(N) when is_integer(N) -> new({N, 1});
new({N, D}) when is_integer(N), is_integer(D), D =/= 0,
                 N < ?MAX_INTEGER, N > -?MAX_INTEGER,
                 D < ?MAX_INTEGER, D > -?MAX_INTEGER ->
    G = gcd(abs(N), abs(D)),
    case D > 0 of
        true -> {N div G, D div G};
        false -> {-N div G, -D div G}
    end;
new({_, 0}) -> error(zero_denominator);
new(_) -> error(invalid_or_oversized_rational).

-spec add(q() | integer(), q() | integer()) -> q().
add(A, B) ->
    {N, D} = new(A), {M, E} = new(B),
    G = gcd(D, E),
    new({N * (E div G) + M * (D div G), D * (E div G)}).
-spec sub(q() | integer(), q() | integer()) -> q().
sub(A, B) -> add(A, neg(B)).
-spec neg(q() | integer()) -> q().
neg(A) -> {N, D} = new(A), {-N, D}.
-spec mul(q() | integer(), q() | integer()) -> q().
mul(A, B) ->
    {N, D} = new(A), {M, E} = new(B),
    G = gcd(abs(N), E), H = gcd(abs(M), D),
    new({(N div G) * (M div H), (D div H) * (E div G)}).
-spec divide(q() | integer(), q() | integer()) -> q().
divide(A, B) -> {N, D} = new(B), mul(A, new({D, N})).
-spec pow(q() | integer(), non_neg_integer()) -> q().
pow(A, N) when is_integer(N), N >= 0, N =< 256 -> power(new(A), N, {1,1});
pow(_, _) -> error(invalid_exponent).
power(_, 0, Acc) -> Acc;
power(A, 1, Acc) -> mul(Acc, A);
power(A, N, Acc) when N rem 2 =:= 1 -> power(mul(A,A), N div 2, mul(Acc,A));
power(A, N, Acc) -> power(mul(A,A), N div 2, Acc).
-spec zero(q() | integer()) -> boolean().
zero(A) -> new(A) =:= {0,1}.
gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).
