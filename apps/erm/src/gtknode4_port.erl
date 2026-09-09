%%%-------------------------------------------------------------------
%%% @doc
%%% Supervisable owner of the local gtknode4 operating-system process.
%%%
%%% This port is used only for lifecycle and log capture. GUI commands still
%%% travel over Erlang distribution to the C-node endpoint.
%%%-------------------------------------------------------------------
-module(gtknode4_port).
-behaviour(gen_server).

-export([start_link/0, start_link/1, stop/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_RETRY_MS, 1000).
-define(DEFAULT_RETRY_MAX_MS, 30000).

-record(state, {
    port = undefined,
    executable = undefined,
    args = [],
    env = [],
    os_pid = undefined,
    cnode_node = undefined,
    cnode_regname = undefined,
    handshake_timer = undefined,
    handshake_timeout = 10000,
    handshake_failures = 0,
    opts = #{},
    retry_timer = undefined,
    retry_delay = ?DEFAULT_RETRY_MS,
    retry_max = ?DEFAULT_RETRY_MAX_MS,
    restart_count = 0,
    ever_ready = false,
    last_error = undefined
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map() | list()) -> gen_server:start_ret().
start_link(Opts0) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, options_map(Opts0), []).

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _Pid -> gen_server:stop(?SERVER)
    end.

-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

init(Opts) ->
    process_flag(trap_exit, true),
    case node() of
        nonode@nohost ->
            {stop, {erlang_distribution_not_started, "start the VM with -sname or -name"}};
        _ ->
            State0 = retry_state(Opts),
            case attempt_start(Opts) of
                {ok, Started} -> {ok, merge_retry_state(Started, State0)};
                {error, Reason} -> {ok, schedule_restart(Reason, State0)}
            end
    end.

handle_call(status, _From, State) ->
    {reply,
        #{
            executable => State#state.executable,
            args => redact_args(State#state.args),
            os_pid => State#state.os_pid,
            cnode_node => State#state.cnode_node,
            cnode_regname => State#state.cnode_regname,
            handshake_timeout => State#state.handshake_timeout,
            handshake_pending => State#state.handshake_timer =/= undefined,
            alive => port_alive(State#state.port),
            retry_pending => State#state.retry_timer =/= undefined,
            retry_delay => State#state.retry_delay,
            restart_count => State#state.restart_count,
            ever_ready => State#state.ever_ready,
            last_error => State#state.last_error
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, Line}}}, State = #state{port = Port}) ->
    logger:notice("gtknode4: ~ts", [Line]),
    {noreply, State};
handle_info({Port, {data, {noeol, Line}}}, State = #state{port = Port}) ->
    logger:notice("gtknode4: ~ts", [Line]),
    {noreply, State};
handle_info({gtknode4, status, ready, _Info}, State) ->
    cancel_timer(State#state.handshake_timer),
    {noreply, State#state{
        handshake_timer = undefined,
        handshake_failures = 0,
        retry_delay = retry_initial(State#state.opts),
        ever_ready = true,
        last_error = undefined
    }};
handle_info({gtknode4, status, disconnected, Reason}, State) ->
    %% The native port owns reconnection. A transport notification must not
    %% terminate this worker and trigger a supervisor restart loop.
    {noreply, State#state{last_error = {transport_disconnected, Reason}}};
handle_info(handshake_timeout, State = #state{port = undefined}) ->
    %% A cancelled timer may already have reached the mailbox after the native
    %% process went down. The retry timer now owns recovery.
    {noreply, State#state{handshake_timer = undefined}};
handle_info(
    handshake_timeout,
    State = #state{
        handshake_timeout = Timeout,
        handshake_failures = Failures
    }
) ->
    case controller_status() of
        #{ready := true} ->
            {noreply, State#state{handshake_timer = undefined, handshake_failures = 0}};
        Status when Failures < 2 ->
            logger:warning(
                "gtknode4 handshake is still pending (~B/~B): ~p",
                [Failures + 1, 3, Status]
            ),
            Timer = start_timer(Timeout, handshake_timeout),
            {noreply, State#state{
                handshake_timer = Timer,
                handshake_failures = Failures + 1,
                last_error = {handshake_pending, Status}
            }};
        Status ->
            Reason = {cnode_handshake_timeout, Timeout, Status},
            {noreply, native_down(Reason, State)}
    end;
handle_info({Port, {exit_status, 0}}, State = #state{port = Port}) ->
    native_exit_result({cnode_stopped, 0}, State);
handle_info({Port, {exit_status, Status}}, State = #state{port = Port}) ->
    native_exit_result({cnode_exit_status, Status}, State);
handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    native_exit_result({cnode_port_exit, Reason}, State);
handle_info(restart_native, State = #state{port = undefined}) ->
    State0 = State#state{retry_timer = undefined},
    case attempt_start(State0#state.opts) of
        {ok, Started} ->
            logger:notice(
                "restarted gtknode4 C-node after ~B failed attempts",
                [State0#state.restart_count]
            ),
            {noreply, merge_retry_state(Started, State0)};
        {error, Reason} ->
            {noreply, schedule_restart(Reason, State0)}
    end;
handle_info(restart_native, State) ->
    {noreply, State#state{retry_timer = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{
    port = Port,
    handshake_timer = HandshakeTimer,
    retry_timer = RetryTimer
}) ->
    cancel_timer(HandshakeTimer),
    cancel_timer(RetryTimer),
    best_effort(fun() -> gtknode4:unsubscribe(self()) end),
    best_effort(fun() -> gtknode4:cast(shutdown) end),
    safe_port_close(Port).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_port(Opts) ->
    case validate_distribution_names(Opts) of
        ok -> start_port_validated(Opts);
        {error, Reason} -> {stop, Reason}
    end.

start_port_validated(Opts) ->
    Executable = resolve_executable(Opts),
    case filelib:is_regular(Executable) of
        false ->
            {stop, {cnode_executable_not_found, Executable}};
        true ->
            CNode = cnode_node(Opts),
            CRegName = option_atom(cnode_regname, Opts, gtknode4),
            Controller = option_atom(controller_regname, Opts, gtknode4),
            CookieEnv = to_string(maps:get(cookie_env, Opts, "GTKNODE4_COOKIE")),
            Args = build_args(Opts, CNode, CRegName, Controller, CookieEnv),
            Env = build_env(Opts, CookieEnv),
            PortOpts0 = [
                binary,
                exit_status,
                use_stdio,
                stderr_to_stdout,
                {line, maps:get(line_length, Opts, 16384)},
                {args, Args},
                {env, Env}
            ],
            PortOpts = maybe_add_cd(PortOpts0, maps:get(cd, Opts, undefined)),
            try open_port({spawn_executable, Executable}, PortOpts) of
                Port ->
                    %% Keep the ownership link. It ensures the external process is
                    %% torn down even if this worker is killed before terminate/2.
                    %% With trap_exit enabled, both port exits and exit_status are
                    %% converted into supervised failure signals.
                    OsPid =
                        case erlang:port_info(Port, os_pid) of
                            {os_pid, Pid} -> Pid;
                            undefined -> undefined
                        end,
                    HandshakeTimeout = handshake_timeout(Opts),
                    case controller_subscribe() of
                        ok ->
                            Timer = start_timer(HandshakeTimeout, handshake_timeout),
                            logger:notice(
                                "started gtknode4 C-node ~p as OS pid ~p",
                                [CNode, OsPid]
                            ),
                            {ok, #state{
                                port = Port,
                                executable = Executable,
                                args = Args,
                                env = Env,
                                os_pid = OsPid,
                                cnode_node = CNode,
                                cnode_regname = CRegName,
                                handshake_timer = Timer,
                                handshake_timeout = HandshakeTimeout,
                                opts = Opts
                            }};
                        {error, SubscribeError} ->
                            safe_port_close(Port),
                            {stop, {controller_subscribe_failed, SubscribeError}}
                    end
            catch
                error:Reason:Stacktrace ->
                    {stop, {open_port_failed, Executable, Reason, Stacktrace}}
            end
    end.

attempt_start(Opts) ->
    try start_port(Opts) of
        {ok, State} -> {ok, State};
        {stop, StopReason} -> {error, StopReason}
    catch
        Class:ExceptionReason:Stacktrace ->
            {error, {native_start_failed, Class, ExceptionReason, Stacktrace}}
    end.

retry_state(Opts) ->
    #state{
        opts = Opts,
        retry_delay = retry_initial(Opts),
        retry_max = retry_max(Opts),
        handshake_timeout = handshake_timeout(Opts)
    }.

merge_retry_state(Started, Previous) ->
    Started#state{
        opts = Previous#state.opts,
        retry_timer = undefined,
        retry_delay = retry_initial(Previous#state.opts),
        retry_max = Previous#state.retry_max,
        restart_count = Previous#state.restart_count,
        ever_ready = Previous#state.ever_ready,
        last_error = undefined
    }.

schedule_restart(Reason, State = #state{retry_timer = Existing}) ->
    cancel_timer(Existing),
    Delay = State#state.retry_delay,
    Max = State#state.retry_max,
    Timer = start_timer(Delay, restart_native),
    logger:warning(
        "gtknode4 native process unavailable: ~p; retrying in ~B ms",
        [Reason, Delay]
    ),
    State#state{
        port = undefined,
        os_pid = undefined,
        handshake_timer = undefined,
        handshake_failures = 0,
        retry_timer = Timer,
        retry_delay = erlang:min(Delay * 2, Max),
        restart_count = State#state.restart_count + 1,
        last_error = Reason
    }.

native_down(Reason, State = #state{port = Port}) ->
    _ = safe_transport_down(Reason),
    cancel_timer(State#state.handshake_timer),
    safe_port_close(Port),
    schedule_restart(Reason, State#state{port = undefined, handshake_timer = undefined}).

native_exit_result(Reason, State = #state{ever_ready = false}) ->
    {noreply, native_down(Reason, State)};
native_exit_result(Reason, State = #state{ever_ready = true, port = Port}) ->
    %% Once native widgets may exist, restart the complete one_for_all GTK
    %% session exactly once so gtkgs cannot retain stale native object IDs.
    _ = safe_transport_down(Reason),
    cancel_timer(State#state.handshake_timer),
    safe_port_close(Port),
    {stop, {native_session_lost, Reason}, State#state{
        port = undefined,
        handshake_timer = undefined,
        last_error = Reason
    }}.

retry_initial(Opts) ->
    positive_integer_option(retry_initial_ms, Opts, ?DEFAULT_RETRY_MS).

retry_max(Opts) ->
    erlang:max(
        retry_initial(Opts),
        positive_integer_option(retry_max_ms, Opts, ?DEFAULT_RETRY_MAX_MS)
    ).

positive_integer_option(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _Invalid -> Default
    end.

handshake_timeout(Opts) ->
    case maps:get(handshake_timeout, Opts, 10000) of
        infinity -> infinity;
        Value when is_integer(Value), Value > 0 -> Value;
        _Invalid -> 10000
    end.

build_args(Opts, CNode, CRegName, Controller, CookieEnv) ->
    case maps:get(args, Opts, undefined) of
        undefined ->
            [
                "--name",
                atom_to_list(CNode),
                "--peer",
                atom_to_list(node()),
                "--register",
                atom_to_list(CRegName),
                "--controller",
                atom_to_list(Controller),
                "--cookie-env",
                CookieEnv,
                "--protocol",
                integer_to_list(maps:get(protocol_version, Opts, 1))
            ] ++ test_mode_args(Opts);
        Args when is_list(Args) ->
            [to_string(Arg) || Arg <- Args]
    end.

test_mode_args(Opts) ->
    case maps:get(test_mode, Opts, false) of
        true -> ["--test-mode"];
        false -> []
    end.

build_env(Opts, CookieEnv) ->
    ExtraEnv = maps:get(env, Opts, []),
    Cookie = atom_to_list(erlang:get_cookie()),
    lists:keystore(CookieEnv, 1, normalize_env(ExtraEnv), {CookieEnv, Cookie}).

normalize_env(Env) when is_map(Env) ->
    normalize_env(maps:to_list(Env));
normalize_env(Env) when is_list(Env) ->
    [{to_string(Name), to_string(Value)} || {Name, Value} <- Env].

resolve_executable(Opts) ->
    Value = maps:get(
        executable,
        Opts,
        application:get_env(erm, gtknode4_cnode_executable, default_executable())
    ),
    filename:absname(to_string(Value)).

default_executable() ->
    case code:priv_dir(erm) of
        {error, bad_name} -> "apps/erm/priv/bin/gtknode4";
        PrivDir -> filename:join([PrivDir, "bin", "gtknode4"])
    end.

cnode_node(Opts) ->
    case maps:get(cnode_node, Opts, undefined) of
        undefined ->
            Host = node_host(node()),
            list_to_atom("gtknode4@" ++ Host);
        Value when is_atom(Value) ->
            Value;
        Value ->
            list_to_atom(to_string(Value))
    end.

node_host(Node) ->
    case string:split(atom_to_list(Node), "@", all) of
        [_Alive, Host] -> Host;
        _ -> error({bad_node_name, Node})
    end.

validate_distribution_names(Opts) ->
    PeerNode = node(),
    CNode = cnode_node(Opts),
    PeerHost = node_host(PeerNode),
    CNodeHost = node_host(CNode),
    case distribution_name_domain() of
        {ok, longnames} ->
            validate_longname_hosts(PeerNode, PeerHost, CNode, CNodeHost);
        {ok, shortnames} ->
            validate_shortname_host(CNode, CNodeHost);
        {error, _Reason} = Error ->
            Error
    end.

distribution_name_domain() ->
    case net_kernel:get_state() of
        #{started := Started, name_domain := NameDomain} when
            Started =/= no,
            (NameDomain =:= shortnames orelse NameDomain =:= longnames)
        ->
            {ok, NameDomain};
        State ->
            {error, {invalid_distribution_state, node(), State}}
    end.

validate_longname_hosts(PeerNode, PeerHost, CNode, CNodeHost) ->
    case {lists:member($., PeerHost), lists:member($., CNodeHost)} of
        {false, _} ->
            {error,
                {invalid_longname_host, PeerNode, PeerHost,
                    "restart the Erlang VM with -sname or use a fully qualified -name host"}};
        {_, false} ->
            {error, {invalid_cnode_longname, CNode, CNodeHost}};
        {true, true} ->
            ok
    end.

validate_shortname_host(CNode, CNodeHost) ->
    case lists:member($., CNodeHost) of
        true -> {error, {invalid_cnode_shortname, CNode, CNodeHost}};
        false -> ok
    end.

option_atom(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_atom(Value) -> Value;
        Value -> list_to_atom(to_string(Value))
    end.

maybe_add_cd(PortOpts, undefined) -> PortOpts;
maybe_add_cd(PortOpts, Dir) -> [{cd, to_string(Dir)} | PortOpts].

start_timer(infinity, _Message) ->
    undefined;
start_timer(Timeout, Message) when is_integer(Timeout), Timeout >= 0 ->
    erlang:send_after(Timeout, self(), Message).

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok.

safe_transport_down(Reason) ->
    case whereis(gtknode4) of
        undefined -> ok;
        _Pid -> gtknode4:transport_down(Reason)
    end.

controller_status() ->
    try gtknode4:status() of
        Status -> Status
    catch
        Class:Reason:Stacktrace ->
            {error, {controller_status_failed, Class, Reason, Stacktrace}}
    end.

controller_subscribe() ->
    try gtknode4:subscribe(self()) of
        ok -> ok;
        Other -> {error, Other}
    catch
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end.

port_alive(Port) when is_port(Port) ->
    erlang:port_info(Port) =/= undefined;
port_alive(_Port) ->
    false.

safe_port_close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        error:badarg -> ok;
        _:_ -> ok
    end;
safe_port_close(_Port) ->
    ok.

best_effort(Fun) when is_function(Fun, 0) ->
    try Fun() of
        _ -> ok
    catch
        _:_ -> ok
    end.

redact_args(Args) ->
    %% The default contract transports the cookie through the environment,
    %% not argv. Keep this helper in case a caller supplies legacy arguments.
    redact_args(Args, []).

redact_args([], Acc) -> lists:reverse(Acc);
redact_args(["--cookie", _Cookie | Rest], Acc) -> redact_args(Rest, ["***", "--cookie" | Acc]);
redact_args([Arg | Rest], Acc) -> redact_args(Rest, [Arg | Acc]).

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List).

to_string(Value) when is_list(Value) -> Value;
to_string(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_string(Value) when is_atom(Value) -> atom_to_list(Value);
to_string(Value) when is_integer(Value) -> integer_to_list(Value).
