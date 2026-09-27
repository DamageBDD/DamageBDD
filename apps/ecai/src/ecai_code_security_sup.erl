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
    PatchManager = #{
        id => ecai_patch_manager,
        start => {ecai_patch_manager, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_patch_manager]
    },
    {ok, {{rest_for_one, 10, 10}, [Store, OllamaPool, PatchSup, Learner, PatchManager]}}.
