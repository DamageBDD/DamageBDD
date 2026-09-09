-module(damage_ipfs_client).
-export([start_link/1, request/1, status/0, execute/2]).
start_link(C) ->
    damage_ipfs_queue:start_link(
        ?MODULE,
        ?MODULE,
        maps:get(client_concurrency, C),
        maps:get(client_queue_limit, C),
        C
    ).
request(R) -> damage_ipfs_queue:request(?MODULE, R).
status() -> damage_ipfs_queue:status(?MODULE).
execute(R, C) ->
    M = maps:get(backend, C),
    M:execute(R, C).
