-module(steps_websockets_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, ws}].

groups() -> [{ws, [parallel], ct_helper:all(?MODULE)}].

init_per_suite(Config) -> damage_test:init_per_suite(Config).

init_per_group(Name, Config) ->
    damage_test:init_http(
        Name,
        #{
            enable_connect_protocol => true,
            env => #{dispatch => init_dispatch(Name)}
        },
        [
            {host, localhost},
            {feature_dirs, ["../../../../features/", "../features/"]},
            {account, "test"}
            | Config
        ]
    ).

init_dispatch(_) ->
    cowboy_router:compile([{"localhost", [{"/", ws_echo, []}]}]).

end_per_group(Name, _) -> cowboy:stop_listener(Name).

step_websocket(Config) ->
    Context = maps:new(),
    Context0 =
        steps_websockets:step(
            Config,
            Context,
            given_keyword,
            0,
            ["I open a websocket connection to", "/"],
            []
        ),
    Context1 =
        steps_websockets:step(
            Config,
            Context0,
            when_keyword,
            0,
            ["I send data on the websocket"],
            [{test, true}]
        ),
    Context2 =
        steps_websockets:step(
            Config,
            Context1,
            when_keyword,
            0,
            ["I should receive data on the websocket"],
            [{test, true}]
        ),
    {text, <<"{\"test\":true}">>} = maps:get(response, Context2).
