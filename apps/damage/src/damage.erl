-module(damage).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
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
-export([check_setup/0]).
-export([parse_file/1]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    ?LOG_INFO("Server ~p starting.~n", [self()]),
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

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
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
    case catch parse_file(Filename) of
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

            %% Decide Result early (you already do this later)
            Result =
                case maps:get(fail, FinalContext0, none) of
                    none -> <<"success">>;
                    R0 when is_list(R0) -> list_to_binary(R0);
                    R1 -> R1
                end,

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
                            string:join([DamageApi, "reports", ReportHash], "/")
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
                    public_key => maps:get(public_key, Context),
                    result_status => ResultStatus,
                    token_contract => maps:get(token_contract, FinalContext),
                    node_public_key => maps:get(node_public_key, FinalContext),
                    dry_run => maps:get(dry_run, FinalContext, false),
                    cost => maps:get(cost, FinalContext, 0),
                    spend => maps:get(step_spend, FinalContext, 0)
                },
            damage_webhooks:trigger_webhooks(FinalContext),
            RunRecord;
        {error, enont} = Err ->
            ?LOG_ERROR("Feature file ~p not found.", [Filename]),
            Err;
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
        lists:foldl(
            fun(Scenario, Context) ->
                execute_scenario(Config, Context, BackGround, Scenario)
            end,
            FeatureContext,
            Scenarios
        ),
    deinit_logging(Config),
    FinalContext.

execute_scenario(Config, Context, undefined, Scenario) ->
    execute_scenario(Config, Context, {none, []}, Scenario);
execute_scenario(Config, Context, [], Scenario) ->
    execute_scenario(Config, Context, {none, []}, Scenario);
execute_scenario(Config, Context, {_, BackGroundSteps}, Scenario) ->
    {LineNo, ScenarioName, Tags, Steps} = Scenario,
    formatter:format(Config, scenario, {ScenarioName, LineNo, Tags}),
    lists:foldl(
        fun(S, C) -> execute_step(Config, S, C) end,
        Context,
        lists:append(BackGroundSteps, Steps)
    ).

% step execution: should execution output be passed in state and then
% handled OR should the handling happen withing the execution function
execute_step_function(
    Config,
    #{public_key := _AeAccount} = Context,
    {StepKeyWord, LineNo, Body, Args} = _Step,
    StepModule
) ->
    case proplists:get_value(dry_run, Config) of
        true ->
            apply(
                StepModule,
                step_dry,
                [Config, Context, StepKeyWord, LineNo, Body, Args]
            );
        _ ->
            apply(
                StepModule,
                step,
                [Config, Context, StepKeyWord, LineNo, Body, Args]
            )
    end.
execute_step_module(
    Config,
    #{public_key := AeAccount} = ContextIn,
    {StepKeyWord, LineNo, Body, Args} = Step,
    StepModule
) ->
    case catch execute_step_function(Config, ContextIn, Step, StepModule) of
        Context when is_map(Context) ->
            Context0 =
                maps:put(
                    step_found,
                    true,
                    Context
                ),
            metrics:update(success, AeAccount),
            Context0;
        {throw, Reason, Stack} ->
            ?LOG_ERROR("Step execution failed! ~p", [
                #{
                    reason => Reason,
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
        {'EXIT', {undef, [{_Module, step_dry, _, []} | _]}} ->
            maps:put(
                step_found,
                false,
                ContextIn
            );
        {'EXIT', {undef, [{_Module, step, _, []} | _]}} ->
            maps:put(
                step_found,
                false,
                ContextIn
            );
        {'EXIT', {function_clause, Err0}} ->
            case Err0 of
                [{_, step, _, _Loc} | _] ->
                    maps:put(
                        step_found,
                        false,
                        ContextIn
                    );
                Err ->
                    Reason = <<"Step error">>,
                    ?LOG_ERROR("Step execution failed! ~p", [
                        #{
                            reason => Reason,
                            stacktrace => Err,
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
        {Error, Reason, Stacktrace} ->
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
    end.

step_spend(Context) ->
    Spend = maps:get(step_spend, Context, 1 * math:pow(10, ?DAMAGE_DECIMALS)),
    %?LOG_DEBUG("Step spend ~p", [Spend]),
    damage_ae:spend(maps:get(public_key, Context), Spend),
    maps:remove(step_spend, Context).

execute_step(Config, Step, [Context]) ->
    execute_step(Config, Step, Context);
execute_step(Config, Step, #{fail := _} = Context) ->
    {LineNo, StepKeyWord, Body} = Step,
    case damage_context:render_body_args(Body, Context) of
        {error, {Body1, Args1}, Reason} ->
            ?LOG_DEBUG("execute_step fail error: ~p, ~p.", [Body1, Args1]),
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args1, Context, {fail, Reason}}
            ),
            Context;
        {ok, {Body1, Args1}} ->
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args1, Context, skip}
            ),
            Context
    end;
execute_step(Config, Step, Context) ->
    {LineNo, StepKeyWord, Body} = Step,
    case damage_context:render_body_args(Body, Context) of
        {error, {Body1, Args1}, Reason} ->
            formatter:format(
                Config,
                step,
                {StepKeyWord, LineNo, Body1, Args1, Context, {fail, Reason}}
            ),
            metrics:update(fail, maps:get(public_key, Context)),
            maps:put(failing_step, tuple_to_list(Step), Context);
        {ok, {Body1, Args1}} ->
            case
                lists:foldl(
                    fun
                        (StepModule, #{step_found := false} = ContextIn) ->
                            Step0 = {StepKeyWord, LineNo, Body1, Args1},
                            case execute_step_module(Config, ContextIn, Step0, StepModule) of
                                #{failing_step := _} = Context1 ->
                                    Context1;
                                #{step_found := true, fail := Err} = Context1 ->
                                    formatter:format(
                                        Config,
                                        step,
                                        {StepKeyWord, LineNo, Body1, Args1, Context1, {fail, Err}}
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
                                        {StepKeyWord, LineNo, Body1, Args1, Context1, Success}
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
                            formatter:format(
                                Config,
                                step,
                                {StepKeyWord, LineNo, Body1, Args1, Context, notfound}
                            ),
                            metrics:update(notfound, maps:get(public_key, Context)),
                            maps:put(failing_step, Step, Context);
                        true ->
                            Context0
                    end;
                Other ->
                    ?LOG_ERROR("execute_step error :~p ~p ~p", [StepKeyWord, Body1, Other]),
                    formatter:format(
                        Config,
                        step,
                        {StepKeyWord, LineNo, Body1, Args1, Context, invalid_context}
                    ),
                    metrics:update(notfound, maps:get(public_key, Context)),
                    maps:put(failing_step, Step, Context)
            end
    end.

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
%% Write run metadata into the run directory so it becomes part of the IPFS report hash.
write_run_meta(RunDir, MetaMap) ->
    %% Keep it stable + easy to parse.
    Bin = jsx:encode(MetaMap),
    file:write_file(filename:join(RunDir, "run.meta"), Bin).
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
