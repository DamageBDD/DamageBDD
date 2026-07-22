-module(ecai_index_jobs_sup).
-behaviour(supervisor).

-export([start_link/0, start_link/1]).
-export([init/1]).

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Opts).

init(Opts) ->
    %% The queue server and its dynamic workers are one recovery unit. If the
    %% durable state owner restarts while old workers keep running, those workers
    %% could continue mutating an index from a stale checkpoint. one_for_all
    %% stops that split-brain condition and lets the server reconstruct the
    %% queue before new workers are scheduled.
    SupFlags = #{strategy => one_for_all, intensity => 10, period => 60},
    Children = [
        #{
            id => ecai_index_job_events,
            start => {ecai_index_job_events, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [ecai_index_job_events]
        },
        #{
            id => ecai_index_job_worker_sup,
            start => {ecai_index_job_worker_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [ecai_index_job_worker_sup]
        },
        #{
            id => ecai_index_jobs_srv,
            start => {ecai_index_jobs_srv, start_link, [Opts]},
            restart => permanent,
            shutdown => 30000,
            type => worker,
            modules => [ecai_index_jobs_srv]
        }
    ],
    {ok, {SupFlags, Children}}.
