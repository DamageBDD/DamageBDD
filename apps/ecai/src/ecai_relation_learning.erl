%%--------------------------------------------------------------------
%% ecai_relation_learning.erl
%%
%% Integrates deterministic ECAI relations with the persistent code learner.
%%
%% Responsibilities:
%%   * materialise relation sets from learned application graphs
%%   * persist relation sets and relation keys in ecai_learning_store
%%   * build a cross-application relation set for damage/ecai/erm
%%   * run an indexed zero-LLM holdout benchmark against analyser ground truth
%%
%% The benchmark currently targets the independently observable relation:
%%
%%     Module --uses--> TargetModule
%%
%% Ground truth comes directly from ecai_code_analyser remote_calls. Recovery
%% must instead compose:
%%
%%     Module --calls--> MFA --belongs_to_module--> TargetModule
%%
%% This avoids using ecai_compose:closure/2 over the whole corpus and keeps the
%% benchmark linear-ish in the number of call relations rather than Cartesian.
%%--------------------------------------------------------------------
-module(ecai_relation_learning).

-export([
    refresh/0,
    refresh/1,
    refresh_all/0,
    relations/0,
    relations/1,
    relation_keys/0,
    relation_keys/1,
    benchmark/0,
    benchmark/1,
    benchmark/2,
    benchmark_relations/3,
    derive_uses/1,
    ground_truth_uses/1,
    status/0
]).

-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_HOLDOUT, 1000).

-spec refresh() -> {ok, map()} | {error, term()}.
refresh() ->
    refresh_all().

-spec refresh(atom()) -> {ok, map()} | {error, term()}.
refresh(App) when is_atom(App) ->
    case ecai_learning_store:get_graph(App) of
        {ok, Graph} ->
            Relations = ecai_relation:from_code_graph(Graph),
            case ecai_learning_store:put_relations(App, Relations) of
                ok ->
                    {ok, #{
                        scope => App,
                        relation_count => length(Relations),
                        relation_key_count => length(ecai_relation:dedupe(Relations))
                    }};
                {error, _} = Error ->
                    Error;
                Other ->
                    {error, {relation_store_failed, App, Other}}
            end;
        not_found ->
            {error, {graph_not_found, App}};
        {error, _} = Error ->
            Error
    end.

-spec refresh_all() -> {ok, map()} | {error, term()}.
refresh_all() ->
    Results = [{App, refresh(App)} || App <- ?APPS],
    case [Error || {_App, {error, _} = Error} <- Results] of
        [] ->
            AppRelations = lists:append([
                case ecai_learning_store:get_relations(App) of
                    {ok, Relations} -> Relations;
                    not_found -> []
                end
             || App <- ?APPS
            ]),
            All = ecai_relation:dedupe(AppRelations),
            case ecai_learning_store:put_relations(all, All) of
                ok ->
                    {ok, #{
                        applications => maps:from_list([
                            {App, Summary}
                         || {App, {ok, Summary}} <- Results
                        ]),
                        scope => all,
                        relation_count => length(All),
                        relation_key_count => length(All)
                    }};
                {error, _} = Error ->
                    Error;
                Other ->
                    {error, {relation_store_failed, all, Other}}
            end;
        Errors ->
            {error, {relation_refresh_failed, Errors}}
    end.

-spec relations() -> {ok, [ecai_relation:relation()]} | not_found.
relations() ->
    relations(all).

-spec relations(atom()) -> {ok, [ecai_relation:relation()]} | not_found.
relations(Scope) ->
    ecai_learning_store:get_relations(Scope).

-spec relation_keys() -> {ok, [binary()]} | not_found.
relation_keys() ->
    relation_keys(all).

-spec relation_keys(atom()) -> {ok, [binary()]} | not_found.
relation_keys(Scope) ->
    ecai_learning_store:relation_keys(Scope).

-spec benchmark() -> {ok, map()} | {error, term()}.
benchmark() ->
    benchmark(all, ?DEFAULT_HOLDOUT).

-spec benchmark(atom()) -> {ok, map()} | {error, term()}.
benchmark(Scope) ->
    benchmark(Scope, ?DEFAULT_HOLDOUT).

-spec benchmark(atom(), pos_integer()) -> {ok, map()} | {error, term()}.
benchmark(Scope, Limit) when is_atom(Scope), is_integer(Limit), Limit > 0 ->
    case ecai_learning_store:get_relations(Scope) of
        not_found ->
            {error, {relations_not_found, Scope}};
        {ok, Relations} ->
            case ground_truth_for_scope(Scope) of
                {ok, Truth} ->
                    Result0 = benchmark_relations(Relations, Truth, Limit),
                    Result = Result0#{
                        scope => Scope,
                        benchmarked_at => now_iso8601()
                    },
                    case ecai_learning_store:put_relation_benchmark(Scope, Result) of
                        ok -> {ok, Result};
                        {error, _} = Error -> Error;
                        Other -> {error, {benchmark_store_failed, Scope, Other}}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Offline/pure benchmark entry point.
%%
%% Truth must be independently produced structural `uses` facts. The function
%% derives uses facts from relation composition and evaluates exact canonical
%% relation-key matches.
-spec benchmark_relations(
    [ecai_relation:relation()],
    [ecai_relation:relation()],
    pos_integer()
) -> map().
benchmark_relations(Relations, Truth0, Limit) when
    is_list(Relations), is_list(Truth0), is_integer(Limit), Limit > 0
->
    Truth = sort_relations(ecai_relation:dedupe(Truth0)),
    Sample = lists:sublist(Truth, erlang:min(Limit, length(Truth))),
    Derived = sort_relations(derive_uses(Relations)),
    TruthKeys = key_set(Truth),
    SampleKeys = key_set(Sample),
    DerivedKeys = key_set(Derived),
    SampleRecovered = intersection_count(SampleKeys, DerivedKeys),
    FullRecovered = intersection_count(TruthKeys, DerivedKeys),
    FalsePositives = maps:size(DerivedKeys) - FullRecovered,
    #{
        benchmark => structural_uses_holdout,
        ground_truth_source => remote_calls,
        derivation_rule => {calls, belongs_to_module, uses},
        requested_holdout => Limit,
        sampled => maps:size(SampleKeys),
        recovered => SampleRecovered,
        sample_recall => ratio(SampleRecovered, maps:size(SampleKeys)),
        full_truth_count => maps:size(TruthKeys),
        full_recovered => FullRecovered,
        full_recall => ratio(FullRecovered, maps:size(TruthKeys)),
        derived_count => maps:size(DerivedKeys),
        false_positives => FalsePositives,
        precision => ratio(FullRecovered, maps:size(DerivedKeys)),
        llm_calls => 0,
        deterministic => true,
        recovered_keys => key_hex_list(intersection_keys(SampleKeys, DerivedKeys)),
        missing_keys => key_hex_list(difference_keys(SampleKeys, DerivedKeys))
    }.

%% @doc Recover Module --uses--> TargetModule by an indexed join over the two
%% structural premise types. This uses ecai_compose:compose/2 to keep proof
%% construction in one place, but never evaluates unrelated relation pairs.
-spec derive_uses([ecai_relation:relation()]) -> [ecai_relation:relation()].
derive_uses(Relations) when is_list(Relations) ->
    Belongs = [
        R
     || R <- Relations,
        predicate_is(R, belongs_to_module)
    ],
    Index = lists:foldl(
        fun(Relation, Acc) ->
            Id = entity_id(ecai_relation:subject(Relation)),
            maps:update_with(Id, fun(L) -> [Relation | L] end, [Relation], Acc)
        end,
        #{},
        Belongs
    ),
    Calls = [R || R <- Relations, predicate_is(R, calls)],
    Derived = lists:append([
        begin
            MiddleId = entity_id(ecai_relation:object(Call)),
            Rights = maps:get(MiddleId, Index, []),
            [
                Use
             || Right <- Rights,
                {ok, Use} <- [ecai_compose:compose(Call, Right)]
            ]
        end
     || Call <- Calls
    ]),
    ecai_relation:dedupe(Derived).

%% @doc Independently build direct Module --uses--> TargetModule truth from an
%% ecai_code_graph graph's analyser output.
-spec ground_truth_uses(map()) -> [ecai_relation:relation()].
ground_truth_uses(Graph) when is_map(Graph) ->
    Modules = maps:get(modules, Graph, #{}),
    Truth = maps:fold(
        fun(Module, Analysis, Acc0) ->
            Calls = maps:get(remote_calls, Analysis, []),
            lists:foldl(
                fun(Call, Acc) ->
                    case maps:get(module, Call, undefined) of
                        Target when is_atom(Target) ->
                            case
                                ecai_relation:new(
                                    Module,
                                    uses,
                                    Target,
                                    #{source => analyser_ground_truth}
                                )
                            of
                                {ok, Relation} -> [Relation | Acc];
                                {error, _} -> Acc
                            end;
                        _ ->
                            Acc
                    end
                end,
                Acc0,
                Calls
            )
        end,
        [],
        Modules
    ),
    ecai_relation:dedupe(Truth);
ground_truth_uses(_Other) ->
    [].

-spec status() -> map().
status() ->
    #{
        scopes => maps:from_list([
            {Scope, scope_status(Scope)}
         || Scope <- ?APPS ++ [all]
        ]),
        latest_benchmark => ecai_learning_store:get_relation_benchmark(all)
    }.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

ground_truth_for_scope(all) ->
    Results = [
        case ecai_learning_store:get_graph(App) of
            {ok, Graph} -> {ok, ground_truth_uses(Graph)};
            not_found -> {error, {graph_not_found, App}}
        end
     || App <- ?APPS
    ],
    case [Error || {error, _} = Error <- Results] of
        [] ->
            {ok, ecai_relation:dedupe(lists:append([Relations || {ok, Relations} <- Results]))};
        Errors ->
            {error, {ground_truth_unavailable, Errors}}
    end;
ground_truth_for_scope(App) ->
    case ecai_learning_store:get_graph(App) of
        {ok, Graph} -> {ok, ground_truth_uses(Graph)};
        not_found -> {error, {graph_not_found, App}}
    end.

scope_status(Scope) ->
    Relations =
        case ecai_learning_store:get_relations(Scope) of
            {ok, Rs} -> length(Rs);
            not_found -> 0
        end,
    Keys =
        case ecai_learning_store:relation_keys(Scope) of
            {ok, Ks} -> length(Ks);
            not_found -> 0
        end,
    #{relation_count => Relations, relation_key_count => Keys}.

predicate_is(Relation, Predicate) ->
    ecai_relation:entity_equal(ecai_relation:predicate(Relation), Predicate).

entity_id(Entity) ->
    case ecai_relation:encode_entity(Entity) of
        {ok, Encoded} -> crypto:hash(sha256, Encoded);
        {error, Reason} -> error({cannot_index_entity, Entity, Reason})
    end.

sort_relations(Relations) ->
    lists:sort(
        fun(A, B) -> ecai_relation:key(A) =< ecai_relation:key(B) end,
        Relations
    ).

key_set(Relations) ->
    maps:from_list([{ecai_relation:key(R), true} || R <- Relations]).

intersection_count(A, B) ->
    length(intersection_keys(A, B)).

intersection_keys(A, B) ->
    lists:sort([K || K <- maps:keys(A), maps:is_key(K, B)]).

difference_keys(A, B) ->
    lists:sort([K || K <- maps:keys(A), not maps:is_key(K, B)]).

key_hex_list(Keys) ->
    [binary:encode_hex(Key) || Key <- Keys].

ratio(_Numerator, 0) -> 1.0;
ratio(Numerator, Denominator) -> Numerator / Denominator.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).
