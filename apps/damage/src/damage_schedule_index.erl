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
    %% Pull per-account schedules ONLY
    Schedules = damage_schedule:get_schedules(Account),
    NowMin = epoch_minute(),
    lists:foreach(
        fun(S) ->
            Id = maps:get(id, S),
            Cron = maps:get(cron, S),
            upsert_internal(Account, Id, S, Cron, NowMin)
        end,
        Schedules
    ),
    {noreply, State};
handle_cast({upsert, Account, Id, ScheduleMap}, State) ->
    Cron = maps:get(cron, ScheduleMap),
    upsert_internal(Account, Id, ScheduleMap, Cron, epoch_minute()),
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
    reschedule(Account, Id, Cron).
%%--------------------------------------------------------------------
%% Internal logic
%%--------------------------------------------------------------------

upsert_internal(Account, Id, ScheduleMap, CronSpec, NowMin) ->
    NextMin = cron_next(CronSpec, NowMin),
    ets:insert(?SCHED_BY_ID, {{Account, Id}, ScheduleMap}),
    ets:insert(?NEXT_DUE, {{Account, Id}, NextMin}),
    ets:insert(?DUE_BUCKET, {NextMin, {Account, Id}}).

run_tick() ->
    NowMin = epoch_minute(),
    DueKeys = due_keys(NowMin, NowMin + ?DUE_WINDOW_MIN),
    Eligible = filter_active_accounts(DueKeys),
    lists:foreach(fun execute/1, Eligible).

execute({Account, Id}) ->
    case ets:lookup(?SCHED_BY_ID, {Account, Id}) of
        [{{_, _}, Schedule}] ->
            maybe_run(Account, Id, Schedule);
        [] ->
            ok
    end.

reschedule(Account, Id, Cron) ->
    NowMin = epoch_minute(),
    NextMin = cron_next(Cron, NowMin + 1),
    ets:insert(?NEXT_DUE, {{Account, Id}, NextMin}),
    ets:insert(?DUE_BUCKET, {NextMin, {Account, Id}}).

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

cron_next([daily, every, Second, sec], FromMin) when is_integer(Second), Second > 0 ->
    %% minute-resolution index: run on the next minute boundary
    FromMin + 1;
cron_next([daily, every, Hour, Minute, AMPM], FromMin) when
    is_integer(Hour), is_integer(Minute), is_atom(AMPM)
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
    FromMin + max(1, Seconds div 60);
cron_next([once, _Hour, _Minute, _Second], FromMin) ->
    %% one-shot absolute times need proper wall clock conversion;
    %% for now, schedule the next minute as a placeholder
    FromMin + 1;
cron_next(CronSpec, FromMin) ->
    error({unsupported_cron_spec, CronSpec, FromMin}).

to_24h(12, am) -> 0;
to_24h(12, pm) -> 12;
to_24h(H, am) when H >= 1, H =< 11 -> H;
to_24h(H, pm) when H >= 1, H =< 11 -> H + 12.
