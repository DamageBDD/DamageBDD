-module(ecai_content_evidence).

-export([build/0, build/1, identity/1]).

build() -> build(#{}).

build(Scope0) when is_map(Scope0) ->
    Scope = normalize_scope(Scope0),
    Snapshot = ecai_learning_snapshot:build(),
    SnapshotId = maps:get(snapshot_id, Snapshot),
    Base = #{
        schema_version => 1,
        snapshot_id => SnapshotId,
        created_at => maps:get(created_at, Snapshot, ecai_content_util:now_iso8601()),
        git => maps:get(git, Snapshot, #{}),
        model => maps:get(model, Snapshot, #{}),
        scope => Scope,
        architecture => safe_architecture(),
        learning => thin_learning(maps:get(learning, Snapshot, #{}))
    },
    Evidence = enrich_scope(Scope, Base),
    {ok, Evidence#{
        evidence_sha256 => ecai_content_util:sha256_hex(
            term_to_binary(ecai_content_util:json_safe(Evidence), [deterministic])
        )
    }}.

identity(Scope) ->
    case build(Scope) of
        {ok, Evidence} ->
            {ok, #{
                snapshot_id => maps:get(snapshot_id, Evidence),
                evidence_sha256 => maps:get(evidence_sha256, Evidence),
                scope => maps:get(scope, Evidence)
            }};
        {error, _} = Error ->
            Error
    end.

normalize_scope(Scope) ->
    App = maps:get(application, Scope, undefined),
    Module = maps:get(module, Scope, undefined),
    maps:filter(fun(_K, V) -> V =/= undefined end, #{application => App, module => Module}).

enrich_scope(#{application := App, module := Module}, Base) when
    is_atom(App), is_atom(Module)
->
    ModuleData = ecai_codebase_learning:module(App, Module),
    Related = safe_related(App, Module),
    Base#{module_context => thin_module_data(ModuleData), related => Related};
enrich_scope(#{application := App}, Base) when is_atom(App) ->
    Base#{application_context => safe_application(App)};
enrich_scope(_, Base) ->
    Base.

safe_architecture() ->
    try ecai_codebase_learning:architecture() of
        {ok, Card} -> Card;
        Other -> Other
    catch
        Class:Reason -> #{error => {Class, Reason}}
    end.

safe_application(App) ->
    try ecai_codebase_learning:application(App) of
        {ok, Card} -> Card;
        Other -> Other
    catch
        Class:Reason -> #{error => {Class, Reason}}
    end.

safe_related(App, Module) ->
    try ecai_codebase_learning:related(App, Module, 2) of
        {ok, Related} -> Related;
        Other -> Other
    catch
        Class:Reason -> #{error => {Class, Reason}}
    end.

thin_module_data(Map) when is_map(Map) ->
    maps:map(
        fun
            (analysis, {ok, Analysis}) when is_map(Analysis) ->
                maps:without([source, <<"source">>], Analysis);
            (_K, V) ->
                V
        end,
        Map
    );
thin_module_data(Other) ->
    Other.

thin_learning(Learning) when is_map(Learning) ->
    Analyses = [
        maps:without([source, <<"source">>], A)
     || A <- maps:get(analyses, Learning, []), is_map(A)
    ],
    Learning#{analyses => Analyses};
thin_learning(Other) ->
    Other.
