%% One non-overlapping background task per server, finite deadlines and
%% coalesced triggers. Network calls never execute inside handle_call/init.
-module(damage_ipfs_loop).
-behaviour(gen_server).
-export([start_link/5, trigger/1, data/1, set_data/2, update_data/2, status/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
start_link(Name, Module, Interval, C, Data) ->
    gen_server:start_link({local, Name}, ?MODULE, {Module, Interval, C, Data}, []).
trigger(Name) -> damage_ipfs_config:call(Name, trigger, 5000).
data(Name) -> damage_ipfs_config:call(Name, data, 5000).
set_data(Name, Data) -> damage_ipfs_config:call(Name, {data, Data}, 5000).
update_data(Name, Fun) -> damage_ipfs_config:call(Name, {update_data, Fun}, 5000).
status(Name) -> damage_ipfs_config:call(Name, status, 5000).
init({Module, Interval, C, Data}) ->
    process_flag(trap_exit, true),
    S = #{
        module => Module,
        interval => Interval,
        config => C,
        data => Data,
        data_version => 0,
        running => undefined,
        pending => false,
        failures => 0,
        last_result => never_run,
        last_run => undefined
    },
    {ok, schedule(0, S)}.
handle_call(data, _, S) ->
    {reply, maps:get(data, S), S};
handle_call(status, _, S) ->
    {reply,
        #{
            running => maps:get(running, S) =/= undefined,
            last_result => maps:get(last_result, S),
            last_run => maps:get(last_run, S),
            failures => maps:get(failures, S)
        },
        S};
handle_call(trigger, _, S) ->
    {reply, {ok, scheduled}, trigger_state(S)};
handle_call({update_data, F}, _, S) ->
    case F(maps:get(data, S), maps:get(config, S)) of
        {ok, D} ->
            {reply, {ok, scheduled},
                trigger_state(S#{
                    data => D,
                    data_version => maps:get(data_version, S) + 1
                })};
        {error, _} = E ->
            {reply, E, S}
    end;
handle_call({data, D}, _, S) ->
    {reply, {ok, scheduled},
        trigger_state(S#{
            data => D,
            data_version => maps:get(data_version, S) + 1
        })};
handle_call(_, _, S) ->
    {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({tick, Token}, S = #{timer := {_, Token}, running := undefined}) ->
    Owner = self(),
    Ref = make_ref(),
    M = maps:get(module, S),
    C = maps:get(config, S),
    D = maps:get(data, S),
    {Pid, Mon} = spawn_opt(
        fun() ->
            R =
                try M:run(C, D) of
                    V -> V
                catch
                    Class:Reason -> {error, {task_exception, Class, Reason}}
                end,
            Owner ! {result, Ref, R}
        end,
        [link, monitor]
    ),
    T = erlang:send_after(maps:get(loop_timeout_ms, C), self(), {task_timeout, Ref}),
    {noreply, S#{
        running => #{
            ref => Ref,
            pid => Pid,
            mon => Mon,
            timer => T,
            version => maps:get(data_version, S)
        },
        pending => false
    }};
handle_info({result, Ref, R}, S = #{running := #{ref := Ref}}) ->
    {noreply, complete(R, S)};
handle_info({task_timeout, Ref}, S = #{running := #{ref := Ref}}) ->
    {noreply, complete({error, timeout}, S)};
handle_info({'DOWN', Mon, process, _, Reason}, S = #{running := #{mon := Mon}}) ->
    {noreply, complete({error, {worker_down, Reason}}, S)};
handle_info(_, S) ->
    {noreply, S}.

trigger_state(S = #{running := undefined}) -> schedule(0, S);
trigger_state(S) -> S#{pending => true}.
complete(R, S = #{running := Run, config := C}) ->
    cancel_run(Run),
    {Result, Data} =
        case R of
            {ok, Summary, NewData} ->
                D =
                    case maps:get(version, Run) =:= maps:get(data_version, S) of
                        true -> NewData;
                        false -> maps:get(data, S)
                    end,
                {{ok, Summary}, D};
            {error, _} ->
                {R, maps:get(data, S)};
            _ ->
                {{error, invalid_task_result}, maps:get(data, S)}
        end,
    Failed =
        case Result of
            {error, _} -> true;
            {ok, #{failed := N}} when N > 0 -> true;
            _ -> false
        end,
    Failures =
        case Failed of
            true -> maps:get(failures, S) + 1;
            false -> 0
        end,
    %% Only transitions are logged. Do not dump bodies, credentials or content.
    PreviousFailed = maps:get(failures, S) > 0,
    case {Failed, PreviousFailed} of
        {true, false} ->
            logger:warning("IPFS background component ~p degraded", [maps:get(module, S)]);
        {false, true} ->
            logger:notice("IPFS background component ~p recovered", [maps:get(module, S)]);
        _ ->
            ok
    end,
    Base = maps:get(interval, S),
    Delay =
        case Failed of
            true ->
                Cap = maps:get(retry_max_ms, C),
                Backoff = min(Cap, Base * (1 bsl min(Failures, 8))),
                min(Cap, Backoff + rand:uniform(max(1, Backoff div 5)));
            false ->
                Base
        end,
    Next =
        case maps:get(pending, S) of
            true -> 0;
            false -> Delay
        end,
    schedule(Next, S#{
        running => undefined,
        data => Data,
        last_result => Result,
        last_run => damage_ipfs_config:now_ms(),
        failures => Failures
    }).
schedule(Ms, S) ->
    case maps:find(timer, S) of
        {ok, {Old, _}} -> erlang:cancel_timer(Old);
        error -> ok
    end,
    Token = make_ref(),
    T = erlang:send_after(Ms, self(), {tick, Token}),
    S#{timer => {T, Token}}.
cancel_run(#{pid := P, mon := M, timer := T}) ->
    erlang:cancel_timer(T),
    exit(P, kill),
    erlang:demonitor(M, [flush]);
cancel_run(undefined) ->
    ok.
terminate(_, S) ->
    {T, _} = maps:get(timer, S),
    erlang:cancel_timer(T),
    cancel_run(maps:get(running, S)),
    ok.
code_change(_, S, _) -> {ok, S}.
