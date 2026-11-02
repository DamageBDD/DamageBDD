-module(damage_agent_sup).
-behaviour(supervisor).
-license("Apache-2.0").
-export([start_link/0, child_spec/0, init/1]).
child_spec() -> #{id => ?MODULE,start => {?MODULE,start_link,[]},
                  type => supervisor,restart => permanent,shutdown => infinity}.
start_link() ->
    %% Installing the wiring alone must not create state in a read-only release.
    %% Once configured, retain the store even with enabled=false for inspection.
    case application:get_env(damage,agentic) of
        undefined -> ignore;
        {ok,Config} when is_list(Config), Config =/= [] ->
            supervisor:start_link({local,?MODULE},?MODULE,[]);
        _ -> ignore
    end.
init([]) ->
    %% A coordinator/store restart fences all in-flight local workers together.
    {ok,{{one_for_all,3,30},[
        #{id => damage_agent_store,start => {damage_agent_store,start_link,[]},
          restart => permanent,shutdown => 10000,type => worker},
        #{id => damage_agent_jobs_sup,start => {damage_agent_jobs_sup,start_link,[]},
          restart => permanent,shutdown => infinity,type => supervisor},
        #{id => damage_agent,start => {damage_agent,start_link,[]},
          restart => permanent,shutdown => 10000,type => worker}
    ]}}.
