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
    mod_inverse/2,
    test/0,
    train_math/0,
    train_high_school_math/0,
    process_math_query/1
]).

%% Elliptic curve parameters (y^2 = x^3 + ax + b over prime field P)
-define(A, -1).
-define(B, 1).
-define(P, 23).

%% Start the AI
start() ->
    io:format("Elliptical AI initialized. Ready for computation.~n").

%% Generate a valid point on the elliptic curve

%% Fallback to a known valid point
generate_point(undefined) ->
    {0, 1};
generate_point(X) ->
    Y2 = (X * X * X + ?A * X + ?B) rem ?P,
    case [Y || Y <- lists:seq(0, ?P - 1), (Y * Y) rem ?P =:= Y2] of
        [Y | _] -> {X, Y};
        [] -> generate_alternate_point(X, 5)
    end.

%% Generate an alternate valid point within a limit

%% Fallback to a known valid point
generate_alternate_point(_, 0) ->
    {0, 1};
generate_alternate_point(X, Attempts) ->
    NextX = (X + 1) rem ?P,
    case generate_point(NextX) of
        {_, undefined} -> generate_alternate_point(NextX, Attempts - 1);
        ValidPoint -> ValidPoint
    end.

%% Encode knowledge as a point on the elliptic curve
encode_knowledge(Label, X) ->
    case generate_point(X) of
        {_, undefined} ->
            io:format("Invalid point for knowledge: ~p, using fallback.~n", [Label]),
            {Label, {0, 1}};
        Point ->
            io:format("Encoding knowledge: ~p as Point: ~p~n", [Label, Point]),
            {Label, Point}
    end.

%% Train AI with general knowledge
train(KnowledgeList) ->
    Encoded = lists:map(fun({Label, X}) -> encode_knowledge(Label, X) end, KnowledgeList),
    io:format("Knowledge encoded: ~p~n", [Encoded]),
    Encoded.

%% Modular inverse using Extended Euclidean Algorithm
mod_inverse(A, P) -> mod_inverse(A, P, P, 0, 1).
mod_inverse(0, _, _, X, _) ->
    X;
mod_inverse(A, B, P, X0, X1) ->
    Q = B div A,
    mod_inverse(B rem A, A, P, X1 - Q * X0, X0).
%% Elliptic curve point addition
add_points({X1, Y1}, {X2, Y2}) when X1 =/= X2 ->
    Lambda = ((Y2 - Y1) * mod_inverse(X2 - X1, ?P)) rem ?P,
    X3 = (Lambda * Lambda - X1 - X2) rem ?P,
    Y3 = (Lambda * (X1 - X3) - Y1) rem ?P,
    {X3, Y3};
add_points({X, Y}, {X, Y}) ->
    Lambda = ((3 * X * X + ?A) * mod_inverse(2 * Y, ?P)) rem ?P,
    X3 = (Lambda * Lambda - 2 * X) rem ?P,
    Y3 = (Lambda * (X - X3) - Y) rem ?P,
    {X3, Y3}.
%% Scalar multiplication on elliptic curve
scalar_multiply(_, {0, 0}) -> {0, 0};
scalar_multiply(1, P) -> P;
scalar_multiply(N, P) when N > 1 -> add_points(P, scalar_multiply(N - 1, P)).
%% AI Thinking Process
think(Knowledge) ->
    case Knowledge of
        [{_, {X, Y}} | _] ->
            ThoughtProcess = scalar_multiply(3, {X, Y}),
            io:format("AI Thought Process result: ~p~n", [ThoughtProcess]),
            ThoughtProcess;
        _ ->
            io:format("No valid base knowledge to think with.~n"),
            undefined
    end.

%% Train AI on basic math problems
train_math() ->
    MathData = [
        {"Addition", 10 + 10},
        {"Subtraction", 15 - 5},
        {"Multiplication", 6 * 7},
        {"Division", 100 div 5}
    ],
    train(MathData).

%% Process a basic math query
process_math_query(Query) ->
    case re:run(Query, "(\\d+)\\s*([+\-*/])\\s*(\\d+)", [{capture, all_but_first, list}]) of
        {match, [A, Op, B]} ->
            AInt = list_to_integer(A),
            BInt = list_to_integer(B),
            Result =
                case Op of
                    "+" ->
                        AInt + BInt;
                    "-" ->
                        AInt - BInt;
                    "*" ->
                        AInt * BInt;
                    "/" ->
                        if
                            BInt =/= 0 -> AInt div BInt;
                            true -> error
                        end
                end,
            io:format("Query: ~p = ~p~n", [Query, Result]),
            encode_knowledge(Query, Result);
        _ ->
            io:format("Invalid query format: ~p~n", [Query]),
            {Query, undefined}
    end.

%% Train AI on high school math problems
train_high_school_math() ->
    HighSchoolMathData = [
        {"Quadratic Formula", 25},
        {"Pythagorean Theorem", 13},
        {"Logarithms", 8},
        {"Trigonometric Identities", 16},
        {"Limits & Derivatives", 10},
        {"Integration", 18}
    ],
    train(HighSchoolMathData).

%% Example execution
test() ->
    start(),
    Knowledge = train([{"Logic", 5}, {"Security", 9}]),
    think(Knowledge),
    train_math(),
    train_high_school_math(),
    process_math_query("10 + 10").
