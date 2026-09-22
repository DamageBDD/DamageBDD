%%%-------------------------------------------------------------------
%%% damage_schedule_index
%%% Scalable off-chain scheduler index for DamageBDD
%%%
%%% Author: Steven Joseph
%%%-------------------------------------------------------------------
-module(damage_schedule_index).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    refresh_account/1,
    upsert_schedule/3,
    delete_schedule/2,
    tick/0
]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%%--------------------------------------------------------------------
%% Tables (named ETS)
%%--------------------------------------------------------------------
-define(SCHED_BY_ID, sched_by_id).
-define(NEXT_DUE, next_due).
-define(DUE_BUCKET, due_bucket).
-define(DAMAGE_BAL_CACHE, damage_balance_cache).

%% Config
-define(DUE_WINDOW_MIN, 2).
-define(BALANCE_TTL_SEC, 300).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

refresh_account(Account) ->
    gen_server:cast(?MODULE, {refresh_account, Account}).

upsert_schedule(Account, ScheduleId, ScheduleMap) ->
    gen_server:cast(?MODULE, {upsert, Account, ScheduleId, ScheduleMap}).

delete_schedule(Account, ScheduleId) ->
    gen_server:cast(?MODULE, {delete, Account, ScheduleId}).

tick() ->
    gen_server:cast(?MODULE, tick).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ets:new(?SCHED_BY_ID, [set, named_table, protected]),
    ets:new(?NEXT_DUE, [set, named_table, protected]),
    ets:new(?DUE_BUCKET, [bag, named_table, protected]),
    ets:new(?DAMAGE_BAL_CACHE, [set, named_table, protected]),
    timer:send_interval(1000, tick),
    {ok, #{}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({refresh_account, Account}, State) ->
    %% Pull per-account schedules ONLY. A locked node, contract outage, or
    %% temporarily restarting schedule server is a transient condition.
    case safe_get_schedules(Account) of
        Schedules when is_list(Schedules) ->
            NowMin = epoch_minute(),
            lists:foreach(
                fun(Schedule) ->
                    case schedule_identity_and_cron(Schedule) of
                        {ok, Id, Cron} ->
                            upsert_internal(Account, Id, Schedule, Cron, NowMin);
                        {error, Reason} ->
                            ?LOG_WARNING(
                                "Skipping malformed schedule during refresh account=~p reason=~p schedule=~p",
                                [Account, Reason, Schedule]
                            )
                    end
                end,
                Schedules
            );
        {error, Reason} ->
            ?LOG_DEBUG(
                "Schedule refresh deferred account=~p reason=~p",
                [Account, Reason]
            );
        Other ->
            ?LOG_WARNING(
                "Unexpected schedule refresh result account=~p result=~p",
                [Account, Other]
            )
    end,
    {noreply, State};
handle_cast({upsert, Account, Id, ScheduleMap}, State) when is_map(ScheduleMap) ->
    case maps:find(cron, ScheduleMap) of
        {ok, Cron} ->
            upsert_internal(Account, Id, ScheduleMap, Cron, epoch_minute());
        error ->
            ?LOG_WARNING(
                "Ignoring schedule upsert without cron account=~p id=~p schedule=~p",
                [Account, Id, ScheduleMap]
            )
    end,
    {noreply, State};
handle_cast({upsert, Account, Id, Other}, State) ->
    ?LOG_WARNING(
        "Ignoring malformed schedule upsert account=~p id=~p schedule=~p",
        [Account, Id, Other]
    ),
    {noreply, State};
handle_cast({delete, Account, Id}, State) ->
    ets:delete(?SCHED_BY_ID, {Account, Id}),
    ets:delete(?NEXT_DUE, {Account, Id}),
    %% buckets lazily cleaned
    {noreply, State};
handle_cast(tick, State) ->
    run_tick(),
    {noreply, State}.

handle_info(tick, State) ->
    run_tick(),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

maybe_run(Account, Id, Schedule) ->
    spawn(fun() ->
        damage_schedule:execute_bdd(Schedule)
    end),
    Cron = maps:get(cron, Schedule),
    case Cron of
        [once | _] ->
            %% One-shot schedules must not be reinserted into the due index.
            ets:delete(?NEXT_DUE, {Account, Id}),
            ets:delete(?SCHED_BY_ID, {Account, Id}),
            ok;
        _ ->
            reschedule(Account, Id, Cron)
    end.
%%--------------------------------------------------------------------
%% Internal logic
%%--------------------------------------------------------------------

upsert_internal(_Account, _Id, #{cron := [once | _], execution_counter := Count}, _CronSpec, _NowMin) when
    is_integer(Count), Count > 0
->
    ok;
upsert_internal(Account, Id, ScheduleMap, CronSpec, NowMin) ->
    case safe_cron_next(CronSpec, NowMin) of
        {ok, NextMin} ->
            ets:insert(?SCHED_BY_ID, {{Account, Id}, ScheduleMap}),
            ets:insert(?NEXT_DUE, {{Account, Id}, NextMin}),
            ets:insert(?DUE_BUCKET, {NextMin, {Account, Id}}),
            ok;
        {error, Reason} ->
            ?LOG_WARNING(
                "Skipping unsupported schedule account=~p id=~p cron=~p reason=~p",
                [Account, Id, CronSpec, Reason]
            ),
            ok
    end.

run_tick() ->
    NowMin = epoch_minute(),
    %% Look backwards to pick up briefly missed buckets; never scan future
    %% buckets, otherwise a schedule can execute before its due minute.
    FromMin = erlang:max(0, NowMin - ?DUE_WINDOW_MIN),
    DueKeys = due_keys(FromMin, NowMin),
    Eligible = filter_active_accounts(DueKeys),
    lists:foreach(fun(Key) -> execute(Key, NowMin) end, Eligible).

execute({Account, Id}, NowMin) ->
    %% NEXT_DUE is authoritative. DUE_BUCKET is only an index and contains lazy
    %% stale entries, so verify and claim the due minute before running.
    case ets:lookup(?NEXT_DUE, {Account, Id}) of
        [{{_, _}, DueMin}] when DueMin =< NowMin ->
            ets:delete(?NEXT_DUE, {Account, Id}),
            ets:delete_object(?DUE_BUCKET, {DueMin, {Account, Id}}),
            case ets:lookup(?SCHED_BY_ID, {Account, Id}) of
                [{{_, _}, Schedule}] -> maybe_run(Account, Id, Schedule);
                [] -> ok
            end;
        _ ->
            ok
    end.

reschedule(Account, Id, Cron) ->
    NowMin = epoch_minute(),
    case safe_cron_next(Cron, NowMin) of
        {ok, NextMin} ->
            ets:insert(?NEXT_DUE, {{Account, Id}, NextMin}),
            ets:insert(?DUE_BUCKET, {NextMin, {Account, Id}}),
            ok;
        {error, Reason} ->
            ?LOG_WARNING(
                "Could not reschedule account=~p id=~p cron=~p reason=~p",
                [Account, Id, Cron, Reason]
            ),
            ets:delete(?NEXT_DUE, {Account, Id}),
            ok
    end.

%%--------------------------------------------------------------------
%% Filtering
%%--------------------------------------------------------------------

due_keys(From, To) ->
    lists:usort(
        lists:flatten(
            [
                [K || {_, K} <- ets:lookup(?DUE_BUCKET, M)]
             || M <- lists:seq(From, To)
            ]
        )
    ).

filter_active_accounts(Keys) ->
    Accounts = lists:usort([A || {A, _} <- Keys]),
    ActiveMap =
        maps:from_list(
            [{A, is_active(A)} || A <- Accounts]
        ),
    [K || {A, _} = K <- Keys, maps:get(A, ActiveMap, false)].

is_active(Account) ->
    Now = os:system_time(second),
    case ets:lookup(?DAMAGE_BAL_CACHE, Account) of
        [{Account, #{active := Active, checked_at := T}}] when
            Now - T < ?BALANCE_TTL_SEC
        ->
            Active;
        _ ->
            Balance =
                case catch damage_ae:balance(Account) of
                    B when is_integer(B) -> B;
                    Err ->
                        ?LOG_WARNING("balance lookup failed ~p for ~p", [Err, Account]),
                        0
                end,
            Active = Balance > 0,
            ets:insert(
                ?DAMAGE_BAL_CACHE,
                {Account, #{active => Active, checked_at => Now}}
            ),
            Active
    end.

%%--------------------------------------------------------------------
%% Time helpers
%%--------------------------------------------------------------------

epoch_minute() ->
    os:system_time(second) div 60.

safe_cron_next(CronSpec0, FromMin) ->
    %% Keep the complete normalization + cron calculation inside the protected
    %% boundary. This matters during rolling/hot upgrades where an old
    %% damage_schedule module may briefly be loaded without the exported helper.
    try
        CronSpec =
            case damage_schedule:normalize_cron_spec(CronSpec0) of
                {ok, C} -> C;
                {error, _} -> CronSpec0
            end,
        case cron_next(CronSpec, FromMin) of
            NextMin when is_integer(NextMin) -> {ok, NextMin};
            Other -> {error, {invalid_cron_next_result, Other}}
        end
    catch
        error:undef ->
            %% A version skew must skip this row, not consume supervisor restart
            %% intensity. The next refresh after the code upgrade will reindex it.
            {error, {normalizer_unavailable, CronSpec0}};
        Class:Reason ->
            {error, {Class, Reason}}
    end.

safe_get_schedules(Account) ->
    try damage_schedule:get_schedules(Account) of
        Result -> Result
    catch
        Class:Reason ->
            {error, {schedule_lookup_failed, Class, Reason}}
    end.

schedule_identity_and_cron(#{id := Id, cron := Cron}) ->
    {ok, Id, Cron};
schedule_identity_and_cron(#{id_hash := Id, cron := Cron}) ->
    {ok, Id, Cron};
schedule_identity_and_cron(Schedule) when is_map(Schedule) ->
    {error, {missing_schedule_identity_or_cron, maps:keys(Schedule)}};
schedule_identity_and_cron(Other) ->
    {error, {invalid_schedule_row, Other}}.

cron_next([daily, every, Second, sec], FromMin) when is_integer(Second), Second > 0 ->
    %% The index is minute-resolution. Any sub-minute/seconds cadence is
    %% therefore represented by the next minute boundary.
    FromMin + max(1, (Second + 59) div 60);
cron_next([daily, every, Minutes, minute], FromMin) when is_integer(Minutes), Minutes > 0 ->
    FromMin + Minutes;
cron_next([daily, every, Hours, hour], FromMin) when is_integer(Hours), Hours > 0 ->
    FromMin + (Hours * 60);
cron_next([daily, every, Days, day], FromMin) when is_integer(Days), Days > 0 ->
    FromMin + (Days * 24 * 60);
cron_next([daily, every, Weeks, week], FromMin) when is_integer(Weeks), Weeks > 0 ->
    FromMin + (Weeks * 7 * 24 * 60);
cron_next([daily, every, Hour, Minute, AMPM], FromMin) when
    is_integer(Hour), is_integer(Minute), (AMPM =:= am orelse AMPM =:= pm)
->
    {Date, _Time} = calendar:gregorian_seconds_to_datetime(FromMin * 60),
    TargetHour24 = to_24h(Hour, AMPM),
    TodayTargetSecs = calendar:datetime_to_gregorian_seconds({Date, {TargetHour24, Minute, 0}}),
    FromSecs = FromMin * 60,
    if
        TodayTargetSecs > FromSecs ->
            TodayTargetSecs div 60;
        true ->
            TomorrowDate = calendar:gregorian_days_to_date(
                calendar:date_to_gregorian_days(Date) + 1
            ),
            calendar:datetime_to_gregorian_seconds({TomorrowDate, {TargetHour24, Minute, 0}}) div 60
    end;
cron_next([once, Seconds], FromMin) when is_integer(Seconds), Seconds >= 0 ->
    FromMin + max(1, (Seconds + 59) div 60);
cron_next([once, _Hour, _Minute, _Second], FromMin) ->
    %% Preserve the existing behavior for absolute one-shot tuples until the
    %% persisted schema carries a date/timezone.
    FromMin + 1;
cron_next(CronSpec, FromMin) ->
    error({unsupported_cron_spec, CronSpec, FromMin}).

to_24h(12, am) -> 0;
to_24h(12, pm) -> 12;
to_24h(H, am) when H >= 1, H =< 11 -> H;
to_24h(H, pm) when H >= 1, H =< 11 -> H + 12.
