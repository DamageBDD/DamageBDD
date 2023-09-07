-module(damage_test).
-compile(export_all).
-compile(nowarn_export_all).
-import(ct_helper, [config/2]).

-include_lib("eunit/include/eunit.hrl").

init_http(Ref, ProtoOpts, Config) ->
  {ok, _} = cowboy:start_clear(Ref, [{port, 0}], ProtoOpts),
  Port = ranch:get_port(Ref),
  [{ref, Ref}, {type, tcp}, {protocol, http}, {port, Port}, {opts, []} | Config].

execute_test() ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  ok = damage:execute(Config, "localhost").
