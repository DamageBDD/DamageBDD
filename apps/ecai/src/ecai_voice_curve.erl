%%% Bounded public secp256k1 coordinates for an acoustic-metric experiment.
%%% This is NOT encryption, an identity proof, or constant-time secret-key code.
%%% Deliberately separate from ecai's existing Curve25519 content identifiers.
-module(ecai_voice_curve).
-license("Apache-2.0").
-export([new/0, encode/2, distance/3, integer_distance/2, bound/0]).

-define(B, 255).
-define(P, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F).
-define(GX, 16#79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798).
-define(GY, 16#483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8).

-type point() :: infinity | {non_neg_integer(), non_neg_integer()}.
-opaque context() :: #{points := map(), allowed := map(), inverse := map()}.
-export_type([context/0]).

-spec bound() -> pos_integer().
bound() -> ?B.

%% Keep one context per batch; no persistent_term, global ETS, or server lifecycle.
-spec new() -> context().
new() ->
    Ps = make_points(1, infinity, #{0 => infinity}),
    Inv = maps:from_list([{sec1(P), Q} || {Q, P} <- maps:to_list(Ps)]),
    true = map_size(Inv) =:= 4 * ?B + 1,
    Allowed = maps:from_list([
        {sec1(maps:get(Q, Ps)), maps:get(Q, Ps)} || Q <- lists:seq(-?B, ?B)
    ]),
    #{points => Ps, allowed => Allowed, inverse => Inv}.

-spec encode([integer()], context()) -> {ok, [binary()]} | {error, term()}.
encode(Qs, #{points := Ps}) ->
    case valid_q(Qs) of
        true -> {ok, [sec1(maps:get(Q, Ps)) || Q <- Qs]};
        false -> {error, invalid_quantized_vector}
    end;
encode(_, _) -> {error, invalid_curve_context}.

-spec integer_distance([integer()], [integer()]) -> {ok, non_neg_integer()} | {error, term()}.
integer_distance(A, B) ->
    case valid_q(A) andalso valid_q(B) andalso length(A) =:= length(B) of
        true -> {ok, lists:sum([abs(X - Y) || {X, Y} <- lists:zip(A, B)])};
        false -> {error, invalid_quantized_vectors}
    end.

-spec distance([binary()], [binary()], context()) -> {ok, non_neg_integer()} | {error, term()}.
distance(A, B, #{allowed := Allowed, inverse := Inverse}) ->
    case is_list(A) andalso is_list(B) andalso A =/= [] andalso
         length(A) =< 128 andalso length(A) =:= length(B) of
        true -> distance_loop(A, B, Allowed, Inverse, 0);
        false -> {error, invalid_point_vectors}
    end;
distance(_, _, _) -> {error, invalid_curve_context}.

distance_loop([], [], _, _, Sum) -> {ok, Sum};
distance_loop([A | As], [B | Bs], Allowed, Inverse, Sum) ->
    %% Only canonical encodings in the declared bounded set reach arithmetic.
    case {maps:find(A, Allowed), maps:find(B, Allowed)} of
        {{ok, PA}, {ok, PB}} ->
            Delta = add(PA, negate(PB)),
            case maps:find(sec1(Delta), Inverse) of
                {ok, D} -> distance_loop(As, Bs, Allowed, Inverse, Sum + abs(D));
                error -> {error, curve_difference_out_of_range}
            end;
        _ -> {error, point_outside_bounded_encoding}
    end.

valid_q(Qs) when is_list(Qs), Qs =/= [], length(Qs) =< 128 ->
    lists:all(fun(Q) -> is_integer(Q) andalso Q >= -?B andalso Q =< ?B end, Qs);
valid_q(_) -> false.

make_points(K, _, Ps) when K > 2 * ?B -> Ps;
make_points(K, Prev, Ps) ->
    Next = add(Prev, {?GX, ?GY}),
    make_points(K + 1, Next, Ps#{K => Next, (-K) => negate(Next)}).

-spec add(point(), point()) -> point().
add(infinity, B) -> B;
add(A, infinity) -> A;
add({X, Y}, {X, V}) ->
    case mod(Y + V) of
        0 -> infinity;
        _ -> finish_add(X, Y, X, mod(3 * X * X * inverse(2 * Y)))
    end;
add({X, Y}, {U, V}) -> finish_add(X, Y, U, mod((V - Y) * inverse(U - X))).

finish_add(X, Y, U, Slope) ->
    NX = mod(Slope * Slope - X - U),
    {NX, mod(Slope * (X - NX) - Y)}.

negate(infinity) -> infinity;
negate({X, Y}) -> {X, mod(-Y)}.

sec1(infinity) -> <<0>>;
sec1({X, Y}) -> <<(2 + (Y band 1)):8, X:256/unsigned-big>>.

mod(X) -> ((X rem ?P) + ?P) rem ?P.
inverse(X) ->
    {1, S, _} = egcd(mod(X), ?P),
    mod(S).
egcd(A, 0) -> {A, 1, 0};
egcd(A, B) ->
    {G, S, T} = egcd(B, A rem B),
    {G, T, S - (A div B) * T}.
