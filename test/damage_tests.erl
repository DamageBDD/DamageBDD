-module(damage_tests).

-include_lib("eunit/include/eunit.hrl").

execute_test() ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  ok = damage:execute(Config, "localhost").
