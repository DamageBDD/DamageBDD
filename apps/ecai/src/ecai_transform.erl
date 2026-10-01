%%--------------------------------------------------------------------
%% ecai_transform.erl
%%
%% Experimental geometric measurements over ECAI relation endpoints.
%%
%% IMPORTANT:
%%   affine_delta/1 is a measurable field-coordinate displacement, not a proven
%%   semantic invariant and not elliptic-curve group subtraction.
%%
%% This module exists so relation classes can be benchmarked empirically before
%% any claim is made that semantic relations survive the hash-to-curve mapping.
%%--------------------------------------------------------------------
-module(ecai_transform).

-export([
    feature/1,
    affine_delta/1,
    compare/2,
    delta_distance/2,
    circular_distance/2
]).

%% Macros are token substitutions; protect the whole value in rem expressions.
-define(P, ((1 bsl 255) - 19)).

-type delta() :: #{
    dx := non_neg_integer(),
    dy := non_neg_integer()
}.

-export_type([delta/0]).

-spec feature(ecai_relation:relation()) -> {ok, map()} | {error, term()}.
feature(Relation) ->
    case affine_delta(Relation) of
        {ok, Delta} ->
            {ok, #{
                relation_key => ecai_relation:key(Relation),
                predicate => ecai_relation:predicate(Relation),
                delta => Delta
            }};
        {error, _} = Error ->
            Error
    end.

-spec affine_delta(ecai_relation:relation()) -> {ok, delta()} | {error, term()}.
affine_delta(Relation) ->
    Subject = ecai_relation:subject(Relation),
    Object = ecai_relation:object(Relation),
    case {ecai_relation:entity_point(Subject), ecai_relation:entity_point(Object)} of
        {#{x := SX, y := SY}, #{x := OX, y := OY}} ->
            {ok, #{
                dx => mod_p(OX - SX),
                dy => mod_p(OY - SY)
            }};
        {{error, Reason}, _} ->
            {error, {subject_point_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {object_point_failed, Reason}};
        {SubjectPoint, ObjectPoint} ->
            {error, {unexpected_points, SubjectPoint, ObjectPoint}}
    end.

-spec compare(ecai_relation:relation(), ecai_relation:relation()) ->
    {ok, map()} | {error, term()}.
compare(A, B) ->
    case {affine_delta(A), affine_delta(B)} of
        {{ok, DA}, {ok, DB}} ->
            {ok, #{
                same_predicate =>
                    ecai_relation:entity_equal(
                        ecai_relation:predicate(A),
                        ecai_relation:predicate(B)
                    ),
                distance => delta_distance(DA, DB),
                left => DA,
                right => DB
            }};
        {{error, Reason}, _} ->
            {error, {left_transform_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {right_transform_failed, Reason}}
    end.

%% @doc L1 distance on the p x p torus of affine field coordinates.
%%
%% This is deliberately simple and deterministic. Later benchmarks can add
%% alternative metrics without changing relation identity.
-spec delta_distance(delta(), delta()) -> non_neg_integer().
delta_distance(#{dx := AX, dy := AY}, #{dx := BX, dy := BY}) ->
    circular_distance(AX, BX) + circular_distance(AY, BY).

-spec circular_distance(integer(), integer()) -> non_neg_integer().
circular_distance(A0, B0) ->
    A = mod_p(A0),
    B = mod_p(B0),
    D = abs(A - B),
    erlang:min(D, ?P - D).

mod_p(N) ->
    ((N rem ?P) + ?P) rem ?P.
