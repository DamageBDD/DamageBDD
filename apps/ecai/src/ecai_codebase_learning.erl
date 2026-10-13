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
    refresh_relations/0,
    relations/0,
    relations/1,
    relation_keys/0,
    relation_keys/1,
    relation_benchmark/0,
    relation_benchmark/1,
    run_relation_benchmark/0,
    run_relation_benchmark/1,
    integration_status/0,
    integration_jobs/0,
    repairs/0,
    repairs/1,
    durability/0,
    health_monitor_status/0,
    health_report/0,
    health_resolution/0,
    health_check/0,
    recent_logs/0,
    recent_logs/1,
    log_learning_status/0,
    incidents/0,
    incidents/1,
    incidents/2,
    events/2,
    events/3,
    release_candidate/0,
    release_candidate/1,
    release_candidate_tags/0,
    release_candidate_tags/1,
    release_candidate_tag_description/0,
    release_candidate_tag_description/1,
    release_version/0,
    release_version/1,
    release_tag_description/0,
    release_tag_description/1,
    tag_release_candidate/0,
    tag_release_candidate/1,
    tag_release/0,
    tag_release/1,
    tag_version/1,
    tag_version/2
]).

refresh() ->
    case ecai_code_runtime_config:learning_admission() of
        {ok, _Policy} -> ecai_codebase_learner:learn_now();
        {error, _} = Error -> Error
    end.

status() ->
    #{
        learner => safe_call(fun ecai_codebase_learner:status/0),
        source_repository => safe_call(fun ecai_source_repository:status/0),
        store => safe_call(fun ecai_learning_store:status/0),
        patch_manager => safe_call(fun ecai_patch_manager:status/0),
        integration => safe_call(fun ecai_patch_integration:status/0),
        relations => safe_call(fun ecai_relation_learning:status/0),
        health_monitor => safe_call(fun ecai_health_monitor:status/0),
        log_bridge => safe_call(fun damage_ecai_log_bridge:status/0),
        log_learning => safe_call(fun ecai_log_learning:status/0),
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

refresh_relations() -> ecai_relation_learning:refresh_all().
relations() -> ecai_relation_learning:relations().
relations(Scope) -> ecai_relation_learning:relations(Scope).
relation_keys() -> ecai_relation_learning:relation_keys().
relation_keys(Scope) -> ecai_relation_learning:relation_keys(Scope).
relation_benchmark() -> ecai_learning_store:get_relation_benchmark(all).
relation_benchmark(Scope) -> ecai_learning_store:get_relation_benchmark(Scope).
run_relation_benchmark() -> ecai_relation_learning:benchmark().
run_relation_benchmark(Limit) when is_integer(Limit), Limit > 0 ->
    ecai_relation_learning:benchmark(all, Limit).

integration_status() -> ecai_patch_integration:status().
integration_jobs() -> ecai_patch_integration:jobs().

repairs() -> ecai_learning_store:repairs().
repairs(Fingerprint) -> ecai_learning_store:repairs(Fingerprint).

durability() ->
    #{
        learner => checkpoint_summary(ecai_learning_store:get_checkpoint(codebase_learner)),
        patch_manager => checkpoint_summary(ecai_learning_store:get_checkpoint(patch_manager)),
        health_monitor => checkpoint_summary(
            ecai_learning_store:get_checkpoint(ecai_health_monitor)
        ),
        log_learning => checkpoint_summary(
            ecai_learning_store:get_checkpoint(ecai_log_learning)
        ),
        store => safe_call(fun ecai_learning_store:status/0),
        integration => safe_call(fun ecai_patch_integration:status/0)
    }.

health_monitor_status() -> ecai_health_monitor:status().
health_report() -> ecai_health_monitor:latest().
health_resolution() -> ecai_health_monitor:resolution().
health_check() -> ecai_health_monitor:check_now().
recent_logs() -> damage_ecai_log_bridge:recent().
recent_logs(Limit) -> damage_ecai_log_bridge:recent(Limit).
log_learning_status() -> ecai_log_learning:status().
incidents() -> ecai_log_learning:incidents().
incidents(Limit) -> ecai_log_learning:incidents(Limit).
incidents(App, Module) -> ecai_log_learning:incidents(App, Module).

events(Type, Id) -> ecai_learning_store:events(Type, Id).
events(Type, Id, Limit) -> ecai_learning_store:events(Type, Id, Limit).

release_candidate() -> ecai_release_candidate:propose().
release_candidate(Opts) when is_map(Opts) -> ecai_release_candidate:propose(Opts).
release_candidate_tags() -> ecai_release_candidate:tags().
release_candidate_tags(Opts) when is_map(Opts) -> ecai_release_candidate:tags(Opts).
release_candidate_tag_description() -> ecai_release_candidate:description().
release_candidate_tag_description(Opts) when is_map(Opts) ->
    ecai_release_candidate:description(Opts).

release_version() -> ecai_release_candidate:propose_release().
release_version(Opts) when is_map(Opts) -> ecai_release_candidate:propose_release(Opts).
release_tag_description() -> ecai_release_candidate:release_description().
release_tag_description(Opts) when is_map(Opts) ->
    ecai_release_candidate:release_description(Opts).

tag_release_candidate() -> ecai_release_candidate:tag_release_candidate().
tag_release_candidate(Opts) when is_map(Opts) ->
    ecai_release_candidate:tag_release_candidate(Opts).
tag_release() -> ecai_release_candidate:tag_release().
tag_release(Opts) when is_map(Opts) -> ecai_release_candidate:tag_release(Opts).
tag_version(Kind) -> ecai_release_candidate:tag(Kind).
tag_version(Kind, Opts) when is_map(Opts) -> ecai_release_candidate:tag(Kind, Opts).

checkpoint_summary({ok, Checkpoint}) when is_map(Checkpoint) ->
    {ok, maps:without([queue, inflight_entries], Checkpoint)};
checkpoint_summary(Other) ->
    Other.

safe_call(Fun) ->
    try Fun() of
        Value -> Value
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.
