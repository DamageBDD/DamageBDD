%%--------------------------------------------------------------------
%% Supervised bootstrap/retry worker for the optional ECAI index-jobs subtree.
%%
%% The worker must not synchronously call its parent supervisor from init/1:
%% supervisor:start_child/2 would deadlock while ecai_sup is waiting for this
%% child's start_link/1 to return. Retry begins from handle_continue/2 instead.
%%--------------------------------------------------------------------
-module(ecai_index_jobs_bootstrap).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, child_spec/1, start_index_jobs/1]).
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(MIN_RETRY_MS, 1000).
-define(MAX_RETRY_MS, 30000).

start_link(SupPid) when is_pid(SupPid) ->
    gen_server:start_link(?MODULE, SupPid, []).

child_spec(SupPid) when is_pid(SupPid) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [SupPid]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

init(SupPid) ->
    {ok, #{sup => SupPid, retry_ms => ?MIN_RETRY_MS}, {continue, schedule_retry}}.

handle_continue(schedule_retry, State) ->
    {noreply, schedule_retry(State)}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(retry_index_jobs, State = #{sup := SupPid, retry_ms := RetryMs}) ->
    case start_index_jobs(SupPid) of
        ok ->
            ?LOG_INFO("ECAI index-jobs subsystem started after supervised retry", []),
            {stop, normal, State};
        {error, {invalid_configuration, index_jobs_enabled, _} = Reason} ->
            ?LOG_ERROR(
                "ECAI index-jobs retry stopped due to configuration error reason=~p",
                [Reason]
            ),
            {stop, normal, State};
        {error, Reason} ->
            NextRetry = erlang:min(?MAX_RETRY_MS, RetryMs * 2),
            ?LOG_DEBUG(
                "ECAI index-jobs subsystem still unavailable; retrying in ~p ms reason=~p",
                [NextRetry, Reason]
            ),
            {noreply, schedule_retry(State#{retry_ms => NextRetry})}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

schedule_retry(State = #{retry_ms := RetryMs}) ->
    _ = erlang:send_after(RetryMs, self(), retry_index_jobs),
    State.

start_index_jobs(SupPid) when is_pid(SupPid) ->
    case application:get_env(ecai, index_jobs_enabled, false) of
        true ->
            start_or_restart_index_jobs(SupPid);
        false ->
            ok;
        Invalid ->
            {error, {invalid_configuration, index_jobs_enabled, Invalid}}
    end.

start_or_restart_index_jobs(SupPid) ->
    ChildSpec = #{
        id => ecai_index_jobs_sup,
        start => {ecai_index_jobs_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [ecai_index_jobs_sup]
    },
    case supervisor:start_child(SupPid, ChildSpec) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        {error, already_present} ->
            case supervisor:restart_child(SupPid, ecai_index_jobs_sup) of
                {ok, _Pid} -> ok;
                {ok, _Pid, _Info} -> ok;
                {error, running} -> ok;
                {error, Reason} -> {error, {index_jobs_restart_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {index_jobs_start_failed, Reason}}
    end.
