-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([step/6]).

step(_Config, Context, _, _N, ["I store an uuid in", Variable], _) ->
  maps:put(Variable, list_to_binary(uuid:to_string(uuid:uuid4())), Context);

step(_Config, Context, _, _N, ["I wait", Seconds, "seconds"], _) ->
  timer:sleep(Seconds),
  Context;

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
  );

step(
  _Config,
  Context,
  _,
  _N,
  [
    "test case ",
    FeatureHash,
    " status was ",
    Status,
    " in the last ",
    Hours,
    " hours"
  ],
  _
) ->
  case damage_ae:get_last_test_status(FeatureHash, Hours) of
    Status -> Context;

    UnExpected ->
      Msg = damage_utils:strf("Unexpected status ~p", [UnExpected]),
      maps:put(fail, Msg, Context)
  end.
