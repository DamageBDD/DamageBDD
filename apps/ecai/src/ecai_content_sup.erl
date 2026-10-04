-module(ecai_content_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    }.

init([]) ->
    Store = #{
        id => ecai_content_store,
        start => {ecai_content_store, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_content_store]
    },
    Manager = #{
        id => ecai_content_manager,
        start => {ecai_content_manager, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ecai_content_manager]
    },
    {ok, {{rest_for_one, 5, 10}, [Store, Manager]}}.
