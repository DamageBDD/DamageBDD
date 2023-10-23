-module(damage_bitcoin_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, ai}].

groups() -> [{ai, [parallel], [generate_code_test]}].

init_per_group(_Name, Config) -> Config.

end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_per_suite(Config) -> damage_test:init_per_suite(Config).

end_per_suite(Config) -> damage_test:end_per_suite(Config).

test_bitcoin_wallet(Config) ->
  ok =
    steps_bitcoin:step(
      Config,
      #{},
      given_keyword,
      0,
      "I have a bitcoin wallet \"testwallet\""
    ).
