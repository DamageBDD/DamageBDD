%% Owner-scoped volatile dashboard jobs. No wallet, cloud, chain or L402 calls.
%% All expensive work happens outside the server; admission is serialized here.
-module(ecai_math_dashboard_srv).
-behaviour(gen_server).
-export([start_link/0, child_specs/0, enabled/0, submit/2, list/1, get/2, replay/2, replay/3, path/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TTL_MS, 3600000).
-define(MAX_RECORDS, 32).
-define(MAX_OWNER_RECORDS, 8).
-define(DEADLINE_MS, 60000).

enabled() -> application:get_env(ecai, math_dashboard_enabled, true) =:= true.
child_specs() ->
    case enabled() of
        true -> [#{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent,
                   shutdown => 5000, type => worker, modules => [?MODULE]}];
        false -> []
    end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
submit(Owner, Body) -> call({submit, Owner, Body}).
list(Owner) -> call({list, Owner}).
get(Owner, Id) -> call({get, Owner, Id}).
replay(Owner, Id) -> replay(Owner, Id, undefined).
replay(Owner, Id, ModelId) -> call({replay, Owner, Id, ModelId}).
path(Owner, Id, ModelId) -> call({path, Owner, Id, ModelId}).
call(Request) ->
    case enabled() of
        false -> {error, math_dashboard_disabled};
        true ->
            try gen_server:call(?MODULE, Request, 5000)
            catch exit:_ -> {error, math_dashboard_unavailable} end
    end.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #{jobs => #{}, sweep => erlang:send_after(60000, self(), sweep)}}.

handle_call({list, Owner}, _, S0) ->
    S = prune(S0),
    Jobs = [public(J, false) || J <- owned(Owner, S)],
    {reply, {ok, Jobs}, S};
handle_call({get, Owner, Id}, _, S0) ->
    S = prune(S0),
    Reply = case lookup(Owner, Id, S) of {ok, J} -> {ok, public(J, true)}; E -> E end,
    {reply, Reply, S};
handle_call({submit, Owner, Body}, _, S0) ->
    S = prune(S0),
    case admission(Owner, S) of
        ok ->
            case ecai_math_dashboard_task:prepare(Body) of
                {ok, Task} -> start_task(Owner, Task, #{}, S);
                E -> {reply, E, S}
            end;
        E -> {reply, E, S}
    end;
handle_call({path, Owner, Id, ModelId}, _, S0) ->
    S = prune(S0),
    Reply = case lookup(Owner,Id,S) of {ok,J} -> selected_path(J,ModelId); E -> E end,
    {reply,Reply,S};
handle_call({replay, Owner, Id, ModelId}, _, S0) ->
    S = prune(S0),
    case lookup(Owner, Id, S) of
        {ok, J} ->
            case selected_path(J,ModelId) of
                {ok,Bin} ->
                    case admission(Owner,S) of
                        ok ->
                            Extra = case ModelId of
                                undefined -> #{replayed_job_id=>Id};
                                _ -> #{replayed_job_id=>Id,replayed_model_id=>ModelId}
                            end,
                            start_task(Owner,#{operation=>replay,path_json=>Bin},Extra,S);
                        E -> {reply,E,S}
                    end;
                E -> {reply,E,S}
            end;
        E -> {reply, E, S}
    end;
handle_call(_, _, S) -> {reply, {error, invalid_request}, S}.
handle_cast(_, S) -> {noreply, S}.

start_task(Owner, Task, Extra, S0) ->
    %% Evict only completed records; a running task is never silently dropped.
    S = make_room(Owner, S0),
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)), Parent = self(),
    {Pid, Ref} = spawn_opt(fun() ->
        Result = try ecai_math_dashboard_task:execute(Task)
                 catch _:_ -> {error, math_worker_failed} end,
        Parent ! {math_result, self(), Id, Result}
    end, [link, monitor, {max_heap_size, #{size => 4000000, kill => true, error_logger => false}}]),
    Timer = erlang:send_after(?DEADLINE_MS, self(), {deadline, Id, Pid}),
    Job = Extra#{id => Id, owner => Owner, operation => maps:get(operation, Task),
                 status => running, created_at_ms => erlang:system_time(millisecond),
                 started_mono => erlang:monotonic_time(millisecond),
                 pid => Pid, monitor => Ref, timer => Timer},
    {reply, {ok, public(Job, false)}, S#{jobs := (maps:get(jobs, S))#{Id => Job}}}.

handle_info({math_result, Pid, Id, Result}, S) ->
    case maps:find(Id, maps:get(jobs, S)) of
        {ok, #{pid := Pid, status := running} = J} ->
            erlang:cancel_timer(maps:get(timer, J)),
            %% Retain slot until DOWN, which also orders worker cleanup.
            Done = case Result of
                {ok, R} -> J#{status := succeeded, result => R};
                {error, Why} ->
                    Failed = J#{status := failed, error => error_text(Why)},
                    case Why of
                        timeout -> Failed#{cooldown_until => erlang:monotonic_time(millisecond) + 30000};
                        {worker_exit, _} -> Failed#{cooldown_until => erlang:monotonic_time(millisecond) + 30000};
                        _ -> Failed
                    end
            end,
            put_job(Id, Done#{finished_at_ms => erlang:system_time(millisecond)}, S);
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Ref, process, Pid, _Reason}, S) ->
    case [J || J <- maps:values(maps:get(jobs, S)), maps:get(monitor, J, none) =:= Ref] of
        [#{id := Id} = J] ->
            erlang:cancel_timer(maps:get(timer, J)),
            Clean = maps:without([pid, monitor, timer], J),
            Done = case maps:get(status, J) of
                running -> Clean#{status := failed, error => <<"math_worker_terminated">>,
                    finished_at_ms => erlang:system_time(millisecond),
                    cooldown_until => erlang:monotonic_time(millisecond) + 30000};
                _ -> Clean
            end,
            unlink(Pid), put_job(Id, Done, S);
        _ -> {noreply, S}
    end;
handle_info({deadline, Id, Pid}, S) ->
    case maps:find(Id, maps:get(jobs, S)) of
        {ok, #{pid := Pid, status := running}} -> exit(Pid, kill);
        _ -> ok
    end,
    {noreply, S};
handle_info(sweep, S) ->
    {noreply, (prune(S))#{sweep := erlang:send_after(60000, self(), sweep)}};
handle_info(_, S) -> {noreply, S}.

terminate(_, S) ->
    erlang:cancel_timer(maps:get(sweep, S)),
    [exit(P, shutdown) || #{pid := P} <- maps:values(maps:get(jobs, S))], ok.
code_change(_, S, _) -> {ok, S}.
put_job(Id, J, S) -> {noreply, S#{jobs := (maps:get(jobs, S))#{Id => J}}}.

selected_path(#{status:=succeeded,result:=#{path_json:=Bin}},undefined) -> {ok,Bin};
selected_path(#{status:=succeeded,result:=#{exploration:=_}},undefined) -> {error,model_selection_required};
selected_path(#{status:=succeeded,result:=#{exploration:=#{<<"results">>:=Rows}}},ModelId)
        when is_binary(ModelId), byte_size(ModelId) =:= 64 ->
    case [maps:get(<<"path_json">>,R) || R <- Rows,maps:get(<<"model_id">>,R)=:=ModelId] of
        [Bin] -> {ok,Bin};
        _ -> {error,not_found}
    end;
selected_path(#{status:=succeeded},_) -> {error,not_found};
selected_path(_,_) -> {error,result_not_ready}.

lookup(Owner, Id, S) ->
    case maps:find(Id, maps:get(jobs, S)) of
        {ok, #{owner := Owner} = J} -> {ok, J};
        _ -> {error, not_found}
    end.
owned(Owner, S) ->
    lists:sort(fun(A, B) -> {maps:get(created_at_ms, A), maps:get(id, A)} >
                           {maps:get(created_at_ms, B), maps:get(id, B)} end,
               [J || #{owner := O} = J <- maps:values(maps:get(jobs, S)), O =:= Owner]).
active(J) -> maps:is_key(pid, J) orelse
    maps:get(cooldown_until, J, -999999999999999999) > erlang:monotonic_time(millisecond).
admission(Owner, S) when is_binary(Owner), byte_size(Owner) > 0, byte_size(Owner) =< 512 ->
    Mine = owned(Owner, S),
    AllActive = [J || J <- maps:values(maps:get(jobs, S)), active(J)],
    Recent = [J || J <- Mine, erlang:monotonic_time(millisecond) - maps:get(started_mono, J) < 1000],
    case {lists:any(fun active/1, Mine), length(AllActive) >= 2, Recent =/= []} of
        {true, _, _} -> {error, owner_busy};
        {_, true, _} -> {error, math_capacity_full};
        {_, _, true} -> {error, rate_limited};
        _ -> ok
    end;
admission(_, _) -> {error, authenticated_account_required}.
prune(S) ->
    Now = erlang:monotonic_time(millisecond),
    S#{jobs := maps:filter(fun(_, J) -> active(J) orelse
        Now - maps:get(started_mono, J) < ?TTL_MS end, maps:get(jobs, S))}.
make_room(Owner, S) ->
    S1 = case length(owned(Owner, S)) >= ?MAX_OWNER_RECORDS of
        true -> evict([J || J <- owned(Owner, S), not active(J)], S);
        false -> S
    end,
    case map_size(maps:get(jobs, S1)) >= ?MAX_RECORDS of
        true -> evict([J || J <- maps:values(maps:get(jobs, S1)), not active(J)], S1);
        false -> S1
    end.
evict(Jobs, S) ->
    [Old | _] = lists:sort(fun(A, B) -> maps:get(started_mono, A) < maps:get(started_mono, B) end, Jobs),
    S#{jobs := maps:remove(maps:get(id, Old), maps:get(jobs, S))}.
public(J, Full) ->
    Base = maps:with([id, operation, status, created_at_ms, finished_at_ms, error, replayed_job_id, replayed_model_id], J),
    Public = Base#{retention => <<"Volatile: up to 8 jobs per account, 32 per node, one hour; cleared on restart. Export evidence to keep it.">>},
    case {Full, maps:find(result, J)} of
        {true, {ok, R}} -> Public#{result => R};
        _ -> Public
    end.
error_text(Why) ->
    B = iolist_to_binary(io_lib:format("~0P", [Why, 6])),
    case byte_size(B) > 600 of true -> binary:part(B, 0, 600); false -> B end.
