%%--------------------------------------------------------------------
%% Live progress fan-out for indexing jobs.
%%
%% Durable replay comes from ecai_index_jobs_srv:events/3. This process only
%% owns live subscriptions and monitors subscribers so disconnected SSE clients
%% are removed automatically.
%%--------------------------------------------------------------------
-module(ecai_index_job_events).
-behaviour(gen_server).

-export([
    start_link/0,
    subscribe/2,
    unsubscribe/2,
    publish/2,
    subscriber_count/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(st, {
    subscriptions = #{},
    monitors = #{}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

subscribe(JobId, Pid) when is_binary(JobId), is_pid(Pid) ->
    gen_server:call(?MODULE, {subscribe, JobId, Pid});
subscribe(_JobId, _Pid) ->
    {error, badarg}.

unsubscribe(JobId, Pid) when is_binary(JobId), is_pid(Pid) ->
    gen_server:call(?MODULE, {unsubscribe, JobId, Pid});
unsubscribe(_JobId, _Pid) ->
    {error, badarg}.

publish(JobId, Event) when is_binary(JobId), is_map(Event) ->
    gen_server:cast(?MODULE, {publish, JobId, Event});
publish(_JobId, _Event) ->
    {error, badarg}.

subscriber_count(JobId) when is_binary(JobId) ->
    gen_server:call(?MODULE, {subscriber_count, JobId}).

init([]) ->
    {ok, #st{}}.

handle_call({subscribe, JobId, Pid}, _From, State0) ->
    case lookup_subscription(JobId, Pid, State0) of
        {ok, _Ref} ->
            {reply, ok, State0};
        not_found ->
            Ref = erlang:monitor(process, Pid),
            State1 = put_subscription(JobId, Pid, Ref, State0),
            {reply, ok, State1}
    end;
handle_call({unsubscribe, JobId, Pid}, _From, State0) ->
    {reply, ok, remove_subscription(JobId, Pid, State0)};
handle_call({subscriber_count, JobId}, _From, State = #st{subscriptions = Subs}) ->
    Count = map_size(maps:get(JobId, Subs, #{})),
    {reply, Count, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unhandled}, State}.

handle_cast({publish, JobId, Event}, State = #st{subscriptions = Subs}) ->
    JobSubs = maps:get(JobId, Subs, #{}),
    maps:foreach(
        fun(Pid, _Ref) ->
            Pid ! {ecai_index_job_event, JobId, Event}
        end,
        JobSubs
    ),
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State0 = #st{monitors = Mons}) ->
    case maps:take(Ref, Mons) of
        {{JobId, Pid}, Mons1} ->
            State1 = remove_subscription_without_demonitor(
                JobId,
                Pid,
                State0#st{monitors = Mons1}
            ),
            {noreply, State1};
        error ->
            {noreply, State0}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

lookup_subscription(JobId, Pid, #st{subscriptions = Subs}) ->
    case maps:find(Pid, maps:get(JobId, Subs, #{})) of
        {ok, Ref} -> {ok, Ref};
        error -> not_found
    end.

put_subscription(
    JobId,
    Pid,
    Ref,
    State = #st{
        subscriptions = Subs0,
        monitors = Mons0
    }
) ->
    JobSubs0 = maps:get(JobId, Subs0, #{}),
    JobSubs1 = JobSubs0#{Pid => Ref},
    State#st{
        subscriptions = Subs0#{JobId => JobSubs1},
        monitors = Mons0#{Ref => {JobId, Pid}}
    }.

remove_subscription(JobId, Pid, State0) ->
    case lookup_subscription(JobId, Pid, State0) of
        {ok, Ref} ->
            _ = erlang:demonitor(Ref, [flush]),
            State1 = State0#st{monitors = maps:remove(Ref, State0#st.monitors)},
            remove_subscription_without_demonitor(JobId, Pid, State1);
        not_found ->
            State0
    end.

remove_subscription_without_demonitor(JobId, Pid, State = #st{subscriptions = Subs0}) ->
    JobSubs0 = maps:get(JobId, Subs0, #{}),
    JobSubs1 = maps:remove(Pid, JobSubs0),
    Subs1 =
        case map_size(JobSubs1) of
            0 -> maps:remove(JobId, Subs0);
            _ -> Subs0#{JobId => JobSubs1}
        end,
    State#st{subscriptions = Subs1}.
