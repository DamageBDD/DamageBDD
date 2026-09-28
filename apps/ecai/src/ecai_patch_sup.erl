-module(ecai_patch_sup).
-behaviour(supervisor).

-export([start_link/0, propose/3, propose/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

propose(App, Module, Finding) -> propose(App, Module, Finding, #{}).

propose(App, Module, Finding, Opts) ->
    Id =
        case maps:get(worker_id, Opts, undefined) of
            {Fingerprint, Version} ->
                {ecai_patch_worker, Fingerprint, Version};
            undefined ->
                {ecai_patch_worker,
                 erlang:unique_integer([positive, monotonic])};
            Other ->
                {ecai_patch_worker, Other}
        end,
    Spec = #{
        id => Id,
        start => {ecai_patch_worker, start_link,
                  [#{app => App, module => Module, finding => Finding, opts => Opts}]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [ecai_patch_worker]
    },
    supervisor:start_child(?SERVER, Spec).

init([]) -> {ok, {{one_for_one, 10, 10}, []}}.
