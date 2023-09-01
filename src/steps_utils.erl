-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([step/6]).

step(
  _Config,
  Context,
  _,
  _N,
  ["I set the variable ", Variable, " to value ", Value],
  _
) ->
  maps:put(Variable, Value, Context);

step(_Config, Context, _, _N, ["I store an uuid in", Variable], _) ->
  maps:put(Variable, list_to_binary(uuid:to_string(uuid:uuid4())), Context);

step(
  _Config,
  Context,
  _,
  _N,
  ["I store current time string in ", Variable, " with format ", Format],
  _
) ->
  maps:put(
    Variable,
    datestring:format(Format, calendar:universal_time()),
    Context
  ).
