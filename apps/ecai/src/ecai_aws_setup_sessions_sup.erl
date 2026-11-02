-module(ecai_aws_setup_sessions_sup).
-behaviour(supervisor).
-export([start_link/0, init/1, start_session/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_session(Id) ->
    %% Credentials MUST NOT appear in this supervisor's mfargs or crash reports.
    supervisor:start_child(?MODULE, #{id => Id, start => {ecai_aws_setup_session, start_link, []},
        restart => temporary, shutdown => 2000, type => worker, modules => [ecai_aws_setup_session]}).
init([]) -> {ok, {{one_for_one, 5, 10}, []}}.
