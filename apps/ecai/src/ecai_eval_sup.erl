-module(ecai_eval_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    %% A ledger-server crash also terminates the workers that owned its leases.
    Workers = #{id => ecai_eval_worker_sup, start => {ecai_eval_worker_sup, start_link, []},
                restart => permanent, shutdown => infinity, type => supervisor},
    Ledger = #{id => ecai_eval_srv, start => {ecai_eval_srv, start_link, []},
               restart => permanent, shutdown => 10000, type => worker},
    {ok, {#{strategy => one_for_all, intensity => 3, period => 10}, [Workers, Ledger]}}.
