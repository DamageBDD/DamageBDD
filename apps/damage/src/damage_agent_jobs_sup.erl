-module(damage_agent_jobs_sup).
-behaviour(supervisor).
-license("Apache-2.0").
-export([start_link/0, start_task/1, init/1]).
start_link() -> supervisor:start_link({local,?MODULE},?MODULE,[]).
start_task(J) -> supervisor:start_child(?MODULE,#{
    id => maps:get(id,J),start => {damage_agent_task,start_link,[J]},
    restart => temporary,shutdown => 5000,type => worker}).
init([]) -> {ok,{{one_for_one,3,30},[]}}.
