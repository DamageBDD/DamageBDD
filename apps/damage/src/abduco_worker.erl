-module(abduco_worker).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).

%% Public API
-export([start_link/1, ping/1, status/1, send_signal/2, revive/1, stop/1]).

%% gen_server
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    name,
    %% string or argv list (we pass through to erlexec)
    cmd,
    %% #{ "K" => "V" }
    env = #{},
    %% Erlang pid returned by erlexec (linked/monitored)
    exec_pid = undefined,
    %% integer OS PID of the child
    os_pid = undefined
}).

%%% =========================
%%% Public API
%%% =========================

start_link(Args = #{name := Name, cmd := _Cmd}) ->
    gen_server:start_link({via, gproc, {n, l, Name}}, ?MODULE, Args, []).

ping(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, ping, 2000).

status(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, status, 5000).

send_signal(Name, Signal) ->
    gen_server:call({via, gproc, {n, l, Name}}, {signal, Signal}, 5000).

revive(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, revive, 5000).

stop(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, stop, 5000).

%%% =========================
%%% gen_server
%%% =========================

init(#{name := Name, cmd := Cmd} = Args) ->
    Env0 = maps:get(env, Args, #{}),
    Env = interpolate_env(Env0),
    process_flag(trap_exit, true),
    try
        case start_child(Cmd, Env) of
            {undefined, undefined} ->
                {ok, #state{name = Name, cmd = Cmd, env = Env}};
            {ExecPid, OsPid} ->
                gproc:reg_other({n, l, {?MODULE, Name}}, self()),
                {ok, #state{
                    name = Name,
                    cmd = Cmd,
                    env = Env,
                    exec_pid = ExecPid,
                    os_pid = OsPid
                }}
        end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(
                "abduco worker ~p init failed gracefully: ~p:~p ~p",
                [Name, Class, Reason, Stack]
            ),
            {ok, #state{name = Name, cmd = Cmd, env = Env}}
    end.

handle_call(ping, _From, S) ->
    {reply, pong, S};
handle_call(
    status, _From, S = #state{name = Name, cmd = Cmd, env = Env, exec_pid = EP, os_pid = OP}
) ->
    AliveExec = is_pid_alive(EP),
    AliveOS = is_os_alive(OP),
    Reply = #{
        name => Name,
        command => Cmd,
        env_keys => maps:keys(Env),
        exec_pid => EP,
        os_pid => OP,
        alive_exec => AliveExec,
        alive_os => AliveOS,
        alive => (AliveExec andalso AliveOS)
    },
    {reply, Reply, S};
handle_call({signal, Sig0}, _From, S = #state{exec_pid = EP, os_pid = OP}) ->
    Sig = to_signal(Sig0),
    Reply =
        case {is_pid_alive(EP), is_os_alive(OP)} of
            {true, true} ->
                catch exec:kill(EP, Sig),
                ok;
            %% child may have reaped; try via ExecPid anyway
            {true, false} ->
                catch exec:kill(EP, Sig),
                ok;
            {_, _} ->
                {error, not_running}
        end,
    {reply, Reply, S};
handle_call(revive, _From, S = #state{cmd = Cmd, env = Env, exec_pid = EP, os_pid = OP}) ->
    case {is_pid_alive(EP), is_os_alive(OP)} of
        {true, true} ->
            {reply, ok, S};
        _ ->
            {ExecPid, OsPid} = start_child(Cmd, Env),
            {reply, ok, S#state{exec_pid = ExecPid, os_pid = OsPid}}
    end;
handle_call(stop, _From, S = #state{exec_pid = EP}) ->
    _ = (catch exec:stop(EP)),
    {reply, ok, S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

%% If the OS child dies, erlexec sends us {'DOWN', OsPid, process, ExecPid, Reason}
handle_info({'DOWN', _RefOrOsPid, process, ExecPid, Reason}, S = #state{exec_pid = ExecPid}) ->
    ?LOG_WARNING("worker ~p child exited: ~p", [S#state.name, Reason]),
    {noreply, S#state{exec_pid = undefined, os_pid = undefined}};
handle_info({'EXIT', ExecPid, Reason}, S = #state{exec_pid = ExecPid}) ->
    ?LOG_WARNING("worker ~p exec pid exit: ~p", [S#state.name, Reason]),
    {noreply, S#state{exec_pid = undefined, os_pid = undefined}};
handle_info(_Info, S) ->
    {noreply, S}.
handle_cast(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{exec_pid = EP}) ->
    _ = (catch exec:stop(EP)),
    ok.

code_change(_Old, S, _Extra) -> {ok, S}.

%%% =========================
%%% Internal
%%% =========================

get_run_user() ->
    %% configurable in sys.config: {damage, [{run_user, "damage"}]}
    application:get_env(damage, run_user, "damage").

%%% ---- UPDATED: allow exec:start/1 options from app env ----

start_child(Cmd, Env) ->
    RunUser = get_run_user(),
    Opts = [{user, RunUser}, link, monitor, {env, env_list(Env)}, {kill_timeout, 5}],
    try
        case exec:run_link(Cmd, Opts) of
            {ok, ExecPid, OsPid} ->
                ?LOG_INFO("started ~p as user=~s os_pid=~p", [Cmd, RunUser, OsPid]),
                {ExecPid, OsPid};
            {error, Reason} ->
                ?LOG_ERROR("failed starting ~p as user=~s => ~p", [Cmd, RunUser, Reason]),
                {undefined, undefined}
        end
    catch
        exit:{noproc, _} ->
            ?LOG_ERROR("exec server not started while starting ~p", [Cmd]),
            {undefined, undefined};
        exit:noproc ->
            ?LOG_ERROR("exec server missing while starting ~p", [Cmd]),
            {undefined, undefined};
        Class:Reason0:Stack ->
            ?LOG_ERROR(
                "failed starting ~p as user=~s => ~p:~p ~p",
                [Cmd, RunUser, Class, Reason0, Stack]
            ),
            {undefined, undefined}
    end.

is_pid_alive(undefined) -> false;
is_pid_alive(P) -> is_process_alive(P).

is_os_alive(undefined) ->
    false;
is_os_alive(Pid) when is_integer(Pid), Pid > 0 ->
    %% kill -0 doesn't send a signal, just checks existence/permission
    case os:cmd("kill -0 " ++ integer_to_list(Pid) ++ " 2>/dev/null; echo $?") of
        "0\n" -> true;
        "0" -> true;
        _ -> false
    end.

%% ---- Env helpers ----

interpolate_env(Map) when is_map(Map) ->
    maps:from_list([
        {to_list(K), secrets:interpolate_template(to_list(V))}
     || {K, V} <- maps:to_list(Map)
    ]).

env_list(Map) ->
    %% Convert #{ "K" => "V" } -> [{"K","V"}, ...]
    [{K, V} || {K, V} <- maps:to_list(Map)].

%% ---- Signal helpers ----

to_signal(N) when is_integer(N) -> N;
to_signal(A) when is_atom(A) ->
    %% Map common short forms to POSIX atoms erlexec understands.
    case A of
        hup -> sighup;
        int -> sigint;
        quit -> sigquit;
        term -> sigterm;
        kill -> sigkill;
        usr1 -> sigusr1;
        usr2 -> sigusr2;
        chld -> sigchld;
        _ -> A
    end;
to_signal(S) when is_list(S) ->
    to_signal(list_to_existing_atom_safe(string:lowercase(S))).

list_to_existing_atom_safe(Str) ->
    try
        list_to_existing_atom(Str)
    catch
        _:_ -> list_to_atom(Str)
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
