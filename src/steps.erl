%% @author Steven Joseph
%% @copyright 2021 Steven Joseph
%% @version 1.0.0
%% @doc Default Steps

-module(steps).

-export([step/6]).

step(
  _Config,
  Context,
  _,
  _N,
  ["I set the variable ", Variable, " to value ", Value],
  _
) ->
  dict:store(Variable, Value, Context);

step(_Config, Context, _, _N, ["I store an uuid in ", Variable], _) ->
  dict:store(Variable, list_to_binary(uuid:to_string(uuid:uuid4())), Context);

step(
  _Config,
  Context,
  _,
  _N,
  ["I store current time string in ", Variable, " with format ", Format],
  _
) ->
  dict:store(
    Variable,
    datestring:format(Format, calendar:universal_time()),
    Context
  ).
