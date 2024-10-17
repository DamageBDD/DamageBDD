-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([step/6]).
-export([is_admin/1]).

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
  end;

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  <<"Given">>,
  _N,
  ["I am an Admin"],
  _
) ->
  case is_admin(AeAccount) of
    true -> Context;
    Other -> maps:put(fail, Other, Context)
  end.


is_admin(AeAccount) ->
  {ok, AdminAccounts} = application:get_env(damage, admin_accounts),
  lists:member(AeAccount, AdminAccounts).
