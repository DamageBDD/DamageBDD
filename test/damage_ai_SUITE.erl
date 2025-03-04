-module(damage_ai_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, ai}].

groups() -> [{ai, [parallel], [generate_code_test]}].

init_per_group(Name, Config) ->
    {ok, _} = formatter:start_link([]),
    application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(erlexec),
    PrivDir = code:priv_dir(damage),
    MessagesYaml = filename:join([PrivDir, "gpt_messages.yaml"]),
    FunctionsYaml = filename:join([PrivDir, "gpt_functions.yaml"]),
    damage_test:init_http(
        Name,
        #{env => #{dispatch => init_dispatch(Name)}},
        [
            {host, localhost},
            {port, 9090},
            {feature_dirs, ["../../../../features/", "../features/"]},
            {account, "test"},
            {data_dir, "/var/lib/damagebdd/"},
            {
                formatters,
                [{text, #{output => "report.txt"}}, {html, #{output => "report.html"}}]
            },
            %{openai_api_host, "api.endpoints.anyscale.com"},
            %{openai_api_path, "/v1/chat/completions"},
            {openai_api_host, "localhost:8080"},
            {openai_api_path, "/api/generate"},
            %{openai_api_host, "api.openai.com"},
            %{openai_api_path, "/v1/chat/completions"},
            %{openai_model, "codellama/CodeLlama-34b-Instruct-hf"},
            %{openai_model, "gpt-4"},
            {openai_model, "mistral"},
            {openai_messages_yaml, MessagesYaml},
            {openai_functions_yaml, FunctionsYaml}
            | Config
        ]
    ).

init_dispatch(_) ->
    cowboy_router:compile(
        [
            {
                "localhost",
                [
                    {"/echo/:key", echo_h, []},
                    {"/", hello_h, []},
                    {"/api/execute_feature/", damage_http, []}
                ]
            }
        ]
    ).

end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_per_suite(Config) -> damage_test:init_per_suite(Config).

end_per_suite(Config) -> damage_test:end_per_suite(Config).

new_pool(Size, MaxOverflow) ->
    poolboy:start_link(
        [
            {name, {local, formatter}},
            {worker_module, formatter},
            {size, Size},
            {max_overflow, MaxOverflow}
        ]
    ).

pool_call(ServerRef, Request) -> gen_server:call(ServerRef, Request).

generate_code_test(TestConfig) ->
    % erlang code to get application root directory
    {ok, Pool} = new_pool(2, 5),
    FeatureFile = "../../../../features/ai_voice_assistant.feature",
    ?debugFmt(
        "Running feature file ~p ~p ~p",
        [file:get_cwd(), FeatureFile, TestConfig]
    ),
    {Code, _Explanation} = damage_ai:generate_code(TestConfig, FeatureFile),
    pool_call(Pool, {run_python_server, TestConfig, #{}, Code}),
    %[#{response := [{status_code, 200} | _]} | _] =
    [] = lists:flatten(damage:execute(TestConfig, "ai_voice_assistant.feature")).
