%% This subtree starts quickly. Downloads and readiness checks happen in workers.
-module(damage_webdriver_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    Children = [#{id => B, start => {damage_webdriver_service, start_link, [B]},
        restart => permanent, shutdown => 15000, type => worker,
        modules => [damage_webdriver_service]} || B <- [chromedriver, appium, fixture]],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 30}, Children}}.
