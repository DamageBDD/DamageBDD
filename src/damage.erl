-module(damage).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

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
-export([execute_file/2, execute/1, execute/2]).

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

execute(Config) ->
  {feature_dirs, FeatureDirs} = lists:keyfind(feature_dirs, 1, Config),
  {feature_include, FeatureInclude} = lists:keyfind(feature_include, 1, Config),
  lists:map(
    fun
      (FeatureDir) ->
        lists:map(
          fun (Filename) -> execute_file(Config, Filename) end,
          filelib:wildcard(filename:join(FeatureDir, FeatureInclude))
        )
    end,
    FeatureDirs
  ).


execute(Config, FeatureName) ->
  {feature_dirs, FeatureDirs} = lists:keyfind(feature_dirs, 1, Config),
  {feature_suffix, FeatureSuffix} =
    case lists:keyfind(feature_suffix, 1, Config) of
      false -> {feature_suffix, ".feature"};
      Val -> Val
    end,
  ?debugFmt(
    "Looking for features in ~p, ~p.~p",
    [
      FeatureDirs,
      filelib:wildcard(lists:flatten(FeatureName, FeatureSuffix), "./features/"),
      file:get_cwd()
    ]
  ),
  lists:map(
    fun
      (FeatureDir) ->
        lists:map(
          fun (Filename) -> execute_file(Config, Filename) end,
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


execute_file(Config, Filename) ->
  ?debugFmt("Looking for feature name ~p.", [Filename]),
  try egherkin:parse_file(Filename) of
    {failed, LineNo, Message} ->
      logger:error("FAIL ~p +~p ~n     ~p.", [Filename, LineNo, Message]);

    {_LineNo, Tags, Feature, Description, BackGround, Scenarios} ->
      ?debugFmt("Executing feature file ~p.", [Filename ++ ".feature"]),
      execute_feature(
        Config,
        Feature,
        Tags,
        Feature,
        Description,
        BackGround,
        Scenarios
      )
  catch
    {error, enont} -> logger:error("Feature file ~p not found.", [Filename])
  end.


execute_feature(
  Config,
  FeatureName,
  Tags,
  Feature,
  Description,
  BackGround,
  Scenarios
) ->
  ?debugFmt(
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
  ?debugFmt(
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


% step execution: should execution output be passed in state and then
% handled OR should the handling happen withing the execution function
execute_step_module(
  Config,
  Context,
  {StepKeyWord, LineNo, Body, Args} = Step,
  StepModule
) ->
  ?debugFmt(
    "Trying step module ~p for ~p, Context: ~p",
    [StepModule, Body, Context]
  ),
  try
    Context0 =
      maps:put(
        step_found,
        true,
        apply(
          list_to_atom(StepModule),
          step,
          [Config, Context, StepKeyWord, LineNo, Body, Args]
        )
      ),
    metrics:update(success, Config),
    Context0
  catch
    error : function_clause:_ ->
      ?LOG_ERROR(
        #{
          step_module => StepModule,
          message => "StepNotFound",
          step => StepKeyWord,
          line => LineNo,
          body => Body,
          args => Args
        }
      ),
      Context;

    error : undef:_ -> Context;

    error : Reason:Stacktrace ->
      metrics:update(fail, Config),
      ?LOG_ERROR(
        #{
          reason => Reason,
          stacktrace => Stacktrace,
          step => Step,
          step_module => StepModule
        }
      ),
      should_exit(Config),
      Context
  end.


execute_step({Config, Step}, [Context]) ->
  execute_step({Config, Step}, Context);

execute_step({_Config, Step}, #{fail := _} = Context) ->
  logger:info("step skipped: ~p ~p", [Step]),
  Context;

execute_step({Config, Step}, Context) ->
  ?debugFmt("step : ~p", [Step]),
  {LineNo, StepKeyWord, Body} = Step,
  {Body1, Args1} = damage_utils:render_body_args(Body, Context),
  ?debugFmt(
    "step keyword: ~p body: ~p: Args ~p, context: ~p",
    [StepKeyWord, Body1, Args1, Context]
  ),
  Context0 =
    lists:foldl(
      fun
        (_StepModule, #{step_found := true} = ContextIn) -> ContextIn;

        (StepModule, ContextIn) ->
          ?debugFmt("contextin body: ~p", [ContextIn]),
          case maps:get(step_found, ContextIn) of
            false ->
              execute_step_module(
                Config,
                ContextIn,
                {StepKeyWord, LineNo, Body1, Args1},
                StepModule
              );

            true -> ContextIn
          end
      end,
      maps:put(step_found, false, Context),
      damage_utils:loaded_steps()
    ),
  case maps:get(step_found, Context0) of
    false ->
      logger:error("step not found: ~p ~p", [Body1, Args1]),
      metrics:update(notfound, Config);

    true -> true
  end,
  Context0.


get_global_template_context(Config, Context) ->
  {_, DeploymentConfig} =
    case lists:keyfind(context_yaml, 1, Config) of
      false -> {local, []};

      {context_yaml, ContextYamlFile} ->
        {deployment, Deployment} = lists:keyfind(deployment, 1, Config),
        {ok, [ContextYaml | _]} =
          fast_yaml:decode_from_file(ContextYamlFile, [{plain_as_atom, true}]),
        {deployments, Deployments} = lists:keyfind(deployments, 1, ContextYaml),
        lists:keyfind(Deployment, 1, Deployments)
    end,
  {ok, Timestamp} = datestring:format("YmdHM", erlang:localtime()),
  maps:put(
    formatter_state,
    #state{},
    maps:put(
      headers,
      [],
      maps:put(
        timestamp,
        Timestamp,
        maps:merge(maps:from_list(DeploymentConfig), Context)
      )
    )
  ).
