-module(ecai).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-export([
    start/0,
    think/1,
    train/1,
    generate_point/1,
    encode_knowledge/2,
    add_points/2,
    scalar_multiply/2,
    test/0
]).

%% Define the elliptic curve parameters (y^2 = x^3 + ax + b)

%% Curve coefficient a
-define(A, -1).
%% Curve coefficient b
-define(B, 1).
%% Prime field (modulus)
-define(P, 23).

%% Start the AI
start() ->
    io:format("Elliptical AI initialized. Ready for computation.~n").

%% Generate a random point on the elliptic curve
generate_point(X) ->
    Y2 = (X * X * X + ?A * X + ?B) rem ?P,
    % Find Y that satisfies Y^2 = f(x) mod P
    Y = lists:nth(1, [Y || Y <- lists:seq(0, ?P - 1), (Y * Y) rem ?P =:= Y2]),
    {X, Y}.

%% Encode knowledge as a point on the elliptic curve
encode_knowledge(Label, X) ->
    Point = generate_point(X),
    io:format("Encoding knowledge: ~p as Point: ~p~n", [Label, Point]),
    {Label, Point}.

%% Elliptic curve point addition
add_points({X1, Y1}, {X2, Y2}) when X1 =/= X2 ->
    Lambda = ((Y2 - Y1) * mod_inverse(X2 - X1, ?P)) rem ?P,
    X3 = (Lambda * Lambda - X1 - X2) rem ?P,
    Y3 = (Lambda * (X1 - X3) - Y1) rem ?P,
    {X3, Y3};
%% Doubling case
add_points({X, Y}, {X, Y}) ->
    Lambda = ((3 * X * X + ?A) * mod_inverse(2 * Y, ?P)) rem ?P,
    X3 = (Lambda * Lambda - 2 * X) rem ?P,
    Y3 = (Lambda * (X - X3) - Y) rem ?P,
    {X3, Y3}.

%% Scalar multiplication on elliptic curve
scalar_multiply(_, {0, 0}) ->
    {0, 0};
scalar_multiply(1, P) ->
    P;
scalar_multiply(N, P) when N > 1 ->
    add_points(P, scalar_multiply(N - 1, P)).

%% Modular inverse (Extended Euclidean Algorithm)
mod_inverse(A, P) -> mod_inverse(A, P, P, 0, 1).
mod_inverse(0, _, _, X, _) ->
    X;
mod_inverse(A, B, P, X0, X1) ->
    Q = B div A,
    mod_inverse(B rem A, A, P, X1 - Q * X0, X0).

%% Train AI with knowledge
train(KnowledgeList) ->
    Encoded = lists:map(fun({Label, X}) -> encode_knowledge(Label, X) end, KnowledgeList),
    io:format("Knowledge encoded: ~p~n", [Encoded]),
    Encoded.

%% AI Thinking Process
think(Knowledge) ->
    {_, BasePoint} = hd(Knowledge),
    ThoughtProcess = scalar_multiply(3, BasePoint),
    io:format("AI Thought Process result: ~p~n", [ThoughtProcess]),
    ThoughtProcess.

test() ->
    example().
%% Example Execution
example() ->
    start(),
    Knowledge = train([{"Logic", 5}, {"Security", 9}]),
    think(Knowledge).
