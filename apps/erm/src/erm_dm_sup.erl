-module(erm_dm_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => erm_dm_greeter_host,
          start => {erm_dm_greeter_host, start_link, []},
          restart => permanent, shutdown => 10000, type => worker,
          modules => [erm_dm_greeter_host]},
        #{id => erm_dm_sessions,
          start => {erm_dm_sessions, start_link, []},
          restart => permanent, shutdown => 5000, type => worker,
          modules => [erm_dm_sessions]},
        #{id => erm_dm_auth,
          start => {erm_dm_auth, start_link, []},
          restart => permanent, shutdown => 5000, type => worker,
          modules => [erm_dm_auth]},
        #{id => erm_dm_ui,
          start => {erm_dm_ui, start_link, []},
          restart => permanent, shutdown => 5000, type => worker,
          modules => [erm_dm_ui]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
