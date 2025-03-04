%% daemon_worker.erl

-module(damage_worker).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% API

-export([start_link/1]).

%% gen_server callbacks

-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).
-export([restart/1]).

-record(state, {exec_pid, command}).

start_link(Command) -> gen_server:start_link(?MODULE, Command, []).

init(Command) ->
    %% Start the OS daemon using erlexec
    {ok, ExecPid, _} =
        exec:run(Command, [{stdout, self()}, {stderr, self()}, monitor]),
    {ok, #state{exec_pid = ExecPid, command = Command}}.

handle_call(stop, _From, State = #state{exec_pid = ExecPid}) ->
    ?LOG_INFO("stop: stopping exec pid ~p~n", [ExecPid]),
    exec:stop(ExecPid),
    {reply, ok, State};
handle_call(Request, From, State) ->
    ?LOG_INFO("damage worker call: ~p ~p~n", [Request, From]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG_INFO("damage worker cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info({'DOWN', ExecPid, Reason}, State) when
    ExecPid =:= State#state.exec_pid
->
    %% Handle the daemon exit and restart if needed
    ?LOG_INFO("Damage worker exited with reason: ~p~n", [Reason]),
    {stop, Reason, State};
handle_info({'EXIT', ExecPid, Reason}, State) when
    ExecPid =:= State#state.exec_pid
->
    %% Handle the daemon exit and restart if needed
    ?LOG_INFO("Damage worker exited with reason: ~p~n", [Reason]),
    {stop, Reason, State};
handle_info({stdout, _, Msg}, State) ->
    ?LOG_INFO("damage_worker stdout: ~p~n", [Msg]),
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_INFO("damage_worker info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, #state{exec_pid = ExecPid}) ->
    %% Ensure the daemon process is stopped on termination
    ?LOG_INFO("damage_worker terminate: stopping exec pid ~p~n", [ExecPid]),
    exec:stop(ExecPid),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

restart(Worker) ->
    supervisor:terminate_child(damage_sup, Worker),
    supervisor:restart_child(damage_sup, Worker).
