-module(ecai_patch_lifecycle).

%% Shared, revision-fenced failure accounting for the manager and reconciler.
%% Temporary patch workers are retried by the durable queue, never by OTP.
-export([failure_record/3, recover/3, owner_alive/1, running/1]).

running(Repair) ->
    lists:member(maps:get(status, Repair, undefined), [running, <<"running">>]).

owner_alive(Repair) ->
    local_alive(maps:get(worker_pid, Repair, undefined)) orelse
        local_alive(maps:get(dispatch_pid, Repair, undefined)).

local_alive(Pid) when is_pid(Pid), node(Pid) =:= node() ->
    erlang:is_process_alive(Pid);
local_alive(_) -> false.

%% Callers must establish that the worker is absent, or own the failing worker.
%% A conflict is success for recovery purposes: somebody already advanced it.
recover(Repair, Reason, Opts) ->
    case running(Repair) of
        false -> {ok, unchanged};
        true ->
            Fp = maps:get(fingerprint, Repair),
            Version = maps:get(finding_version, Repair),
            Updated = failure_record(Repair, Reason, Opts),
            case ecai_learning_store:compare_and_put_repair(Fp, Version, Repair, Updated) of
                {ok, Stored} -> {ok, Stored};
                {error, conflict} -> {ok, unchanged};
                Other -> {error, {recovery_persist_failed, Fp, Version, Other}}
            end
    end.

failure_record(Repair, Reason, Opts) ->
    Count0 = maps:get(retry_count, Repair, 0),
    Count = case Count0 of N when is_integer(N), N >= 0 -> N + 1; _ -> 1 end,
    Limit = ecai_patch_retry:retry_limit(Opts),
    NowMs = erlang:system_time(millisecond),
    Now = list_to_binary(calendar:system_time_to_rfc3339(
        NowMs, [{unit, millisecond}, {offset, "Z"}])),
    Base = maps:without([worker_pid, dispatch_pid, worker_started_at,
        worker_ref, monitor_ref, next_retry_at_ms, completed_at], Repair),
    Failed = Base#{retry_count => Count, last_error => Reason,
        failure_class => failure_class(Reason), last_failed_at => Now,
        updated_at => Now, recovery_protocol => 1},
    case Count >= Limit of
        true -> Failed#{status => failed, stage => terminal, retryable => false,
            error => {retry_exhausted, Reason}, completed_at => Now};
        false -> Failed#{status => retry_wait, stage => dispatch_wait,
            retryable => true, error => Reason,
            next_retry_at_ms => ecai_patch_retry:next_retry_at_ms(Count, NowMs, Opts)}
    end.

failure_class({worker_start_failed, _}) -> worker_start_failed;
failure_class({worker_down, _}) -> worker_down;
failure_class({worker_error, _}) -> worker_error;
failure_class({orphaned_worker, _}) -> orphaned_worker;
failure_class(_) -> worker_error.
