-module(erm_pay_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children =
        [
            #{
                id => erm_pay,
                start => {erm_pay, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [erm_pay]
            }
        ],
    {ok, {{one_for_one, 5, 10}, Children}}.
