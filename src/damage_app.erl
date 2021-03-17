%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(damage_app).

-export([parse_file/1]).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
  lager:start(),
  application:ensure_all_started(hackney),
  application:start(cedb),
  application:start(p1_utils),
  application:start(fast_yaml),
  damage_sup:start_link().


stop(_State) -> ok.

%% internal functions

parse_file(Filename) ->
  {_LineNo, Tags, Feature, Description, BackGround, Scenarios} = egherkin:parse_file(Filename),
  {ok, ConfigBase} = file:consult(filename:join("config", "damage.config")),
  execute_feature(ConfigBase, Feature, Tags, Feature, Description, BackGround, Scenarios).


execute_feature(Config, FeatureName, Tags, Feature, Description, BackGround, Scenarios) ->
  lager:info("~p: ~p: ~p: ~p", [FeatureName, Tags, Feature, Description]),
  [execute_scenario(Config, BackGround, Scenario) || Scenario <- Scenarios].


execute_scenario(Config, BackGround, Scenario) ->
  {_, BackGroundSteps} = BackGround,
  {LineNo, ScenarioName, Tags, Steps} = Scenario,
  lager:info("executing scenario: ~p: ~p: ~p, ~p", [LineNo, ScenarioName, Tags, Steps]),
  lists:foldl(
    fun execute_step/2,
    get_global_template_context(Config, dict:new()),
    [{Config, S} || S <- lists:append(BackGroundSteps, Steps)]
  ).


execute_step({Config, Step}, Context) ->
  {LineNo, StepKeyWord, Body} = Step,
  {Body0, Args} = get_stepargs(Body),
  Body1 = damage_utils:tokenize(mustache:render(binary_to_list(Body0), Context)),
  Args1 = list_to_binary(mustache:render(binary_to_list(Args), Context)),
  lager:info("executing step: ~p: ~p: ~p: ~p", [LineNo, StepKeyWord, Body1, Args1]),
  try apply(steps_web, step, [Config, Context, StepKeyWord, LineNo, Body1, Args1]) of
    error -> dict:store(result, {error, Step}, Context);
    true -> Context;
    false -> throw("Step condition failed.");
    Result -> dict:merge(fun (_Key, Val1, _Val2) -> Val1 end, Result, Context)
  catch
    %error : undef -> step_run(Config, Input, Step, Features);
    %error : function_clause -> step_run(Config, Input, Step, Features);
    throw : {fail, Reason} : Stacktrace ->
      lager:error(
        "~s~nStacktrace:~s",
        [Reason, lager:pr_stacktrace(Stacktrace, {fail, list_to_binary(Reason)})]
      ),
      case lists:keyfind(stop, 1, Config) of
        {stop, true} -> throw(Reason);
        _ -> lager:debug("Continuing after errors.")
      end
  end.


get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(docstring, 1, Body) of
    {value, {docstring, Doc}, Body0} ->
      {damage_utils:binarystr_join(Body0, <<" ">>), damage_utils:binarystr_join(Doc)};

    _ -> {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
  end.


get_global_template_context(Config, Context) ->
  {context_yaml, ContextYamlFile} = lists:keyfind(context_yaml, 1, Config),
  {deployment, Deployment} = lists:keyfind(deployment, 1, Config),
  {ok, [ContextYaml | _]} = fast_yaml:decode_from_file(ContextYamlFile, [{plain_as_atom, true}]),
  {deployments, Deployments} = lists:keyfind(deployments, 1, ContextYaml),
  {Deployment, DeploymentConfig} = lists:keyfind(Deployment, 1, Deployments),
  {ok, Timestamp} = datestring:format("YmdHM", erlang:localtime()),
  dict:store(
    headers,
    [],
    dict:store(
      timestamp,
      Timestamp,
      dict:merge(fun (_Key, Val1, _Val2) -> Val1 end, dict:from_list(DeploymentConfig), Context)
    )
  ).
