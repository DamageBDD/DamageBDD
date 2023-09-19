-module(damage_ai_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, ai}].

groups() -> [{ai, [parallel], [generate_code_test]}].

init_per_suite(Config) ->
  application:ensure_all_started(gun),
  PrivDir = code:priv_dir(damage),
  MessagesYaml = filename:join([PrivDir, "gpt_messages.yaml"]),
  FunctionsYaml = filename:join([PrivDir, "gpt_functions.yaml"]),
  [
    {host, localhost},
    {feature_dirs, ["../../../../features/", "../features/"]},
    {account, "test"},
    {
      formatters,
      [{text, #{output => "report.txt"}}, {html, #{output => "report.html"}}]
    },
    {openai_api_host, "api.endpoints.anyscale.com"},
    {openai_api_path, "/v1/chat/completions"},
    {openai_messages_yaml, MessagesYaml},
    {openai_functions_yaml, FunctionsYaml} | Config
  ].


end_per_suite(Config) -> Config.

generate_code_test(TestConfig) ->
  % erlang code to get application root directory
  FeatureFile = "../../../../features/api.feature",
  ?debugFmt("Running feature file ~p ~p", [file:get_cwd(), FeatureFile]),
  ok = damage_ai:generate_code(TestConfig, FeatureFile).
