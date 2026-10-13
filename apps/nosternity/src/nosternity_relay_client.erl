-module(nosternity_relay_client).
-export([start/0, relay_event/1]).
-include_lib("nosternity.hrl").

start() ->
    Relays = ?NOSTERNITY_UPSTREAM_RELAYS,
    lists:foreach(fun(R) -> spawn(fun() -> connect(R) end) end, Relays),
    ok.

connect(Url) ->
    {ok, ConnPid} = gun:open(Url, 443, #{transport => tls}),
    receive
        {gun_up, ConnPid, _} ->
            StreamRef = gun:ws_upgrade(ConnPid, "/"),
            wait_upgrade(ConnPid, StreamRef, Url)
    end.

wait_upgrade(ConnPid, StreamRef, Url) ->
    receive
        {gun_response, ConnPid, StreamRef, _, 101, _} ->
            io:format("Connected to ~s~n", [Url]),
            register(list_to_atom(Url), ConnPid);
        _ ->
            io:format("Failed to connect to ~s~n", [Url])
    end.

relay_event(Event) ->
    Json = jsx:encode(["EVENT", Event]),
    [relay(Json, Relay) || Relay <- registered_relays()],
    ok.

registered_relays() ->
    [R || {R, _} <- erlang:processes(), is_atom(R), lists:prefix("wss://", atom_to_list(R))].

relay(Json, Relay) ->
    case whereis(Relay) of
        undefined -> ok;
        Pid -> gun:ws_send(Pid, {text, Json})
    end.
