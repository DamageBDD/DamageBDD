-module(ecai_eval_worker_sup).
-behaviour(supervisor).
-export([start_link/0, start_child/3, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_child(Parent, Token, Work) -> supervisor:start_child(?MODULE, [Parent, Token, Work]).
init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1},
           [#{id => ecai_eval_worker, start => {ecai_eval_worker, start_link, []},
              restart => temporary, shutdown => 1000, type => worker}]}}.
