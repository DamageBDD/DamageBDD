-module(damage_accounts_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, payment}].

groups() -> [{payment, [parallel], [create_account_test]}].

init_per_group(_Name, Config) ->
  logger:info("Starting vanilla."),
  damage_utils:setup_vanillae_deps(),
  {ok, _} = application:ensure_all_started(vanillae),
  ok = vanillae:network_id("ae_uat"),
  {ok, AeNodes} = application:get_env(damage, ae_nodes),
  ok = vanillae:ae_nodes(AeNodes),
  logger:info("Started vanilla."),
  {ok, _} = application:ensure_all_started(gun),
  {ok, _} = application:ensure_all_started(erlexec),
  Config.


end_per_group(_Name, _) -> ok.

create_account_test(_TestConfig) ->
  Account = damage_accounts:create_account(),
  _Account = damage_accounts:check_spend(Account),
  ok.
