%% Bounded OTP lifecycle for local inference. One active request per principal,
%% a node-wide concurrency cap, deadline and caller/worker monitoring.
-module(damage_bdd_service).
-behaviour(gen_server).
-export([start_link/0, generate/3, cancel/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
generate(Id, Prompt, Context) ->
    gen_server:call(?MODULE, {generate, Id, Prompt, Context}, timeout_ms() + 5000).
cancel(Id, Principal) -> gen_server:call(?MODULE, {cancel, Id, Principal}).
init([]) -> process_flag(trap_exit, true), {ok, #{jobs => #{}}}.

handle_call({generate, Id, Prompt, #{public_key := Principal} = Context}, From,
            #{jobs := Jobs} = State) ->
    Limit = case application:get_env(damage, bdd_generation_concurrency, 2) of
        N when is_integer(N), N >= 1, N =< 16 -> N;
        _ -> 2
    end,
    case maps:is_key(Principal, Jobs) orelse map_size(Jobs) >= Limit of
        true -> {reply, {error, generation_busy,
            <<"Generation is already running or the node is at capacity. Retry after the current request completes.">>}, State};
        false ->
            Parent = self(),
            {Pid, Ref} = spawn_opt(fun() ->
                Result = try damage_bdd_generator:generate(Prompt, Context)
                         catch _:_ -> {error, generation_failed,
                             <<"Generation failed. Check the local ECAI service and retry.">>} end,
                Parent ! {bdd_done, Principal, self(), Result}
            end, [link, monitor]),
            CallerRef = monitor(process, element(1, From)),
            Timer = erlang:send_after(timeout_ms(), self(), {bdd_timeout, Principal, Pid}),
            Job = #{pid => Pid, ref => Ref, caller_ref => CallerRef, timer => Timer,
                    from => From, id => Id},
            {noreply, State#{jobs := Jobs#{Principal => Job}}}
    end;
handle_call({cancel, Id, Principal}, _From, #{jobs := Jobs} = State) ->
    case maps:find(Principal, Jobs) of
        {ok, #{id := Id} = Job} ->
            exit(maps:get(pid, Job), kill),
            gen_server:reply(maps:get(from, Job), {error, generation_cancelled, <<"Generation cancelled.">>}),
            {reply, {ok, cancelled}, remove(Principal, Job, State)};
        _ -> {reply, {ok, not_running}, State}
    end;
handle_call(_, _, State) -> {reply, {error, bad_request, <<"Invalid generation request.">>}, State}.

handle_info({bdd_done, Principal, Pid, Result}, #{jobs := Jobs} = State) ->
    case maps:find(Principal, Jobs) of
        {ok, #{pid := Pid} = Job} ->
            gen_server:reply(maps:get(from, Job), Result),
            {noreply, remove(Principal, Job, State)};
        _ -> {noreply, State}
    end;
handle_info({bdd_timeout, Principal, Pid}, #{jobs := Jobs} = State) ->
    case maps:find(Principal, Jobs) of
        {ok, #{pid := Pid} = Job} ->
            exit(Pid, kill),
            gen_server:reply(maps:get(from, Job), {error, generation_timeout, <<"Generation timed out.">>}),
            {noreply, remove(Principal, Job, State)};
        _ -> {noreply, State}
    end;
handle_info({'DOWN', Ref, process, _, _}, #{jobs := Jobs} = State) ->
    Matching = [{P, J} || {P, J} <- maps:to_list(Jobs),
                         maps:get(ref, J) =:= Ref orelse maps:get(caller_ref, J) =:= Ref],
    State1 = lists:foldl(fun({P, J}, S) ->
        exit(maps:get(pid, J), kill),
        gen_server:reply(maps:get(from, J), {error, generation_failed, <<"Generation stopped.">>}),
        remove(P, J, S)
    end, State, Matching),
    {noreply, State1};
handle_info(_, State) -> {noreply, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, #{jobs := Jobs}) ->
    maps:foreach(fun(_, J) -> exit(maps:get(pid, J), kill) end, Jobs), ok.
code_change(_, State, _) -> {ok, State}.

remove(Principal, Job, #{jobs := Jobs} = State) ->
    erlang:cancel_timer(maps:get(timer, Job)),
    erlang:demonitor(maps:get(ref, Job), [flush]),
    erlang:demonitor(maps:get(caller_ref, Job), [flush]),
    State#{jobs := maps:remove(Principal, Jobs)}.
timeout_ms() ->
    case application:get_env(damage, bdd_generation_timeout_ms, 120000) of
        N when is_integer(N), N >= 1000, N =< 300000 -> N;
        _ -> 120000
    end.
