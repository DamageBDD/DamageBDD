-module(ecai_codebase_learning).

-export([
    refresh/0,
    status/0,
    snapshot/0,
    snapshot_path/0,
    module/2,
    related/2,
    related/3,
    application/1,
    architecture/0,
    repairs/0,
    repairs/1,
    durability/0,
    events/2,
    events/3
]).

refresh() ->
    ecai_codebase_learner:learn_now().

status() ->
    #{
        learner => safe_call(fun ecai_codebase_learner:status/0),
        store => safe_call(fun ecai_learning_store:status/0),
        patch_manager => safe_call(fun ecai_patch_manager:status/0),
        snapshot_path => snapshot_path()
    }.

snapshot() ->
    ecai_learning_snapshot:write().

snapshot_path() ->
    ecai_learning_snapshot:path().

module(App, Module) when is_atom(App), is_atom(Module) ->
    #{
        analysis => ecai_learning_store:get_analysis(App, Module),
        knowledge => ecai_learning_store:get_module_knowledge(App, Module)
    }.

related(App, Module) -> related(App, Module, 1).

related(App, Module, Depth) ->
    case ecai_learning_store:get_graph(App) of
        {ok, Graph} -> {ok, ecai_code_graph:neighborhood(Graph, Module, Depth)};
        not_found -> not_found
    end.

application(App) when is_atom(App) ->
    ecai_learning_store:get_app_knowledge(App).

architecture() ->
    ecai_learning_store:get_global_knowledge().

repairs() -> ecai_learning_store:repairs().
repairs(Fingerprint) -> ecai_learning_store:repairs(Fingerprint).

durability() ->
    #{
        learner => checkpoint_summary(ecai_learning_store:get_checkpoint(codebase_learner)),
        patch_manager => checkpoint_summary(ecai_learning_store:get_checkpoint(patch_manager)),
        store => safe_call(fun ecai_learning_store:status/0)
    }.

events(Type, Id) -> ecai_learning_store:events(Type, Id).
events(Type, Id, Limit) -> ecai_learning_store:events(Type, Id, Limit).

checkpoint_summary({ok, Checkpoint}) when is_map(Checkpoint) ->
    {ok, maps:without([queue, inflight_entries], Checkpoint)};
checkpoint_summary(Other) -> Other.

safe_call(Fun) ->
    try Fun() of Value -> Value
    catch Class:Reason -> {error, {Class, Reason}}
    end.
