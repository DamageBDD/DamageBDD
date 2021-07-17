-module(damage).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([execute_file/1, execute/1, execute/0]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) -> {ok, undefined}.

handle_call(die, _From, State) -> {stop, {error, died}, dead, State};

handle_call({execute, FeatureName}, _From, State) ->
  logger:debug("handle_call execute/1 : ~p", [FeatureName]),
  execute(FeatureName),
  {reply, ok, State}.


handle_cast(_Event, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

execute() ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  {feature_dir, FeatureDir} = lists:keyfind(feature_dir, 1, Config),
  lists:map(fun execute_file/1, filelib:wildcard(filename:join([FeatureDir, "**", "*.feature"]))).


execute(FeatureName) ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  {feature_dir, FeatureDir} = lists:keyfind(feature_dir, 1, Config),
  logger:debug("Executing feature ~p in featuredir ~p.", [FeatureName ++ ".feature", FeatureDir]),
  execute_file(filename:join([FeatureDir, FeatureName ++ ".feature"])).


execute_file(Filename) ->
  {_LineNo, Tags, Feature, Description, BackGround, Scenarios} = egherkin:parse_file(Filename),
  {ok, ConfigBase} = file:consult(filename:join("config", "damage.config")),
  execute_feature(ConfigBase, Feature, Tags, Feature, Description, BackGround, Scenarios).


execute_feature(Config, FeatureName, Tags, Feature, Description, BackGround, Scenarios) ->
  logger:info("~p: ~p: ~p: ~p, ~p", [FeatureName, Tags, Feature, Description, BackGround]),
  [execute_scenario(Config, BackGround, Scenario) || Scenario <- Scenarios].


execute_scenario(Config, undefined, Scenario) -> execute_scenario(Config, {none, []}, Scenario);
execute_scenario(Config, [], Scenario) -> execute_scenario(Config, {none, []}, Scenario);

execute_scenario(Config, {_, BackGroundSteps}, Scenario) ->
  {LineNo, ScenarioName, Tags, Steps} = Scenario,
  logger:info("executing scenario: ~p: line: ~p: tags ~p", [ScenarioName, LineNo, Tags]),
  lists:foldl(
    fun execute_step/2,
    get_global_template_context(Config, dict:new()),
    [{Config, S} || S <- lists:append(BackGroundSteps, Steps)]
  ).



execute_step_module([Config, Context, StepKeyWord, LineNo, Body1, Args1], StepModuleSrc) ->
    [StepModule, _]=string:tokens(filename:basename(StepModuleSrc), "."),

  try 
    case apply(list_to_atom(StepModule), step, [Config, Context, StepKeyWord, LineNo, Body1, Args1]) of
        error -> dict:store(result, {error, LineNo}, Context);
        true -> Context;
        false -> throw("Step condition failed.");
        Result -> dict:merge(fun (_Key, Val1, _Val2) -> Val1 end, Result, Context)
    end
  catch
    error : Reason : _Stacktrace ->
      logger:error("no step definition ~p", [Reason]);
    %error : function_clause -> step_run(Config, Input, Step, Features);
    throw : {fail, Reason} : Stacktrace ->
      logger:error(
        "~s~nStacktrace:~s",
        [Reason, logger:pr_stacktrace(Stacktrace, {fail, list_to_binary(Reason)})]
      ),
      case lists:keyfind(stop, 1, Config) of
        {stop, true} -> throw(Reason);
        _ -> logger:debug("Continuing after errors.")
      end
  end.

execute_step({Config, Step}, Context) ->
  {LineNo, StepKeyWord, Body} = Step,
  {Body0, Args} = get_stepargs(Body),
  logger:info("rendering step: ~p", [Context]),
  Body1 = damage_utils:tokenize(mustache:render(binary_to_list(Body0), Context)),
  Args1 = list_to_binary(mustache:render(binary_to_list(Args), Context)),
  logger:info("executing step: ~p: ~p: ~p", [LineNo, StepKeyWord, Body1]),
  logger:debug("step body: ~p: ~p", [Body1, Args1]),
  StepExecutor =
    pa:bind(fun execute_step_module/2, [Config, Context, StepKeyWord, LineNo, Body1, Args1]),
  lists:map(StepExecutor, filelib:wildcard(filename:join(["src", "steps_*.erl"]))).


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
