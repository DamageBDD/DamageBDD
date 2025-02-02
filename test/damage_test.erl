-module(damage_test).

-compile(export_all).
-compile(nowarn_export_all).

-import(ct_helper, [config/2]).

-include_lib("eunit/include/eunit.hrl").

init_http(https, ProtoOpts, Config) ->
    {ok, _} = cowboy:start_tls(https, [{port, 0}], ProtoOpts),
    Port = ranch:get_port(https),
    [
        {ref, https},
        {type, tcp},
        {protocol, http},
        {port, Port},
        {opts, []}
        | Config
    ];
init_http(Ref, ProtoOpts, Config) ->
    {ok, _} = cowboy:start_clear(Ref, [{port, 0}], ProtoOpts),
    Port = ranch:get_port(Ref),
    [{ref, Ref}, {type, tcp}, {protocol, http}, {port, Port}, {opts, []} | Config].

init_per_suite(Config) ->
    application:ensure_all_started(ranch),
    application:ensure_all_started(gun),
    application:ensure_all_started(cowboy),
    application:ensure_all_started(prometheus),
    metrics:init(),
    %cedb:break(steps_http, 66),
    Config.

end_per_suite(Config) ->
    webdrv_session:stop_session(default),
    Config.
