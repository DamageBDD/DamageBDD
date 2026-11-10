%% This application owns the user runtime, never the system Damage runtime.
-module(erm_user_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    Children = [
        #{id => erm_user_bridge, start => {erm_user_bridge, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => erm_sup, start => {erm_sup, start_link, [userspace]},
          restart => permanent, shutdown => infinity, type => supervisor}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
