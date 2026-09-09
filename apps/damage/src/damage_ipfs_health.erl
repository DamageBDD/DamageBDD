-module(damage_ipfs_health).
-export([start_link/1, check/0, status/0, run/2]).
start_link(C) ->
    damage_ipfs_loop:start_link(
        ?MODULE,
        ?MODULE,
        maps:get(health_interval_ms, C),
        C,
        undefined
    ).
check() -> damage_ipfs_loop:trigger(?MODULE).
status() -> damage_ipfs_loop:status(?MODULE).
run(_, D) ->
    case damage_ipfs_client:request(version) of
        {ok, #{<<"Version">> := Version}} ->
            case damage_ipfs_client:request(swarm_peers) of
                {ok, #{<<"Peers">> := Peers}} when is_list(Peers) ->
                    {ok, #{state => healthy, version => Version, peer_count => length(Peers)}, D};
                {ok, #{<<"Peers">> := null}} ->
                    {ok, #{state => healthy, version => Version, peer_count => 0}, D};
                {error, _} = E ->
                    E;
                _ ->
                    {error, invalid_swarm_response}
            end;
        {error, _} = E ->
            E;
        _ ->
            {error, invalid_version_response}
    end.
