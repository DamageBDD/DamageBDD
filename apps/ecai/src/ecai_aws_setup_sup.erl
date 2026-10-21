-module(ecai_aws_setup_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) -> {ok, {{one_for_all, 5, 10}, [
    #{id => ecai_aws_setup_sessions_sup, start => {ecai_aws_setup_sessions_sup, start_link, []},
      restart => permanent, shutdown => infinity, type => supervisor, modules => [ecai_aws_setup_sessions_sup]},
    #{id => ecai_aws_setup, start => {ecai_aws_setup, start_link, []}, restart => permanent,
      shutdown => 10000, type => worker, modules => [ecai_aws_setup]}]}}.
