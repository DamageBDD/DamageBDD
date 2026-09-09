%%%-------------------------------------------------------------------
%%% @doc Poll bounded relay snapshots without giving relays control over the
%%% application lifecycle.
%%%
%%% Relay failures are tracked per URL with bounded backoff. Repeated identical
%%% transient failures are demoted to debug logs; local code/API faults remain
%%% error-level and include their concrete reason.
%%%-------------------------------------------------------------------
-module(erm_lens_sync).

-ifdef(TEST).
-export([retry_delay/2, status_snapshot/1, in_backoff/2]).
-endif.
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, refresh/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_BACKOFF_MS, 30000).
-define(DEFAULT_BACKOFF_MAX_MS, 300000).

start_link(C) -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).
refresh() -> gen_server:cast(?MODULE, refresh).
status() -> gen_server:call(?MODULE, status).

init(C) ->
    process_flag(trap_exit, true),
    ?LOG_INFO("ERM Lens sync initialized relays=~p refresh_ms=~p", [
        length(maps:get(relays, C, [])), maps:get(refresh_ms, C, 60000)
    ]),
    Timer = erlang:start_timer(0, self(), tick),
    {ok, #{config => C, jobs => #{}, status => #{}, timer => Timer}}.

handle_call(status, _, S) ->
    {reply, status_snapshot(S), S};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.

handle_cast(refresh, S) ->
    ?LOG_DEBUG("ERM Lens manual relay refresh requested", []),
    {noreply, start_jobs(S, true)};
handle_cast(_, S) ->
    {noreply, S}.

handle_info({timeout, Ref, tick}, S = #{timer := Ref}) ->
    cancel(maps:get(timer, S, undefined)),
    C = maps:get(config, S),
    Interval = erm_lens_config:integer(refresh_ms, C, 60000, 30000, 3600000),
    Timer = erlang:start_timer(Interval, self(), tick),
    {noreply, start_jobs(S#{timer := Timer}, false)};
handle_info({relay_result, Pid, Result}, S) ->
    case maps:take(Pid, maps:get(jobs, S)) of
        error ->
            {noreply, S};
        {#{monitor := Mon, timer := Timer, url := U, started_ms := Started}, Jobs} ->
            erlang:demonitor(Mon, [flush]),
            cancel(Timer),
            Duration = max(0, erlang:monotonic_time(millisecond) - Started),
            {Status1, Entry} = record_result(U, Result, Duration, S),
            log_relay_result(U, Result, Entry),
            {noreply, S#{jobs := Jobs, status := Status1}}
    end;
handle_info({job_timeout, Pid}, S) ->
    case maps:take(Pid, maps:get(jobs, S)) of
        error ->
            {noreply, S};
        {#{monitor := Mon, timer := Timer, url := U, started_ms := Started}, Jobs} ->
            cancel(Timer),
            erlang:demonitor(Mon, [flush]),
            exit(Pid, kill),
            Duration = max(0, erlang:monotonic_time(millisecond) - Started),
            Result = {error, relay_sample_timeout},
            S0 = S#{jobs := Jobs},
            {Status1, Entry} = record_result(U, Result, Duration, S0),
            ?LOG_WARNING(
                "ERM Lens relay sample timed out relay=~p duration_ms=~p failures=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), Duration, maps:get(consecutive_failures, Entry), maps:get(retry_in_ms, Entry)]
            ),
            {noreply, S0#{status := Status1}}
    end;
handle_info({'DOWN', Mon, process, Pid, Reason}, S) ->
    case maps:take(Pid, maps:get(jobs, S)) of
        {#{monitor := Mon, timer := Timer, url := U, started_ms := Started}, Jobs} ->
            cancel(Timer),
            Duration = max(0, erlang:monotonic_time(millisecond) - Started),
            Result = {error, {relay_worker_exit, Reason}},
            S0 = S#{jobs := Jobs},
            {Status1, Entry} = record_result(U, Result, Duration, S0),
            log_relay_result(U, Result, Entry),
            {noreply, S0#{status := Status1}};
        _ ->
            {noreply, S}
    end;
handle_info(Info, S) ->
    ?LOG_DEBUG("ERM Lens sync ignored message: ~p", [erm_lens_diagnostics:summary(Info)]),
    {noreply, S}.

terminate(Reason, S) ->
    ?LOG_INFO("Stopping ERM Lens sync reason=~p active_jobs=~p", [
        Reason, map_size(maps:get(jobs, S))
    ]),
    cancel(maps:get(timer, S, undefined)),
    maps:foreach(
        fun(P, J) ->
            cancel(maps:get(timer, J, undefined)),
            exit(P, shutdown)
        end,
        maps:get(jobs, S)
    ),
    ok.

code_change(_, S, _) ->
    cancel(maps:get(timer, S, undefined)),
    {ok, S#{timer => erlang:start_timer(0, self(), tick)}}.

start_jobs(S, Force) ->
    C = maps:get(config, S),
    Relays = lists:sublist(lists:usort(maps:get(relays, C, [])), 4),
    lists:foldl(
        fun(U, Acc) ->
            Jobs = maps:get(jobs, Acc),
            Status = maps:get(status, Acc),
            Busy = lists:any(fun(J) -> maps:get(url, J) =:= U end, maps:values(Jobs)),
            BackedOff = not Force andalso in_backoff(U, Status),
            case {Busy, BackedOff} of
                {true, _} ->
                    Acc;
                {false, true} ->
                    ?LOG_DEBUG("ERM Lens relay still in backoff relay=~p", [erm_lens_diagnostics:relay_label(U)]),
                    Acc;
                {false, false} ->
                    ?LOG_DEBUG("ERM Lens sampling relay=~p force=~p", [erm_lens_diagnostics:relay_label(U), Force]),
                    Started = erlang:monotonic_time(millisecond),
                    {Pid, Mon} = erm_lens_worker:start(relay_result, fun() ->
                        erm_lens_relay:fetch(U, C)
                    end),
                    Timer = erlang:send_after(40000, self(), {job_timeout, Pid}),
                    Prev = maps:get(U, Status, #{}),
                    Entry = Prev#{
                        state => connecting,
                        last_started_at => erlang:system_time(millisecond),
                        retry_in_ms => 0,
                        next_retry_mono => undefined
                    },
                    Acc#{
                        jobs := Jobs#{
                            Pid => #{
                                url => U,
                                monitor => Mon,
                                timer => Timer,
                                started_ms => Started
                            }
                        },
                        status := Status#{U => Entry}
                    }
            end
        end,
        S,
        Relays
    ).

record_result(U, Result, Duration, S) ->
    C = maps:get(config, S),
    Status0 = maps:get(status, S),
    Prev = maps:get(U, Status0, #{}),
    NowWall = erlang:system_time(millisecond),
    NowMono = erlang:monotonic_time(millisecond),
    case Result of
        {ok, Summary} ->
            Entry = #{
                state => ok,
                last_result => {ok, Summary},
                last_ok_at => NowWall,
                last_error_at => maps:get(last_error_at, Prev, undefined),
                consecutive_failures => 0,
                retry_in_ms => 0,
                next_retry_mono => undefined,
                duration_ms => Duration
            },
            {Status0#{U => Entry}, Entry};
        _ ->
            Failures = maps:get(consecutive_failures, Prev, 0) + 1,
            Delay = retry_delay(Failures, C),
            Entry = Prev#{
                state => error,
                last_result => Result,
                last_error_at => NowWall,
                consecutive_failures => Failures,
                retry_in_ms => Delay,
                next_retry_mono => NowMono + Delay,
                duration_ms => Duration
            },
            {Status0#{U => Entry}, Entry}
    end.

retry_delay(Failures, C) ->
    Base = erm_lens_config:integer(relay_backoff_ms, C, ?DEFAULT_BACKOFF_MS, 1000, 3600000),
    Max = max(Base, erm_lens_config:integer(relay_backoff_max_ms, C, ?DEFAULT_BACKOFF_MAX_MS, 1000, 3600000)),
    Shift = min(8, max(0, Failures - 1)),
    Ceiling = min(Max, Base * (1 bsl Shift)),
    %% Equal jitter spreads eligibility deadlines; refresh cadence still
    %% determines when the next automatic sampling opportunity occurs.
    Half = max(1, Ceiling div 2),
    Half + rand:uniform(max(1, Ceiling - Half)).

in_backoff(U, Status) ->
    case maps:get(U, Status, undefined) of
        #{state := error, next_retry_mono := At} when is_integer(At) ->
            erlang:monotonic_time(millisecond) < At;
        _ ->
            false
    end.

status_snapshot(S) ->
    Now = erlang:monotonic_time(millisecond),
    maps:map(
        fun(_U, Entry) ->
            Next = maps:get(next_retry_mono, Entry, undefined),
            Retry =
                case Next of
                    At when is_integer(At) ->
                        case maps:get(state, Entry, undefined) of
                            error -> max(0, At - Now);
                            _ -> 0
                        end;
                    _ -> 0
                end,
            Entry#{retry_in_ms => Retry}
        end,
        maps:get(status, S)
    ).

log_relay_result(U, {ok, Summary}, Entry) ->
    ?LOG_DEBUG(
        "ERM Lens relay sample complete relay=~p duration_ms=~p summary=~p",
        [erm_lens_diagnostics:relay_label(U), maps:get(duration_ms, Entry, undefined),
         erm_lens_diagnostics:summary(Summary)]
    );
log_relay_result(U, {error, Reason} = Result, Entry) ->
    Failures = maps:get(consecutive_failures, Entry, 1),
    Delay = maps:get(retry_in_ms, Entry, 0),
    case {error_class(Reason), Failures} of
        {local_fault, _} ->
            ?LOG_ERROR(
                "ERM Lens local relay implementation failure relay=~p reason=~p failures=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Reason), Failures, Delay]
            );
        {transient, 1} ->
            ?LOG_WARNING(
                "ERM Lens relay temporarily unavailable relay=~p reason=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Reason), Delay]
            );
        {transient, _} ->
            ?LOG_DEBUG(
                "ERM Lens relay still unavailable relay=~p reason=~p failures=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Reason), Failures, Delay]
            );
        {remote, 1} ->
            ?LOG_WARNING(
                "ERM Lens relay sample failed relay=~p reason=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Reason), Delay]
            );
        {remote, _} ->
            ?LOG_DEBUG(
                "ERM Lens relay sample still failing relay=~p reason=~p failures=~p retry_in_ms=~p",
                [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Reason), Failures, Delay]
            )
    end,
    _ = Result,
    ok;
log_relay_result(U, Other, Entry) ->
    ?LOG_WARNING("ERM Lens unexpected relay result relay=~p result=~p entry=~p", [erm_lens_diagnostics:relay_label(U), erm_lens_diagnostics:summary(Other),
         erm_lens_diagnostics:summary(Entry)]).

error_class({relay_api_undefined, _}) -> local_fault;
error_class(json_codec_unavailable) -> local_fault;
error_class({send_failed, json_codec_unavailable}) -> local_fault;
error_class({relay_failed, _, Reason}) -> error_class(Reason);
error_class({relay_query_timeout, _, _}) -> transient;
error_class({feed_unavailable, _}) -> local_fault;
error_class({upgrade_rejected, Status, _}) when Status >= 500 -> transient;
error_class({upgrade_rejected, Status}) when Status >= 500 -> transient;
error_class(upgrade_timeout) -> transient;
error_class(relay_sample_timeout) -> transient;
error_class({await_up_failed, timeout}) -> transient;
error_class({gun_down, _}) -> transient;
error_class({relay_down, _}) -> transient;
error_class(_) -> remote.

cancel(undefined) ->
    ok;
cancel(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
