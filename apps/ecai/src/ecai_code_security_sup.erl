-module(ecai_code_security_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    Store = #{
        id => ecai_learning_store,
        start => {ecai_learning_store, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_learning_store]
    },
    OllamaPool = #{
        id => ecai_ollama_pool,
        start => {ecai_ollama_pool, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_ollama_pool]
    },
    PatchSup = #{
        id => ecai_patch_sup,
        start => {ecai_patch_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [ecai_patch_sup]
    },
    Learner = #{
        id => ecai_codebase_learner,
        start => {ecai_codebase_learner, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_codebase_learner]
    },
    LogLearning = ecai_log_learning:child_spec(#{}),
    PatchManager = #{
        id => ecai_patch_manager,
        start => {ecai_patch_manager, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_patch_manager]
    },
    Integration = ecai_patch_integration:child_spec(#{}),
    Reconciler = ecai_patch_reconciler:child_spec(#{}),
    Core = [
        Store,
        OllamaPool,
        PatchSup,
        Learner,
        LogLearning,
        PatchManager,
        Integration,
        Reconciler
    ],
    {ok, {{rest_for_one, 10, 10}, Core ++ review_queue_specs() ++ health_monitor_specs()}}.

health_monitor_specs() ->
    case application:get_env(ecai, code_health_monitor_enabled, true) of
        true ->
            [ecai_health_monitor:child_spec(#{})];
        false ->
            [];
        Invalid ->
            erlang:error({invalid_configuration, code_health_monitor_enabled, Invalid})
    end.

%% DETS review queue follows the learning store and repair workers in the
%% rest_for_one tree; it is never available without the code-security stack.
review_queue_specs() ->
    case application:get_env(ecai, code_admin_enabled, false) of
        true -> [#{id => ecai_code_review_queue,
                   start => {ecai_code_review_queue, start_link, []},
                   restart => permanent, shutdown => 5000, type => worker,
                   modules => [ecai_code_review_queue]}];
        _ -> []
    end.
