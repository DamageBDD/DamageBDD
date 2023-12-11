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
-export(
  [execute_data/2, execute_file/2, execute/1, execute/2, execute_feature/7]
).
-export([get_default_config/3]).


start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  logger:info("Server ~p starting.~n", [self()]),
  process_flag(trap_exit, true),
  {ok, undefined}.


handle_call(die, _From, State) -> {stop, {error, died}, dead, State};

handle_call({execute, FeatureName}, _From, State) ->
  logger:debug("handle_call execute/1 : ~p", [FeatureName]),
  execute(FeatureName),
  {reply, ok, State};

handle_call(
  {
    execute_feature,
    {Config, Feature, LineNo, Tags, Description, BackGround, Scenarios}
  },
  _From,
  State
) ->
  execute_feature(
    Config,
    Feature,
    LineNo,
    Tags,
    Description,
    BackGround,
    Scenarios
  ),
  {reply, ok, State}.


handle_cast(
  {
    execute_feature,
    {Config, Feature, LineNo, Tags, Description, BackGround, Scenarios}
  },
  State
) ->
  execute_feature(
    Config,
    Feature,
    LineNo,
    Tags,
    Description,
    BackGround,
    Scenarios
  ),
  {noreply, State};

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
  {feature_dirs, FeatureDirs} =
    case lists:keyfind(feature_dirs, 1, Config) of
      false -> {feature_dirs, ["../../../../features/", "../features/"]};
      Val0 -> Val0
    end,
  {feature_suffix, FeatureSuffix} =
    case lists:keyfind(feature_suffix, 1, Config) of
      false -> {feature_suffix, ".feature"};
      Val -> Val
    end,
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


init_logging(RunId, RunDir) ->
  PidToLog = self(),
  PidFilter =
    fun
      (LogEvent, _) when PidToLog =:= self() -> LogEvent;
      (_LogEvent, _) -> ignore
    end,
  logger:add_handler(
    RunId,
    logger_std_h,
    #{
      filters => [{PidFilter, []}],
      config => #{file => filename:join(RunDir, "run.log")}
    }
  ).


deinit_logging(ScheduleId) -> logger:remove_handler(ScheduleId).

execute_data(Config, FeatureData) ->
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  BddFileName = filename:join(RunDir, string:join(["adhoc_http.feature"], "")),
  ok = file:write_file(BddFileName, FeatureData),
  execute_file(Config, BddFileName).


execute_file(Config, Filename) ->
  {run_id, RunId} = lists:keyfind(run_id, 1, Config),
  {concurrency, Concurrency} = lists:keyfind(concurrency, 1, Config),
  try egherkin:parse_file(Filename) of
    {failed, LineNo, Message} ->
      logger:error(
        "Parsing Failed ~p +~p ~n     ~p.",
        [Filename, LineNo, Message]
      ),
      {parse_error, LineNo, Message};

    {LineNo, Tags, Feature, Description, BackGround, Scenarios} ->
      case Concurrency of
        1 ->
          execute_feature(
            Config,
            Feature,
            LineNo,
            Tags,
            Description,
            BackGround,
            Scenarios
          );

        _ ->
          execute_feature_concurrent(
            [Config, Feature, LineNo, Tags, Description, BackGround, Scenarios],
            Concurrency,
            []
          )
      end,
      {ok, Hash} = damage_ipfs:add({file, Filename}),
      formatter:format(Config, summary, #{feature => Hash, run_id => RunId})
  catch
    {error, enont} -> logger:error("Feature file ~p not found.", [Filename])
  end.


execute_feature_concurrent(_Args, 0, Acc) -> Acc;

execute_feature_concurrent(Args, N, Acc) ->
  execute_feature_concurrent(
    Args,
    N - 1,
    [
      %apply(?MODULE, execute_feature, Args)
      spawn(?MODULE, execute_feature, Args) | Acc
    ]
  ).


execute_feature(
  Config,
  FeatureName,
  LineNo,
  Tags,
  Description,
  BackGround,
  Scenarios
) ->
  {run_id, RunId} = lists:keyfind(run_id, 1, Config),
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  init_logging(RunId, RunDir),
  formatter:format(Config, feature, {FeatureName, LineNo, Tags, Description}),
  [execute_scenario(Config, BackGround, Scenario) || Scenario <- Scenarios],
  deinit_logging(RunId).


execute_scenario(Config, undefined, Scenario) ->
  execute_scenario(Config, {none, []}, Scenario);

execute_scenario(Config, [], Scenario) ->
  execute_scenario(Config, {none, []}, Scenario);

execute_scenario(Config, {_, BackGroundSteps}, Scenario) ->
  {LineNo, ScenarioName, Tags, Steps} = Scenario,
  formatter:format(Config, scenario, {ScenarioName, LineNo, Tags}),
  lists:foldl(
    fun (S, C) -> execute_step(Config, S, C) end,
    get_global_template_context(Config, maps:new()),
    lists:append(BackGroundSteps, Steps)
  ).


% step execution: should execution output be passed in state and then
% handled OR should the handling happen withing the execution function
execute_step_module(
  Config,
  Context,
  {StepKeyWord, LineNo, Body, Args} = Step,
  StepModule
) ->
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
    error : function_clause:Err0 ->
      case Err0 of
        [{_, step, _, _Loc} | _] -> Context;

        Err ->
          logger:error("function fail ~p", [Err]),
          metrics:update(fail, Config),
          Reason = <<"Step error">>,
          ?LOG_ERROR(
            #{
              reason => Reason,
              stacktrace => Err,
              step => Step,
              step_module => StepModule
            }
          ),
          formatter:format(
            Config,
            step,
            {StepKeyWord, LineNo, Body, Args, Context, {fail, Reason}}
          ),
          maps:put(
            step_found,
            true,
            maps:put(failing_step, Step, maps:put(fail, Reason, Context))
          )
      end;

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
      formatter:format(
        Config,
        step,
        {StepKeyWord, LineNo, Body, Args, Context, {fail, Reason}}
      ),
      maps:put(
        step_found,
        true,
        maps:put(failing_step, Step, maps:put(fail, Reason, Context))
      )
  end.


execute_step(Config, Step, [Context]) -> execute_step(Config, Step, Context);

execute_step(Config, Step, #{fail := _} = Context) ->
  logger:info("step skipped: ~p.", [Step]),
  {LineNo, StepKeyWord, Body} = Step,
  {Body1, Args1} = damage_utils:render_body_args(Body, Context),
  formatter:format(
    Config,
    step,
    {StepKeyWord, LineNo, Body1, Args1, Context, skip}
  ),
  Context;

execute_step(Config, Step, Context) ->
  {LineNo, StepKeyWord, Body} = Step,
  {Body1, Args1} = damage_utils:render_body_args(Body, Context),
  Context0 =
    lists:foldl(
      fun
        (StepModule, #{step_found := false} = ContextIn) ->
          Step0 = {StepKeyWord, LineNo, Body1, Args1},
          case execute_step_module(Config, ContextIn, Step0, StepModule) of
            #{failing_step := _} = Context1 -> Context1;

            #{fail := Err} = Context1 ->
              formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args1, Context1, {fail, Err}}
              ),
              maps:put(failing_step, Step0, Context1);

            #{step_found := false} = Context1 -> Context1;

            #{step_found := true} = Context1 ->
              formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args1, Context1, success}
              ),
              Context1
          end;

        (_StepModule, #{step_found := true} = ContextIn) -> ContextIn
      end,
      maps:remove(fail, maps:put(step_found, false, Context)),
      damage_utils:loaded_steps()
    ),
  case maps:get(step_found, Context0) of
    false ->
      %logger:error("step not found:~p ~p", [StepKeyWord, Body1]),
      formatter:format(
        Config,
        step,
        {StepKeyWord, LineNo, Body1, Args1, Context, notfound}
      ),
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


get_default_config(Account, Concurrency, Formatters) ->
  {ok, DataDir} = application:get_env(damage, data_dir),
  {ok, RunId} = datestring:format("YmdHMS", erlang:localtime()),
  {ok, ChromeDriver} = application:get_env(damage, chromedriver),
  AccountDir = filename:join(DataDir, Account),
  RunDir = filename:join(AccountDir, RunId),
  ReportDir = filename:join([RunDir, "reports"]),
  TextReport = filename:join([ReportDir, "{{process_id}}.plain.txt"]),
  TextReportColor = filename:join([ReportDir, "{{process_id}}.color.txt"]),
  HtmlReport = filename:join([ReportDir, "{{process_id}}.html"]),
  ok = filelib:ensure_path(RunDir),
  ok = filelib:ensure_path(ReportDir),
  [
    {
      formatters,
      [
        {text, #{output => TextReportColor, color => true}},
        {text, #{output => TextReport, color => false}},
        {html, #{output => HtmlReport}} | Formatters
      ]
    },
    {feature_dirs, ["../../../../features/", "../features/"]},
    {chromedriver, ChromeDriver},
    {concurrency, Concurrency},
    {run_id, RunId},
    {run_dir, RunDir},
    {account, binary_to_list(Account)}
  ].
