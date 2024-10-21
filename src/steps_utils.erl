-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

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
  #{ae_account := AeAccount} = Context,
  _,
  _N,
  [
    "test case",
    FeatureHash,
    "status was",
    Status,
    "in the last",
    Hours,
    "hours"
  ],
  _
) ->
  case get_last_test_status(AeAccount, FeatureHash, list_to_integer(Hours)) of
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
  end;

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  <<"Given">>,
  _N,
  ["I am a", Service, "Admin"],
  _
) ->
  {ok, {admins, ServiceAdmins}} =
    application:get_env(damage_systemd, list_to_atom(Service)),
  case lists:member(AeAccount, ServiceAdmins) of
    true -> Context;
    Other -> maps:put(fail, Other, Context)
  end.


is_admin(AeAccount) when is_binary(AeAccount) ->
  is_admin(binary_to_list(AeAccount));

is_admin(AeAccount) ->
  case application:get_env(damage, node_admins) of
    {ok, NodeAdmins} -> lists:member(AeAccount, NodeAdmins);

    Other ->
      ?LOG_ERROR("not node admin ~p <> ~p", [Other, AeAccount]),
      false
  end.


get_last_test_status(AeAccount, FeatureHash, Hours) ->
  ?LOG_DEBUG("Check balance ~p", [AeAccount]),
  DamageAEPid = damage_ae:get_wallet_proc(AeAccount),
  gen_server:call(
    DamageAEPid,
    {get_last_test_status, AeAccount, FeatureHash, Hours},
    ?AE_TIMEOUT
  ).
