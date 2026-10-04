%%--------------------------------------------------------------------
%% ecai_relation.erl
%%
%% Deterministic typed relations for ECAI.
%%
%% A relation identity is the canonical semantic triple:
%%     {Subject, Predicate, Object}
%%
%% Metadata and proof are deliberately excluded from the identity so the same
%% fact receives the same key regardless of where/how it was discovered.
%% New ECAI objects use the domain-separated ecai:hash_to_curve_point/2 path;
%% the legacy one-arity point mapping is never used here.
%%--------------------------------------------------------------------
-module(ecai_relation).

-export([
    new/3,
    new/4,
    subject/1,
    predicate/1,
    object/1,
    key/1,
    encode/1,
    encode_entity/1,
    canonical/1,
    entity_equal/2,
    point/1,
    entity_point/1,
    predicate_point/1,
    with_proof/2,
    proof/1,
    from_analysis/2,
    from_code_graph/1,
    dedupe/1
]).

-export_type([
    relation/0,
    relation_key/0
]).

-define(SCHEMA, 1).
-define(RELATION_DOMAIN, <<"ECAI-RELATION-V1">>).
-define(ENTITY_DOMAIN, <<"ECAI-ENTITY-V1">>).
-define(PREDICATE_DOMAIN, <<"ECAI-PREDICATE-V1">>).

-type relation_key() :: binary().
-type relation() :: #{
    schema := pos_integer(),
    subject := term(),
    predicate := term(),
    object := term(),
    key := relation_key(),
    meta => map(),
    proof => map()
}.

-spec new(term(), term(), term()) -> {ok, relation()} | {error, term()}.
new(Subject, Predicate, Object) ->
    new(Subject, Predicate, Object, #{}).

-spec new(term(), term(), term(), map()) -> {ok, relation()} | {error, term()}.
new(Subject, Predicate, Object, Meta) when is_map(Meta) ->
    case encode_triple(Subject, Predicate, Object) of
        {ok, Encoded} ->
            Key = crypto:hash(sha256, Encoded),
            {ok, #{
                schema => ?SCHEMA,
                subject => Subject,
                predicate => Predicate,
                object => Object,
                key => Key,
                meta => Meta
            }};
        {error, _} = Error ->
            Error
    end;
new(_Subject, _Predicate, _Object, Meta) ->
    {error, {invalid_meta, Meta}}.

-spec subject(relation()) -> term().
subject(Relation) -> maps:get(subject, Relation).

-spec predicate(relation()) -> term().
predicate(Relation) -> maps:get(predicate, Relation).

-spec object(relation()) -> term().
object(Relation) -> maps:get(object, Relation).

-spec key(relation()) -> relation_key().
key(#{key := Key}) when is_binary(Key) ->
    Key;
key(Relation) ->
    case encode(Relation) of
        {ok, Encoded} -> crypto:hash(sha256, Encoded);
        {error, Reason} -> error(Reason)
    end.

-spec encode(relation()) -> {ok, binary()} | {error, term()}.
encode(Relation) when is_map(Relation) ->
    case
        {maps:find(subject, Relation), maps:find(predicate, Relation), maps:find(object, Relation)}
    of
        {{ok, Subject}, {ok, Predicate}, {ok, Object}} ->
            encode_triple(Subject, Predicate, Object);
        _ ->
            {error, invalid_relation}
    end;
encode(Other) ->
    {error, {invalid_relation, Other}}.

-spec encode_entity(term()) -> {ok, binary()} | {error, term()}.
encode_entity(Entity) ->
    case canonical(Entity) of
        {ok, Canonical} ->
            {ok, term_to_binary(Canonical, [deterministic])};
        {error, _} = Error ->
            Error
    end.

-spec canonical(term()) -> {ok, term()} | {error, term()}.
canonical(Value) when is_atom(Value) ->
    {ok, {atom, atom_to_binary(Value, utf8)}};
canonical(Value) when is_binary(Value) ->
    {ok, {binary, Value}};
canonical(Value) when is_integer(Value) ->
    {ok, {integer, integer_to_binary(Value)}};
canonical(Value) when is_float(Value) ->
    {ok, {float, float_to_binary(Value, [short])}};
canonical([]) ->
    {ok, {list, []}};
canonical(Value) when is_list(Value) ->
    canonical_list(Value, []);
canonical(Value) when is_tuple(Value) ->
    case canonical_list(tuple_to_list(Value), []) of
        {ok, {list, Items}} -> {ok, {tuple, Items}};
        {error, _} = Error -> Error
    end;
canonical(Value) when is_map(Value) ->
    canonical_map(maps:to_list(Value), []);
canonical(Value) ->
    {error, {unsupported_canonical_term, Value}}.

-spec entity_equal(term(), term()) -> boolean().
entity_equal(A, B) ->
    case {encode_entity(A), encode_entity(B)} of
        {{ok, ABin}, {ok, BBin}} -> ABin =:= BBin;
        _ -> false
    end.

-spec point(relation()) -> ecai:curve_point() | {error, term()}.
point(Relation) ->
    case encode(Relation) of
        {ok, Encoded} -> safe_hash_to_curve_point(?RELATION_DOMAIN, Encoded);
        {error, _} = Error -> Error
    end.

-spec entity_point(term()) -> ecai:curve_point() | {error, term()}.
entity_point(Entity) ->
    case encode_entity(Entity) of
        {ok, Encoded} -> safe_hash_to_curve_point(?ENTITY_DOMAIN, Encoded);
        {error, _} = Error -> Error
    end.

-spec predicate_point(term()) -> ecai:curve_point() | {error, term()}.
predicate_point(Predicate) ->
    case encode_entity(Predicate) of
        {ok, Encoded} -> safe_hash_to_curve_point(?PREDICATE_DOMAIN, Encoded);
        {error, _} = Error -> Error
    end.

-spec with_proof(relation(), map()) -> relation().
with_proof(Relation, Proof) when is_map(Relation), is_map(Proof) ->
    Relation#{proof => Proof}.

-spec proof(relation()) -> map() | undefined.
proof(Relation) ->
    maps:get(proof, Relation, undefined).

%% @doc Convert one ecai_code_analyser analysis map to typed relations.
%%
%% The extraction is deterministic and does not invoke an LLM.
-spec from_analysis(atom(), map()) -> [relation()].
from_analysis(App, Analysis) when is_atom(App), is_map(Analysis) ->
    case maps:find(module, Analysis) of
        error ->
            [];
        {ok, Module} ->
            Meta = analysis_meta(App, Analysis),
            Base = [
                must_new(Module, belongs_to_application, App, Meta)
            ],
            Exports = export_relations(Module, maps:get(exports, Analysis, []), Meta),
            Calls = remote_call_relations(Module, maps:get(remote_calls, Analysis, []), Meta),
            Behaviours = [
                must_new(Module, implements, Behaviour, Meta)
             || Behaviour <- maps:get(behaviours, Analysis, []),
                is_atom(Behaviour)
            ],
            Includes = [
                must_new(Module, includes, Include, Meta)
             || Include <- maps:get(includes, Analysis, []),
                stable_term(Include)
            ],
            dedupe(Base ++ Exports ++ Calls ++ Behaviours ++ Includes)
    end;
from_analysis(_App, _Analysis) ->
    [].

%% @doc Convert an ecai_code_graph graph into relations.
%%
%% This consumes Graph.modules analyses when available. It also consumes the
%% graph's outgoing module edges so graphs built from reduced analysis maps still
%% produce module-level call facts.
-spec from_code_graph(map()) -> [relation()].
from_code_graph(Graph) when is_map(Graph) ->
    Modules = maps:get(modules, Graph, #{}),
    AnalysisRelations = maps:fold(
        fun(_Module, Analysis, Acc) ->
            App = maps:get(application, Analysis, ecai),
            from_analysis(App, Analysis) ++ Acc
        end,
        [],
        Modules
    ),
    Outgoing = maps:get(outgoing, Graph, #{}),
    GraphRelations = maps:fold(
        fun(From, Targets, Acc0) ->
            lists:foldl(
                fun(To, Acc) ->
                    [must_new(From, calls_module, To, #{source => code_graph}) | Acc]
                end,
                Acc0,
                Targets
            )
        end,
        [],
        Outgoing
    ),
    dedupe(AnalysisRelations ++ GraphRelations);
from_code_graph(_Other) ->
    [].

-spec dedupe([relation()]) -> [relation()].
dedupe(Relations) ->
    Map = lists:foldl(
        fun(Relation, Acc) ->
            Acc#{key(Relation) => Relation}
        end,
        #{},
        [R || R <- Relations, is_map(R)]
    ),
    [R || {_K, R} <- lists:sort(maps:to_list(Map))].

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

encode_triple(Subject, Predicate, Object) ->
    case {canonical(Subject), canonical(Predicate), canonical(Object)} of
        {{ok, CS}, {ok, CP}, {ok, CO}} ->
            {ok, term_to_binary({ecai_relation, ?SCHEMA, CS, CP, CO}, [deterministic])};
        {{error, Reason}, _, _} ->
            {error, {invalid_subject, Reason}};
        {_, {error, Reason}, _} ->
            {error, {invalid_predicate, Reason}};
        {_, _, {error, Reason}} ->
            {error, {invalid_object, Reason}}
    end.

canonical_list([], Acc) ->
    {ok, {list, lists:reverse(Acc)}};
canonical_list([Head | Tail], Acc) ->
    case canonical(Head) of
        {ok, CHead} -> canonical_list(Tail, [CHead | Acc]);
        {error, _} = Error -> Error
    end;
canonical_list(Improper, _Acc) ->
    {error, {improper_list, Improper}}.

canonical_map([], Acc) ->
    Sorted = lists:sort(
        fun({K1, _}, {K2, _}) ->
            term_to_binary(K1, [deterministic]) =<
                term_to_binary(K2, [deterministic])
        end,
        Acc
    ),
    {ok, {map, Sorted}};
canonical_map([{Key, Value} | Rest], Acc) ->
    case {canonical(Key), canonical(Value)} of
        {{ok, CKey}, {ok, CValue}} ->
            canonical_map(Rest, [{CKey, CValue} | Acc]);
        {{error, Reason}, _} ->
            {error, {invalid_map_key, Reason}};
        {_, {error, Reason}} ->
            {error, {invalid_map_value, Reason}}
    end.

analysis_meta(App, Analysis) ->
    maps:filter(
        fun(_K, V) -> V =/= undefined end,
        #{
            source => code_analysis,
            application => App,
            source_sha256 => maps:get(source_sha256, Analysis, undefined),
            analysis_sha256 => maps:get(analysis_sha256, Analysis, undefined)
        }
    ).

export_relations(Module, Exports, Meta) ->
    lists:append([
        case export_mfa(Module, Export) of
            {ok, MFA} ->
                [
                    must_new(Module, exports, MFA, Meta),
                    must_new(MFA, belongs_to_module, Module, Meta)
                ];
            error ->
                []
        end
     || Export <- Exports
    ]).

export_mfa(Module, {Function, Arity}) when
    is_atom(Function), is_integer(Arity), Arity >= 0
->
    {ok, {mfa, Module, Function, Arity}};
export_mfa(Module, #{function := Function, arity := Arity}) when
    is_atom(Function), is_integer(Arity), Arity >= 0
->
    {ok, {mfa, Module, Function, Arity}};
export_mfa(_Module, _Other) ->
    error.

remote_call_relations(Module, Calls, Meta) ->
    lists:append([
        case remote_call_mfa(Call) of
            {ok, TargetModule, MFA} ->
                [
                    must_new(Module, calls, MFA, Meta),
                    must_new(MFA, belongs_to_module, TargetModule, Meta)
                ];
            error ->
                []
        end
     || Call <- Calls
    ]).

remote_call_mfa(#{module := TargetModule, function := Function, arity := Arity}) when
    is_atom(TargetModule), is_atom(Function), is_integer(Arity), Arity >= 0
->
    {ok, TargetModule, {mfa, TargetModule, Function, Arity}};
remote_call_mfa({TargetModule, Function, Arity}) when
    is_atom(TargetModule), is_atom(Function), is_integer(Arity), Arity >= 0
->
    {ok, TargetModule, {mfa, TargetModule, Function, Arity}};
remote_call_mfa(_Other) ->
    error.

must_new(Subject, Predicate, Object, Meta) ->
    case new(Subject, Predicate, Object, Meta) of
        {ok, Relation} -> Relation;
        {error, Reason} -> error({invalid_internal_relation, Reason})
    end.

stable_term(Term) ->
    case canonical(Term) of
        {ok, _} -> true;
        {error, _} -> false
    end.

safe_hash_to_curve_point(Domain, Encoded) ->
    try ecai:hash_to_curve_point(Domain, Encoded) of
        Result -> Result
    catch
        error:undef -> {error, hash_to_curve_point_2_unavailable};
        error:nif_library_not_loaded -> {error, nif_library_not_loaded};
        Class:Reason -> {error, {Class, Reason}}
    end.
