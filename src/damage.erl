-module(damage).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export(
  [
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).
-export([execute_file/1, execute/1, execute/0]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  logger:info("Server ~p starting.~n", [self()]),
  process_flag(trap_exit, true),
  {ok, undefined}.


handle_call(die, _From, State) -> {stop, {error, died}, dead, State};

handle_call({execute, FeatureName}, _From, State) ->
  logger:debug("handle_call execute/1 : ~p", [FeatureName]),
  execute(FeatureName),
  {reply, ok, State}.


handle_cast(_Event, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

execute() ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  {feature_dirs, FeatureDirs} = lists:keyfind(feature_dirs, 1, Config),
  {feature_include, FeatureInclude} = lists:keyfind(feature_include, 1, Config),
  lists:map(
    fun
      (FeatureDir) ->
        lists:map(
          fun execute_file/1,
          filelib:wildcard(filename:join(FeatureDir, FeatureInclude))
        )
    end,
    FeatureDirs
  ).


execute(FeatureName) ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  {feature_dirs, FeatureDirs} = lists:keyfind(feature_dirs, 1, Config),
  {feature_suffix, FeatureSuffix} = lists:keyfind(feature_suffix, 1, Config),
  %{feature_include, FeatureInclude} = lists:keyfind(feature_include, 1, Config),
  lists:map(
    fun
      (FeatureDir) ->
        logger:debug(
          "Looking for feature name ~p in featuredir ~p.",
          [lists:flatten(FeatureName, FeatureSuffix), FeatureDir]
        ),
        lists:map(
          fun execute_file/1,
          lists:map(
            fun
              (FeatureFileName) -> filename:join(FeatureDir, FeatureFileName)
            end,
            filelib:wildcard(
              lists:flatten(FeatureName, FeatureSuffix),
              FeatureDir
            )
          )
        )
    end,
    FeatureDirs
  ).


execute_file(Filename) ->
  try egherkin:parse_file(Filename) of
    {failed, LineNo, Message} ->
      logger:info("FAIL ~p +~p ~n     ~p.", [Filename, LineNo, Message]);

    {_LineNo, Tags, Feature, Description, BackGround, Scenarios} ->
      logger:debug("Executing feature file ~p.", [Filename ++ ".feature"]),
      execute_feature(
        none,
        Feature,
        Tags,
        Feature,
        Description,
        BackGround,
        Scenarios
      )
  catch
    {error, enont} -> logger:debug("Feature file ~p not found.", [Filename])
  end.


execute_feature(
  none,
  _FeatureName,
  Tags,
  Feature,
  Description,
  BackGround,
  Scenarios
) ->
  {ok, ConfigBase} = file:consult(filename:join("config", "damage.config")),
  execute_feature(
    ConfigBase,
    Feature,
    Tags,
    Feature,
    Description,
    BackGround,
    Scenarios
  );

execute_feature(
  Config,
  FeatureName,
  Tags,
  Feature,
  Description,
  BackGround,
  Scenarios
) ->
  logger:debug(
    "~p: ~p: ~p: ~p, ~p",
    [FeatureName, Tags, Feature, Description, BackGround]
  ),
  [execute_scenario(Config, BackGround, Scenario) || Scenario <- Scenarios].


execute_scenario(Config, undefined, Scenario) ->
  execute_scenario(Config, {none, []}, Scenario);

execute_scenario(Config, [], Scenario) ->
  execute_scenario(Config, {none, []}, Scenario);

execute_scenario(Config, {_, BackGroundSteps}, Scenario) ->
  {LineNo, ScenarioName, Tags, Steps} = Scenario,
  logger:info(
    "executing scenario: ~p: line: ~p: tags ~p",
    [ScenarioName, LineNo, Tags]
  ),
  lists:foldl(
    fun execute_step/2,
    get_global_template_context(Config, maps:new()),
    [{Config, S} || S <- lists:append(BackGroundSteps, Steps)]
  ).


should_exit(Config) ->
  case lists:keyfind(stop, 1, Config) of
    {stop, true} -> exit(normal);
    _ -> logger:debug("Continuing after errors.")
  end.


handle_step_fail(Config, Reason, Stacktrace) ->
  ?LOG_ERROR(#{reason => Reason, stacktrace => Stacktrace}),
  should_exit(Config).


execute_step_module(
  _Config,
  #{step_notfound := false} = Context,
  _StepKeyWord,
  _LineNo,
  _Body1,
  _Args1,
  _StepModuleSrc
) ->
  Context;

execute_step_module(
  Config,
  #{step_notfound := true} = Context,
  StepKeyWord,
  LineNo,
  Body1,
  Args1,
  StepModuleSrc
) ->
  [StepModule, _] = string:tokens(filename:basename(StepModuleSrc), "."),
  logger:debug("Trying step module ~p for ~p", [StepModule, Body1]),
  try
    Context0 =
      case
      apply(
        list_to_atom(StepModule),
        step,
        [Config, Context, StepKeyWord, LineNo, Body1, Args1]
      ) of
        error -> maps:put(result, {error, LineNo}, Context);
        true -> Context;
        false -> throw("Step condition failed.");
        Result -> maps:merge(Result, Context)
      end,
    maps:put(step_notfound, false, Context0)
  catch
    error : function_clause:_ -> maps:put(step_notfound, true, Context);
    %%should_exit(Config);
    error : Reason:Stacktrace -> handle_step_fail(Config, Reason, Stacktrace);

    throw : {fail, Reason} : Stacktrace ->
      handle_step_fail(Config, Reason, Stacktrace)
  end.


execute_step({Config, Step}, [Context]) ->
  execute_step({Config, Step}, Context);

execute_step({Config, Step}, Context) ->
  {LineNo, StepKeyWord, Body} = Step,
  {Body0, Args} = get_stepargs(Body),
  %logger:debug("rendering step body: ~p: ~p", [Body0, Context]),
  Body1 =
    damage_utils:tokenize(
      mustache:render(
        binary_to_list(Body0),
        dict:from_list(maps:to_list(Context))
      )
    ),
  Args1 =
    list_to_binary(
      mustache:render(
        binary_to_list(Args),
        dict:from_list(maps:to_list(Context))
      )
    ),
  logger:info("executing step: ~p: ~p: ~p", [LineNo, StepKeyWord, Body1]),
  logger:debug("step body: ~p: ~p", [Body1, Args1]),
  Context0 =
    lists:foldl(
      fun
        (StepModule, ContextIn) ->
          execute_step_module(
            Config,
            ContextIn,
            StepKeyWord,
            LineNo,
            Body1,
            Args1,
            StepModule
          )
      end,
      maps:put(step_notfound, true, Context),
      filelib:wildcard(filename:join(["src", "steps_*.erl"]))
    ),
  case maps:get(step_notfound, Context0) of
    true ->
      logger:error("Step not implemented: ~p ~p", [StepKeyWord, Body1]),
      handle_step_fail(Config, step_notfound, [Body1]);

    _ -> maps:merge(Context0, Context)
  end.


get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(docstring, 1, Body) of
    {value, {docstring, Doc}, Body0} ->
      {
        damage_utils:binarystr_join(Body0, <<" ">>),
        damage_utils:binarystr_join(Doc)
      };

    _ -> {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
  end.


get_global_template_context(Config, Context) ->
  {context_yaml, ContextYamlFile} = lists:keyfind(context_yaml, 1, Config),
  {deployment, Deployment} = lists:keyfind(deployment, 1, Config),
  {ok, [ContextYaml | _]} =
    fast_yaml:decode_from_file(ContextYamlFile, [{plain_as_atom, true}]),
  {deployments, Deployments} = lists:keyfind(deployments, 1, ContextYaml),
  {Deployment, DeploymentConfig} = lists:keyfind(Deployment, 1, Deployments),
  {ok, Timestamp} = datestring:format("YmdHM", erlang:localtime()),
  maps:put(
    headers,
    [],
    maps:put(
      timestamp,
      Timestamp,
      maps:merge(maps:from_list(DeploymentConfig), Context)
    )
  ).
