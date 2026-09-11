%%%-------------------------------------------------------------------
%%% @doc Managed MPV process owner using erlexec.
%%%
%%% This module owns the OS MPV process. mpv_ipc should only send JSON IPC
%%% commands after this process has ensured the IPC socket exists.
%%%
%%% All MPV JSON commands should cross this boundary via command/2,3 so a
%%% blocked IPC call cannot wedge the media UI or autoplay worker. A command
%%% timeout is treated as a poisoned MPV session and triggers a managed restart.
%%%
%%% The managed MPV is launched as a hidden audio backend: no standalone MPV
%%% window, no video output, no album-art video surface, and no terminal input.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_mpv_proc).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    ensure_started/0,
    ensure_started/1,
    restart/0,
    stop/0,
    status/0,
    ipc_path/0,
    command/2,
    command/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_IPC_PATH, "/tmp/mpv.sock").
-define(SOCKET_WAIT_MS, 5000).
-define(SOCKET_POLL_MS, 100).
-define(STOP_WAIT_MS, 5000).
-define(KILL_WAIT_MS, 1000).
-define(CMD_TIMEOUT_MS, 3000).

-record(st, {
    path = ipc_path(),
    pid = undefined,
    os_pid = undefined,
    last_error = undefined
}).

%% Public API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ensure_started() ->
    ensure_started(ipc_path()).

ensure_started(Path0) ->
    Path = normalize_path(Path0),
    call_or_start({ensure_started, Path}, 10000).

restart() ->
    call_or_start(restart, 15000).

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> call_or_start(stop, 10000)
    end.

status() ->
    call_or_start(status, 10000).

ipc_path() ->
    getenv_default("MPV_IPC", ?DEFAULT_IPC_PATH).

command(Function, Args) ->
    command(Function, Args, ?CMD_TIMEOUT_MS).

command(Function, Args, Timeout) when
    is_atom(Function),
    is_list(Args),
    Timeout =:= infinity
->
    call_or_start({command, Function, Args, Timeout}, infinity);
command(Function, Args, Timeout) when
    is_atom(Function),
    is_list(Args),
    is_integer(Timeout),
    Timeout >= 0
->
    call_or_start({command, Function, Args, Timeout}, Timeout + 7000).

%% gen_server

init([]) ->
    process_flag(trap_exit, true),
    case ensure_exec_started() of
        ok ->
            {ok, #st{}};
        {error, Reason} ->
            {stop, {exec_start_failed, Reason}}
    end.

handle_call({ensure_started, Path}, _From, S0) ->
    S = S0#st{path = Path},
    case ensure_mpv(Path, S) of
        {ok, S1} ->
            {reply, ok, S1};
        {error, Reason, S1} ->
            {reply, {error, Reason}, S1#st{last_error = Reason}}
    end;
handle_call({command, Function, Args, Timeout}, _From, S0) ->
    case ensure_mpv(S0#st.path, S0) of
        {ok, S1} ->
            case bounded_mpv_call(Function, Args, Timeout, S1#st.path) of
                {ok, Reply} ->
                    {reply, Reply, S1#st{last_error = undefined}};
                {error, Reason = {mpv_command_timeout, _Function, _Timeout}} ->
                    %% Reply immediately so the caller/UI is not held hostage
                    %% while MPV is being torn down and recreated. Recovery is
                    %% owned by this process and happens asynchronously.
                    self() ! {restart_mpv, Reason},
                    {reply, {error, Reason}, S1#st{last_error = Reason}};
                {error, Reason} ->
                    {reply, {error, Reason}, S1#st{last_error = Reason}}
            end;
        {error, Reason, S1} ->
            {reply, {error, {mpv_unavailable, Reason}}, S1#st{last_error = Reason}}
    end;
handle_call(restart, _From, S0) ->
    case restart_mpv(manual_restart, S0) of
        {ok, S1} ->
            {reply, ok, S1};
        {error, Reason, S1} ->
            {reply, {error, Reason}, S1}
    end;
handle_call(stop, _From, S0) ->
    {Reply, S1} = stop_mpv(S0),
    {reply, Reply, S1};
handle_call(status, _From, S) ->
    SocketAlive = socket_alive(S#st.path),
    ManagedAlive = managed_alive(S),
    Reply = #{
        path => S#st.path,
        pid => S#st.pid,
        os_pid => S#st.os_pid,
        managed_alive => ManagedAlive,
        socket_alive => SocketAlive,
        available => SocketAlive,
        owned => S#st.os_pid =/= undefined,
        hidden_gui => true,
        video => disabled,
        healthy => (ManagedAlive andalso SocketAlive) orelse
                   (S#st.os_pid =:= undefined andalso SocketAlive),
        last_error => S#st.last_error
    },
    {reply, Reply, S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', OsPid, process, Pid, Reason}, S = #st{
    os_pid = OsPid,
    pid = Pid,
    path = Path
}) ->
    ?LOG_WARNING("Managed MPV exited os_pid=~p pid=~p reason=~p", [OsPid, Pid, Reason]),
    safe_delete_socket(Path),
    {noreply, S#st{
        pid = undefined,
        os_pid = undefined,
        last_error = {managed_mpv_down, Reason}
    }};
handle_info({'EXIT', Pid, Reason}, S = #st{pid = Pid, path = Path}) ->
    ?LOG_WARNING("Managed MPV linked process exited pid=~p reason=~p", [Pid, Reason]),
    safe_delete_socket(Path),
    {noreply, S#st{
        pid = undefined,
        os_pid = undefined,
        last_error = {managed_mpv_exit, Reason}
    }};
handle_info({restart_mpv, Reason}, S0) ->
    case restart_mpv(Reason, S0) of
        {ok, S1} ->
            {noreply, S1#st{last_error = Reason}};
        {error, RestartReason, S1} ->
            ?LOG_WARNING("MPV restart failed after ~p: ~p", [Reason, RestartReason]),
            {noreply, S1#st{last_error = {Reason, RestartReason}}}
    end;
handle_info(Msg, S) ->
    ?LOG_DEBUG("Unhandled erm_mpv_proc message: ~p", [Msg]),
    {noreply, S}.

terminate(_Reason, S) ->
    _ = stop_mpv(S),
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% Internal

call_or_start(Req, Timeout) ->
    case whereis(?MODULE) of
        undefined ->
            case start_link() of
                {ok, _Pid} ->
                    safe_call(Req, Timeout);
                {error, {already_started, _Pid}} ->
                    safe_call(Req, Timeout);
                {error, Reason} ->
                    {error, Reason}
            end;
        _Pid ->
            safe_call(Req, Timeout)
    end.

safe_call(Req, Timeout) ->
    try gen_server:call(?MODULE, Req, Timeout) of
        Reply ->
            Reply
    catch
        exit:Reason ->
            {error, {erm_mpv_proc_unavailable, Reason}}
    end.

ensure_exec_started() ->
    ensure_shell_env(),
    try application:ensure_all_started(erlexec) of
        {ok, _Apps} ->
            ok;
        {error, {already_started, _App}} ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_erlexec_start_reply, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {exception, Class, Reason, Stacktrace}}
    end.

ensure_shell_env() ->
    case os:getenv("SHELL") of
        false -> os:putenv("SHELL", "/bin/sh");
        "" -> os:putenv("SHELL", "/bin/sh");
        _ -> ok
    end.

ensure_mpv(Path, S) ->
    case {managed_alive(S), socket_alive(Path)} of
        {true, true} ->
            {ok, S#st{last_error = undefined}};
        {true, false} ->
            ?LOG_WARNING(
                "Managed MPV pid=~p os_pid=~p is alive but IPC socket ~s is unavailable; restarting",
                [S#st.pid, S#st.os_pid, Path]
            ),
            case restart_mpv({managed_mpv_socket_unavailable, Path}, S) of
                {ok, S1} -> {ok, S1};
                {error, Reason, S1} -> {error, Reason, S1}
            end;
        %% Something already owns the socket. Do not delete it.
        {false, true} ->
            ?LOG_INFO("MPV IPC socket already alive at ~s; using existing MPV", [Path]),
            {ok, S#st{pid = undefined, os_pid = undefined, last_error = undefined}};
        {false, false} ->
            start_managed_mpv(Path, S)
    end.

start_managed_mpv(Path, S) ->
    case os:find_executable("mpv") of
        false ->
            {error, mpv_not_found, S#st{last_error = mpv_not_found}};
        Mpv ->
            safe_delete_socket(Path),

            Cmd = hidden_mpv_command(Mpv, Path),

            LogFun =
                fun(Stream, OsPid0, Data) ->
                    ?LOG_DEBUG("mpv(~p) ~p: ~ts", [OsPid0, Stream, safe_text(Data)])
                end,

            Opts = [
                monitor,
                {stdin, null},
                {stdout, LogFun},
                {stderr, LogFun},
                {group, 0},
                kill_group,
                {kill_timeout, 3}
            ],

            case safe_exec_run(Cmd, Opts) of
                {ok, Pid, OsPid} ->
                    ?LOG_INFO("Started managed MPV os_pid=~p pid=~p ipc=~s", [OsPid, Pid, Path]),
                    S1 = S#st{path = Path, pid = Pid, os_pid = OsPid, last_error = undefined},
                    case wait_for_socket(Path, ?SOCKET_WAIT_MS) of
                        ok ->
                            {ok, S1};
                        {error, Reason} ->
                            {_StopReply, S2} = stop_mpv(S1),
                            {error, {mpv_ipc_socket_not_ready, Path, Reason}, S2}
                    end;
                {error, Reason} ->
                    {error, {mpv_start_failed, Reason}, S#st{last_error = Reason}};
                Other ->
                    {error, {unexpected_exec_run_reply, Other}, S#st{last_error = Other}}
            end
    end.

hidden_mpv_command(Mpv, Path) ->
    %% Run MPV as a headless media backend controlled by the gtkgs UI.
    %% --no-video is intentional: without it, loading a video file can still
    %% create a native MPV window even when --force-window=no is set.
    [
        Mpv,
        "--idle=yes",
        "--keep-open=yes",
        "--force-window=no",
        "--no-video",
        "--audio-display=no",
        "--osc=no",
        "--no-terminal",
        "--input-terminal=no",
        "--input-ipc-server=" ++ Path
    ].

restart_mpv(Reason, S = #st{os_pid = undefined, path = Path}) ->
    case socket_alive(Path) of
        true ->
            %% This is an external MPV/socket. Do not delete or kill something
            %% not started through this worker.
            {error, {external_mpv_socket_alive, Path, Reason}, S#st{last_error = Reason}};
        false ->
            start_managed_mpv(Path, S#st{last_error = Reason})
    end;
restart_mpv(Reason, S0) ->
    ?LOG_WARNING("Restarting managed MPV session: ~p", [Reason]),
    {_Reply, S1} = stop_mpv(S0),
    start_managed_mpv(S1#st.path, S1#st{last_error = Reason}).

stop_mpv(S = #st{os_pid = undefined, path = Path}) ->
    %% If no owned OS process exists, do not delete a live external socket.
    case socket_alive(Path) of
        true -> ok;
        false -> safe_delete_socket(Path)
    end,
    {ok, S#st{pid = undefined, os_pid = undefined}};
stop_mpv(S = #st{os_pid = OsPid, pid = Pid, path = Path}) ->
    StopReply = safe_exec_stop(OsPid),
    DownReply0 = wait_for_down(OsPid, Pid, ?STOP_WAIT_MS),
    DownReply =
        case DownReply0 of
            timeout ->
                ?LOG_WARNING("MPV os_pid=~p did not stop cleanly; forcing SIGKILL", [OsPid]),
                _ = safe_exec_kill(OsPid, 9),
                wait_for_down(OsPid, Pid, ?KILL_WAIT_MS);
            Other ->
                Other
        end,
    safe_delete_socket(Path),
    S1 = S#st{pid = undefined, os_pid = undefined},
    case {StopReply, DownReply} of
        {{error, Reason}, timeout} ->
            {{error, {mpv_stop_failed, Reason}}, S1#st{last_error = Reason}};
        {_Stop, timeout} ->
            {{error, {mpv_stop_timeout, OsPid}}, S1#st{last_error = {mpv_stop_timeout, OsPid}}};
        _ ->
            {ok, S1#st{last_error = undefined}}
    end.

bounded_mpv_call(Function, Args, infinity, Path) ->
    safe_mpv_call(Function, Args, Path);
bounded_mpv_call(Function, Args, Timeout, Path) when is_integer(Timeout), Timeout >= 0 ->
    Parent = self(),
    Ref = make_ref(),
    {Worker, MonitorRef} = spawn_monitor(fun() ->
        Parent ! {Ref, safe_mpv_call(Function, Args, Path)}
    end),
    receive
        {Ref, Result} ->
            _ = erlang:demonitor(MonitorRef, [flush]),
            Result;
        {'DOWN', MonitorRef, process, Worker, Reason} ->
            {error, {mpv_command_worker_down, Function, Reason}}
    after Timeout ->
        exit(Worker, kill),
        _ = erlang:demonitor(MonitorRef, [flush]),
        {error, {mpv_command_timeout, Function, Timeout}}
    end.

safe_mpv_call(Function, Args, Path) ->
    case direct_mpv_call(Function, Args, Path) of
        unsupported -> fallback_mpv_ipc_call(Function, Args);
        Result -> Result
    end.

%% The owner can execute the common media commands itself. This keeps the UI
%% working even when an older mpv_ipc module still builds JSON with Erlang
%% string lists such as #{"command" => ["set", "volume", 73]}, which crashes
%% jsx_encoder. Unknown commands still fall back to mpv_ipc for compatibility.
direct_mpv_call(connect, [Path0], _OwnerPath) ->
    connect_socket(normalize_path(Path0));
direct_mpv_call(load_file, [File], Path) ->
    send_mpv_json(Path, [<<"loadfile">>, File, <<"replace">>]);
direct_mpv_call(load_list, [File], Path) ->
    send_mpv_json(Path, [<<"loadlist">>, File, <<"replace">>]);
direct_mpv_call(toggle_pause, [], Path) ->
    send_mpv_json(Path, [<<"cycle">>, <<"pause">>]);
direct_mpv_call(set_volume, [Volume0], Path) when is_integer(Volume0); is_float(Volume0) ->
    Volume = clamp_number(Volume0, 0, 100),
    send_mpv_json(Path, [<<"set_property">>, <<"volume">>, Volume]);
direct_mpv_call(seek_percent, [Percent0], Path) when is_integer(Percent0); is_float(Percent0) ->
    Percent = clamp_number(Percent0, 0, 100),
    send_mpv_json(Path, [<<"seek">>, Percent, <<"absolute-percent">>]);
direct_mpv_call(_Function, _Args, _Path) ->
    unsupported.

send_mpv_json(Path0, Args0) ->
    Path = normalize_path(Path0),
    Args = [json_arg(Arg) || Arg <- Args0],
    Payload = [jsx:encode(#{<<"command">> => Args}), <<"\n">>],
    case send_ipc(Path, Payload) of
        ok -> {ok, ok};
        {error, Reason} -> {error, Reason}
    end.

connect_socket(Path) ->
    case gen_tcp:connect({local, Path}, 0, [binary, {active, false}], 1000) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            {ok, self()};
        {error, Reason} ->
            {error, {mpv_ipc_connect_failed, Path, Reason}}
    end.

send_ipc(Path, Payload0) ->
    Payload = iolist_to_binary(Payload0),
    try gen_tcp:connect({local, Path}, 0, [binary, {active, false}], 1000) of
        {ok, Sock} ->
            try gen_tcp:send(Sock, Payload) of
                ok -> ok;
                {error, Reason} -> {error, {mpv_ipc_send_failed, Path, Reason}}
            after
                gen_tcp:close(Sock)
            end;
        {error, Reason} ->
            {error, {mpv_ipc_connect_failed, Path, Reason}}
    catch
        Class:Reason:Stacktrace ->
            {error, {exception, Class, Reason, Stacktrace}}
    end.

json_arg(Arg) when is_binary(Arg) -> Arg;
json_arg(Arg) when is_list(Arg) -> unicode:characters_to_binary(Arg);
json_arg(Arg) when is_integer(Arg); is_float(Arg) -> Arg;
json_arg(true) -> true;
json_arg(false) -> false;
json_arg(null) -> null;
json_arg(Arg) when is_atom(Arg) -> atom_to_binary(Arg, utf8).

clamp_number(Value, Min, _Max) when Value < Min -> Min;
clamp_number(Value, _Min, Max) when Value > Max -> Max;
clamp_number(Value, _Min, _Max) -> Value.

fallback_mpv_ipc_call(Function, Args) ->
    try code:ensure_loaded(mpv_ipc) of
        {module, mpv_ipc} ->
            case erlang:function_exported(mpv_ipc, Function, length(Args)) of
                true ->
                    try apply(mpv_ipc, Function, Args) of
                        {error, Reason} -> {error, Reason};
                        Reply -> {ok, Reply}
                    catch
                        Class:Reason:Stacktrace ->
                            {error, {exception, Class, Reason, Stacktrace}}
                    end;
                false ->
                    {error, {not_exported, mpv_ipc, Function, length(Args)}}
            end;
        {error, Reason} ->
            {error, {mpv_ipc_not_loaded, Reason}}
    catch
        Class:Reason:Stacktrace ->
            {error, {mpv_ipc_load_failed, Class, Reason, Stacktrace}}
    end.

safe_exec_run(Cmd, Opts) ->
    try exec:run(Cmd, Opts) of
        Reply ->
            Reply
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
    end.

safe_exec_stop(OsPid) ->
    try exec:stop(OsPid) of
        Reply ->
            Reply
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
    end.

safe_exec_kill(OsPid, Signal) ->
    try exec:kill(OsPid, Signal) of
        Reply ->
            Reply
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
    end.

wait_for_down(_OsPid, undefined, _Timeout) ->
    timeout;
wait_for_down(OsPid, Pid, Timeout) ->
    receive
        {'DOWN', OsPid, process, Pid, Reason} ->
            {ok, Reason};
        {'EXIT', Pid, Reason} ->
            {ok, Reason}
    after Timeout ->
        timeout
    end.

managed_alive(#st{pid = Pid}) when is_pid(Pid) ->
    is_process_alive(Pid);
managed_alive(_) ->
    false.

wait_for_socket(Path, LeftMs) when LeftMs =< 0 ->
    case socket_alive(Path) of
        true -> ok;
        false -> {error, timeout}
    end;
wait_for_socket(Path, LeftMs) ->
    case socket_alive(Path) of
        true ->
            ok;
        false ->
            timer:sleep(?SOCKET_POLL_MS),
            wait_for_socket(Path, LeftMs - ?SOCKET_POLL_MS)
    end.

socket_alive(Path) ->
    try gen_tcp:connect({local, Path}, 0, [binary, {active, false}], 250) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            true;
        {error, _Reason} ->
            false
    catch
        _Class:_Reason:_Stack ->
            false
    end.

safe_delete_socket(Path) ->
    %% Only remove the file when it is not accepting connections. This avoids
    %% deleting a socket owned by an externally started MPV instance.
    case socket_alive(Path) of
        true ->
            ok;
        false ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, Reason} ->
                    ?LOG_DEBUG("Could not delete MPV IPC path ~s: ~p", [Path, Reason]),
                    ok
            end
    end.

normalize_path(Path) when is_binary(Path) ->
    unicode:characters_to_list(Path);
normalize_path(Path) when is_list(Path) ->
    Path.

getenv_default(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

safe_text(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        Text when is_list(Text) ->
            string:trim(Text);
        {error, Text, _Rest} ->
            string:trim(Text);
        {incomplete, Text, _Rest} ->
            string:trim(Text)
    end;
safe_text(Other) ->
    io_lib:format("~p", [Other]).
