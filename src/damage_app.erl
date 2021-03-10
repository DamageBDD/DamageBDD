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
    maps:new(),
    [{Config, S} || S <- lists:append(BackGroundSteps, Steps)]
  ).


execute_step({Config, Step}, Context) ->
  {LineNo, StepKeyWord, Body} = Step,
  lager:info("executing step: ~p: ~p: ~p", [LineNo, StepKeyWord, Body]),
  {Body0, Args} = get_stepargs(Body),
  Body1 = damage_utils:tokenize(Body0),
  lager:info("executing step: ~p: ~p: ~p: ~p", [LineNo, StepKeyWord, Body1, Args]),
  try apply(steps_web, step, [Config, Context, StepKeyWord, LineNo, Body1, Args]) of
    error -> maps:put(result, {error, Step}, Context);
    true -> Context;
    false -> 
      throw("Step condition failed.");
    Result -> maps:merge(Context, Result)
  catch
    %error : undef -> step_run(Config, Input, Step, Features);
    %error : function_clause -> step_run(Config, Input, Step, Features);
    X:Y : Trace ->
      lager:error("ERROR: step run found ~p:~p~n~s~n", [X, Y, lager:pr_stacktrace(Trace)]),
      throw("Unknown error type in BDD step_run.")
  end.


get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(docstring, 1, Body) of
    {value, {docstring, Doc}, Body0} ->
      {damage_utils:binarystr_join(Body0, <<" ">>), damage_utils:binarystr_join(Doc)};

    _ -> {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
  end.
