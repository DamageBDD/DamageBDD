%% Bounded accepted work, absolute deadlines and caller/worker monitoring.
%% Copyright Steven Joseph. SPDX-License-Identifier: Apache-2.0
-module(damage_ipfs_queue).
-behaviour(gen_server).
-export([start_link/5, request/2, status/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

start_link(Name, Executor, Limit, QueueLimit, C) ->
    gen_server:start_link(
        {local, Name},
        ?MODULE,
        {Executor, Limit, QueueLimit, C},
        []
    ).
request(Name, Request) ->
    %% Resolve the configured budget from the running service, not mutable
    %% application env. Config is fixed until the subtree is restarted.
    case damage_ipfs_config:call(Name, budget, 5000) of
        T when is_integer(T) ->
            Deadline = erlang:monotonic_time(millisecond) + T,
            damage_ipfs_config:call(Name, {request, Request, Deadline}, T + 1000);
        Error ->
            Error
    end.
status(Name) -> damage_ipfs_config:call(Name, status, 5000).

init({Executor, Limit, QueueLimit, C}) ->
    process_flag(trap_exit, true),
    {ok, #{
        executor => Executor,
        limit => Limit,
        queue_limit => QueueLimit,
        config => C,
        active => 0,
        jobs => #{},
        queue => queue:new()
    }}.

handle_call(budget, _, S = #{config := C}) ->
    {reply, maps:get(request_timeout_ms, C), S};
handle_call(status, _, S) ->
    {reply,
        #{
            active => maps:get(active, S),
            queued => queue:len(maps:get(queue, S)),
            limit => maps:get(limit, S),
            queue_limit => maps:get(queue_limit, S)
        },
        S};
handle_call({request, Request, Deadline}, From, S = #{jobs := Jobs, config := C}) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    Full = map_size(Jobs) >= maps:get(limit, S) + maps:get(queue_limit, S),
    Large = erlang:external_size(Request) > maps:get(max_request_bytes, C),
    case {Remaining > 0, Full, Large} of
        {false, _, _} ->
            {reply, {error, timeout}, S};
        {_, true, _} ->
            {reply, {error, overloaded}, S};
        {_, _, true} ->
            {reply, {error, request_too_large}, S};
        _ ->
            Ref = make_ref(),
            Caller = erlang:monitor(process, element(1, From)),
            Timer = erlang:send_after(Remaining, self(), {deadline, Ref}),
            J = #{
                from => From,
                caller => Caller,
                timer => Timer,
                request => Request,
                deadline => Deadline
            },
            S1 = S#{
                jobs => Jobs#{Ref => J},
                queue => queue:in(Ref, maps:get(queue, S))
            },
            {noreply, drain(S1)}
    end;
handle_call(_, _, S) ->
    {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({job_result, Ref, Result}, S) ->
    {noreply, finish(Ref, Result, true, S)};
handle_info({deadline, Ref}, S) ->
    {noreply, finish(Ref, {error, timeout}, true, S)};
handle_info({'DOWN', Mon, process, _, Reason}, S = #{jobs := Jobs}) ->
    Matches = [
        {R, J}
     || {R, J} <- maps:to_list(Jobs),
        maps:get(caller, J) =:= Mon orelse maps:get(worker_mon, J, none) =:= Mon
    ],
    case Matches of
        [{R, J}] ->
            IsCaller = maps:get(caller, J) =:= Mon,
            {noreply, finish(R, {error, {worker_down, Reason}}, not IsCaller, S)};
        [] ->
            {noreply, S}
    end;
handle_info(_, S) ->
    {noreply, S}.

drain(S = #{active := N, limit := Limit}) when N >= Limit -> S;
drain(S = #{queue := Q, jobs := Jobs, active := N, executor := M, config := C}) ->
    case queue:out(Q) of
        {empty, _} ->
            S;
        {{value, Ref}, Q1} ->
            J = maps:get(Ref, Jobs),
            case maps:get(deadline, J) > erlang:monotonic_time(millisecond) of
                false ->
                    finish(Ref, {error, timeout}, true, S);
                true ->
                    Owner = self(),
                    Request = maps:get(request, J),
                    {Pid, Mon} = spawn_opt(
                        fun() ->
                            Result =
                                try M:execute(Request, C) of
                                    R -> R
                                catch
                                    Class:Reason -> {error, {backend_exception, Class, Reason}}
                                end,
                            Owner ! {job_result, Ref, Result}
                        end,
                        [link, monitor]
                    ),
                    J1 = J#{worker => Pid, worker_mon => Mon},
                    drain(S#{queue => Q1, active => N + 1, jobs => Jobs#{Ref => J1}})
            end
    end.

finish(Ref, Result, Reply, S = #{jobs := Jobs, queue := Q, active := N}) ->
    case maps:take(Ref, Jobs) of
        error ->
            S;
        {J, Rest} ->
            cleanup(J),
            case Reply of
                true -> gen_server:reply(maps:get(from, J), Result);
                false -> ok
            end,
            Delta =
                case maps:is_key(worker, J) of
                    true -> 1;
                    false -> 0
                end,
            drain(S#{
                jobs => Rest,
                active => N - Delta,
                queue => queue:filter(fun(R) -> R =/= Ref end, Q)
            })
    end.
cleanup(J) ->
    erlang:cancel_timer(maps:get(timer, J)),
    erlang:demonitor(maps:get(caller, J), [flush]),
    case maps:find(worker, J) of
        {ok, P} ->
            %% Do not unlink before killing: linked backend connections must
            %% receive the worker's death even during forced cancellation.
            exit(P, kill),
            erlang:demonitor(maps:get(worker_mon, J), [flush]);
        error ->
            ok
    end.
terminate(_, #{jobs := Jobs}) ->
    maps:foreach(
        fun(_, J) ->
            cleanup(J),
            gen_server:reply(maps:get(from, J), {error, unavailable})
        end,
        Jobs
    ),
    ok.
code_change(_, S, _) -> {ok, S}.
