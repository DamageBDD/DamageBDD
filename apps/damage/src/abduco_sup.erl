-module(abduco_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

start_link(ServiceSpecs) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, ServiceSpecs).

init(ServiceSpecs) ->
    %% was {one_for_one, 10, 60}
    SupFlags = {one_for_one, 50, 10},
    ChildSpecs = lists:map(fun service_spec/1, ServiceSpecs),
    {ok, {SupFlags, ChildSpecs}}.

service_spec(#{name := Name} = Spec) ->
    #{
        id => Name,
        start => {abduco_worker, start_link, [Spec]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [abduco_worker]
    }.
