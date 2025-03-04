-module(damage_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, web}].

groups() -> [{web, [parallel], [execute_test, execute_http_api_test]}].

init_per_suite(Config) ->
    {ok, _} = formatter:start_link([]),
    damage_test:init_per_suite(Config).

init_per_group(Name, Config) ->
    damage_test:init_http(
        Name,
        #{env => #{dispatch => init_dispatch(Name)}},
        [
            {host, localhost},
            {feature_dirs, ["../../../../features/", "../features/"]},
            {account, "test"},
            {
                formatters,
                [{text, #{output => "report.txt"}}, {html, #{output => "report.html"}}]
            }
            | Config
        ]
    ).

end_per_group(Name, _) -> cowboy:stop_listener(Name).

end_per_suite(Config) -> damage_test:end_per_suite(Config).

init_dispatch(Name) ->
    cowboy_router:compile(
        [
            {
                atom_to_list(Name),
                [
                    {"/echo/:key", echo_h, []},
                    {"/", hello_h, []},
                    {"/api/execute_feature/", damage_http, []}
                ]
            }
        ]
    ).

execute_test(TestConfig) ->
    [#{response := [{status_code, 200} | _]} | _] =
        lists:flatten(damage:execute(TestConfig, "localhost")).

execute_http_api_test(TestConfig) ->
    [#{response := [{status_code, 201} | _]} | _] =
        lists:flatten(damage:execute(TestConfig, "api")).
