-module(steps_websockets).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([step/6]).
step(
  Config,
  Context,
  given_keyword,
  _N,
  ["I open a websocket connection to", Path],
  _
) ->
  {host, Host} = lists:keyfind(host, 1, Config),
  {port, Port} = lists:keyfind(port, 1, Config),
  {ok, ConnPid} = gun:open(Host, Port),
  StreamRef = gun:ws_upgrade(ConnPid, Path, []),
  receive
    {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
      maps:put(
        websocket_connpid,
        ConnPid,
        maps:put(websocket_streamref, StreamRef, Context)
      );

    {gun_response, ConnPid, _, _, Status, Headers} ->
      exit({ws_upgrade_failed, Status, Headers});

    {gun_error, ConnPid, StreamRef, Reason} -> exit({ws_upgrade_failed, Reason})
  after
    1000 -> error(timeout)
  end;

step(_Config, Context, when_keyword, _N, ["I send data on the websocket"], Data) ->
  StreamRef = maps:get(websocket_streamref, Context),
  ConnPid = maps:get(websocket_connpid, Context),
  Res = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode(Data)}),
  logger:info("Received data back on websocket send: ~p ", [Res]),
  maps:put(response, Res, Context);

step(
  _Config,
  Context,
  when_keyword,
  _N,
  ["I should receive data on the websocket"],
  _
) ->
  receive
    {gun_ws, _ConnPid, _StreamRef, Frame} ->
      maps:put(
        response,
        Frame,
        Context
      );
    {gun_response, _ConnPid, _, _, Status, Headers} ->
      exit({ws_upgrade_failed, Status, Headers});

    {gun_error, _ConnPid, _StreamRef, Reason} ->
      exit({ws_upgrade_failed, Reason})
  after
    1000 -> error(timeout)
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the received data contains key ", Key, "with value", Value],
  _
) ->
  Value = maps:get(Key, Context).


