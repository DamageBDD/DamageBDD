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
  [execute_data/3, execute_file/3, execute/3, execute/2, execute_feature/8]
).
-export([get_default_config/3]).
-export([sats_to_damage/1]).

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

parse_file(Filename) ->
  %?LOG_DEBUG("parse context: ~p", [Context]),
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
  StartTimestamp = date_util:now_to_seconds_hires(os:timestamp()),
  case catch parse_file(Filename) of
    {failed, LineNo, Message} ->
      logger:error(
        "Parsing Failed ~p +~p ~n     ~p.",
        [Filename, LineNo, Message]
      ),
      {parse_error, LineNo, Message};

    {LineNo, Tags, Feature, Description, BackGround, Scenarios} ->
      FinalContext0 =
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
              [
                Config,
                Feature,
                LineNo,
                Tags,
                Description,
                BackGround,
                Scenarios
              ],
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
      FinalContext =
        maps:merge(
          FinalContext0,
          #{
            feature_hash => FeatureHash,
            report_hash => ReportHash,
            feature_title => FeatureTitle
          }
        ),
      ResultStatus =
        case maps:get(fail, FinalContext, 0) of
          0 ->
            list_to_integer(
              ?RESULT_STATUS_PREFIX_SUCCESS
              ++
              integer_to_list(round(date_util:now_to_seconds(os:timestamp())))
            );

          _Something ->
            list_to_integer(
              ?RESULT_STATUS_PREFIX_FAIL
              ++
              integer_to_list(round(date_util:now_to_seconds(os:timestamp())))
            )
        end,
      ?LOG_DEBUG("Result status index ~p", [ResultStatus]),
      Result =
        case maps:get(fail, FinalContext, none) of
          none -> "success";
          Result0 when is_list(Result0) -> list_to_binary(Result0);
          Result1 -> Result1
        end,
      RunRecord =
        #{
          run_id => list_to_binary(RunId),
          feature_hash => FeatureHash,
          report_hash => ReportHash,
          start_time => StartTimestamp,
          execution_time => EndTimestamp - StartTimestamp,
          end_time => EndTimestamp,
          feature_title => FeatureTitle,
          schedule_id => case lists:keyfind(schedule_id, 1, Config) of
            {schedule_id, ScheduleId} -> ScheduleId;
            false -> false
          end,
          result => Result,
          ae_account => maps:get(ae_account, Context),
          result_status => ResultStatus
        },
      store_runrecord(RunRecord),
      damage_webhooks:trigger_webhooks(FinalContext),
      damage_ae:confirm_spend(FinalContext),
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
    ae_account := AeAccount,
    schedule_id := ScheduleId,
    result_status := ResultStatus
  } = RunRecord
) ->
  Index =
    [
      {{binary_index, "ae_account"}, [AeAccount]},
      {{integer_index, "created"}, [date_util:epoch()]},
      {{integer_index, "result_status"}, [ResultStatus]}
    ],
  damage_riak:put(
    ?RUNRECORDS_BUCKET,
    ReportHash,
    RunRecord,
    case ScheduleId of
      false -> Index;
      ScheduleId -> Index ++ [{{binary_index, "schedule_id"}, [ScheduleId]}]
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
  FinalContext =
    lists:foldl(
      fun
        (Scenario, Context) ->
          execute_scenario(Config, Context, BackGround, Scenario)
      end,
      FeatureContext,
      Scenarios
    ),
  deinit_logging(RunId),
  FinalContext.


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
  #{ae_account := AeAccount} = Context,
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
    metrics:update(success, AeAccount),
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
      metrics:update(fail, AeAccount),
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
          ?LOG_DEBUG(
            #{
              reason => Reason,
              stacktrace => Err,
              step => Step,
              step_module => StepModule
            }
          ),
          metrics:update(fail, AeAccount),
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
      metrics:update(fail, AeAccount),
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


step_spend(Context) ->
  Spend = maps:get(step_spend, Context, 1 * math:pow(10, ?DAMAGE_DECIMALS)),
  %?LOG_DEBUG("Step spend ~p", [Spend]),
  damage_ae:spend(maps:get(username, Context), Spend),
  maps:remove(step_spend, Context).


execute_step(Config, Step, [Context]) -> execute_step(Config, Step, Context);

execute_step(Config, Step, #{fail := _} = Context) ->
  %?LOG_INFO("step skipped: ~p.", [Step]),
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
  Context2 =
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
  Context0 = step_spend(Context2),
  case maps:get(step_found, Context0) of
    false ->
      %logger:error("step not found:~p ~p", [StepKeyWord, Body1]),
      formatter:format(
        Config,
        step,
        {StepKeyWord, LineNo, Body1, Args1, Context, notfound}
      ),
      metrics:update(notfound, maps:get(ae_account, Context));

    true -> true
  end,
  %?LOG_DEBUG("STEP CONTEXT ~p ~p", [Body1, Context0]),
  Context0.


get_default_config(AeAccount, Concurrency, Formatters) ->
  {ok, DataDir} = application:get_env(damage, data_dir),
  {ok, RunId} = datestring:format("YmdHMS", erlang:localtime()),
  {ok, ChromeDriver} = application:get_env(damage, chromedriver),
  {ok, DamageApi} = application:get_env(damage, api_url),
  AccountDir = filename:join(DataDir, AeAccount),
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
    {api_url, DamageApi}
  ].
sats_to_damage(Sats) ->
    round((Sats * ?DAMAGE_PRICE) * math:pow(10, ?DAMAGE_DECIMALS)).
