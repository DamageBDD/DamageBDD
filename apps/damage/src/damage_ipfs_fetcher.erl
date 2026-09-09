-module(damage_ipfs_fetcher).
-export([start_link/1, cat/1, get/2, status/0, execute/2]).
start_link(C) ->
    damage_ipfs_queue:start_link(
        ?MODULE,
        ?MODULE,
        maps:get(fetch_concurrency, C),
        maps:get(fetch_queue_limit, C),
        C
    ).
cat(Cid) -> damage_ipfs_queue:request(?MODULE, {cat, Cid}).
get(Cid, Path) -> damage_ipfs_queue:request(?MODULE, {get, Cid, Path}).
status() -> damage_ipfs_queue:status(?MODULE).
execute(R, _) -> damage_ipfs_client:request(R).
