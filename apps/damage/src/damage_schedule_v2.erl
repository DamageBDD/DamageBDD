-module(damage_schedule_v2).

-behaviour(gen_server).

-export([
    start_link/0,
    load_all_schedules/0,
    ensure_vault/1,
    setup_vault/0,
    preview/2,
    create/2,
    submit_tx/2,
    list/1,
    get/2,
    runs/3,
    action/3,
    run_now/2,
    analytics/3,
    prepare_token_upgrade/1,
    claim_token_upgrade/0,
    finish_token_upgrade/0,
    execute/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, damage_schedule_v2_store).
-define(DEFAULT_HORIZON_DAYS, 30).
-define(DEFAULT_SAFETY_PERCENT, 15).
-define(DEFAULT_RUN_SAFETY_PERCENT, 15).
-define(MAX_TIMER_MS, 86400000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

load_all_schedules() ->
    gen_server:call(?SERVER, load_all_schedules, 30000).

ensure_vault(Owner) ->
    gen_server:call(?SERVER, {ensure_vault, to_bin(Owner)}, 120000).

setup_vault() ->
    gen_server:call(?SERVER, setup_vault, 120000).

preview(Owner, Spec) ->
    gen_server:call(?SERVER, {preview, to_bin(Owner), Spec}, 120000).

create(Owner, Spec) ->
    gen_server:call(?SERVER, {create, to_bin(Owner), Spec}, 120000).

submit_tx(Owner, TxSpec) ->
    gen_server:call(?SERVER, {submit_tx, to_bin(Owner), TxSpec}, 120000).

list(Owner) ->
    gen_server:call(?SERVER, {list, to_bin(Owner)}, 30000).

get(Owner, ScheduleId) ->
    gen_server:call(?SERVER, {get, to_bin(Owner), to_bin(ScheduleId)}, 30000).

runs(Owner, ScheduleId, Limit) ->
    gen_server:call(
        ?SERVER,
        {runs, to_bin(Owner), to_bin(ScheduleId), positive_int(Limit, 20)},
        30000
    ).

action(Owner, ScheduleId, Action) ->
    gen_server:call(?SERVER, {action, to_bin(Owner), to_bin(ScheduleId), Action}, 120000).

run_now(Owner, ScheduleId) ->
    gen_server:call(?SERVER, {run_now, to_bin(Owner), to_bin(ScheduleId)}, 30000).

analytics(Owner, From, To) ->
    gen_server:call(?SERVER, {analytics, to_bin(Owner), From, To}, 30000).

prepare_token_upgrade(NewToken) ->
    gen_server:call(?SERVER, {prepare_token_upgrade, to_bin(NewToken)}, 120000).

claim_token_upgrade() ->
    gen_server:call(?SERVER, claim_token_upgrade, 120000).

finish_token_upgrade() ->
    gen_server:call(?SERVER, finish_token_upgrade, 120000).

execute(ScheduleId, ScheduledAt) ->
    gen_server:cast(?SERVER, {execute, to_bin(ScheduleId), ScheduledAt}).

init([]) ->
    process_flag(trap_exit, true),
    ok = ensure_data_dir(),
    File = filename:join(data_dir(), "schedule_v2.dets"),
    case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 5000}]) of
        {ok, ?TABLE} ->
            {ok, #{timers => #{}, inflight => #{}, pending => #{}}};
        {error, Reason} ->
            {stop, {schedule_v2_store_open_failed, Reason}}
    end.

handle_call(load_all_schedules, _From, State0) ->
    State1 = cancel_all_timers(State0),
    Schedules = all_schedules(),
    case damage_schedule_v2_contract:ensure_contract() of
        {ok, _Contract} ->
            State2 = lists:foldl(fun maybe_arm/2, State1, Schedules),
            {reply, {ok, length(Schedules)}, State2};
        {error, Why} ->
            ?LOG_WARNING("Schedule V2 loaded without an active vault: ~p", [Why]),
            {reply, {error, Why}, State1}
    end;

handle_call({ensure_vault, Owner}, _From, State) ->
    Reply = ensure_vault_for_owner(Owner),
    {reply, Reply, State};

handle_call(setup_vault, _From, State) ->
    {reply, damage_schedule_v2_contract:setup(), State};

handle_call({preview, Owner, Spec0}, _From, State) ->
    Reply =
        case owner_busy(Owner, State) of
            true -> {error, schedule_execution_in_progress};
            false -> do_preview(Owner, Spec0)
        end,
    {reply, Reply, State};

handle_call({create, Owner, Spec0}, _From, State0) ->
    case owner_busy(Owner, State0) of
        true ->
            {reply, {error, schedule_execution_in_progress}, State0};
        false ->
            case ensure_vault_for_owner(Owner) of
                {ok, _Contract} ->
                    {Reply, State1} = do_create_call(Owner, Spec0, State0),
                    {reply, Reply, State1};
                {error, _} = Error ->
                    {reply, Error, State0}
            end
    end;

handle_call({submit_tx, Owner, TxSpec}, _From, State0) ->
    {Reply, State1} = do_submit_tx(Owner, TxSpec, State0),
    {reply, Reply, State1};

handle_call({list, Owner}, _From, State) ->
    Schedules = [public_schedule(enrich_schedule(S)) || S <- owner_schedules(Owner)],
    {reply, {ok, Schedules}, State};

handle_call({get, Owner, ScheduleId}, _From, State) ->
    Reply =
        case lookup({schedule, ScheduleId}) of
            {ok, #{owner := Owner} = Schedule} -> {ok, public_schedule(enrich_schedule(Schedule))};
            {ok, _} -> {error, forbidden};
            not_found -> {error, not_found}
        end,
    {reply, Reply, State};

handle_call({runs, Owner, ScheduleId, Limit0}, _From, State) ->
    Limit = erlang:min(100, positive_int(Limit0, 20)),
    Reply =
        case lookup({schedule, ScheduleId}) of
            {ok, #{owner := Owner}} ->
                Runs0 = runs_for_schedule(ScheduleId),
                Runs = lists:sort(
                    fun(A, B) ->
                        maps:get(ended_at, A, maps:get(started_at, A, 0)) >=
                            maps:get(ended_at, B, maps:get(started_at, B, 0))
                    end,
                    Runs0
                ),
                {ok, [json_value(R) || R <- lists:sublist(Runs, Limit)]};
            {ok, _} -> {error, forbidden};
            not_found -> {error, not_found}
        end,
    {reply, Reply, State};

handle_call({action, Owner, ScheduleId, Action}, _From, State0) ->
    {Reply, State1} = do_action(Owner, ScheduleId, Action, State0),
    {reply, Reply, State1};

handle_call({run_now, Owner, ScheduleId}, _From, State) ->
    Reply =
        case lookup({schedule, ScheduleId}) of
            {ok, #{owner := Owner, status := active}} ->
                execute(ScheduleId, erlang:system_time(second)),
                {ok, #{status => queued, schedule_id => ScheduleId}};
            {ok, #{owner := Owner, status := Status}} ->
                {error, {schedule_not_active, Status}};
            {ok, _} -> {error, forbidden};
            not_found -> {error, not_found}
        end,
    {reply, Reply, State};

handle_call({analytics, Owner, From0, To0}, _From, State) ->
    Now = erlang:system_time(second),
    From = int_value(From0, Now - 30 * 86400),
    To = int_value(To0, Now),
    {reply, {ok, build_analytics(Owner, From, To)}, State};

handle_call({prepare_token_upgrade, NewToken}, _From, State0) ->
    %% Migration is intentionally global. Refuse it while a local Schedule V2
    %% execution is running/queued, then stop timers before burning the V1
    %% vault balance. The contract independently refuses migration while an
    %% on-chain reservation exists, so both the BEAM and chain sides quiesce.
    case scheduler_idle(State0) of
        false ->
            {reply, {error, schedule_runs_in_progress}, State0};
        true ->
            State1 = cancel_all_timers(State0),
            case damage_schedule_v2_contract:prepare_token_upgrade(NewToken) of
                {ok, Result} = Ok ->
                    case damage_schedule_v2_contract:call_result_ok(Result) of
                        true ->
                            ok = store(
                                {meta, token_migration},
                                #{stage => prepared, target => NewToken}
                            ),
                            {reply, Ok, State1};
                        false ->
                            {reply,
                                {error, {prepare_token_upgrade_failed, Result}},
                                rearm_all(State1)}
                    end;
                Error ->
                    {reply, Error, rearm_all(State1)}
            end
    end;

handle_call(claim_token_upgrade, _From, State) ->
    {reply, damage_schedule_v2_contract:claim_token_upgrade(), State};

handle_call(finish_token_upgrade, _From, State0) ->
    case damage_schedule_v2_contract:finish_token_upgrade() of
        {ok, Result} = Ok ->
            case damage_schedule_v2_contract:call_result_ok(Result) of
                true ->
                    ok = delete({meta, token_migration}),
                    {reply, Ok, rearm_all(State0)};
                false ->
                    {reply, {error, {finish_token_upgrade_failed, Result}}, State0}
            end;
        Error -> {reply, Error, State0}
    end;

handle_call(_Other, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({execute, ScheduleId, ScheduledAt}, State0) ->
    {noreply, queue_or_start_execution(ScheduleId, ScheduledAt, State0)};
handle_cast({execution_complete, Owner}, State0) ->
    State1 = clear_inflight(Owner, State0),
    {noreply, start_next_pending(Owner, State1)};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info({schedule_due, ScheduleId, ScheduledAt}, State0) ->
    Now = erlang:system_time(second),
    State1 = remove_timer(ScheduleId, State0),
    case lookup({schedule, ScheduleId}) of
        {ok, Schedule} when Now + 1 < ScheduledAt ->
            %% Long timers are capped so re-arm without executing early.
            {noreply, maybe_arm(Schedule, State1)};
        {ok, Schedule} ->
            execute(ScheduleId, ScheduledAt),
            {noreply, maybe_arm(Schedule, State1)};
        not_found ->
            {noreply, State1}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cancel_all_timers(State),
    _ = close_table(),
    ok.

close_table() ->
    try dets:close(?TABLE) of
        Result -> Result
    catch
        _:_ -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


ensure_vault_for_owner(Owner) ->
    case damage_schedule_v2_contract:contract_address() of
        {ok, _Contract} = Ok ->
            Ok;
        {error, schedule_v2_contract_not_configured} = Error ->
            case damage_schedule_v2_contract:is_custodial_wallet(Owner) of
                true ->
                    ?LOG_INFO("Auto-initializing Schedule V2 vault for custodial account ~p", [Owner]),
                    damage_schedule_v2_contract:setup();
                false ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

do_create_call(Owner, Spec0, State0) ->
    case do_prepare_create(Owner, Spec0) of
        {ok, Draft} ->
            ScheduleId = maps:get(id, Draft),
            ok = store({draft, Owner, ScheduleId}, Draft),
            case damage_schedule_v2_contract:create_schedule(Owner, Draft) of
                {ok, Result} ->
                    case damage_schedule_v2_contract:call_result_ok(Result) of
                        true ->
                            case complete_custodial_funding(Owner, Draft) of
                                {ok, Schedule} ->
                                    ok = delete({draft, Owner, ScheduleId}),
                                    ok = store({schedule, ScheduleId}, Schedule),
                                    State1 = maybe_arm(Schedule, State0),
                                    {{ok, public_schedule(Schedule)}, State1};
                                Error ->
                                    {Error, State0}
                            end;
                        false ->
                            {{error, {create_schedule_failed, Result}}, State0}
                    end;
                {signing_required, #{tx := Tx}} ->
                    Reply = #{
                        status => signing_required,
                        schedule_id => ScheduleId,
                        stage => create_schedule,
                        tx => Tx,
                        draft => public_schedule(Draft)
                    },
                    {{ok, Reply}, State0};
                Error ->
                    {Error, State0}
            end;
        Error ->
            {Error, State0}
    end.

%% ------------------------------------------------------------------
%% Preview / creation
%% ------------------------------------------------------------------

do_preview(Owner, Spec0) ->
    Spec = normalize_input(Spec0),
    Feature = maps:get(feature, Spec, <<>>),
    Cron = maps:get(cron_spec, Spec, <<>>),
    StartAt = maps:get(start_at, Spec, erlang:system_time(second)),
    EndAt0 = maps:get(end_at, Spec, 0),
    HorizonDays = maps:get(horizon_days, Spec, ?DEFAULT_HORIZON_DAYS),
    BudgetEnd = case EndAt0 of 0 -> StartAt + HorizonDays * 86400; _ -> EndAt0 end,
    Concurrency = positive_int(maps:get(concurrency, Spec, 1), 1),
    Safety = bounded_percent(maps:get(safety_percent, Spec, ?DEFAULT_SAFETY_PERCENT)),
    RunSafety = bounded_percent(maps:get(run_safety_percent, Spec, ?DEFAULT_RUN_SAFETY_PERCENT)),
    case Concurrency =:= 1 of
        false -> {error, schedule_v2_concurrency_must_be_one};
        true -> do_preview_validated(Owner, Spec, Feature, Cron, StartAt, EndAt0, BudgetEnd, Concurrency, Safety, RunSafety)
    end.

do_preview_validated(Owner, _Spec, Feature, Cron, StartAt, EndAt0, BudgetEnd, Concurrency, Safety, RunSafety) ->
    case {byte_size(Feature) > 0, damage_schedule_v2_cron:parse(Cron)} of
        {false, _} -> {error, feature_required};
        {_, {error, Why}} -> {error, {invalid_cron, Why}};
        {true, {ok, _}} ->
            case dry_run_feature(Owner, Feature, Concurrency) of
                {ok, Dry} ->
                    Cost = amount_value(maps:get(cost, Dry, 0)),
                    case damage_schedule_v2_cron:occurrences(Cron, StartAt, BudgetEnd) of
                        {ok, Occurrences} ->
                            Count = length(Occurrences),
                            Estimated = Cost * Count,
                            Recommended = add_percent(Estimated, Safety),
                            MaxPerRun = erlang:max(Cost, add_percent(Cost, RunSafety)),
                            First = list_first(Occurrences),
                            Last = list_last(Occurrences),
                            {ok, #{
                                status => ok,
                                dry_run => #{
                                    cost_per_run => Cost,
                                    feature_hash => maps:get(feature_hash, Dry, <<>>),
                                    feature_title => maps:get(feature_title, Dry, feature_title(Feature)),
                                    report_hash => maps:get(report_hash, Dry, <<>>)
                                },
                                window => #{
                                    start_at => StartAt,
                                    end_at => EndAt0,
                                    budget_horizon_end => BudgetEnd,
                                    occurrences => Count,
                                    first_run_at => First,
                                    last_run_at => Last,
                                    cron_spec => Cron,
                                    cron_human => damage_schedule_v2_cron:human(Cron)
                                },
                                budget => #{
                                    estimated => Estimated,
                                    safety_percent => Safety,
                                    recommended_lock => Recommended,
                                    max_cost_per_run => MaxPerRun,
                                    run_safety_percent => RunSafety
                                }
                            }};
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

do_prepare_create(Owner, Spec0) ->
    Spec = normalize_input(Spec0),
    case do_preview(Owner, Spec) of
        {ok, Preview} ->
            Dry = maps:get(dry_run, Preview),
            Budget = maps:get(budget, Preview),
            Window = maps:get(window, Preview),
            LockAmount = amount_value(maps:get(lock_amount, Spec, maps:get(recommended_lock, Budget))),
            MinLock = maps:get(max_cost_per_run, Budget),
            case LockAmount >= MinLock andalso LockAmount > 0 of
                false -> {error, {invalid_lock_amount, #{minimum => MinLock}}};
                true ->
                    ScheduleId = new_schedule_id(Owner),
                    Now = erlang:system_time(second),
                    {ok, #{
                        id => ScheduleId,
                        owner => Owner,
                        feature => maps:get(feature, Spec),
                        feature_hash => maps:get(feature_hash, Dry),
                        feature_title => maps:get(feature_title, Dry),
                        cron_spec => maps:get(cron_spec, Window),
                        cron_human => maps:get(cron_human, Window),
                        timezone => maps:get(timezone, Spec, <<"UTC">>),
                        start_at => maps:get(start_at, Window),
                        end_at => maps:get(end_at, Window),
                        concurrency => positive_int(maps:get(concurrency, Spec, 1), 1),
                        max_cost_per_run => maps:get(max_cost_per_run, Budget),
                        funded => LockAmount,
                        spent => 0,
                        reserved => 0,
                        refunded => 0,
                        status => pending,
                        created_at => Now,
                        run_count => 0,
                        next_run_at => undefined,
                        last_run => undefined
                    }}
            end;
        Error -> Error
    end.

complete_custodial_funding(Owner, Draft) ->
    Lock = maps:get(funded, Draft),
    case damage_schedule_v2_contract:approve_allowance(Owner, Lock) of
        {ok, ApproveResult} ->
            case damage_schedule_v2_contract:call_result_ok(ApproveResult) of
                true -> fund_custodial(Owner, Draft);
                false -> {error, {allowance_failed, ApproveResult}}
            end;
        Error -> Error
    end.

fund_custodial(Owner, Draft) ->
    Id = maps:get(id, Draft),
    Lock = maps:get(funded, Draft),
    case damage_schedule_v2_contract:fund_schedule(Owner, Id, Lock) of
        {ok, FundResult} ->
            case damage_schedule_v2_contract:call_result_ok(FundResult) of
                true -> {ok, Draft#{status => active}};
                false -> {error, {fund_schedule_failed, FundResult}}
            end;
        Error -> Error
    end.

%% ------------------------------------------------------------------
%% Wallet staged transaction flow
%% ------------------------------------------------------------------

do_submit_tx(Owner, TxSpec0, State0) ->
    TxSpec = normalize_input(TxSpec0),
    ScheduleId = maps:get(schedule_id, TxSpec, <<>>),
    Stage = normalize_stage(maps:get(stage, TxSpec, undefined)),
    case lookup({draft, Owner, ScheduleId}) of
        {ok, Draft} ->
            case finalize_chain_tx(TxSpec) of
                {ok, ChainResult} ->
                    case damage_schedule_v2_contract:call_result_ok(ChainResult) of
                        true -> next_wallet_stage(Owner, ScheduleId, Stage, Draft, State0);
                        false -> {{error, {signed_transaction_failed, ChainResult}}, State0}
                    end;
                Error -> {Error, State0}
            end;
        not_found ->
            case lookup({pending_action, Owner, ScheduleId}) of
                {ok, Pending} -> finish_wallet_action(Owner, ScheduleId, Stage, Pending, TxSpec, State0);
                not_found -> {{error, pending_schedule_not_found}, State0}
            end
    end.

next_wallet_stage(Owner, ScheduleId, create_schedule, Draft, State) ->
    %% Every schedule funds its own locked budget. The previous V1 allowance is
    %% consumed as funds are pulled, so prepare a fresh increment for this lock
    %% rather than relying on a long-lived/unlimited browser approval.
    case damage_schedule_v2_contract:prepare_allowance(Owner, maps:get(funded, Draft)) of
        {ok, #{tx := Tx} = Approval} ->
            Reply = #{
                status => signing_required,
                schedule_id => ScheduleId,
                stage => approve_allowance,
                tx => Tx,
                allowance => maps:without([tx], Approval)
            },
            {{ok, Reply}, State};
        Error -> {Error, State}
    end;
next_wallet_stage(Owner, ScheduleId, approve_allowance, Draft, State) ->
    prepare_wallet_fund(Owner, ScheduleId, Draft, State);
next_wallet_stage(_Owner, _ScheduleId, fund_schedule, Draft, State0) ->
    Schedule = Draft#{status => active},
    Id = maps:get(id, Schedule),
    ok = delete_draft(Draft),
    ok = store({schedule, Id}, Schedule),
    State1 = maybe_arm(Schedule, State0),
    {{ok, #{status => ok, schedule => public_schedule(Schedule)}}, State1};
next_wallet_stage(_Owner, _ScheduleId, Stage, _Draft, State) ->
    {{error, {unexpected_wallet_stage, Stage}}, State}.

prepare_wallet_fund(Owner, ScheduleId, Draft, State) ->
    Lock = maps:get(funded, Draft),
    case damage_schedule_v2_contract:prepare_user_call(
        Owner, "fund_schedule", [to_s(ScheduleId), integer_to_list(Lock)]
    ) of
        {ok, Tx} ->
            {{ok, #{status => signing_required, schedule_id => ScheduleId, stage => fund_schedule, tx => Tx}}, State};
        Error -> {Error, State}
    end.

finish_wallet_action(Owner, ScheduleId, Stage, Pending, TxSpec, State0) ->
    ExpectedStage = maps:get(stage, Pending),
    case Stage =:= ExpectedStage of
        false -> {{error, {unexpected_wallet_stage, Stage, ExpectedStage}}, State0};
        true ->
            case finalize_chain_tx(TxSpec) of
                {ok, ChainResult} ->
                    case damage_schedule_v2_contract:call_result_ok(ChainResult) of
                        true ->
                            ok = delete({pending_action, Owner, ScheduleId}),
                            apply_local_action(Owner, ScheduleId, maps:get(action, Pending), State0);
                        false -> {{error, {signed_transaction_failed, ChainResult}}, State0}
                    end;
                Error -> {Error, State0}
            end
    end.

finalize_chain_tx(TxSpec) ->
    SignedTx = maps:get(signed_tx, TxSpec, <<>>),
    TxHash = maps:get(tx_hash, TxSpec, maps:get(<<"tx_hash">>, TxSpec, <<>>)),
    case {SignedTx, TxHash} of
        {B, _} when is_binary(B), byte_size(B) > 0 -> damage_schedule_v2_contract:post_signed(B);
        {L, _} when is_list(L), L =/= [] -> damage_schedule_v2_contract:post_signed(L);
        {_, B} when is_binary(B), byte_size(B) > 0 -> damage_schedule_v2_contract:wait_tx_hash(B);
        {_, L} when is_list(L), L =/= [] -> damage_schedule_v2_contract:wait_tx_hash(L);
        _ -> {error, signed_tx_or_tx_hash_required}
    end.

%% ------------------------------------------------------------------
%% Actions
%% ------------------------------------------------------------------

do_action(Owner, ScheduleId, Action0, State0) ->
    Action = normalize_action(Action0),
    case lookup({schedule, ScheduleId}) of
        {ok, #{owner := Owner} = _Schedule} ->
            ContractCall = action_contract_call(Action, Owner, ScheduleId),
            case ContractCall of
                {ok, Result} ->
                    case damage_schedule_v2_contract:call_result_ok(Result) of
                        true -> apply_local_action(Owner, ScheduleId, Action, State0);
                        false -> {{error, {schedule_action_failed, Action, Result}}, State0}
                    end;
                {signing_required, #{tx := Tx, stage := Stage0}} ->
                    Stage = normalize_stage(Stage0),
                    Pending = #{action => Action, stage => Stage},
                    ok = store({pending_action, Owner, ScheduleId}, Pending),
                    {{ok, #{status => signing_required, schedule_id => ScheduleId, stage => Stage, tx => Tx}}, State0};
                Error -> {Error, State0}
            end;
        {ok, _} -> {{error, forbidden}, State0};
        not_found -> {{error, not_found}, State0}
    end.

action_contract_call(pause, Owner, Id) -> damage_schedule_v2_contract:pause_schedule(Owner, Id);
action_contract_call(resume, Owner, Id) -> damage_schedule_v2_contract:resume_schedule(Owner, Id);
action_contract_call(cancel, Owner, Id) -> damage_schedule_v2_contract:cancel_schedule(Owner, Id);
action_contract_call(Action, _Owner, _Id) -> {error, {unsupported_action, Action}}.

apply_local_action(Owner, ScheduleId, Action, State0) ->
    case lookup({schedule, ScheduleId}) of
        {ok, #{owner := Owner} = Schedule0} ->
            {Schedule1, State1} =
                case Action of
                    pause -> {Schedule0#{status => paused, next_run_at => undefined}, cancel_timer(ScheduleId, State0)};
                    resume ->
                        S = Schedule0#{status => active},
                        {S, maybe_arm(S, cancel_timer(ScheduleId, State0))};
                    cancel ->
                        Refund = remaining(Schedule0),
                        S = Schedule0#{
                            status => cancelled,
                            refunded => maps:get(refunded, Schedule0, 0) + Refund,
                            next_run_at => undefined
                        },
                        {S, cancel_timer(ScheduleId, State0)}
                end,
            ok = store({schedule, ScheduleId}, Schedule1),
            {{ok, #{status => ok, schedule => public_schedule(enrich_schedule(Schedule1))}}, State1};
        _ -> {{error, not_found}, State0}
    end.

%% ------------------------------------------------------------------
%% Execution
%% ------------------------------------------------------------------

execute_worker(ScheduleId, ScheduledAt) ->
    case lookup({schedule, ScheduleId}) of
        {ok, #{status := active} = Schedule0} ->
            Now = erlang:system_time(second),
            case within_window(Schedule0, ScheduledAt, Now) of
                false -> ok;
                true -> execute_active_schedule(Schedule0, ScheduledAt)
            end;
        _ -> ok
    end.

execute_active_schedule(Schedule0, ScheduledAt) ->
    ScheduleId = maps:get(id, Schedule0),
    Owner = maps:get(owner, Schedule0),
    Feature = maps:get(feature, Schedule0),
    Concurrency = maps:get(concurrency, Schedule0, 1),
    ReserveAmount = maps:get(max_cost_per_run, Schedule0),
    case remaining(Schedule0) >= ReserveAmount of
        false ->
            _ = damage_schedule_v2_contract:mark_exhausted(ScheduleId),
            update_schedule(ScheduleId, fun(S) -> S#{status => exhausted, next_run_at => undefined} end),
            record_run(Schedule0, #{
                run_id => new_run_id(ScheduleId, ScheduledAt),
                scheduled_at => ScheduledAt,
                started_at => erlang:system_time(second),
                ended_at => erlang:system_time(second),
                status => budget_exhausted,
                cost => 0,
                duration_ms => 0
            });
        true ->
            case dry_run_feature(Owner, Feature, Concurrency) of
                {ok, Dry} ->
                    DryCost = amount_value(maps:get(cost, Dry, 0)),
                    case DryCost =< ReserveAmount of
                        false ->
                            record_run(Schedule0, #{
                                run_id => new_run_id(ScheduleId, ScheduledAt),
                                scheduled_at => ScheduledAt,
                                started_at => erlang:system_time(second),
                                ended_at => erlang:system_time(second),
                                status => dry_run_over_cap,
                                cost => DryCost,
                                duration_ms => 0
                            });
                        true -> reserve_and_execute(Schedule0, ScheduledAt, Dry)
                    end;
                {error, Why} ->
                    record_run(Schedule0, #{
                        run_id => new_run_id(ScheduleId, ScheduledAt),
                        scheduled_at => ScheduledAt,
                        started_at => erlang:system_time(second),
                        ended_at => erlang:system_time(second),
                        status => dry_run_failed,
                        error => term_bin(Why),
                        cost => 0,
                        duration_ms => 0
                    })
            end
    end.

reserve_and_execute(Schedule0, ScheduledAt, Dry) ->
    Id = maps:get(id, Schedule0),
    ReserveAmount = maps:get(max_cost_per_run, Schedule0),
    RunId = new_run_id(Id, ScheduledAt),
    case damage_schedule_v2_contract:reserve_run(Id, RunId, ReserveAmount) of
        {ok, ReserveResult} ->
            case damage_schedule_v2_contract:call_result_ok(ReserveResult) of
                true ->
                    update_schedule(Id, fun(S) -> S#{reserved => maps:get(reserved, S, 0) + ReserveAmount} end),
                    execute_reserved(Schedule0, ScheduledAt, RunId, ReserveAmount, Dry);
                false ->
                    record_run(Schedule0, #{
                        run_id => RunId,
                        scheduled_at => ScheduledAt,
                        started_at => erlang:system_time(second),
                        ended_at => erlang:system_time(second),
                        status => reserve_failed,
                        error => term_bin(ReserveResult),
                        cost => 0,
                        duration_ms => 0
                    })
            end;
        Error ->
            %% Unknown post/wait state: conservatively account the reservation
            %% locally and do not execute. This fails closed until an operator
            %% reconciles the deterministic run_id with on-chain state.
            update_schedule(Id, fun(S) ->
                S#{reserved => maps:get(reserved, S, 0) + ReserveAmount}
            end),
            record_run(Schedule0, #{
                run_id => RunId,
                scheduled_at => ScheduledAt,
                started_at => erlang:system_time(second),
                ended_at => erlang:system_time(second),
                status => reservation_reconciliation_required,
                reservation_amount => ReserveAmount,
                error => term_bin(Error),
                cost => 0,
                duration_ms => 0
            })
    end.

execute_reserved(Schedule0, ScheduledAt, RunId, ReserveAmount, _Dry) ->
    Id = maps:get(id, Schedule0),
    Owner = maps:get(owner, Schedule0),
    Feature = maps:get(feature, Schedule0),
    Concurrency = maps:get(concurrency, Schedule0, 1),
    StartMs = erlang:system_time(millisecond),
    Start = StartMs div 1000,
    case execute_feature(Owner, Feature, Concurrency, Id) of
        {ok, Result} ->
            ActualCost = amount_value(maps:get(cost, Result, 0)),
            FeatureHash = maps:get(feature_hash, Result, maps:get(feature_hash, Schedule0)),
            ReportHash = maps:get(report_hash, Result, <<>>),
            EndMs = erlang:system_time(millisecond),
            case ActualCost =< ReserveAmount of
                true ->
                    #{public_key := NodeAccount} = secrets:node_keypair(),
                    case damage_schedule_v2_contract:settle_run(
                        Id, RunId, NodeAccount, ActualCost, FeatureHash, ReportHash
                    ) of
                        {ok, SettleResult} ->
                            case damage_schedule_v2_contract:call_result_ok(SettleResult) of
                                true ->
                                    update_after_settlement(Id, ReserveAmount, ActualCost, Result),
                                    record_run(Schedule0, #{
                                        run_id => RunId,
                                        scheduled_at => ScheduledAt,
                                        started_at => Start,
                                        ended_at => EndMs div 1000,
                                        status => result_status(Result),
                                        cost => ActualCost,
                                        duration_ms => EndMs - StartMs,
                                        report_hash => ReportHash,
                                        feature_hash => FeatureHash,
                                        result => maps:get(result, Result, <<>>),
                                        settlement => ok
                                    });
                                false ->
                                    release_reservation(Id, RunId, ReserveAmount),
                                    record_run(Schedule0, #{
                                        run_id => RunId,
                                        scheduled_at => ScheduledAt,
                                        started_at => Start,
                                        ended_at => EndMs div 1000,
                                        status => settlement_failed,
                                        cost => ActualCost,
                                        duration_ms => EndMs - StartMs,
                                        report_hash => ReportHash,
                                        error => term_bin(SettleResult)
                                    })
                            end;
                        Error ->
                            %% A transport/wait error is ambiguous: the settle tx may
                            %% already be on chain. Keep the reservation locked instead
                            %% of issuing a blind release that could make an executed
                            %% run free or race a late settlement. Contract run state is
                            %% the replay-protected authority for reconciliation.
                            record_run(Schedule0, #{
                                run_id => RunId,
                                scheduled_at => ScheduledAt,
                                started_at => Start,
                                ended_at => EndMs div 1000,
                                status => settlement_reconciliation_required,
                                cost => ActualCost,
                                duration_ms => EndMs - StartMs,
                                report_hash => ReportHash,
                                feature_hash => FeatureHash,
                                reservation_amount => ReserveAmount,
                                error => term_bin(Error)
                            })
                    end;
                false ->
                    release_reservation(Id, RunId, ReserveAmount),
                    record_run(Schedule0, #{
                        run_id => RunId,
                        scheduled_at => ScheduledAt,
                        started_at => Start,
                        ended_at => EndMs div 1000,
                        status => actual_cost_over_cap,
                        cost => ActualCost,
                        duration_ms => EndMs - StartMs,
                        report_hash => ReportHash
                    })
            end;
        {error, Why} ->
            EndMs = erlang:system_time(millisecond),
            release_reservation(Id, RunId, ReserveAmount),
            record_run(Schedule0, #{
                run_id => RunId,
                scheduled_at => ScheduledAt,
                started_at => Start,
                ended_at => EndMs div 1000,
                status => execution_failed,
                error => term_bin(Why),
                cost => 0,
                duration_ms => EndMs - StartMs
            })
    end.

release_reservation(Id, RunId, ReserveAmount) ->
    _ = damage_schedule_v2_contract:release_run(Id, RunId),
    update_schedule(Id, fun(S) -> S#{reserved => erlang:max(0, maps:get(reserved, S, 0) - ReserveAmount)} end).

update_after_settlement(Id, ReserveAmount, ActualCost, Result) ->
    update_schedule(Id, fun(S) ->
        S#{
            reserved => erlang:max(0, maps:get(reserved, S, 0) - ReserveAmount),
            spent => maps:get(spent, S, 0) + ActualCost,
            run_count => maps:get(run_count, S, 0) + 1,
            last_run => #{
                at => erlang:system_time(second),
                status => result_status(Result),
                cost => ActualCost,
                report_hash => maps:get(report_hash, Result, <<>>),
                duration_ms => round(1000 * number_value(maps:get(execution_time, Result, 0)))
            }
        }
    end).

execute_feature(Owner, Feature, Concurrency, ScheduleId) ->
    try
        Overrides = [
            {public_key, Owner},
            {concurrency, Concurrency},
            {schedule_id, ScheduleId},
            {settlement, schedule_v2}
        ],
        Config = damage_config:get_default_config(Overrides),
        Context = execution_context(Owner),
        case damage:execute_data(Config, Context, Feature) of
            Result when is_map(Result) -> {ok, Result};
            Other -> {error, Other}
        end
    catch
        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.

dry_run_feature(Owner, Feature, Concurrency) ->
    try
        Config = damage_config:get_default_config([
            {public_key, Owner}, {concurrency, Concurrency}, {dry_run, true}
        ]),
        Context = execution_context(Owner),
        case damage:execute_data(Config, Context, Feature) of
            #{cost := _} = Result -> {ok, Result};
            #{fail := Why} -> {error, {dry_run_failed, Why}};
            Other -> {error, {unexpected_dry_run_result, Other}}
        end
    catch
        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.

execution_context(Owner) ->
    Base = #{public_key => Owner, stream => nostream, concurrency => 1},
    Global = safe_map(fun() -> damage_context:get_global_template_context(Base) end),
    Account = safe_map(fun() -> damage_context:get_context(Owner) end),
    maps:put(account_context, Account, maps:merge(Global, Base)).

safe_map(Fun) ->
    try Fun() of
        M when is_map(M) -> M;
        _ -> #{}
    catch _:_ -> #{} end.

%% ------------------------------------------------------------------
%% Per-account execution serialization
%%
%% Schedule V2 accounting is run-scoped via settlement=schedule_v2, but the
%% initial release still serializes scheduled work per account. This keeps the
%% reserve -> execute -> settle/release sequence deterministic while the new
%% escrow path is being proven. Different account owners can run concurrently.
%% ------------------------------------------------------------------

owner_busy(Owner, State) ->
    maps:is_key(Owner, maps:get(inflight, State, #{})).

scheduler_idle(State) ->
    maps:size(maps:get(inflight, State, #{})) =:= 0 andalso
        maps:fold(
            fun(_Owner, Queue, Empty) -> Empty andalso Queue =:= [] end,
            true,
            maps:get(pending, State, #{})
        ).

queue_or_start_execution(ScheduleId, ScheduledAt, State0) ->
    case lookup({schedule, ScheduleId}) of
        {ok, #{owner := Owner}} ->
            case owner_busy(Owner, State0) of
                true -> queue_pending(Owner, {ScheduleId, ScheduledAt}, State0);
                false -> start_execution(Owner, ScheduleId, ScheduledAt, State0)
            end;
        _ -> State0
    end.

start_execution(Owner, ScheduleId, ScheduledAt, State0) ->
    _Pid = spawn(fun() ->
        try execute_worker(ScheduleId, ScheduledAt)
        after
            gen_server:cast(?SERVER, {execution_complete, Owner})
        end
    end),
    Inflight0 = maps:get(inflight, State0, #{}),
    State0#{inflight => maps:put(Owner, ScheduleId, Inflight0)}.

queue_pending(Owner, Item, State0) ->
    Pending0 = maps:get(pending, State0, #{}),
    Queue0 = maps:get(Owner, Pending0, []),
    Pending1 = maps:put(Owner, Queue0 ++ [Item], Pending0),
    State0#{pending => Pending1}.

clear_inflight(Owner, State0) ->
    Inflight0 = maps:get(inflight, State0, #{}),
    State0#{inflight => maps:remove(Owner, Inflight0)}.

start_next_pending(Owner, State0) ->
    Pending0 = maps:get(pending, State0, #{}),
    case maps:get(Owner, Pending0, []) of
        [{ScheduleId, ScheduledAt} | Rest] ->
            Pending1 =
                case Rest of
                    [] -> maps:remove(Owner, Pending0);
                    _ -> maps:put(Owner, Rest, Pending0)
                end,
            start_execution(Owner, ScheduleId, ScheduledAt, State0#{pending => Pending1});
        [] -> State0
    end.

%% ------------------------------------------------------------------
%% Timers
%% ------------------------------------------------------------------

maybe_arm(#{status := active} = Schedule0, State0) ->
    Schedule = enrich_next_run(Schedule0),
    Id = maps:get(id, Schedule),
    ok = store({schedule, Id}, Schedule),
    case maps:get(next_run_at, Schedule, undefined) of
        Next when is_integer(Next) ->
            Now = erlang:system_time(second),
            Delay0 = erlang:max(0, (Next - Now) * 1000),
            Delay = erlang:min(?MAX_TIMER_MS, Delay0),
            Ref = erlang:send_after(Delay, self(), {schedule_due, Id, Next}),
            put_timer(Id, Ref, State0);
        _ -> State0
    end;
maybe_arm(_Schedule, State) -> State.

enrich_next_run(Schedule) ->
    Cron = maps:get(cron_spec, Schedule),
    Now = erlang:system_time(second),
    Start = maps:get(start_at, Schedule, 0),
    Cursor = erlang:max(Now, Start - 1),
    End = maps:get(end_at, Schedule, 0),
    case damage_schedule_v2_cron:next_after(Cron, Cursor) of
        {ok, Next} when End =:= 0 orelse Next =< End -> Schedule#{next_run_at => Next};
        _ -> Schedule#{next_run_at => undefined}
    end.

put_timer(Id, Ref, State) ->
    Timers0 = maps:get(timers, State, #{}),
    State#{timers => maps:put(Id, Ref, Timers0)}.

remove_timer(Id, State) ->
    Timers0 = maps:get(timers, State, #{}),
    State#{timers => maps:remove(Id, Timers0)}.

cancel_timer(Id, State0) ->
    Timers0 = maps:get(timers, State0, #{}),
    case maps:get(Id, Timers0, undefined) of
        undefined -> State0;
        Ref ->
            _ = erlang:cancel_timer(Ref),
            State0#{timers => maps:remove(Id, Timers0)}
    end.

cancel_all_timers(State0) ->
    Timers = maps:get(timers, State0, #{}),
    lists:foreach(fun({_Id, Ref}) -> _ = erlang:cancel_timer(Ref) end, maps:to_list(Timers)),
    State0#{timers => #{}}.

rearm_all(State0) ->
    lists:foldl(fun maybe_arm/2, cancel_all_timers(State0), all_schedules()).

within_window(Schedule, ScheduledAt, Now) ->
    Start = maps:get(start_at, Schedule, 0),
    End = maps:get(end_at, Schedule, 0),
    ScheduledAt >= Start andalso (End =:= 0 orelse ScheduledAt =< End) andalso Now >= Start.

%% ------------------------------------------------------------------
%% Storage / analytics
%% ------------------------------------------------------------------

store(Key, Value) ->
    case dets:insert(?TABLE, {Key, Value}) of true -> ok; ok -> ok; Other -> Other end.

delete(Key) ->
    case dets:delete(?TABLE, Key) of true -> ok; ok -> ok; Other -> Other end.

delete_draft(Draft) -> delete({draft, maps:get(owner, Draft), maps:get(id, Draft)}).

lookup(Key) ->
    case dets:lookup(?TABLE, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> not_found
    end.

all_schedules() ->
    dets:foldl(
        fun
            ({{schedule, _Id}, Schedule}, Acc) -> [Schedule | Acc];
            (_, Acc) -> Acc
        end,
        [],
        ?TABLE
    ).

owner_schedules(Owner) ->
    lists:sort(
        fun(A, B) -> maps:get(created_at, A, 0) >= maps:get(created_at, B, 0) end,
        [S || S <- all_schedules(), maps:get(owner, S, undefined) =:= Owner]
    ).

update_schedule(Id, Fun) ->
    case lookup({schedule, Id}) of
        {ok, S0} ->
            S1 = Fun(S0),
            store({schedule, Id}, S1),
            {ok, S1};
        not_found -> {error, not_found}
    end.

record_run(Schedule, Run0) ->
    Id = maps:get(id, Schedule),
    Owner = maps:get(owner, Schedule),
    Run = maps:merge(#{schedule_id => Id, owner => Owner}, Run0),
    RunId = maps:get(run_id, Run),
    ok = store({run, Id, RunId}, Run),
    update_schedule(Id, fun(S) -> S#{last_run => run_summary(Run)} end),
    ok.

run_summary(Run) ->
    #{
        at => maps:get(ended_at, Run, maps:get(started_at, Run, 0)),
        status => maps:get(status, Run, unknown),
        cost => maps:get(cost, Run, 0),
        duration_ms => maps:get(duration_ms, Run, 0),
        report_hash => maps:get(report_hash, Run, <<>>)
    }.

runs_for_owner(Owner, From, To) ->
    dets:foldl(
        fun
            ({{run, _Id, _RunId}, #{owner := Owner0} = Run}, Acc) when Owner0 =:= Owner ->
                At = maps:get(ended_at, Run, maps:get(started_at, Run, 0)),
                case At >= From andalso At =< To of true -> [Run | Acc]; false -> Acc end;
            (_, Acc) -> Acc
        end,
        [],
        ?TABLE
    ).

enrich_schedule(Schedule) ->
    Runs = runs_for_schedule(maps:get(id, Schedule)),
    Total = length(Runs),
    Success = length([R || R <- Runs, maps:get(status, R, unknown) =:= success]),
    Rate = case Total of 0 -> 0.0; _ -> (Success * 100.0) / Total end,
    Schedule#{
        remaining => remaining(Schedule),
        success_rate => Rate,
        success_runs => Success,
        total_runs => Total
    }.

runs_for_schedule(Id) ->
    dets:foldl(
        fun
            ({{run, Id0, _RunId}, Run}, Acc) when Id0 =:= Id -> [Run | Acc];
            (_, Acc) -> Acc
        end,
        [],
        ?TABLE
    ).

build_analytics(Owner, From, To) ->
    Runs = runs_for_owner(Owner, From, To),
    Total = length(Runs),
    Success = length([R || R <- Runs, maps:get(status, R, unknown) =:= success]),
    Failed = Total - Success,
    Spend = lists:sum([maps:get(cost, R, 0) || R <- Runs]),
    DurationTotal = lists:sum([maps:get(duration_ms, R, 0) || R <- Runs]),
    AvgDuration = case Total of 0 -> 0; _ -> DurationTotal div Total end,
    Buckets = analytics_buckets(Runs),
    Active = length([S || S <- owner_schedules(Owner), maps:get(status, S, undefined) =:= active]),
    Locked = lists:sum([remaining(S) || S <- owner_schedules(Owner), maps:get(status, S, undefined) =/= cancelled]),
    #{
        from => From,
        to => To,
        summary => #{
            active_schedules => Active,
            runs => Total,
            success => Success,
            failed => Failed,
            success_rate => case Total of 0 -> 0.0; _ -> (Success * 100.0) / Total end,
            spend => Spend,
            average_duration_ms => AvgDuration,
            budget_available => Locked
        },
        buckets => Buckets
    }.

analytics_buckets(Runs) ->
    Map = lists:foldl(
        fun(Run, Acc) ->
            Day = day_key(maps:get(ended_at, Run, maps:get(started_at, Run, 0))),
            Old = maps:get(Day, Acc, #{day => Day, runs => 0, success => 0, failed => 0, spend => 0}),
            IsSuccess = maps:get(status, Run, unknown) =:= success,
            New = Old#{
                runs := maps:get(runs, Old) + 1,
                success := maps:get(success, Old) + bool_int(IsSuccess),
                failed := maps:get(failed, Old) + bool_int(not IsSuccess),
                spend := maps:get(spend, Old) + maps:get(cost, Run, 0)
            },
            maps:put(Day, New, Acc)
        end,
        #{},
        Runs
    ),
    [maps:get(K, Map) || K <- lists:sort(maps:keys(Map))].

public_schedule(Schedule0) ->
    Schedule = maps:remove(feature, Schedule0),
    maps:map(fun(_K, V) -> json_value(V) end, Schedule).

remaining(S) ->
    erlang:max(
        0,
        maps:get(funded, S, 0) - maps:get(spent, S, 0) - maps:get(reserved, S, 0) -
            maps:get(refunded, S, 0)
    ).

%% ------------------------------------------------------------------
%% Utility
%% ------------------------------------------------------------------

normalize_input(M) when is_map(M) ->
    maps:from_list([{normalize_key(K), normalize_value(V)} || {K, V} <- maps:to_list(M)]);
normalize_input(_) -> #{}.

normalize_key(K) when is_atom(K) -> K;
normalize_key(K) when is_binary(K) ->
    case K of
        <<"feature">> -> feature;
        <<"feature_hash">> -> feature_hash;
        <<"feature_title">> -> feature_title;
        <<"cron_spec">> -> cron_spec;
        <<"timezone">> -> timezone;
        <<"start_at">> -> start_at;
        <<"end_at">> -> end_at;
        <<"concurrency">> -> concurrency;
        <<"safety_percent">> -> safety_percent;
        <<"run_safety_percent">> -> run_safety_percent;
        <<"horizon_days">> -> horizon_days;
        <<"lock_amount">> -> lock_amount;
        <<"schedule_id">> -> schedule_id;
        <<"stage">> -> stage;
        <<"signed_tx">> -> signed_tx;
        <<"tx_hash">> -> tx_hash;
        <<"from">> -> from;
        <<"to">> -> to;
        _ -> K
    end;
normalize_key(K) -> K.

normalize_value(V) when is_map(V) -> normalize_input(V);
normalize_value(V) -> V.

normalize_stage(create_schedule) -> create_schedule;
normalize_stage(approve_allowance) -> approve_allowance;
normalize_stage(fund_schedule) -> fund_schedule;
normalize_stage(pause_schedule) -> pause_schedule;
normalize_stage(resume_schedule) -> resume_schedule;
normalize_stage(cancel_schedule) -> cancel_schedule;
normalize_stage(B) when is_binary(B) -> normalize_stage(binary_to_atom_safe(B));
normalize_stage(L) when is_list(L) -> normalize_stage(list_to_binary(L));
normalize_stage(Other) -> Other.

normalize_action(pause) -> pause;
normalize_action(resume) -> resume;
normalize_action(cancel) -> cancel;
normalize_action(B) when is_binary(B) -> normalize_action(binary_to_atom_safe(B));
normalize_action(L) when is_list(L) -> normalize_action(list_to_binary(L));
normalize_action(Other) -> Other.

binary_to_atom_safe(<<"create_schedule">>) -> create_schedule;
binary_to_atom_safe(<<"approve_allowance">>) -> approve_allowance;
binary_to_atom_safe(<<"fund_schedule">>) -> fund_schedule;
binary_to_atom_safe(<<"pause_schedule">>) -> pause_schedule;
binary_to_atom_safe(<<"resume_schedule">>) -> resume_schedule;
binary_to_atom_safe(<<"cancel_schedule">>) -> cancel_schedule;
binary_to_atom_safe(<<"pause">>) -> pause;
binary_to_atom_safe(<<"resume">>) -> resume;
binary_to_atom_safe(<<"cancel">>) -> cancel;
binary_to_atom_safe(Other) -> {unknown, Other}.

new_schedule_id(Owner) ->
    Entropy = crypto:strong_rand_bytes(16),
    Now = integer_to_binary(erlang:system_time(microsecond)),
    Hash = crypto:hash(sha256, <<Owner/binary, $:, Now/binary, $:, Entropy/binary>>),
    <<Short:16/binary, _/binary>> = Hash,
    <<"sv2_", (lower_hex(Short))/binary>>.

new_run_id(ScheduleId, ScheduledAt) ->
    Hash = crypto:hash(sha256, <<ScheduleId/binary, $:, (integer_to_binary(ScheduledAt))/binary>>),
    <<"run_", (lower_hex(Hash))/binary>>.

lower_hex(Bin) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

feature_title(Feature) ->
    Lines = binary:split(Feature, <<"\n">>, [global]),
    case [string:trim(L) || L <- Lines, binary:match(string:trim(L), <<"Feature:">>) =:= {0, 8}] of
        [Line | _] -> Line;
        [] -> <<"Feature">>
    end.

amount_value(V) when is_integer(V) -> V;
amount_value(V) when is_float(V) -> round(V);
amount_value(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> 0 end;
amount_value(V) when is_list(V) ->
    try list_to_integer(V) catch _:_ -> 0 end;
amount_value(_) -> 0.

number_value(V) when is_integer(V); is_float(V) -> V;
number_value(_) -> 0.

positive_int(V, Default) ->
    I = int_value(V, Default),
    case I > 0 of true -> I; false -> Default end.

int_value(V, _Default) when is_integer(V) -> V;
int_value(V, Default) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> Default end;
int_value(V, Default) when is_list(V) ->
    try list_to_integer(V) catch _:_ -> Default end;
int_value(_, Default) -> Default.

bounded_percent(V) ->
    I = int_value(V, ?DEFAULT_SAFETY_PERCENT),
    erlang:min(100, erlang:max(0, I)).

add_percent(Value, Percent) ->
    (Value * (100 + Percent) + 99) div 100.

result_status(Result) ->
    case maps:get(result, Result, <<"success">>) of
        "success" -> success;
        <<"success">> -> success;
        success -> success;
        _ -> failed
    end.

list_first([H | _]) -> H;
list_first([]) -> null.

list_last([]) -> null;
list_last(L) -> lists:last(L).

bool_int(true) -> 1;
bool_int(false) -> 0.

day_key(Epoch) when is_integer(Epoch), Epoch > 0 ->
    {{Y, M, D}, _} = calendar:system_time_to_universal_time(Epoch, second),
    list_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]));
day_key(_) -> <<"unknown">>.

json_value(undefined) -> null;
json_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
json_value(V) when is_map(V) -> maps:map(fun(_K, X) -> json_value(X) end, V);
json_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [json_value(X) || X <- V]
    end;
json_value(V) -> V.

term_bin(V) when is_binary(V) -> V;
term_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

data_dir() ->
    application:get_env(
        damage,
        schedule_v2_data_dir,
        application:get_env(damage, runtime_data_dir, "./data")
    ).

ensure_data_dir() ->
    filelib:ensure_dir(filename:join(data_dir(), "placeholder")).

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L;
to_s(I) when is_integer(I) -> integer_to_list(I).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
