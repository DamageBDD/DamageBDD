%% Copyright Steven Joseph. SPDX-License-Identifier: Apache-2.0
%%%-------------------------------------------------------------------
%%% @doc Damage-owned Kubo process manager.
%%%
%%% Kubo remains a native OS daemon. This worker owns one isolated repo and
%%% process through erlexec, separate from any system-wide Kubo instance.
%%% The RPC API is bound to loopback only.
%%%-------------------------------------------------------------------
-module(damage_ipfs_kubo).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, status/0]).
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    config = #{},
    executable = undefined,
    pid = undefined,
    os_pid = undefined,
    retry_ref = undefined,
    last_error = undefined
}).

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

status() ->
    damage_ipfs_config:call(?MODULE, status, 5000).

init(Config0) ->
    process_flag(trap_exit, true),
    Config = damage_ipfs_config:normalize(Config0),
    {ok, #state{config = Config}, {continue, ensure_started}}.

handle_continue(ensure_started, State0) ->
    {noreply, ensure_kubo(State0)}.

handle_call(status, _From, State) ->
    {reply,
        #{
            managed => true,
            repo => maps:get(kubo_repo, State#state.config),
            api => maps:get(ipfs_api, State#state.config),
            pid => State#state.pid,
            os_pid => State#state.os_pid,
            running => managed_alive(State),
            last_error => State#state.last_error
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(retry_kubo, State0) ->
    {noreply, ensure_kubo(State0#state{retry_ref = undefined})};
handle_info(
    {'DOWN', OsPid, process, Pid, Reason},
    State = #state{os_pid = OsPid, pid = Pid}
) ->
    ?LOG_WARNING("Managed Kubo exited os_pid=~p pid=~p reason=~p", [OsPid, Pid, Reason]),
    {noreply,
        schedule_retry(
            {kubo_exited, Reason},
            State#state{pid = undefined, os_pid = undefined}
        )};
handle_info({'EXIT', Pid, Reason}, State = #state{pid = Pid}) ->
    ?LOG_WARNING("Managed Kubo linked process exited pid=~p reason=~p", [Pid, Reason]),
    {noreply,
        schedule_retry(
            {kubo_exited, Reason},
            State#state{pid = undefined, os_pid = undefined}
        )};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_retry(State#state.retry_ref),
    _ = stop_kubo(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_kubo(State = #state{pid = Pid}) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> State;
        false -> ensure_kubo(State#state{pid = undefined, os_pid = undefined})
    end;
ensure_kubo(State0 = #state{config = Config}) ->
    case ensure_erlexec() of
        ok ->
            case kubo_executable(Config) of
                {ok, Executable} ->
                    State1 = State0#state{executable = Executable},
                    case prepare_repo(State1) of
                        ok ->
                            case start_daemon(State1) of
                                {ok, State2} -> State2#state{last_error = undefined};
                                {error, Reason} -> schedule_retry(Reason, State1)
                            end;
                        {error, Reason} ->
                            schedule_retry(Reason, State1)
                    end;
                {error, Reason} ->
                    schedule_retry(Reason, State0)
            end;
        {error, Reason} ->
            schedule_retry({erlexec_unavailable, Reason}, State0)
    end.

prepare_repo(State = #state{config = Config}) ->
    Repo = maps:get(kubo_repo, Config),
    case damage_config:ensure_directory(Repo) of
        ok ->
            case filelib:is_regular(filename:join(Repo, "config")) of
                true ->
                    configure_repo(State);
                false ->
                    case run_ipfs_sync(State, ["init", "--profile=server"]) of
                        ok -> configure_repo(State);
                        {error, _} = Error -> Error
                    end
            end;
        {error, Reason} ->
            {error, {kubo_repo_directory_failed, Repo, Reason}}
    end.

configure_repo(State = #state{config = Config}) ->
    Api =
        "/ip4/127.0.0.1/tcp/" ++
            integer_to_list(maps:get(kubo_api_port, Config)),
    Gateway =
        "/ip4/127.0.0.1/tcp/" ++
            integer_to_list(maps:get(kubo_gateway_port, Config)),
    SwarmPort = maps:get(kubo_swarm_port, Config),
    Swarm = swarm_addresses_json(SwarmPort),
    run_config_steps(State, [
        ["config", "Addresses.API", Api],
        ["config", "Addresses.Gateway", Gateway],
        ["config", "--json", "Addresses.Swarm", binary_to_list(Swarm)]
    ]).

%% JSX requires binaries for JSON string values.
-spec swarm_addresses_json(inet:port_number()) -> binary().
swarm_addresses_json(SwarmPort) ->
    Port = integer_to_binary(SwarmPort),
    jsx:encode([
        <<"/ip4/0.0.0.0/tcp/", Port/binary>>,
        <<"/ip6/::/tcp/", Port/binary>>,
        <<"/ip4/0.0.0.0/udp/", Port/binary, "/quic-v1">>,
        <<"/ip6/::/udp/", Port/binary, "/quic-v1">>
    ]).

run_config_steps(_State, []) ->
    ok;
run_config_steps(State, [Args | Rest]) ->
    case run_ipfs_sync(State, Args) of
        ok -> run_config_steps(State, Rest);
        {error, _} = Error -> Error
    end.

start_daemon(State = #state{config = Config}) ->
    Args =
        case maps:get(kubo_gc, Config, true) of
            true -> ["daemon", "--enable-gc"];
            false -> ["daemon"]
        end,
    Cmd = ipfs_command(State, Args),
    LogFun = fun(Stream, OsPid0, Data) ->
        ?LOG_DEBUG("kubo(~p) ~p: ~ts", [OsPid0, Stream, safe_text(Data)])
    end,
    Opts = [
        monitor,
        {stdin, null},
        {stdout, LogFun},
        {stderr, LogFun},
        {group, 0},
        kill_group,
        {kill_timeout, 5}
    ],
    case safe_exec_run(Cmd, Opts) of
        {ok, Pid, OsPid} ->
            Candidate = State#state{pid = Pid, os_pid = OsPid},
            case
                wait_for_api(
                    maps:get(kubo_api_port, Config), maps:get(kubo_start_timeout_ms, Config)
                )
            of
                ok ->
                    ?LOG_INFO(
                        "Started Damage-managed Kubo repo=~s api=~s os_pid=~p",
                        [maps:get(kubo_repo, Config), maps:get(ipfs_api, Config), OsPid]
                    ),
                    {ok, Candidate};
                {error, Reason} ->
                    _ = stop_kubo(Candidate),
                    {error, {kubo_api_not_ready, Reason}}
            end;
        {error, Reason} ->
            {error, {kubo_start_failed, Reason}}
    end.

run_ipfs_sync(State, Args) ->
    case safe_exec_run(ipfs_command(State, Args), [sync, stdout, stderr]) of
        {ok, _} -> ok;
        {error, Reason} -> {error, {kubo_command_failed, Args, sanitize_exec_error(Reason)}}
    end.

ipfs_command(#state{config = Config, executable = Executable}, Args) ->
    Repo = maps:get(kubo_repo, Config),
    Env =
        case os:find_executable("env") of
            false -> "/usr/bin/env";
            Path -> Path
        end,
    [Env, "IPFS_PATH=" ++ Repo, Executable | Args].

kubo_executable(Config) ->
    Configured = maps:get(kubo_binary, Config, "ipfs"),
    case filename:pathtype(Configured) of
        absolute ->
            case filelib:is_regular(Configured) of
                true -> {ok, Configured};
                false -> {error, {kubo_not_found, Configured}}
            end;
        _ ->
            case os:find_executable(Configured) of
                false -> {error, {kubo_not_found, Configured}};
                Path -> {ok, Path}
            end
    end.

schedule_retry(Reason, State = #state{config = Config, retry_ref = Ref}) ->
    cancel_retry(Ref),
    RetryMs = maps:get(kubo_retry_ms, Config, 5000),
    ?LOG_WARNING("Managed Kubo unavailable reason=~p retry_in_ms=~p", [Reason, RetryMs]),
    NewRef = erlang:send_after(RetryMs, self(), retry_kubo),
    State#state{retry_ref = NewRef, last_error = Reason}.

cancel_retry(undefined) ->
    ok;
cancel_retry(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

stop_kubo(#state{os_pid = undefined}) ->
    ok;
stop_kubo(#state{os_pid = OsPid}) ->
    try exec:stop_and_wait(OsPid, 10000) of
        _ -> ok
    catch
        _:_ -> ok
    end.

managed_alive(#state{pid = Pid}) when is_pid(Pid) -> is_process_alive(Pid);
managed_alive(_) -> false.

wait_for_api(_Port, LeftMs) when LeftMs =< 0 -> {error, timeout};
wait_for_api(Port, LeftMs) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 250) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            ok;
        {error, _} ->
            timer:sleep(100),
            wait_for_api(Port, LeftMs - 100)
    end.

ensure_erlexec() ->
    try application:ensure_all_started(erlexec) of
        {ok, _} -> ok;
        {error, {already_started, erlexec}} -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_erlexec_reply, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

safe_exec_run(Cmd, Opts) ->
    try exec:run(Cmd, Opts) of
        Reply -> Reply
    catch
        Class:Reason:Stack -> {error, {exception, Class, Reason, Stack}}
    end.

sanitize_exec_error({exit_status, Status}) ->
    {exit_status, Status};
sanitize_exec_error(List) when is_list(List) ->
    [
        case Item of
            {exit_status, Status} -> {exit_status, Status};
            {stderr, _} -> {stderr, redacted};
            {stdout, _} -> {stdout, redacted};
            Other -> Other
        end
     || Item <- List
    ];
sanitize_exec_error(Other) ->
    Other.

safe_text(Data) when is_binary(Data) -> Data;
safe_text(Data) when is_list(Data) -> unicode:characters_to_binary(Data);
safe_text(Data) -> iolist_to_binary(io_lib:format("~p", [Data])).
