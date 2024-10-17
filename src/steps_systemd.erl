-module(steps_systemd).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-export([step/6]).
-export([test/0]).

-include_lib("kernel/include/logger.hrl").

step(
  _Config,
  Context,
  <<"Given">>,
  _N,
  ["that status of service", Service, "is", Status],
  _
) ->
  {ok, [{stdout, Stdout}]} =
    exec:run(
      "systemctl show -p ActiveState " ++ Service ++ "\n",
      [stdout, sync]
    ),
  case binary_to_list(Stdout) of
    ["ActiveState=", "active"] -> Context;

    _ ->
      maps:put(
        fail,
        damage_utils:strf("Service ~p is not in state ~p", [Service, State]),
        Context
      );

    _ -> Context
  end.


test() -> ok.
