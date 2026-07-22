-module(ecai_index_job_worker_sup).
-behaviour(supervisor).

-export([start_link/0, start_job/1, stop_job/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_job(JobId) when is_binary(JobId) ->
    ChildSpec = #{
        id => {ecai_index_job_worker, JobId},
        start => {ecai_index_job_worker, start_link, [JobId]},
        restart => temporary,
        shutdown => 30000,
        type => worker,
        modules => [ecai_index_job_worker]
    },
    supervisor:start_child(?MODULE, ChildSpec);
start_job(_JobId) ->
    {error, badarg}.

stop_job(JobId) when is_binary(JobId) ->
    ChildId = {ecai_index_job_worker, JobId},
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            supervisor:delete_child(?MODULE, ChildId);
        {error, not_found} = Error ->
            Error;
        {error, _Reason} = Error ->
            Error
    end;
stop_job(_JobId) ->
    {error, badarg}.

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, []}}.
