%%%-------------------------------------------------------------------
%%% ecai_demo.erl
%%% A pure Erlang demo of ECAI-style isogeny mapping (toy, non-secure)
%%% Curve: y^2 = x^3 - x + 1 (mod 23)
%%%-------------------------------------------------------------------
-module(ecai_demo).
-export([test/0, toy_isogeny/2, on_curve/1, add/2, double/1]).

-define(A, -1).
-define(B, 1).
-define(P, 23).

%%% ---------- helpers ----------
modp(N) ->
    ((N rem ?P) + ?P) rem ?P.

inv(A) ->
    modinv(modp(A), ?P).

modinv(0, _P) ->
    error(no_inverse);
modinv(A, P) ->
    {G, X, _Y} = egcd(A, P),
    case G of
        1 -> modp(X);
        _ -> error(no_inverse)
    end.

egcd(0, B) ->
    {B, 0, 1};
egcd(A, B) ->
    {G, X1, Y1} = egcd(B rem A, A),
    {G, Y1 - (B div A) * X1, X1}.

%%% ---------- curve predicates ----------
on_curve(inf) ->
    true;
on_curve({X, Y}) ->
    L = modp(Y * Y),
    R = modp(X * X * X + ?A * X + ?B),
    L =:= R.

%%% ---------- group law ----------
%% Point addition with full cases (including infinity and doubling)
add(inf, Q) ->
    Q;
add(Pt, inf) ->
    Pt;
add({X1, Y1} = P1, {X2, Y2} = P2) ->
    case {X1 =:= X2, modp(Y1 + Y2) =:= 0} of
        %% P + (-P) = inf
        {true, true} ->
            inf;
        %% Doubling case (P == Q)
        {true, false} ->
            double(P1);
        %% General addition
        {false, _} ->
            %% IMPORTANT FIX: use ?P (the modulus), not a bare P
            Lambda = modp((Y2 - Y1)) * inv(modp(X2 - X1)),
            X3 = modp(Lambda * Lambda - X1 - X2),
            Y3 = modp(Lambda * (X1 - X3) - Y1),
            {X3, Y3}
    end.

double(inf) ->
    inf;
double({X, Y}) ->
    case modp(Y) of
        % tangent is vertical
        0 ->
            inf;
        _ ->
            Lambda = modp(3 * X * X + ?A) * inv(modp(2 * Y)),
            X3 = modp(Lambda * Lambda - 2 * X),
            Y3 = modp(Lambda * (X - X3) - Y),
            {X3, Y3}
    end.

%%% ---------- toy "isogeny" map ----------
%% A simple illustrative map: φ(P) = P + K
toy_isogeny(Pt, KernelPt) ->
    add(Pt, KernelPt).

%%% ---------- demo ----------
test() ->
    %% Two known points on y^2 = x^3 - x + 1 mod 23
    P = {3, 10},
    K = {9, 7},

    io:format("P on curve? ~p~n", [on_curve(P)]),
    io:format("K on curve? ~p~n", [on_curve(K)]),

    PhiP = toy_isogeny(P, K),
    io:format("φ(P) = ~p~n", [PhiP]),

    %% Determinism check
    io:format("Deterministic? ~p~n", [PhiP =:= toy_isogeny(P, K)]).
