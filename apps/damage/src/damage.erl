-module(damage).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

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
-export([check_setup/0]).
-export([parse_file/1]).
-export([hits_to_damage/1]).
-import(damage_utils, [to_bin/1]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, undefined}.

handle_call(die, _From, State) ->
    {stop, {error, died}, dead, State};
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
handle_cast(_Event, State) ->
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    %?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
get_feature_dir(Config) ->
    {feature_dirs, FeatureDirs} =
        case lists:keyfind(feature_dirs, 1, Config) of
            false -> application:get_env(damgage, feature_dirs, ["./features/"]);
            Val0 -> Val0
        end,
    FeatureDirs.

execute(Config, Context) ->
    {feature_include, FeatureInclude} = lists:keyfind(feature_include, 1, Config),
    lists:map(
        fun(FeatureDir) ->
            lists:map(
                fun(Filename) -> execute_file(Config, Context, Filename) end,
                filelib:wildcard(filename:join(FeatureDir, FeatureInclude))
            )
        end,
        get_feature_dir(Config)
    ).

execute(Config, Context, FeatureName) ->
    {feature_suffix, FeatureSuffix} =
        case lists:keyfind(feature_suffix, 1, Config) of
            false -> {feature_suffix, ".feature"};
            Val -> Val
        end,
    lists:map(
        fun(FeatureDir) ->
            lists:map(
                fun(Filename) -> execute_file(Config, Context, Filename) end,
                lists:map(
                    fun(FeatureFileName) -> filename:join(FeatureDir, FeatureFileName) end,
                    filelib:wildcard(
                        lists:flatten(FeatureName, FeatureSuffix),
                        FeatureDir
                    )
                )
            )
        end,
        get_feature_dir(Config)
    ).

init_logging(Config) ->
    {run_id, RunId} = lists:keyfind(run_id, 1, Config),
    {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
    Cfg =
        case proplists:get_value(dry_run, Config, false) of
            true -> #{};
            false -> #{file => filename:join(RunDir, "run.log")}
        end,

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
            config => Cfg
        }
    ).

deinit_logging(Config) ->
    {run_id, RunId} = lists:keyfind(run_id, 1, Config),
    logger:remove_handler(RunId).

parse_file(Filename) ->
    case file:read_file(Filename) of
        {ok, SourceBin} ->
            case egherkin:parse(SourceBin) of
                {ok, AST} ->
                    {ok, AST};
                {failed, Line, Message} ->
                    %% Build a pretty, humanized error (iolist) and log it.
                    Pretty = egherkin_pretty:format_failure(Filename, SourceBin, Line, Message),
                    %% Return the original failure plus a pretty blob for UIs/CLIs.
                    {failed, Line, Message, Pretty};
                Else ->
                    Else
            end;
        {error, Reason} ->
            ?LOG_ERROR("Could not read ~s: ~p", [Filename, Reason]),
            {error, {file_read_failed, Reason}}
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

execute_file(Config, Context, Filename) when is_map(Context) ->
    {run_id, RunId} = lists:keyfind(run_id, 1, Config),
    Concurrency = proplists:get_value(concurrency, Config, 1),
    StartTimestamp = date_util:now_to_seconds_hires(os:timestamp()),
    Parsed =
        try parse_file(Filename) of
            {ok, AST} -> AST;
            Other -> Other
        catch
            Class:Reason:Stack ->
                {parse_crashed, Class, Reason, Stack}
        end,
    case Parsed of
        {failed, LineNo, _Message, MessagePretty} ->
            ?LOG_DEBUG("parse file ~p", [Config]),
            formatter:format(Config, error, {LineNo, MessagePretty}),
            {parse_error, LineNo, MessagePretty};
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

            %% Decide Result early. Keep it JSON-safe because it is later
            %% included in run metadata and HTTP response maps.
            FailReason = maps:get(fail, FinalContext0, none),
            Result = result_value(FailReason),

            %% Use a stable “completed_at” in seconds for reaping
            CompletedAtSec = round(date_util:now_to_seconds(os:timestamp())),

            %% Write meta BEFORE IPFS add so it is included in ReportHash
            ok = write_run_meta(
                RunDir,
                #{
                    v => 1,
                    run_id => list_to_binary(RunId),
                    completed_at => CompletedAtSec,
                    start_time_hires => StartTimestamp,
                    end_time_hires => EndTimestamp,
                    execution_time_hires => (EndTimestamp - StartTimestamp),
                    result => Result
                }
            ),

            {ok, DamageApi} = application:get_env(damage, api_url),
            {ok, HashList} = damage_ipfs:add({directory, RunDir}),
            [#{<<"Hash">> := ReportHash}] =
                lists:filter(
                    fun(I) ->
                        #{<<"Hash">> := _Hash, <<"Name">> := Dir} = I,
                        string:equal(filename:join(["/", Dir]), RunDir)
                    end,
                    HashList
                ),
            [#{<<"Hash">> := FeatureHash}] =
                lists:filter(
                    fun(I) ->
                        #{<<"Hash">> := _Hash, <<"Name">> := Dir} = I,
                        FeatureFile = filename:join([RunDir, RunId ++ ".feature"]),
                        RunDir0 = filename:join(["/", Dir]),
                        string:equal(
                            FeatureFile, RunDir0
                        )
                    end,
                    HashList
                ),
            FeatureTitle = lists:nth(1, binary:split(Feature, <<"\n">>, [global])),
            FinalContext =
                maps:merge(
                    FinalContext0,
                    #{
                        run_id => list_to_binary(RunId),
                        feature_hash => FeatureHash,
                        report_hash => ReportHash,
                        feature_title => FeatureTitle,
                        public_key => maps:get(public_key, Context),
                        report_dir =>
                            to_bin(
                                string:join([DamageApi, "reports", binary_to_list(ReportHash)], "/")
                            )
                    }
                ),
            ResultStatus =
                case maps:get(fail, FinalContext, 0) of
                    0 ->
                        list_to_integer(
                            ?RESULT_STATUS_PREFIX_SUCCESS ++
                                integer_to_list(round(date_util:now_to_seconds(os:timestamp())))
                        );
                    _Something ->
                        list_to_integer(
                            ?RESULT_STATUS_PREFIX_FAIL ++
                                integer_to_list(round(date_util:now_to_seconds(os:timestamp())))
                        )
                end,
            PublicKey = maps:get(public_key, Context),
            RunRecord =
                #{
                    run_id => list_to_binary(RunId),
                    feature_hash => FeatureHash,
                    report_hash => ReportHash,
                    report_dir => maps:get(report_dir, FinalContext),
                    start_time => StartTimestamp,
                    execution_time => EndTimestamp - StartTimestamp,
                    end_time => EndTimestamp,
                    feature_title => FeatureTitle,
                    schedule_id =>
                        case lists:keyfind(schedule_id, 1, Config) of
                            {schedule_id, ScheduleId} -> ScheduleId;
                            false -> false
                        end,
                    result => Result,
                    public_key => PublicKey,
                    result_status => ResultStatus,
                    token_contract => maps:get(token_contract, FinalContext),
                    node_public_key => maps:get(node_public_key, FinalContext),
                    dry_run => proplists:get_value(dry_run, Config, false),
                    cost => damage_ae:get_spend(PublicKey),
                    spend => maps:get(step_spend, FinalContext, 0)
                },
            damage_webhooks:trigger_webhooks(FinalContext),
            %?LOG_DEBUG("RunRecord ~p", [RunRecord]),
            RunRecord;
        {error, enont} = Err ->
            ?LOG_ERROR("Feature file ~p not found.", [Filename]),
            Err;
        {parse_crashed, Class0, Reason0, Stack0} ->
            ?LOG_ERROR(
                "Feature parsing crashed for file ~p: ~p:~p ~p",
                [Filename, Class0, Reason0, Stack0]
            ),
            {error, {parse_crashed, Class0, Reason0}};
        Err ->
            ?LOG_ERROR("Feature parsing error file ~p .", [Filename]),
            Err
    end.

execute_feature_concurrent(_Args, 0, Acc) ->
    Acc;
execute_feature_concurrent(Args, N, Acc) ->
    execute_feature_concurrent(
        Args,
        N - 1,
        [
            %apply(?MODULE, execute_feature, Args)
            spawn(?MODULE, execute_feature, Args)
            | Acc
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
    init_logging(Config),
    %% BAN catch-all steps globally
    case ensure_no_catchall_steps(Config) of
        ok ->
            ok;
        {error, Errors} ->
            %% Convert to a fail context and stop executing scenarios.
            ?LOG_ERROR("Catch-all step(s) banned: ~p", [Errors]),
            formatter:format(
                Config, error, {LineNo, io_lib:format("Catch-all steps banned: ~p", [Errors])}
            ),
            deinit_logging(Config),
            %% mark failure in context so run is red
            throw({catchall_steps_banned, Errors})
    end,

    formatter:format(Config, feature, {FeatureName, LineNo, Tags, Description}),
    FinalContext =
        run_fold(
            Config,
            fun(Scenario, AccContext) ->
                ScenarioBase = clear_step_control(AccContext),
                ScenarioContext = execute_scenario(Config, ScenarioBase, BackGround, Scenario),

                case maps:get(fail, ScenarioContext, none) of
                    none ->
                        maps:merge(AccContext, clear_step_control(ScenarioContext));
                    Fail ->
                        maps:put(
                            fail,
                            Fail,
                            maps:put(
                                failing_step,
                                maps:get(failing_step, ScenarioContext, undefined),
                                AccContext
                            )
                        )
                end
            end,
            FeatureContext,
            Scenarios
        ),
    deinit_logging(Config),
    FinalContext.

continue_on_fail(Config) ->
    proplists:get_value(continue_on_fail, Config, false) =:= true.

run_fold(Config, Fun, Acc, Items) ->
    case continue_on_fail(Config) of
        true ->
            lists:foldl(Fun, Acc, Items);
        false ->
            fold_until_fail(Fun, Acc, Items)
    end.

fold_until_fail(_Fun, #{fail := _} = Context, _Items) ->
    Context;
fold_until_fail(_Fun, Context, []) ->
    Context;
fold_until_fail(Fun, Context, [Item | Rest]) ->
    case Fun(Item, Context) of
        #{fail := _} = Failed ->
            Failed;
        NextContext ->
            fold_until_fail(Fun, NextContext, Rest)
    end.

execute_steps(Config, Context, Steps) ->
    run_fold(
        Config,
        fun(Step, AccContext) ->
            execute_step(Config, Step, AccContext)
        end,
        Context,
        Steps
    ).

execute_scenario(Config, Context, undefined, Scenario) ->
    execute_scenario(Config, Context, {none, []}, Scenario);
execute_scenario(Config, Context, [], Scenario) ->
    execute_scenario(Config, Context, {none, []}, Scenario);
execute_scenario(Config, Context, BackGround, Scenario0) ->
    BackGroundSteps = background_steps(BackGround),
    case normalize_scenario(Scenario0) of
        {ok, LineNo, ScenarioName, Tags, Steps0, ScenarioExamples} ->
            Steps = normalize_steps(Steps0),
            case extract_outline_examples(ScenarioName, Steps, ScenarioExamples) of
                {outline, Steps1, Rows} ->
                    execute_scenario_outline(
                        Config,
                        Context,
                        BackGroundSteps,
                        LineNo,
                        ScenarioName,
                        Tags,
                        Steps1,
                        Rows
                    );
                normal ->
                    formatter:format(Config, scenario, {ScenarioName, LineNo, Tags}),
                    execute_steps(
                        Config,
                        Context,
                        lists:append(BackGroundSteps, Steps)
                    )
            end;
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Unsupported scenario/background shape: scenario=~p background=~p reason=~p",
                    [Scenario0, BackGround, Reason]
                ),
                Context
            )
    end.

normalize_scenario([Scenario]) ->
    normalize_scenario(Scenario);
normalize_scenario(Scenario) when is_tuple(Scenario) ->
    normalize_scenario_tuple(tuple_to_list(Scenario));
normalize_scenario(Other) ->
    {error, {unsupported_scenario_term, Other}}.

normalize_scenario_tuple([LineNo, ScenarioName, Tags, Steps | Rest]) when is_integer(LineNo) ->
    {Steps0, ScenarioExamples} = split_scenario_tail([Steps | Rest]),
    {ok, LineNo, ScenarioName, normalize_tags(Tags), Steps0, ScenarioExamples};
normalize_scenario_tuple([LineNo, ScenarioName, Steps]) when is_integer(LineNo) ->
    {ok, LineNo, ScenarioName, [], Steps, none};
normalize_scenario_tuple(Other) ->
    {error, {unsupported_scenario_tuple, Other}}.

normalize_tags(Tags) when is_list(Tags) ->
    Tags;
normalize_tags(undefined) ->
    [];
normalize_tags(Tag) ->
    [Tag].

split_scenario_tail(Tail) ->
    {Examples, StepPartsRev} =
        lists:foldl(
            fun
                ({datatable, _Rows} = Table, {none, Acc}) ->
                    {Table, Acc};
                ({datatable, _Rows}, {Seen, Acc}) ->
                    {Seen, Acc};
                (Part, {Seen, Acc}) ->
                    {Seen, [Part | Acc]}
            end,
            {none, []},
            Tail
        ),
    StepParts = lists:reverse(StepPartsRev),
    Steps =
        case StepParts of
            [Only] -> Only;
            _ -> StepParts
        end,
    {Steps, Examples}.

background_steps(undefined) ->
    [];
background_steps([]) ->
    [];
background_steps({none, Steps}) ->
    normalize_steps(Steps);
background_steps({_LineNo, Steps}) ->
    normalize_steps(Steps);
background_steps({_LineNo, _Name, Steps}) ->
    normalize_steps(Steps);
background_steps({_LineNo, _Name, _Tags, Steps}) ->
    normalize_steps(Steps);
background_steps(BackGround) when is_tuple(BackGround) ->
    background_steps_from_tuple(tuple_to_list(BackGround));
background_steps(Steps) when is_list(Steps) ->
    normalize_steps(Steps);
background_steps(_Other) ->
    [].

background_steps_from_tuple([]) ->
    [];
background_steps_from_tuple(Parts) ->
    case lists:reverse(Parts) of
        [Steps | _] -> normalize_steps(Steps);
        [] -> []
    end.

normalize_steps(Steps) when is_list(Steps) ->
    normalize_steps(Steps, []);
normalize_steps(Other) ->
    [Other].

normalize_steps([], Acc) ->
    lists:reverse(Acc);
%% egherkin can emit a datatable as the next AST item after the step it belongs
%% to. Attach it to the previous step instead of letting table rows be executed
%% as steps by the formatter/runner.
normalize_steps([{LineNo, Keyword, Body}, {datatable, Rows} | Rest], Acc) ->
    normalize_steps(Rest, [{LineNo, Keyword, Body, {datatable, normalize_table_rows(Rows)}} | Acc]);
normalize_steps([{LineNo, Keyword, Body, Args0}, {datatable, Rows} | Rest], Acc) ->
    Args =
        case normalize_step_args(Args0) of
            [] -> {datatable, normalize_table_rows(Rows)};
            <<>> -> {datatable, normalize_table_rows(Rows)};
            _ -> Args0
        end,
    normalize_steps(Rest, [{LineNo, Keyword, Body, Args} | Acc]);
normalize_steps([{LineNo, Keyword, Body, {datatable, Rows}} | Rest], Acc) ->
    normalize_steps(Rest, [{LineNo, Keyword, Body, {datatable, normalize_table_rows(Rows)}} | Acc]);
normalize_steps([{_LineNo, _Keyword, _Body, _Args} = Step | Rest], Acc) ->
    normalize_steps(Rest, [Step | Acc]);
normalize_steps([{datatable, Rows} | Rest], Acc) ->
    normalize_steps(Rest, [{datatable, normalize_table_rows(Rows)} | Acc]);
normalize_steps([Nested | Rest], Acc) when is_list(Nested) ->
    case {outline_charlist(Nested), contains_step_ast(Nested)} of
        {true, _} ->
            %% A charlist is text, not a nested step list. It should not normally
            %% appear at step-list level, but preserve it rather than exploding.
            normalize_steps(Rest, [Nested | Acc]);
        {false, true} ->
            normalize_steps(Rest, lists:reverse(normalize_steps(Nested)) ++ Acc);
        {false, false} ->
            %% This is most commonly a raw datatable row/list. Do not execute it
            %% as a step.
            normalize_steps(Rest, Acc)
    end;
normalize_steps([Other | Rest], Acc) ->
    normalize_steps(Rest, [Other | Acc]).

extract_outline_examples(ScenarioName, Steps0, ScenarioExamples) ->
    Steps = normalize_steps(Steps0),
    Keys = placeholder_keys({ScenarioName, Steps}),
    case normalize_datatable(ScenarioExamples) of
        {datatable, Rows0} ->
            case outline_rows(Keys, normalize_table_rows(Rows0)) of
                {ok, Header, DataRows} ->
                    {outline, Steps, [Header | DataRows]};
                none ->
                    normal
            end;
        none ->
            extract_outline_examples_from_steps(ScenarioName, Steps)
    end.

extract_outline_examples_from_steps(ScenarioName, Steps0) ->
    Steps = normalize_steps(Steps0),
    Keys = placeholder_keys({ScenarioName, Steps}),
    case split_outline_datatable(Keys, Steps) of
        {Steps1, Rows0} ->
            case outline_rows(Keys, normalize_table_rows(Rows0)) of
                {ok, Header, DataRows} ->
                    {outline, Steps1, [Header | DataRows]};
                none ->
                    normal
            end;
        none ->
            normal
    end.

split_outline_datatable(Keys, Steps) ->
    split_outline_datatable(Keys, Steps, []).

split_outline_datatable(_Keys, [], _Acc) ->
    none;

%% Examples attached as explicit datatable arg.
split_outline_datatable(_Keys, [{LineNo, Keyword, Body, {datatable, Rows}} | Rest], Acc) ->
    Steps = lists:reverse(Acc) ++ [{LineNo, Keyword, Body} | Rest],
    {Steps, Rows};

%% Examples already decoded as plain step args/table rows.
%% Only steal these args when they can actually bind the scenario placeholders.
split_outline_datatable(Keys, [{LineNo, Keyword, Body, Args0} = Step | Rest], Acc) ->
    case outline_arg_rows(Keys, Args0) of
        {ok, Rows} ->
            Steps = lists:reverse(Acc) ++ [{LineNo, Keyword, Body} | Rest],
            {Steps, Rows};
        none ->
            split_outline_datatable(Keys, Rest, [Step | Acc])
    end;

%% Examples emitted as standalone datatable item.
split_outline_datatable(_Keys, [{datatable, Rows} | Rest], Acc) ->
    Steps = lists:reverse(Acc) ++ Rest,
    {Steps, Rows};

split_outline_datatable(Keys, [Step | Rest], Acc) ->
    split_outline_datatable(Keys, Rest, [Step | Acc]).

outline_arg_rows([], _Args) ->
    none;
outline_arg_rows(Keys, Args0) ->
    Rows = normalize_table_rows(Args0),
    case outline_rows(Keys, Rows) of
        {ok, Header, DataRows} ->
            {ok, [Header | DataRows]};
        none ->
            none
    end.

placeholder_keys(Term) ->
    ordsets:from_list(placeholder_keys(Term, [])).

placeholder_keys(Bin, Acc) when is_binary(Bin) ->
    placeholder_keys_from_binary(Bin, Acc);
placeholder_keys(List, Acc) when is_list(List) ->
    case outline_charlist(List) of
        true ->
            placeholder_keys_from_binary(outline_bin(List), Acc);
        false ->
            lists:foldl(fun placeholder_keys/2, Acc, List)
    end;
placeholder_keys(Tuple, Acc) when is_tuple(Tuple) ->
    lists:foldl(fun placeholder_keys/2, Acc, tuple_to_list(Tuple));
placeholder_keys(_Other, Acc) ->
    Acc.

placeholder_keys_from_binary(Bin, Acc) ->
    case binary:split(Bin, <<"<">>) of
        [_] ->
            Acc;
        [_Before, Rest0] ->
            case binary:split(Rest0, <<">">>) of
                [Key0, Rest] ->
                    placeholder_keys_from_binary(Rest, [outline_key(Key0) | Acc]);
                _ ->
                    Acc
            end
    end.

outline_rows([], _Rows) ->
    none;
outline_rows(Keys, [First | Rest] = Rows) ->
    Header = [outline_key(K) || K <- normalize_table_row(First)],
    case header_matches(Keys, Header) of
        true ->
            {ok, Header, Rest};
        false ->
            case {Keys, one_column_rows(Rows)} of
                {[OnlyKey], true} ->
                    %% No-header examples table for one placeholder.
                    {ok, [OnlyKey], Rows};
                _ ->
                    none
            end
    end;
outline_rows(_Keys, []) ->
    none.

header_matches(Keys, Header) ->
    lists:all(fun(K) -> lists:member(K, Header) end, Keys).

one_column_rows(Rows) ->
    lists:all(
        fun(Row) ->
            length(normalize_table_row(Row)) =:= 1
        end,
        Rows
    ).

normalize_datatable({datatable, Rows}) ->
    {datatable, normalize_table_rows(Rows)};
normalize_datatable(_) ->
    none.

normalize_table_rows({datatable, Rows}) ->
    normalize_table_rows(Rows);
normalize_table_rows([Header0, Rows0]) when is_list(Header0), is_list(Rows0) ->
    Header = normalize_table_row(Header0),
    case table_rows_list(Rows0, length(Header)) of
        true ->
            [Header | [normalize_table_row(Row) || Row <- Rows0]];
        false ->
            [Header, normalize_table_row(Rows0)]
    end;
normalize_table_rows(Rows) when is_list(Rows) ->
    [normalize_table_row(Row) || Row <- Rows];
normalize_table_rows(_Other) ->
    [].

table_rows_list([First | _], HeaderLen) when is_list(First) ->
    case outline_charlist(First) of
        true -> false;
        false -> length(normalize_table_row(First)) =:= HeaderLen
    end;
table_rows_list(_Rows, _HeaderLen) ->
    false.

normalize_table_row(Row) when is_list(Row) ->
    case outline_charlist(Row) of
        true ->
            [normalize_table_cell(Row)];
        false ->
            [normalize_table_cell(Cell) || Cell <- Row]
    end;
normalize_table_row(Cell) ->
    [normalize_table_cell(Cell)].

normalize_table_cell([Value]) ->
    normalize_table_cell(Value);
normalize_table_cell(Value) when is_binary(Value) ->
    Value;
normalize_table_cell(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
normalize_table_cell(Value) when is_integer(Value) ->
    integer_to_binary(Value);
normalize_table_cell(Value) when is_float(Value) ->
    list_to_binary(io_lib:format("~p", [Value]));
normalize_table_cell(Value) when is_list(Value) ->
    case outline_charlist(Value) of
        true -> unicode:characters_to_binary(Value);
        false -> iolist_to_binary([normalize_table_cell(V) || V <- Value])
    end;
normalize_table_cell(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

execute_scenario_outline(_Config, Context, _BackGroundSteps, _LineNo, _Name, _Tags, _Steps, []) ->
    Context;
execute_scenario_outline(
    Config, Context, BackGroundSteps, LineNo, ScenarioName, Tags, Steps, Rows0
) ->
    Keys = placeholder_keys({ScenarioName, Steps}),
    case normalize_table_rows(Rows0) of
        [] ->
            Context;
        [Header | DataRows] ->
            run_fold(
                Config,
                fun(Row, ContextAcc) ->
                    RowBase = clear_step_control(ContextAcc),
                    Vars0 = scenario_outline_vars(Header, Row),
                    Vars = complete_outline_vars(Keys, Vars0, Row),
                    ScenarioName0 = scenario_outline_replace(ScenarioName, Vars),
                    Steps0 = scenario_outline_replace(Steps, Vars),

                    case placeholder_keys({ScenarioName0, Steps0}) of
                        [] ->
                            formatter:format(Config, scenario, {ScenarioName0, LineNo, Tags}),
                            RowContext =
                                execute_steps(
                                    Config,
                                    RowBase,
                                    lists:append(BackGroundSteps, Steps0)
                                ),

                            case maps:get(fail, RowContext, none) of
                                none ->
                                    maps:merge(ContextAcc, clear_step_control(RowContext));
                                Fail ->
                                    maps:put(
                                        fail,
                                        Fail,
                                        maps:put(
                                            failing_step,
                                            maps:get(failing_step, RowContext, undefined),
                                            ContextAcc
                                        )
                                    )
                            end;
                        Left ->
                            maps:put(
                                fail,
                                {outline_placeholder_unresolved, Left, Vars, Header, Row},
                                ContextAcc
                            )
                    end
                end,
                Context,
                DataRows
            )
    end.
complete_outline_vars(Keys, Vars0, Row) ->
    Missing = [K || K <- Keys, not maps:is_key(K, Vars0)],
    Row0 = normalize_table_row(Row),
    case {Missing, Row0} of
        {[OnlyKey], [OnlyValue]} ->
            maps:put(OnlyKey, outline_bin(OnlyValue), Vars0);
        _ ->
            Vars0
    end.
scenario_outline_vars(Header, Row) ->
    maps:from_list(
        [
            {outline_key(K), outline_bin(V)}
         || {K, V} <- lists:zip(normalize_table_row(Header), normalize_table_row(Row))
        ]
    ).


scenario_outline_replace(Bin, Vars) when is_binary(Bin) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            binary:replace(Acc, <<"<", Key/binary, ">">>, Value, [global])
        end,
        Bin,
        Vars
    );
scenario_outline_replace(List, Vars) when is_list(List) ->
    case outline_charlist(List) of
        true ->
            binary_to_list(scenario_outline_replace(outline_bin(List), Vars));
        false ->
            [scenario_outline_replace(Item, Vars) || Item <- List]
    end;
scenario_outline_replace(Tuple, Vars) when is_tuple(Tuple) ->
    list_to_tuple([scenario_outline_replace(Item, Vars) || Item <- tuple_to_list(Tuple)]);
scenario_outline_replace(Other, _Vars) ->
    Other.

outline_bin(V) when is_binary(V) -> V;
outline_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
outline_bin(V) when is_integer(V) -> integer_to_binary(V);
outline_bin(V) when is_float(V) -> list_to_binary(io_lib:format("~p", [V]));
outline_bin(V) when is_list(V) -> normalize_table_cell(V);
outline_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

outline_key(V) ->
    K0 = string:trim(outline_bin(V)),
    K1 = strip_wrapping(K0, <<"\"">>, <<"\"">>),
    K2 = strip_wrapping(K1, <<"'">>, <<"'">>),
    strip_wrapping(K2, <<"<">>, <<">">>).

strip_wrapping(Bin, Left, Right) when is_binary(Bin) ->
    L = byte_size(Left),
    R = byte_size(Right),
    Size = byte_size(Bin),
    case
        Size >= L + R andalso
            binary:part(Bin, 0, L) =:= Left andalso
            binary:part(Bin, Size - R, R) =:= Right
    of
        true -> binary:part(Bin, L, Size - L - R);
        false -> Bin
    end.

outline_charlist([]) ->
    true;
outline_charlist([H | T]) when is_integer(H) ->
    outline_charlist(T);
outline_charlist(_) ->
    false.

% step execution: should execution output be passed in state and then
% handled OR should the handling happen withing the execution function
execute_step_function(
    Config,
    #{public_key := _AeAccount} = Context,
    {StepKeyWord, LineNo, Body, Args} = _Step,
    StepModule
) ->
    StepModule0 = normalize_step_module(StepModule),
    case proplists:get_value(dry_run, Config) of
        true ->
            apply(
                StepModule0,
                step_dry,
                [Config, Context, StepKeyWord, LineNo, Body, Args]
            );
        _ ->
            %?LOG_DEBUG("execute_step_function ~p ~p", [StepModule0, Body]),
            apply(
                StepModule0,
                step,
                [Config, Context, StepKeyWord, LineNo, Body, Args]
            )
    end.

normalize_step_module(M) when is_atom(M) ->
    M;
normalize_step_module(M) when is_binary(M) ->
    binary_to_atom(M, utf8);
normalize_step_module(M) when is_list(M) ->
    list_to_atom(M).
execute_step_module(
    Config,
    #{public_key := AeAccount} = ContextIn,
    {StepKeyWord, LineNo, Body, Args} = Step,
    StepModule
) ->
    try execute_step_function(Config, ContextIn, Step, StepModule) of
        Context when is_map(Context) ->
            Context0 = maps:put(step_found, true, Context),
            metrics:update(success, AeAccount),
            Context0;
        {throw, Reason, Stack} ->
            ?LOG_ERROR("Step execution failed! ~p", [
                #{
                    reason => result_reason(Reason),
                    stacktrace => Stack,
                    step => Step,
                    step_module => StepModule
                }
            ]),
            metrics:update(fail, AeAccount),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, Reason}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            );
        {error, Reason, Stacktrace} ->
            metrics:update(fail, AeAccount),
            ?LOG_ERROR("Step execution failed! ~p", [Stacktrace]),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, Reason}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            );
        {Error, _Reason0, Stacktrace} ->
            Reason = damage_utils:strf(<<"invalid context from ~p ~p ~p">>, [
                StepModule, Step, Error
            ]),
            metrics:update(fail, AeAccount),
            ?LOG_ERROR("Step execution failed! unhandled ~p ~p", [Error, Stacktrace]),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, <<"Unhandled Error">>}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            );
        unauthorized ->
            Reason = damage_utils:strf(<<"Unauthorized to execute step ~p ~p.">>, [
                StepModule, Step
            ]),
            metrics:update(fail, AeAccount),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, <<"Unauthorized">>}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            );
        Other ->
            Reason = damage_utils:strf(<<"invalid context from ~p ~p ~p">>, [
                StepModule, Step, Other
            ]),
            metrics:update(fail, AeAccount),
            ?LOG_ERROR("Step execution failed! unhandled other ~p", [Other]),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, <<"Unhandled Exception">>}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            )
    catch
        error:undef:Stacktrace ->
            case Stacktrace of
                [{_Module, step_dry, _, _} | _] ->
                    maps:put(step_found, false, ContextIn);
                [{_Module, step, _, _} | _] ->
                    maps:put(step_found, false, ContextIn);
                _ ->
                    Reason = <<"Step undef error">>,
                    ?LOG_ERROR("Step execution undef! ~p", [
                        #{
                    reason => result_reason(Reason),
                            stacktrace => Stacktrace,
                            step => Step,
                            step_module => StepModule
                        }
                    ]),
                    metrics:update(fail, AeAccount),
                    formatter:format(
                        Config,
                        step,
                        {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, Reason}}
                    ),
                    maps:put(
                        step_found,
                        false,
                        maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
                    )
            end;
        error:function_clause:Stacktrace ->
            case Stacktrace of
                [{_Module, step_dry, _, _Loc} | _] ->
                    maps:put(step_found, false, ContextIn);
                [{_Module, step, _, _Loc} | _] ->
                    maps:put(step_found, false, ContextIn);
                _ ->
                    Reason = <<"Step error">>,
                    ?LOG_ERROR("Step execution failed! ~p", [
                        #{
                    reason => result_reason(Reason),
                            stacktrace => Stacktrace,
                            step => Step,
                            step_module => StepModule
                        }
                    ]),
                    metrics:update(fail, AeAccount),
                    formatter:format(
                        Config,
                        step,
                        {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, Reason}}
                    ),
                    maps:put(
                        step_found,
                        false,
                        maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
                    )
            end;
        Class:Reason:Stacktrace ->
            ?LOG_ERROR("Step execution crashed! ~p", [
                #{
                    class => Class,
                    reason => result_reason(Reason),
                    stacktrace => Stacktrace,
                    step => Step,
                    step_module => StepModule
                }
            ]),
            metrics:update(fail, AeAccount),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body, Args, ContextIn, {fail, Reason}}
            ),
            maps:put(
                step_found,
                true,
                maps:put(failing_step, Step, maps:put(fail, Reason, ContextIn))
            )
    end.

hits_to_damage(Hits) ->
    Hits / 100000000.
step_spend(Context) ->
    Spend = maps:get(step_spend, Context, 1 * math:pow(10, ?DAMAGE_DECIMALS)),
    damage_ae:spend(maps:get(public_key, Context), Spend),
    maps:remove(step_spend, Context).
normalize_step({LineNo, StepKeyWord, Body}) ->
    {LineNo, StepKeyWord, Body, []};
normalize_step({LineNo, StepKeyWord, Body, Args}) ->
    {LineNo, StepKeyWord, Body, normalize_step_args(Args)}.

contains_step_ast([]) ->
    false;
contains_step_ast([{datatable, _Rows} | _]) ->
    true;
contains_step_ast([{LineNo, _Keyword, _Body} | _]) when is_integer(LineNo) ->
    true;
contains_step_ast([{LineNo, _Keyword, _Body, _Args} | _]) when is_integer(LineNo) ->
    true;
contains_step_ast([Nested | Rest]) when is_list(Nested) ->
    contains_step_ast(Nested) orelse contains_step_ast(Rest);
contains_step_ast([_Other | Rest]) ->
    contains_step_ast(Rest).

normalize_step_args({datatable, Rows}) ->
    normalize_table_rows(Rows);
normalize_step_args({docstring, Body}) ->
    Body;
normalize_step_args({text, Body}) ->
    Body;
normalize_step_args(undefined) ->
    [];
normalize_step_args(Args) ->
    Args.

merge_step_args(RenderedArgs, StepArgs0) ->
    case normalize_step_args(StepArgs0) of
        [] -> RenderedArgs;
        <<>> -> RenderedArgs;
        StepArgs -> StepArgs
    end.

execute_step(Config, Step, [Context]) ->
    execute_step(Config, Step, Context);
execute_step(Config, Step, #{fail := _} = Context) ->
    {LineNo, StepKeyWord, Body, StepArgs} = normalize_step(Step),
    case damage_context:render_body_args(Body, Context) of
        {error, {Body1, Args1}, Reason} ->
            Args2 = merge_step_args(Args1, StepArgs),
            ?LOG_DEBUG("execute_step fail error: ~p, ~p.", [Body1, Args2]),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args2, Context, {fail, Reason}}
            ),
            Context;
        {ok, {Body1, Args1}} ->
            Args2 = merge_step_args(Args1, StepArgs),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args2, Context, skip}
            ),
            Context
    end;
execute_step(Config, Step, Context) ->
    {LineNo, StepKeyWord, Body, StepArgs} = normalize_step(Step),
    case damage_context:render_body_args(Body, Context) of
        {error, {Body1, Args1}, Reason} ->
            Args2 = merge_step_args(Args1, StepArgs),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args2, Context, {fail, Reason}}
            ),
            metrics:update(fail, maps:get(public_key, Context)),
            maps:put(failing_step, tuple_to_list(Step), Context);
        {ok, {Body1, Args1}} ->
            Args2 = merge_step_args(Args1, StepArgs),
            case placeholder_keys({Body1, Args2}) of
                [] ->
                    execute_step_resolved(Config, Context, Step, LineNo, StepKeyWord, Body1, Args2);
                Left ->
                    maps:put(
                        fail,
                        {unresolved_step_placeholder, Left, StepKeyWord, Body1, Args2},
                        maps:put(failing_step, Step, Context)
                    )
            end
    end.

execute_step_resolved(Config, Context, Step, LineNo, StepKeyWord, Body1, Args2) ->
    case
                lists:foldl(
                    fun
                        (StepModule, #{step_found := false} = ContextIn) ->
                            Step0 = {StepKeyWord, LineNo, Body1, Args2},
                            case execute_step_module(Config, ContextIn, Step0, StepModule) of
                                #{failing_step := _} = Context1 ->
                                    Context1;
                                #{step_found := true, fail := Err} = Context1 ->
                                    formatter:format(
                                        Config,
                                        step,
                                        {StepKeyWord, LineNo, Body1, Args2, Context1, {fail, Err}}
                                    ),
                                    maps:put(failing_step, Step0, Context1);
                                #{step_found := false} = Context1 ->
                                    Context1;
                                #{step_found := true} = Context1 ->
                                    Success =
                                        case proplists:get_value(dry_run, Config) of
                                            true -> dry;
                                            _ -> success
                                        end,
                                    formatter:format(
                                        Config,
                                        step,
                                        {StepKeyWord, LineNo, Body1, Args2, Context1, Success}
                                    ),
                                    Context1
                            end;
                        (_StepModule, #{step_found := true} = ContextIn) ->
                            ContextIn
                    end,
                    maps:remove(fail, maps:put(step_found, false, Context)),
                    damage_utils:loaded_steps()
                )
            of
                Context2 when is_map(Context2) ->
                    Context0 = step_spend(Context2),

                    case maps:get(step_found, Context0) of
                        false ->
                            ?LOG_ERROR("execute_step notfound :~p ~p ", [StepKeyWord, Body1]),
                            formatter:format(
                                Config,
                                step,
                                {StepKeyWord, LineNo, Body1, Args2, Context, notfound}
                            ),
                            metrics:update(notfound, maps:get(public_key, Context)),
                            maps:put(
                                fail,
                                {step_not_found, StepKeyWord, Body1},
                                maps:put(failing_step, Step, Context)
                            );
                        true ->
                            Context0
                    end;
                Other ->
                    ?LOG_ERROR("execute_step error :~p ~p ~p", [StepKeyWord, Body1, Other]),
                    formatter:format(
                        Config,
                        step,
                        {StepKeyWord, LineNo, Body1, Args2, Context, invalid_context}
                    ),
                    metrics:update(notfound, maps:get(public_key, Context)),
                    maps:put(failing_step, Step, Context)
    end.

clear_step_control(Context) ->
    maps:remove(
        step_found,
        maps:remove(
            failing_step,
            maps:remove(fail, Context)
        )
    ).
check_setup() ->
    ok =
        case secrets:retrieve_decrypt(nostr_nsec) of
            {ok, _} ->
                ok;
            _ ->
                case erm:ask_password("Nostr Nsec for nostr integration.") of
                    undefined ->
                        ?LOG_WARNING("Nost Nsec not set, nostr functions will not work.", []),
                        ok;
                    Nsec ->
                        ok = secrets:encrypt_store(nostr_nsec, Nsec)
                end
        end,
    ok =
        case secrets:retrieve_decrypt(bitcoin_rpc_password) of
            {ok, _} ->
                ok;
            _ ->
                case erm:ask_password("Bitcoin rpc_password for bitcoin integration.") of
                    undefined ->
                        ?LOG_WARNING(
                            "Bitcoin rpc_password for bitcoin integration not set, bitcoin functions will not work.",
                            []
                        ),
                        ok;
                    BitcoinRpcPassword ->
                        ok = secrets:encrypt_store(bitcoin_rpc_password, BitcoinRpcPassword)
                end
        end,
    ok =
        case secrets:retrieve_decrypt(lnd_macaroon) of
            {ok, _} ->
                ok;
            _ ->
                case erm:ask_password("lnd macaroon for lnd integration.") of
                    undefined ->
                        ?LOG_WARNING(
                            "lnd macaroon for lnd integration not set, lnd functions will not work.",
                            []
                        ),
                        ok;
                    Macaroon ->
                        ok = secrets:encrypt_store(lnd_macaroon, Macaroon)
                end
        end,
    ok =
        case secrets:retrieve_decrypt(cln_rune) of
            {ok, _} ->
                ok;
            _ ->
                case erm:ask_password("cln rune for core lightning integration.") of
                    undefined ->
                        ?LOG_WARNING(
                            "cln rune for core lightning integration, cln functions will not work.",
                            []
                        ),
                        ok;
                    Rune ->
                        ok = secrets:encrypt_store(cln_rune, Rune)
                end
        end,
    ok =
        case secrets:retrieve_decrypt(smtp_pass) of
            {ok, _} ->
                ok;
            _ ->
                case erm:ask_password("smtp password for smtp integration.") of
                    undefined ->
                        ?LOG_WARNING(
                            "smtp password for smtp integration, smtp functions will not work.", []
                        ),
                        ok;
                    SmtpPassword ->
                        ok = secrets:encrypt_store(smtp_pass, SmtpPassword)
                end
        end.
write_run_meta(RunDir, MetaMap) ->
    %% Keep it stable + easy to parse.
    Bin = jsx:encode(MetaMap),
    file:write_file(filename:join(RunDir, "run.meta"), Bin).

result_value(none) ->
    <<"success">>;
result_value(FailReason) ->
    fmt(FailReason).

result_reason(none) ->
    <<>>;
result_reason(FailReason) ->
    fmt(FailReason).
fmt(T) ->
    iolist_to_binary(io_lib:format("~p", [T])).

%% -------------------------------------------------------------------
%% Catch-all step ban (no fallbacks / catchalls allowed)
%% -------------------------------------------------------------------

-define(STEP_CATCHALL_CACHE_KEY, {damage, step_catchall_checked}).
get_module_md5(M) ->
    try
        M:module_info(md5)
    catch
        _:_ -> undefined
    end.

ensure_no_catchall_steps(Config) ->
    Modules = damage_utils:loaded_steps(),
    CacheKey = ?STEP_CATCHALL_CACHE_KEY,
    Cache0 =
        case persistent_term:get(CacheKey, undefined) of
            undefined -> #{};
            M when is_map(M) -> M
        end,

    {Cache1, Errors} =
        lists:foldl(
            fun(M, {AccCache, AccErrs}) ->
                Md5 = get_module_md5(M),
                case maps:get(M, AccCache, undefined) of
                    Md5 ->
                        %% unchanged → skip re-check
                        {AccCache, AccErrs};
                    _ ->
                        case check_module_for_catchall_steps(Config, M) of
                            ok ->
                                {maps:put(M, Md5, AccCache), AccErrs};
                            {error, Why} ->
                                {maps:put(M, Md5, AccCache), [{M, Why} | AccErrs]}
                        end
                end
            end,
            {Cache0, []},
            Modules
        ),

    persistent_term:put(CacheKey, Cache1),

    case Errors of
        [] -> ok;
        _ -> {error, lists:reverse(Errors)}
    end.

check_module_for_catchall_steps(Config, M) ->
    %% If module isn't loaded yet, code:which/1 still works.
    case code:which(M) of
        non_existing ->
            %% ignore
            ok;
        BeamPath ->
            case beam_lib:chunks(BeamPath, [abstract_code]) of
                {ok, {M, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
                    case find_catchall_in_forms(Forms) of
                        none -> ok;
                        {found, FunName, Line} -> {error, {catchall_step_banned, FunName, Line}}
                    end;
                {ok, {M, [{abstract_code, no_abstract_code}]}} ->
                    %% Policy choice:
                    case proplists:get_value(strict_no_catchall, Config, true) of
                        true -> {error, {no_debug_info, M}};
                        false -> ok
                    end;
                {error, Reason} ->
                    %% If we can't inspect, choose strict or warn.
                    case proplists:get_value(strict_no_catchall, Config, true) of
                        true -> {error, {beam_inspect_failed, Reason}};
                        false -> ok
                    end
            end
    end.

find_catchall_in_forms(Forms) ->
    %% Look for step/6 and step_dry/6, and any clause with 6 var patterns.
    case
        lists:filtermap(
            fun
                ({function, Line, step, 6, Clauses}) ->
                    case clause_list_has_catchall(Clauses) of
                        true -> {true, {found, step, Line}};
                        false -> false
                    end;
                %({function, Line, step_dry, 6, Clauses}) ->
                %    case clause_list_has_catchall(Clauses) of
                %        true -> {true, {found, step_dry, Line}};
                %        false -> false
                %    end;
                (_) ->
                    false
            end,
            Forms
        )
    of
        [Hit | _] -> Hit;
        [] -> none
    end.

clause_list_has_catchall(Clauses) ->
    lists:any(
        fun
            ({clause, _Line, Pats, _Guards, _Body}) when is_list(Pats), length(Pats) =:= 6 ->
                lists:all(fun is_var_pat/1, Pats);
            (_) ->
                false
        end,
        Clauses
    ).

%% underscore
is_var_pat({var, _, '_'}) -> true;
%% any variable
is_var_pat({var, _, _Name}) -> true;
is_var_pat(_) -> false.

