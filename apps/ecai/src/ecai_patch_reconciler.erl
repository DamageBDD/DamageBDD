-module(ecai_patch_reconciler).
-behaviour(gen_server).

%% Reconciles durable repair state with the patch-worker supervisor.
%%
%% Repair records are authoritative across VM restarts, but a persisted
%% `running` status is only meaningful while the matching patch worker is
%% actually alive. This process periodically compares the two and moves stale
%% interrupted jobs back to `queued` without discarding their durable stage,
%% generated patch, verifier diagnostics, or retry metadata.

-export([
    start_link/0,
    start_link/1,
    child_spec/1,
    run_now/0,
    status/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([active_worker_keys/1, should_recover/4]).
-endif.

-define(SERVER, ?MODULE).
-define(DEFAULT_INTERVAL_MS, 15000).
-define(DEFAULT_GRACE_MS, 120000).
-define(CHECKPOINT, patch_reconciler).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL_MS,
    grace_ms = ?DEFAULT_GRACE_MS,
    timer_ref = undefined,
    cycles = 0,
    scanned = 0,
    recovered = 0,
    active_workers = 0,
    last_run_at = undefined,
    last_error = undefined,
    opts = #{}
}).

start_link() -> start_link(#{}).
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

child_spec(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

run_now() -> gen_server:call(?SERVER, reconcile, infinity).
status() -> gen_server:call(?SERVER, status).

init(Opts) ->
    Interval = maps:get(
        interval_ms,
        Opts,
        application:get_env(ecai, code_patch_reconcile_interval_ms, ?DEFAULT_INTERVAL_MS)
    ),
    Grace = maps:get(
        grace_ms,
        Opts,
        application:get_env(ecai, code_patch_running_grace_ms, ?DEFAULT_GRACE_MS)
    ),
    State0 = #state{interval_ms = Interval, grace_ms = Grace, opts = Opts},
    State1 = schedule(State0, 3000),
    {ok, State1}.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(reconcile, _From, State0) ->
    State1 = cancel_timer(State0),
    {Summary, State2} = reconcile(State1),
    State3 = schedule(State2, State2#state.interval_ms),
    {reply, Summary, State3};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(reconcile, State0) ->
    State1 = State0#state{timer_ref = undefined},
    {_Summary, State2} = reconcile(State1),
    {noreply, schedule(State2, State2#state.interval_ms)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cancel_timer(State),
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

reconcile(State0) ->
    NowMs = erlang:system_time(millisecond),
    case {safe_repairs(), safe_children()} of
        {{ok, Repairs}, {ok, Children}} ->
            Active = active_worker_keys(Children),
            {Recovered, Errors} = lists:foldl(
                fun(Repair, {Recovered0, Errors0}) ->
                    case maybe_recover(Repair, Active, NowMs, State0#state.grace_ms) of
                        unchanged -> {Recovered0, Errors0};
                        {ok, _Key} -> {Recovered0 + 1, Errors0};
                        {error, Reason} -> {Recovered0, [Reason | Errors0]}
                    end
                end,
                {0, []},
                Repairs
            ),
            Summary = #{
                scanned => length(Repairs),
                active_workers => map_size(Active),
                recovered_running => Recovered,
                errors => lists:reverse(Errors)
            },
            State1 = State0#state{
                cycles = State0#state.cycles + 1,
                scanned = State0#state.scanned + length(Repairs),
                recovered = State0#state.recovered + Recovered,
                active_workers = map_size(Active),
                last_run_at = now_iso8601(),
                last_error =
                    case Errors of
                        [] -> undefined;
                        _ -> lists:reverse(Errors)
                    end
            },
            _ = checkpoint(State1, Summary),
            {Summary, State1};
        {{error, Reason}, _} ->
            fail_cycle({learning_store_unavailable, Reason}, State0);
        {_, {error, Reason}} ->
            fail_cycle({patch_supervisor_unavailable, Reason}, State0)
    end.

fail_cycle(Reason, State0) ->
    Summary = #{
        scanned => 0,
        active_workers => 0,
        recovered_running => 0,
        errors => [Reason]
    },
    State1 = State0#state{
        cycles = State0#state.cycles + 1,
        last_run_at = now_iso8601(),
        last_error = Reason
    },
    _ = checkpoint(State1, Summary),
    {Summary, State1}.

maybe_recover(Repair, Active, NowMs, GraceMs) when is_map(Repair) ->
    case repair_key(Repair) of
        {error, _} = Error ->
            case normalize_status(maps:get(status, Repair, undefined)) of
                running -> Error;
                _ -> unchanged
            end;
        {ok, Key} ->
            case should_recover(Repair, Key, Active, {NowMs, GraceMs}) of
                false -> unchanged;
                true -> recover_repair(Key, Repair)
            end
    end;
maybe_recover(_Repair, _Active, _NowMs, _GraceMs) ->
    unchanged.

should_recover(Repair, Key, Active, {NowMs, GraceMs}) ->
    normalize_status(maps:get(status, Repair, undefined)) =:= running andalso
        not maps:is_key(Key, Active) andalso
        stale_enough(Repair, NowMs, GraceMs).

recover_repair({Fp, Version}, Repair0) ->
    Now = now_iso8601(),
    Recovery = #{
        reason => stale_running_without_live_worker,
        recovered_at => Now,
        previous_status => running,
        previous_stage => maps:get(stage, Repair0, undefined)
    },
    Repair1 = maps:without(
        [worker, worker_pid, worker_ref, monitor_ref, pid, mref],
        Repair0
    ),
    Repair = Repair1#{
        status => queued,
        updated_at => Now,
        recovered_at => Now,
        recovery => Recovery
    },
    try ecai_learning_store:put_repair(Fp, Version, Repair) of
        ok -> {ok, {Fp, Version}};
        Other -> {error, {repair_requeue_failed, Fp, Version, Other}}
    catch
        Class:Reason ->
            {error, {repair_requeue_failed, Fp, Version, {Class, Reason}}}
    end.

repair_key(Repair) ->
    Fp0 = maps:get(fingerprint, Repair, undefined),
    Version0 = maps:get(finding_version, Repair, undefined),
    case {nonempty_binary(Fp0), nonempty_binary(Version0)} of
        {{ok, Fp}, {ok, Version}} -> {ok, {Fp, Version}};
        _ -> {error, {invalid_repair_identity, Fp0, Version0}}
    end.

active_worker_keys(Children) when is_list(Children) ->
    lists:foldl(
        fun
            ({{ecai_patch_worker, Fp0, Version0}, Pid, _Type, _Mods}, Acc) when
                is_pid(Pid)
            ->
                case {nonempty_binary(Fp0), nonempty_binary(Version0)} of
                    {{ok, Fp}, {ok, Version}} -> Acc#{{Fp, Version} => true};
                    _ -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        #{},
        Children
    ).

stale_enough(Repair, NowMs, GraceMs) ->
    case repair_timestamp_ms(Repair) of
        undefined -> true;
        Stamp when is_integer(Stamp) -> NowMs - Stamp >= max(0, GraceMs)
    end.

repair_timestamp_ms(Repair) ->
    first_timestamp([
        maps:get(updated_at_ms, Repair, undefined),
        maps:get(updated_at, Repair, undefined),
        maps:get(persisted_at, Repair, undefined),
        maps:get(started_at, Repair, undefined),
        maps:get(created_at, Repair, undefined)
    ]).

first_timestamp([]) ->
    undefined;
first_timestamp([undefined | Rest]) ->
    first_timestamp(Rest);
first_timestamp([Value | Rest]) ->
    case timestamp_ms(Value) of
        undefined -> first_timestamp(Rest);
        Ms -> Ms
    end.

timestamp_ms(I) when is_integer(I), I > 0 -> I;
timestamp_ms(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    timestamp_ms(binary_to_list(Bin));
timestamp_ms(List) when is_list(List), List =/= [] ->
    try calendar:rfc3339_to_system_time(List, [{unit, millisecond}]) of
        I when is_integer(I) -> I
    catch
        _:_ -> undefined
    end;
timestamp_ms(_) ->
    undefined.

normalize_status(running) -> running;
normalize_status(<<"running">>) -> running;
normalize_status(Other) -> Other.

safe_repairs() ->
    try ecai_learning_store:repairs() of
        Repairs when is_list(Repairs) -> {ok, Repairs};
        Other -> {error, {unexpected_repairs_response, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

safe_children() ->
    try supervisor:which_children(ecai_patch_sup) of
        Children when is_list(Children) -> {ok, Children};
        Other -> {error, {unexpected_children_response, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

checkpoint(State, Summary) ->
    Checkpoint = #{
        schema_version => 1,
        cycles => State#state.cycles,
        scanned => State#state.scanned,
        recovered => State#state.recovered,
        active_workers => State#state.active_workers,
        last_run_at => State#state.last_run_at,
        last_error => State#state.last_error,
        last_summary => Summary
    },
    try ecai_learning_store:put_checkpoint(?CHECKPOINT, Checkpoint) of
        Result -> Result
    catch
        _Class:_Reason -> ok
    end.

schedule(State0, Delay0) ->
    Delay = max(0, Delay0),
    TRef = erlang:send_after(Delay, self(), reconcile),
    State0#state{timer_ref = TRef}.

cancel_timer(State = #state{timer_ref = undefined}) ->
    State;
cancel_timer(State = #state{timer_ref = TRef}) ->
    _ = erlang:cancel_timer(TRef),
    State#state{timer_ref = undefined}.

status_map(State) ->
    #{
        cycles => State#state.cycles,
        scanned => State#state.scanned,
        recovered => State#state.recovered,
        active_workers => State#state.active_workers,
        interval_ms => State#state.interval_ms,
        grace_ms => State#state.grace_ms,
        last_run_at => State#state.last_run_at,
        last_error => State#state.last_error
    }.

nonempty_binary(undefined) -> error;
nonempty_binary(null) -> error;
nonempty_binary(B) when is_binary(B), byte_size(B) > 0 -> {ok, B};
nonempty_binary(L) when is_list(L), L =/= [] -> {ok, unicode:characters_to_binary(L)};
nonempty_binary(A) when is_atom(A) -> {ok, atom_to_binary(A, utf8)};
nonempty_binary(_) -> error.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).
