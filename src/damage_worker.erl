%% daemon_worker.erl
-module(damage_worker).
-behaviour(gen_server).

%% API
-export([start_link/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {exec_pid}).

start_link(Command) ->
    gen_server:start_link(?MODULE, Command, []).

init(Command) ->
    %% Start the OS daemon using erlexec
    {ok, ExecPid} = exec:run_link(Command, [ {stdout, self()}, {stderr, self()}, monitor]),
    {ok, #state{exec_pid = ExecPid}}.

handle_call(stop, _From, State = #state{exec_pid = ExecPid}) ->
    exec:stop(ExecPid),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', ExecPid, Reason}, State) when ExecPid =:= State#state.exec_pid ->
    %% Handle the daemon exit and restart if needed
    io:format("Daemon exited with reason: ~p~n", [Reason]),
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{exec_pid = ExecPid}) ->
    %% Ensure the daemon process is stopped on termination
    exec:stop(ExecPid),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
