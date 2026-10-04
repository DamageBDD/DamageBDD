%%--------------------------------------------------------------------
%% ecai_compose.erl
%%
%% Deterministic relation composition and proof production.
%%
%% This is intentionally a small structural rule engine. It provides a baseline
%% that can derive hidden relations without an LLM. It must not be confused with
%% the still-unproven hypothesis that semantic composition can be performed by
%% elliptic-curve algebra itself.
%%--------------------------------------------------------------------
-module(ecai_compose).

-export([
    rules/0,
    compose/2,
    closure/1,
    closure/2,
    derive/3,
    derive/4
]).

-type rule() :: {term(), term(), term()}.
-export_type([rule/0]).

-define(DEFAULT_DEPTH, 4).

-spec rules() -> [rule()].
rules() ->
    [
        %% module -> MFA -> module
        {calls, belongs_to_module, uses},

        %% module dependency through another module
        {calls_module, calls_module, depends_on},
        {calls_module, depends_on, depends_on},
        {depends_on, calls_module, depends_on},
        {depends_on, depends_on, depends_on},

        %% module/API dependency to application dependency
        {uses, belongs_to_application, depends_on_application},
        {calls_module, belongs_to_application, depends_on_application},
        {depends_on, belongs_to_application, depends_on_application}
    ].

-spec compose(ecai_relation:relation(), ecai_relation:relation()) ->
    {ok, ecai_relation:relation()} | no_rule | {error, term()}.
compose(Left, Right) when is_map(Left), is_map(Right) ->
    MiddleLeft = ecai_relation:object(Left),
    MiddleRight = ecai_relation:subject(Right),
    case ecai_relation:entity_equal(MiddleLeft, MiddleRight) of
        false ->
            {error, disconnected};
        true ->
            P1 = ecai_relation:predicate(Left),
            P2 = ecai_relation:predicate(Right),
            case result_predicate(P1, P2) of
                not_found ->
                    no_rule;
                {ok, ResultPredicate} ->
                    Subject = ecai_relation:subject(Left),
                    Object = ecai_relation:object(Right),
                    case
                        ecai_relation:new(
                            Subject,
                            ResultPredicate,
                            Object,
                            #{source => deterministic_composition}
                        )
                    of
                        {ok, Relation0} ->
                            Proof = #{
                                kind => deterministic_relation_composition,
                                rule => {P1, P2, ResultPredicate},
                                premises => [
                                    ecai_relation:key(Left),
                                    ecai_relation:key(Right)
                                ],
                                middle => MiddleLeft,
                                llm_used => false
                            },
                            {ok, ecai_relation:with_proof(Relation0, Proof)};
                        {error, _} = Error ->
                            Error
                    end
            end
    end;
compose(_Left, _Right) ->
    {error, invalid_relation}.

-spec closure([ecai_relation:relation()]) -> [ecai_relation:relation()].
closure(Relations) ->
    closure(Relations, ?DEFAULT_DEPTH).

-spec closure([ecai_relation:relation()], non_neg_integer()) ->
    [ecai_relation:relation()].
closure(Relations, MaxDepth) when
    is_list(Relations), is_integer(MaxDepth), MaxDepth >= 0
->
    Base = ecai_relation:dedupe(Relations),
    closure_round(Base, Base, 0, MaxDepth).

-spec derive([ecai_relation:relation()], term(), term()) ->
    [ecai_relation:relation()].
derive(Relations, Subject, Predicate) ->
    derive(Relations, Subject, Predicate, ?DEFAULT_DEPTH).

-spec derive([ecai_relation:relation()], term(), term(), non_neg_integer()) ->
    [ecai_relation:relation()].
derive(Relations, Subject, Predicate, MaxDepth) ->
    [
        Relation
     || Relation <- closure(Relations, MaxDepth),
        ecai_relation:entity_equal(ecai_relation:subject(Relation), Subject),
        ecai_relation:entity_equal(ecai_relation:predicate(Relation), Predicate)
    ].

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

result_predicate(P1, P2) ->
    case
        [
            Result
         || {LeftPredicate, RightPredicate, Result} <- rules(),
            ecai_relation:entity_equal(P1, LeftPredicate),
            ecai_relation:entity_equal(P2, RightPredicate)
        ]
    of
        [Result | _] -> {ok, Result};
        [] -> not_found
    end.

closure_round(All, _Frontier, Depth, MaxDepth) when Depth >= MaxDepth ->
    All;
closure_round(All, [], _Depth, _MaxDepth) ->
    All;
closure_round(All, Frontier, Depth, MaxDepth) ->
    Existing = maps:from_list([{ecai_relation:key(R), true} || R <- All]),
    Candidates0 = compose_frontier(Frontier, All) ++ compose_frontier(All, Frontier),
    Candidates = ecai_relation:dedupe(Candidates0),
    New = [
        R
     || R <- Candidates,
        not maps:is_key(ecai_relation:key(R), Existing)
    ],
    case New of
        [] ->
            All;
        _ ->
            All1 = ecai_relation:dedupe(All ++ New),
            closure_round(All1, New, Depth + 1, MaxDepth)
    end.

compose_frontier(LeftRelations, RightRelations) ->
    lists:append([
        case compose(Left, Right) of
            {ok, Relation} -> [Relation];
            no_rule -> [];
            {error, disconnected} -> [];
            {error, _Reason} -> []
        end
     || Left <- LeftRelations,
        Right <- RightRelations
    ]).
