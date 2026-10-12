%%%-------------------------------------------------------------------
%%% Optional ECAI projection for verification analytics.
%%%
%%% The Damage analytics cache is authoritative for fast numeric reads. This
%%% adapter enriches a run with deterministic ECAI search/relation identities
%%% when the ecai application is present. Every call fails open: analytics and
%%% verification execution must remain available when ECAI is stopped or an
%%% experimental geometry module is absent.
%%%-------------------------------------------------------------------
-module(damage_analytics_ecai).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([project_run/1, availability/0]).

-define(CURVE_P, (1 bsl 255) - 19).

project_run(Run) when is_map(Run) ->
    case enabled() of
        false ->
            unavailable_projection(disabled);
        true ->
            %% This function is executed by damage_analytics_ecai_worker, a
            %% dedicated supervised process outside the analytics read model.
            %% Do not kill a public-index mutation mid-write merely to enforce a
            %% wall-clock timeout; isolation keeps dashboard/execution paths fast
            %% without risking a partially updated ECAI index.
            try
                project_run0(Run)
            catch
                Class:Reason -> unavailable_projection({Class, safe_reason(Reason)})
            end
    end;
project_run(_) ->
    unavailable_projection(invalid_run).

project_run0(Run) ->
    Relations = relation_projection(Run),
    RelationKeys = relation_keys(Relations),
    CurveFeatures = curve_features(Relations),
    Search = index_search_record(Run),
    RelationAvailable = module_available(ecai_relation),
    SearchAvailable = search_available(),
    GeometryBackend = geometry_backend(),
    GeometryAvailable = GeometryBackend =/= unavailable,
    Status =
        case {RelationAvailable, SearchAvailable, maps:get(indexed, Search, false)} of
            {false, false, _} -> unavailable;
            {true, true, true} -> active;
            {true, false, _} -> degraded;
            {false, true, true} -> degraded;
            _ -> degraded
        end,
    #{
        status => Status,
        search_indexed => maps:get(indexed, Search, false),
        search_status => maps:get(status, Search, unavailable),
        relation_count => length(Relations),
        relation_keys => RelationKeys,
        curve_feature_count => length(CurveFeatures),
        curve_features => CurveFeatures,
        geometry_fingerprint => geometry_fingerprint(CurveFeatures),
        geometry_status =>
            case GeometryAvailable of
                true -> experimental;
                false -> unavailable
            end,
        geometry_backend => GeometryBackend
    }.

unavailable_projection(Reason) ->
    #{
        status => unavailable,
        search_indexed => false,
        search_status => unavailable,
        relation_count => 0,
        relation_keys => [],
        curve_feature_count => 0,
        curve_features => [],
        geometry_fingerprint => <<>>,
        geometry_status => unavailable,
        geometry_backend => unavailable,
        reason => safe_reason(Reason)
    }.

availability() ->
    case enabled() of
        false ->
            #{enabled => false, search => false, relations => false, geometry => false};
        true ->
            #{
                enabled => true,
                search => search_available(),
                relations => module_available(ecai_relation),
                geometry => geometry_backend() =/= unavailable,
                geometry_backend => geometry_backend()
            }
    end.

enabled() ->
    application:get_env(damage, analytics_ecai_enabled, true) =/= false.

search_available() ->
    application:get_env(damage, analytics_ecai_search_enabled, true) =/= false andalso
        module_available(ecai_search) andalso module_available(ecai_search_server).

%% ===================================================================
%% Search indexing
%% ===================================================================

index_search_record(Run) ->
    case search_available() of
        false ->
            #{indexed => false, status => unavailable};
        true ->
            try
                Ctx = apply(ecai_search_server, get_ctx, []),
                DocId = doc_id(Run),
                Record = search_record(Run),
                Result =
                    case erlang:function_exported(ecai_search, upsert_record, 3) of
                        true -> apply(ecai_search, upsert_record, [Ctx, DocId, Record]);
                        false -> apply(ecai_search, add_record, [Ctx, DocId, Record])
                    end,
                case index_ok(Result) of
                    true -> #{indexed => true, status => active};
                    false -> #{indexed => false, status => degraded, error => safe_reason(Result)}
                end
            catch
                Class:Reason ->
                    ?LOG_DEBUG("analytics ECAI search projection unavailable class=~p reason=~p", [
                        Class, Reason
                    ]),
                    #{indexed => false, status => degraded, error => safe_reason(Reason)}
            end
    end.

index_ok(ok) -> true;
index_ok({ok, _}) -> true;
index_ok({error, already_exists}) -> true;
index_ok({error, {already_exists, _}}) -> true;
index_ok(_) -> false.

doc_id(Run) ->
    Report = maps:get(report_cid, Run, <<>>),
    <<"damage-analytics:", Report/binary>>.

%% Stay within fields already used by the public ECAI term vocabulary. The
%% complete structured run remains in the analytics store; the ECAI record is a
%% bounded retrieval projection, not another source of truth.
search_record(Run) ->
    Title0 = maps:get(feature_title, Run, <<>>),
    Title =
        case Title0 of
            <<>> -> maps:get(feature_cid, Run, <<>>);
            _ -> Title0
        end,
    Status = atom_text(maps:get(status, Run, unknown)),
    Text = bounded_text(
        iolist_to_binary([
            <<"DamageBDD verification ">>,
            Status,
            <<" feature ">>,
            maps:get(feature_cid, Run, <<>>),
            <<" report ">>,
            maps:get(report_cid, Run, <<>>),
            maybe_field(<<" node ">>, maps:get(node, Run, <<>>)),
            maybe_field(<<" account ">>, maps:get(account, Run, <<>>)),
            maybe_field(<<" transaction ">>, maps:get(tx_hash, Run, <<>>)),
            maybe_field(<<" failure-signature ">>, maps:get(failure_signature, Run, <<>>))
        ]),
        8192
    ),
    #{
        title => Title,
        text => Text,
        category => <<"damagebdd verification analytics">>,
        language => <<"en">>
    }.

maybe_field(_Prefix, <<>>) -> <<>>;
maybe_field(Prefix, Value) when is_binary(Value) -> <<Prefix/binary, Value/binary>>;
maybe_field(Prefix, Value) -> <<Prefix/binary, (safe_reason(Value))/binary>>.

%% ===================================================================
%% Deterministic relation projection
%% ===================================================================

relation_projection(Run) ->
    case module_available(ecai_relation) of
        false ->
            [];
        true ->
            Report = maps:get(report_cid, Run, <<>>),
            Feature = maps:get(feature_cid, Run, <<>>),
            Account = maps:get(account, Run, <<>>),
            Node = maps:get(node, Run, <<>>),
            Tx = maps:get(tx_hash, Run, <<>>),
            Status = maps:get(status, Run, unknown),
            Signature = maps:get(failure_signature, Run, <<>>),
            RunEntity = {damage_run, Report},
            Specs0 = [
                {RunEntity, verifies, maybe_entity(feature, Feature)},
                {RunEntity, belongs_to_account, maybe_entity(account, Account)},
                {RunEntity, executed_on, maybe_entity(node, Node)},
                {RunEntity, produced, {report, Report}},
                {RunEntity, has_result, {verification_result, Status}},
                {RunEntity, settled_by, maybe_entity(transaction, Tx)},
                {RunEntity, has_failure_signature, maybe_entity(failure_signature, Signature)}
            ],
            Meta = #{source => damage_analytics, report_cid => Report, schema => 1},
            lists:filtermap(
                fun
                    ({_S, _P, undefined}) ->
                        false;
                    ({S, P, O}) ->
                        case relation_new(S, P, O, Meta) of
                            {ok, Relation} -> {true, Relation};
                            _ -> false
                        end
                end,
                Specs0
            )
    end.

maybe_entity(_Kind, <<>>) -> undefined;
maybe_entity(Kind, Value) -> {Kind, Value}.

relation_new(S, P, O, Meta) ->
    try
        apply(ecai_relation, new, [S, P, O, Meta])
    catch
        _:_ -> {error, unavailable}
    end.

relation_keys(Relations) ->
    lists:filtermap(
        fun(Relation) ->
            try apply(ecai_relation, key, [Relation]) of
                Key when is_binary(Key) -> {true, lower_hex(Key)};
                _ -> false
            catch
                _:_ -> false
            end
        end,
        Relations
    ).

%% The geometry path is deliberately labelled experimental. ecai_transform's
%% own contract states that affine displacement is a measurement, not a proven
%% semantic invariant. Store only the bounded feature needed for benchmarking.
curve_features(Relations) ->
    case geometry_backend() of
        ecai_transform ->
            lists:filtermap(fun transform_feature/1, Relations);
        relation_affine_fallback ->
            lists:filtermap(fun relation_affine_feature/1, Relations);
        unavailable ->
            []
    end.

transform_feature(Relation) ->
    try apply(ecai_transform, feature, [Relation]) of
        {ok, Feature} when is_map(Feature) ->
            Predicate = maps:get(predicate, Feature, unknown),
            Delta = maps:get(delta, Feature, #{}),
            {true, #{
                relation_key => lower_hex(maps:get(relation_key, Feature, <<>>)),
                predicate => atom_text(Predicate),
                dx => integer_text(maps:get(dx, Delta, 0)),
                dy => integer_text(maps:get(dy, Delta, 0))
            }};
        _ ->
            false
    catch
        _:_ -> false
    end.

%% Compatibility fallback for deployments that have ecai_relation's
%% domain-separated entity points but not the optional ecai_transform module.
%% This mirrors the experimental affine-coordinate measurement only; it is not
%% elliptic-curve group subtraction and is never interpreted as semantic distance.
relation_affine_feature(Relation) ->
    try
        Subject = apply(ecai_relation, subject, [Relation]),
        Object = apply(ecai_relation, object, [Relation]),
        Predicate = apply(ecai_relation, predicate, [Relation]),
        SubjectPoint = apply(ecai_relation, entity_point, [Subject]),
        ObjectPoint = apply(ecai_relation, entity_point, [Object]),
        case {SubjectPoint, ObjectPoint} of
            {#{x := SX, y := SY}, #{x := OX, y := OY}} ->
                RelationKey =
                    try
                        apply(ecai_relation, key, [Relation])
                    catch
                        _:_ -> <<>>
                    end,
                {true, #{
                    relation_key => lower_hex(RelationKey),
                    predicate => atom_text(Predicate),
                    dx => integer_text(mod_p(OX - SX)),
                    dy => integer_text(mod_p(OY - SY))
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end.

geometry_backend() ->
    case
        module_available(ecai_transform) andalso
            erlang:function_exported(ecai_transform, feature, 1)
    of
        true ->
            ecai_transform;
        false ->
            case relation_geometry_available() of
                true -> relation_affine_fallback;
                false -> unavailable
            end
    end.

relation_geometry_available() ->
    module_available(ecai_relation) andalso
        lists:all(
            fun({F, A}) -> erlang:function_exported(ecai_relation, F, A) end,
            [{subject, 1}, {object, 1}, {predicate, 1}, {entity_point, 1}]
        ).

mod_p(N) when is_integer(N) -> ((N rem ?CURVE_P) + ?CURVE_P) rem ?CURVE_P.

module_available(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> true;
        _ -> false
    end.

safe_reason(B) when is_binary(B) -> bounded_text(B, 240);
safe_reason(A) when is_atom(A) -> atom_to_binary(A, utf8);
safe_reason(V) -> bounded_text(iolist_to_binary(io_lib:format("~p", [V])), 240).

bounded_text(B, Limit) when is_binary(B), byte_size(B) =< Limit -> B;
bounded_text(B, Limit) when is_binary(B) -> binary:part(B, 0, Limit).

atom_text(A) when is_atom(A) -> atom_to_binary(A, utf8);
atom_text(B) when is_binary(B) -> B;
atom_text(V) -> safe_reason(V).

integer_text(I) when is_integer(I) -> integer_to_binary(I);
integer_text(V) -> safe_reason(V).

geometry_fingerprint([]) ->
    <<>>;
geometry_fingerprint(Features) ->
    Canonical = lists:sort([maps:with([relation_key, predicate, dx, dy], F) || F <- Features]),
    Hex = lower_hex(crypto:hash(sha256, term_to_binary(Canonical, [deterministic]))),
    <<Short:16/binary, _/binary>> = Hex,
    Short.

lower_hex(<<>>) ->
    <<>>;
lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin))));
lower_hex(V) ->
    safe_reason(V).
