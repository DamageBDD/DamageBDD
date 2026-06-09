%%%-------------------------------------------------------------------
%%% @doc Managed MPV process owner using erlexec.
%%%
%%% This module owns the OS MPV process. mpv_ipc should only send JSON IPC
%%% commands after this process has ensured the IPC socket exists.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_mpv_proc).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    ensure_started/0,
    ensure_started/1,
    stop/0,
    status/0,
    ipc_path/0
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

-record(st, {
    path = ipc_path(),
    pid = undefined,
    os_pid = undefined
}).

%% Public API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ensure_started() ->
    ensure_started(ipc_path()).

ensure_started(Path0) ->
    Path = normalize_path(Path0),
    call_or_start({ensure_started, Path}).

stop() ->
    call_or_start(stop).

status() ->
    call_or_start(status).

ipc_path() ->
    getenv_default("MPV_IPC", ?DEFAULT_IPC_PATH).

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
            {reply, {error, Reason}, S1}
    end;
handle_call(stop, _From, S0) ->
    {Reply, S1} = stop_mpv(S0),
    {reply, Reply, S1};
handle_call(status, _From, S) ->
    Reply = #{
        path => S#st.path,
        pid => S#st.pid,
        os_pid => S#st.os_pid,
        managed_alive => managed_alive(S),
        socket_alive => socket_alive(S#st.path)
    },
    {reply, Reply, S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', OsPid, process, Pid, Reason}, S = #st{os_pid = OsPid, pid = Pid}) ->
    ?LOG_WARNING("Managed MPV exited os_pid=~p pid=~p reason=~p", [OsPid, Pid, Reason]),
    {noreply, S#st{pid = undefined, os_pid = undefined}};
handle_info({'EXIT', Pid, Reason}, S = #st{pid = Pid}) ->
    ?LOG_WARNING("Managed MPV linked process exited pid=~p reason=~p", [Pid, Reason]),
    {noreply, S#st{pid = undefined, os_pid = undefined}};
handle_info(Msg, S) ->
    ?LOG_DEBUG("Unhandled erm_mpv_proc message: ~p", [Msg]),
    {noreply, S}.

terminate(_Reason, S) ->
    _ = stop_mpv(S),
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% Internal

call_or_start(Req) ->
    case whereis(?MODULE) of
        undefined ->
            case start_link() of
                {ok, _Pid} ->
                    gen_server:call(?MODULE, Req, 10000);
                {error, {already_started, _Pid}} ->
                    gen_server:call(?MODULE, Req, 10000);
                {error, Reason} ->
                    {error, Reason}
            end;
        _Pid ->
            gen_server:call(?MODULE, Req, 10000)
    end.

ensure_exec_started() ->
    try application:ensure_all_started(exec) of
        {ok, _Apps} ->
            ok;
        {error, {already_started, exec}} ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_exec_start_reply, Other}}
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
    end.

ensure_mpv(Path, S) ->
    case {managed_alive(S), socket_alive(Path)} of
        {true, true} ->
            {ok, S};
        %% Something already owns the socket. Do not delete it.
        {false, true} ->
            ?LOG_INFO("MPV IPC socket already alive at ~s; using existing MPV", [Path]),
            {ok, S};
        _ ->
            start_managed_mpv(Path, S)
    end.

start_managed_mpv(Path, S) ->
    case os:find_executable("mpv") of
        false ->
            {error, mpv_not_found, S};
        Mpv ->
            _ = file:delete(Path),

            Cmd = [
                Mpv,
                "--idle=yes",
                "--keep-open=yes",
                "--force-window=yes",
                "--no-terminal",
                "--input-ipc-server=" ++ Path
            ],

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
                    case wait_for_socket(Path, ?SOCKET_WAIT_MS) of
                        ok ->
                            {ok, S#st{pid = Pid, os_pid = OsPid}};
                        {error, Reason} ->
                            _ = safe_exec_stop_and_wait(OsPid, 5000),
                            {error, {mpv_ipc_socket_not_ready, Path, Reason}, S#st{
                                pid = undefined, os_pid = undefined
                            }}
                    end;
                {error, Reason} ->
                    {error, {mpv_start_failed, Reason}, S}
            end
    end.

stop_mpv(S = #st{os_pid = undefined}) ->
    {ok, S};
stop_mpv(S = #st{os_pid = OsPid, path = Path}) ->
    Reply = safe_exec_stop_and_wait(OsPid, 5000),
    _ = file:delete(Path),
    S1 = S#st{pid = undefined, os_pid = undefined},
    case Reply of
        {error, Reason} ->
            {{error, Reason}, S1};
        _ ->
            {ok, S1}
    end.

safe_exec_run(Cmd, Opts) ->
    try exec:run(Cmd, Opts) of
        Reply ->
            Reply
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
    end.

safe_exec_stop_and_wait(OsPid, Timeout) ->
    try exec:stop_and_wait(OsPid, Timeout) of
        Reply ->
            Reply
    catch
        Class:Reason:Stack ->
            {error, {exception, Class, Reason, Stack}}
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
