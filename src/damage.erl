-module(damage).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").
-include_lib("damage.hrl").

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
  [
    execute_data/3,
    execute_file/3,
    execute/3,
    execute/2,
    execute_feature/8,
    publish_data/2,
    get_global_template_context/2
  ]
).
-export([get_default_config/3]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  ?LOG_INFO("Server ~p starting.~n", [self()]),
  process_flag(trap_exit, true),
  {ok, undefined}.


handle_call(die, _From, State) -> {stop, {error, died}, dead, State};

handle_call({execute, FeatureName}, _From, State) ->
  ?LOG_DEBUG("handle_call execute/1 : ~p", [FeatureName]),
  execute([], #{}, FeatureName),
  {reply, ok, State};

handle_call(
  {
    execute_feature,
    {Config, Context, Feature, LineNo, Tags, Description, BackGround, Scenarios}
  },
  _From,
  State
) ->
  execute_feature(
    Config,
    Context,
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
    {Config, Context, Feature, LineNo, Tags, Description, BackGround, Scenarios}
  },
  State
) ->
  execute_feature(
    Config,
    Context,
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
  ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

execute(Config, Context) ->
  {feature_dirs, FeatureDirs} = lists:keyfind(feature_dirs, 1, Config),
  {feature_include, FeatureInclude} = lists:keyfind(feature_include, 1, Config),
  lists:map(
    fun
      (FeatureDir) ->
        lists:map(
          fun (Filename) -> execute_file(Config, Context, Filename) end,
          filelib:wildcard(filename:join(FeatureDir, FeatureInclude))
        )
    end,
    FeatureDirs
  ).


execute(Config, Context, FeatureName) ->
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
          fun (Filename) -> execute_file(Config, Context, Filename) end,
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

publish_data(Config, FeatureData) ->
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  BddFileName =
    filename:join(RunDir, string:join(["adhoc_http_publish.feature"], "")),
  ok = file:write_file(BddFileName, FeatureData),
  publish_file(Config, BddFileName).


publish_file(Config, Filename) ->
  {contract_address, ContractAddress} =
    lists:keyfind(contract_address, 1, Config),
  {fee, Fee} = lists:keyfind(fee, 1, Config),
  {ok, [#{<<"Hash">> := Hash, <<"Name">> := Name, <<"Size">> := Size}]} =
    damage_ipfs:add({file, Filename}),
  #{address := PubContractAddress} =
    Result =
      damage_ae:aecli(
        contract,
        deploy,
        "contracts/publish_feature.aes",
        [list_to_binary(ContractAddress), Hash, Fee]
      ),
  ?LOG_INFO("call AE contract  : ~p : ~p", [PubContractAddress, Result]),
  PubFeature =
    #{
      feature_hash => Hash,
      name => Name,
      size => Size,
      fee => Fee,
      publish_contract_address => PubContractAddress
    },
  {ok, true} = damage_riak:put(?PUBLISHED_FEATURES_BUCKET, Hash, PubFeature),
  ?LOG_INFO("store pub feature  : ~p", [PubFeature]),
  PubFeature.


parse_file(Filename, Context) ->
  ?LOG_DEBUG("parse context: ~p", [Context]),
  case file:read_file(Filename) of
    {ok, Source0} -> egherkin:parse(Source0);
    Else -> Else
  end.


execute_data(Config, Context, FeatureData) ->
  {run_id, RunId} = lists:keyfind(run_id, 1, Config),
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  BddFileName =
    case lists:keyfind(feature_filename, 1, Config) of
      {feature_filename, FeatureFile} -> FeatureFile;
      _ -> filename:join(RunDir, string:join([RunId, ".feature"], ""))
    end,
  ok = file:write_file(BddFileName, FeatureData),
  execute_file(Config, Context, BddFileName).


execute_file(Config, Context, Filename) ->
  {run_id, RunId} = lists:keyfind(run_id, 1, Config),
  {concurrency, Concurrency} = lists:keyfind(concurrency, 1, Config),
  {contract_address, ContractAddress0} =
    lists:keyfind(contract_address, 1, Config),
  ContractAddress = list_to_binary(ContractAddress0),
  StartTimestamp = date_util:now_to_seconds_hires(os:timestamp()),
  case catch parse_file(Filename, Context) of
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
            Context,
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
      EndTimestamp = date_util:now_to_seconds_hires(os:timestamp()),
      {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
      {api_url, DamageApi} = lists:keyfind(api_url, 1, Config),
      ?LOG_DEBUG("RunDir ~p", [RunDir]),
      {ok, HashList} = damage_ipfs:add({directory, RunDir}),
      [#{<<"Hash">> := ReportHash}] =
        lists:filter(
          fun
            (I) ->
              #{<<"Hash">> := _Hash, <<"Name">> := Dir} = I,
              string:equal(<<"/", Dir/binary>>, RunDir)
          end,
          HashList
        ),
      FeatureFile = list_to_binary(string:join([RunId, ".feature"], "")),
      [#{<<"Hash">> := FeatureHash}] =
        lists:filter(
          fun
            (I) ->
              #{<<"Hash">> := _Hash, <<"Name">> := Dir} = I,
              %?LOG_DEBUG(
              %  "Files ~p ~p",
              %  [
              %    <<RunDir/binary, "/", FeatureFile/binary>>,
              %    <<"/", Dir/binary>>
              %  ]
              %),
              string:equal(
                <<RunDir/binary, "/", FeatureFile/binary>>,
                <<"/", Dir/binary>>
              )
          end,
          HashList
        ),
      formatter:format(
        Config,
        summary,
        #{
          report_dir
          =>
          string:join([DamageApi, "reports", binary_to_list(ReportHash)], "/"),
          run_id => RunId
        }
      ),
      FeatureTitle = lists:nth(1, binary:split(Feature, <<"\n">>, [global])),
      RunRecord =
        #{
          run_id => list_to_binary(RunId),
          feature_hash => FeatureHash,
          report_hash => ReportHash,
          start_time => StartTimestamp,
          execution_time => EndTimestamp - StartTimestamp,
          end_time => EndTimestamp,
          feature_title => FeatureTitle,
          contract_address => ContractAddress,
          schedule_id => case lists:keyfind(schedule_id, 1, Config) of
            {schedule_id, ScheduleId} -> ScheduleId;
            false -> false
          end
        },
      store_runrecord(RunRecord),
      damage_ae:confirm_spend(ContractAddress),
      RunRecord;

    {error, enont} = Err ->
      logger:error("Feature file ~p not found.", [Filename]),
      Err
  end.


store_runrecord(
  #{
    feature_hash := _FeatureHash,
    report_hash := ReportHash,
    start_time := _StartTimestamp,
    execution_time := _ExecutionTime,
    end_time := _EndTimestamp,
    contract_address := ContractAddress,
    schedule_id := ScheduleId
  } = RunRecord
) ->
  damage_riak:put(
    ?RUNRECORDS_BUCKET,
    ReportHash,
    RunRecord,
    case ScheduleId of
      false -> [{{binary_index, "contract_address"}, [ContractAddress]}];

      ScheduleId ->
        [
          {{binary_index, "contract_address"}, [ContractAddress]},
          {{binary_index, "schedule_id"}, [ScheduleId]}
        ]
    end
  ).


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
  FeatureContext,
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
  lists:foldl(
    fun
      (Scenario, Context) ->
        execute_scenario(Config, Context, BackGround, Scenario)
    end,
    FeatureContext,
    Scenarios
  ),
  deinit_logging(RunId).


execute_scenario(Config, Context, undefined, Scenario) ->
  execute_scenario(Config, Context, {none, []}, Scenario);

execute_scenario(Config, Context, [], Scenario) ->
  execute_scenario(Config, Context, {none, []}, Scenario);

execute_scenario(Config, Context, {_, BackGroundSteps}, Scenario) ->
  {LineNo, ScenarioName, Tags, Steps} = Scenario,
  formatter:format(Config, scenario, {ScenarioName, LineNo, Tags}),
  lists:foldl(
    fun (S, C) -> execute_step(Config, S, C) end,
    Context,
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
    throw : Reason:Stack ->
      ?LOG_ERROR(
        #{
          reason => Reason,
          stacktrace => Stack,
          step => Step,
          step_module => StepModule
        }
      ),
      metrics:update(fail, Config),
      formatter:format(
        Config,
        step,
        {StepKeyWord, LineNo, Body, Args, Context, {fail, Reason}}
      ),
      maps:put(
        step_found,
        true,
        maps:put(failing_step, Step, maps:put(fail, Reason, Context))
      );

    error : function_clause:Err0 ->
      case Err0 of
        [{_, step, _, _Loc} | _] -> Context;

        Err ->
          Reason = <<"Step error">>,
          ?LOG_ERROR(
            #{
              reason => Reason,
              stacktrace => Err,
              step => Step,
              step_module => StepModule
            }
          ),
          metrics:update(fail, Config),
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
  ?LOG_INFO("step skipped: ~p.", [Step]),
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
              {contract_address, ContractAddress} =
                lists:keyfind(contract_address, 1, Config),
              damage_ae:spend(
                ContractAddress,
                maps:get(step_spend, Context1, 1)
              ),
              maps:remove(step_spend, Context1)
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
  %?LOG_DEBUG("STEP CONTEXT ~p ~p", [Body1, Context0]),
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
  maps:put(
    formatter_state,
    #state{},
    maps:put(
      headers,
      [],
      maps:put(
        timestamp,
        date_util:now_to_seconds_hires(os:timestamp()),
        maps:merge(maps:from_list(DeploymentConfig), Context)
      )
    )
  ).


get_default_config(ContractAddress, Concurrency, Formatters) ->
  {ok, DataDir} = application:get_env(damage, data_dir),
  {ok, RunId} = datestring:format("YmdHMS", erlang:localtime()),
  {ok, ChromeDriver} = application:get_env(damage, chromedriver),
  {ok, DamageApi} = application:get_env(damage, api_url),
  AccountDir = filename:join(DataDir, ContractAddress),
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
    {contract_address, binary_to_list(ContractAddress)},
    {api_url, DamageApi}
  ].
