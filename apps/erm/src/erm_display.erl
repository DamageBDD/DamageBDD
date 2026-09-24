%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime graphical-session discovery for erm.
%%%
%%% The desktop session is discovered from kernel/OS state rather than trusting
%%% DISPLAY or XAUTHORITY inherited by the BEAM.  For X11 we pair live
%%% /tmp/.X11-unix/X* sockets with readable authority files discovered from the
%%% owning Xorg/Xwayland process and configured fallback paths, then validate
%%% each pair with a bounded X11 client probe.
%%%
%%% The selected session is written into the BEAM environment only as an
%%% adapter for libraries such as wx.  Native children should use child_env/0
%%% so their launch environment comes from this module directly.
%%%
%%% Configuration intentionally uses plain tuples/proplists:
%%%
%%% {display, [
%%%     {enabled, true},
%%%     {backend, x11},
%%%     {refresh_ms, 5000},
%%%     {failure_threshold, 3},
%%%     {environment_fallback, false},
%%%     {x11, [
%%%         {socket_dir, "/tmp/.X11-unix"},
%%%         {probe_timeout_ms, 1500},
%%%         {probe_commands, ["xdpyinfo", "xset", "xprop"]},
%%%         {authority_paths, [
%%%             "/run/user/%UID%/xauth_*",
%%%             "/run/user/%UID%/Xauthority*",
%%%             "/run/user/%UID%/gdm/Xauthority",
%%%             "%HOME%/.Xauthority"
%%%         ]}
%%%     ]}
%%% ]}
%%%-------------------------------------------------------------------
-module(erm_display).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    child_spec/0,
    enabled/0,
    ensure/0,
    detect/0,
    refresh/0,
    status/0,
    available/0,
    session/0,
    child_env/0,
    subscribe/1,
    unsubscribe/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(CACHE_KEY, {?MODULE, session}).
-define(DEFAULT_REFRESH_MS, 5000).
-define(DEFAULT_FAILURE_THRESHOLD, 3).
-define(DEFAULT_PROBE_TIMEOUT_MS, 1500).

-record(state, {
    current = undefined,
    refresh_ms = ?DEFAULT_REFRESH_MS,
    failure_threshold = ?DEFAULT_FAILURE_THRESHOLD,
    consecutive_failures = 0,
    timer = undefined,
    subscribers = []
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

enabled() ->
    case proplists:get_value(enabled, config(), true) of
        true -> true;
        false -> false;
        Invalid ->
            ?LOG_WARNING("Ignoring invalid erm.display enabled value ~p; defaulting to true", [
                Invalid
            ]),
            true
    end.

%% @doc Detect and install the graphical session for in-VM users such as wx.
%% This is safe to call before the erm_display gen_server has started.
ensure() ->
    case enabled() of
        false ->
            cache({error, disabled}),
            {error, disabled};
        true ->
            case detect() of
                {ok, Session} = Ok ->
                    install_session(Session),
                    cache(Ok),
                    Ok;
                {error, _Reason} = Error ->
                    cache(Error),
                    Error
            end
    end.

%% @doc Discover a live graphical session without mutating the environment.
detect() ->
    Config = config(),
    case proplists:get_value(backend, Config, x11) of
        x11 ->
            detect_x11(Config);
        auto ->
            %% X11 is the first supported runtime detector.  Keeping the
            %% backend selector explicit leaves room for a Wayland detector.
            detect_x11(Config);
        Backend ->
            {error, {unsupported_display_backend, Backend}}
    end.

refresh() ->
    case whereis(?SERVER) of
        undefined -> ensure();
        _Pid -> gen_server:call(?SERVER, refresh, 10000)
    end.

status() ->
    case whereis(?SERVER) of
        undefined ->
            [
                {running, false},
                {enabled, enabled()},
                {current, cached()}
            ];
        _Pid ->
            gen_server:call(?SERVER, status)
    end.

available() ->
    case cached() of
        {ok, _Session} -> true;
        _ -> false
    end.

session() ->
    cached().

%% @doc Environment overrides for native GUI children.  These values are
%% sourced from validated erm discovery, not from the parent process env.
child_env() ->
    case cached_or_ensure() of
        {ok, Session} ->
            {ok, session_env(Session)};
        {error, _Reason} = Error ->
            Error
    end.

subscribe(Pid) when is_pid(Pid) ->
    case whereis(?SERVER) of
        undefined -> {error, not_started};
        _ -> gen_server:call(?SERVER, {subscribe, Pid})
    end.

unsubscribe(Pid) when is_pid(Pid) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:call(?SERVER, {unsubscribe, Pid})
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Config = config(),
    RefreshMs = positive_or_infinity(
        proplists:get_value(refresh_ms, Config, ?DEFAULT_REFRESH_MS),
        ?DEFAULT_REFRESH_MS
    ),
    FailureThreshold = positive_integer(
        proplists:get_value(failure_threshold, Config, ?DEFAULT_FAILURE_THRESHOLD),
        ?DEFAULT_FAILURE_THRESHOLD
    ),
    Current =
        case cached() of
            undefined -> ensure();
            Value -> Value
        end,
    Timer = schedule_refresh(RefreshMs),
    {ok, #state{
        current = Current,
        refresh_ms = RefreshMs,
        failure_threshold = FailureThreshold,
        timer = Timer
    }}.

handle_call(status, _From, State) ->
    {reply, state_status(State), State};
handle_call(refresh, _From, State0) ->
    {Result, State1} = refresh_state(State0),
    {reply, Result, State1};
handle_call({subscribe, Pid}, _From, State) ->
    {reply, ok, add_subscriber(Pid, State)};
handle_call({unsubscribe, Pid}, _From, State) ->
    {reply, ok, remove_subscriber(Pid, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(refresh, State0) ->
    {_Result, State1} = refresh_state(State0#state{timer = undefined}),
    Timer = schedule_refresh(State1#state.refresh_ms),
    {noreply, State1#state{timer = Timer}};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State) ->
    {noreply, remove_subscriber_ref(Pid, Ref, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.timer),
    lists:foreach(
        fun({_Pid, Ref}) -> erlang:demonitor(Ref, [flush]) end,
        State#state.subscribers
    ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Session refresh / publication
%%%===================================================================

refresh_state(State = #state{current = Old}) ->
    case enabled() of
        false ->
            New = {error, disabled},
            cache(New),
            maybe_notify_change(Old, New, State#state.subscribers),
            {New, State#state{current = New, consecutive_failures = 0}};
        true ->
            refresh_enabled(State)
    end.

refresh_enabled(State = #state{current = Old}) ->
    case detect() of
        {ok, Session} = New ->
            install_session(Session),
            cache(New),
            maybe_notify_change(Old, New, State#state.subscribers),
            {New, State#state{current = New, consecutive_failures = 0}};
        {error, Reason} = Error ->
            handle_detection_failure(Old, Error, Reason, State)
    end.

handle_detection_failure({ok, _Session} = Old, Error, Reason, State) ->
    Failures = State#state.consecutive_failures + 1,
    case Failures >= State#state.failure_threshold of
        true ->
            ?LOG_WARNING(
                "ERM graphical session unavailable after ~B consecutive probes: ~p",
                [Failures, Reason]
            ),
            cache(Error),
            maybe_notify_change(Old, Error, State#state.subscribers),
            {Error, State#state{current = Error, consecutive_failures = Failures}};
        false ->
            ?LOG_DEBUG(
                "ERM graphical session probe failed (~B/~B), keeping previous session: ~p",
                [Failures, State#state.failure_threshold, Reason]
            ),
            {Old, State#state{consecutive_failures = Failures}}
    end;
handle_detection_failure(Old, Error, _Reason, State) ->
    cache(Error),
    maybe_notify_change(Old, Error, State#state.subscribers),
    {Error, State#state{
        current = Error,
        consecutive_failures = State#state.consecutive_failures + 1
    }}.

maybe_notify_change(undefined, {ok, NewSession}, Subscribers) ->
    notify(Subscribers, {erm_display, available, NewSession});
maybe_notify_change({error, _}, {ok, NewSession}, Subscribers) ->
    notify(Subscribers, {erm_display, available, NewSession});
maybe_notify_change({ok, OldSession}, {ok, NewSession}, Subscribers) ->
    case same_session(OldSession, NewSession) of
        true -> ok;
        false -> notify(Subscribers, {erm_display, changed, OldSession, NewSession})
    end;
maybe_notify_change({ok, _OldSession}, {error, Reason}, Subscribers) ->
    notify(Subscribers, {erm_display, unavailable, Reason});
maybe_notify_change(_Old, _New, _Subscribers) ->
    ok.

same_session(A, B) ->
    proplists:get_value(backend, A) =:= proplists:get_value(backend, B) andalso
        proplists:get_value(display, A) =:= proplists:get_value(display, B) andalso
        proplists:get_value(xauthority, A) =:= proplists:get_value(xauthority, B) andalso
        proplists:get_value(xdg_runtime_dir, A) =:= proplists:get_value(xdg_runtime_dir, B).

notify(Subscribers, Message) ->
    lists:foreach(fun({Pid, _Ref}) -> Pid ! Message end, Subscribers).

add_subscriber(Pid, State) ->
    case lists:keyfind(Pid, 1, State#state.subscribers) of
        false ->
            Ref = erlang:monitor(process, Pid),
            State#state{subscribers = [{Pid, Ref} | State#state.subscribers]};
        _ ->
            State
    end.

remove_subscriber(Pid, State) ->
    case lists:keytake(Pid, 1, State#state.subscribers) of
        {value, {_Pid, Ref}, Rest} ->
            erlang:demonitor(Ref, [flush]),
            State#state{subscribers = Rest};
        false ->
            State
    end.

remove_subscriber_ref(Pid, Ref, State) ->
    State#state{
        subscribers = [
            Entry
         || Entry = {SubPid, SubRef} <- State#state.subscribers,
            not (SubPid =:= Pid andalso SubRef =:= Ref)
        ]
    }.

%%%===================================================================
%%% X11 discovery
%%%===================================================================

detect_x11(Config) ->
    X11 = proplist_value(x11, Config, []),
    SocketDir = proplists:get_value(socket_dir, X11, "/tmp/.X11-unix"),
    ProbeTimeout = positive_integer(
        proplists:get_value(probe_timeout_ms, X11, ?DEFAULT_PROBE_TIMEOUT_MS),
        ?DEFAULT_PROBE_TIMEOUT_MS
    ),
    ProbeCommands = proplists:get_value(
        probe_commands,
        X11,
        ["xdpyinfo", "xset", "xprop"]
    ),
    case current_uid() of
        {error, _Reason} = Error ->
            Error;
        {ok, Uid} ->
            RuntimeDir = runtime_dir(Uid),
            Home = home_dir(Uid),
            Displays0 = socket_displays(SocketDir),
            Authorities0 =
                x_server_authorities(Uid) ++
                    configured_authorities(Uid, Home, X11),
            {Displays, Authorities} = maybe_add_environment_fallback(
                Displays0,
                Authorities0,
                Config
            ),
            select_x11_session(
                unique(Displays),
                unique(Authorities),
                RuntimeDir,
                ProbeCommands,
                ProbeTimeout,
                SocketDir
            )
    end.

select_x11_session([], _Authorities, _RuntimeDir, _Commands, _Timeout, SocketDir) ->
    {error, {no_x11_sockets, SocketDir}};
select_x11_session(_Displays, [], _RuntimeDir, _Commands, _Timeout, _SocketDir) ->
    {error, no_xauthority_candidates};
select_x11_session(Displays, Authorities, RuntimeDir, Commands, Timeout, _SocketDir) ->
    Pairs = [{Display, Authority} || Display <- Displays, Authority <- Authorities],
    try_x11_pairs(Pairs, RuntimeDir, Commands, Timeout, []).

try_x11_pairs([], _RuntimeDir, _Commands, _Timeout, Errors) ->
    {error, {no_usable_x11_session, lists:reverse(Errors)}};
try_x11_pairs([{Display, Authority} | Rest], RuntimeDir, Commands, Timeout, Errors) ->
    case probe_x11(Display, Authority, RuntimeDir, Commands, Timeout) of
        {ok, Validator} ->
            {ok,
                [
                    {backend, x11},
                    {display, Display},
                    {xauthority, Authority},
                    {xdg_runtime_dir, RuntimeDir},
                    {validated_by, Validator},
                    {detected_at_ms, erlang:system_time(millisecond)}
                ]};
        {error, Reason} ->
            try_x11_pairs(
                Rest,
                RuntimeDir,
                Commands,
                Timeout,
                [{{Display, Authority}, Reason} | Errors]
            )
    end.

socket_displays(SocketDir) ->
    case file:list_dir(SocketDir) of
        {ok, Names} ->
            Parsed =
                lists:filtermap(
                    fun(Name) -> parse_x_socket(SocketDir, Name) end,
                    Names
                ),
            [Display || {_Number, Display} <- lists:keysort(1, Parsed)];
        {error, _} ->
            []
    end.

parse_x_socket(SocketDir, [$X | Digits] = Name) ->
    case decimal_string(Digits) of
        true ->
            Path = filename:join(SocketDir, Name),
            case file:read_file_info(Path) of
                {ok, #file_info{type = Type}} when Type =:= socket; Type =:= other ->
                    Number = list_to_integer(Digits),
                    {true, {Number, ":" ++ Digits}};
                _ ->
                    false
            end;
        false ->
            false
    end;
parse_x_socket(_SocketDir, _Name) ->
    false.

x_server_authorities(Uid) ->
    case file:list_dir("/proc") of
        {ok, Entries} ->
            unique(
                lists:flatmap(
                    fun(Pid) -> x_server_authority(Pid, Uid) end,
                    [Entry || Entry <- Entries, decimal_string(Entry)]
                )
            );
        {error, _} ->
            []
    end.

x_server_authority(Pid, Uid) ->
    ProcDir = filename:join("/proc", Pid),
    case file:read_file_info(ProcDir) of
        {ok, #file_info{uid = Uid}} ->
            case proc_cmdline(Pid) of
                [Executable | Args] ->
                    case is_x_server(filename:basename(Executable)) of
                        true ->
                            case arg_after("-auth", Args) of
                                undefined -> [];
                                Path -> readable_file(Path)
                            end;
                        false ->
                            []
                    end;
                _ ->
                    []
            end;
        _ ->
            []
    end.

is_x_server(Name0) ->
    Name = string:lowercase(Name0),
    Name =:= "x" orelse
        Name =:= "xorg" orelse
        Name =:= "xwayland" orelse
        lists:prefix("xorg", Name).

proc_cmdline(Pid) ->
    Path = filename:join(["/proc", Pid, "cmdline"]),
    case file:read_file(Path) of
        {ok, Binary} ->
            [
                binary_to_list(Arg)
             || Arg <- binary:split(Binary, <<0>>, [global]),
                Arg =/= <<>>
            ];
        {error, _} ->
            []
    end.

arg_after(Key, [Key, Value | _]) -> Value;
arg_after(Key, [_ | Rest]) -> arg_after(Key, Rest);
arg_after(_Key, []) -> undefined.

configured_authorities(Uid, Home, X11) ->
    Defaults = [
        "/run/user/%UID%/xauth_*",
        "/run/user/%UID%/Xauthority*",
        "/run/user/%UID%/gdm/Xauthority",
        "%HOME%/.Xauthority"
    ],
    Patterns = proplists:get_value(authority_paths, X11, Defaults),
    unique(
        lists:flatmap(
            fun(Pattern0) ->
                Pattern1 = expand_token(to_string(Pattern0), "%UID%", integer_to_list(Uid)),
                Pattern = expand_token(Pattern1, "%HOME%", Home),
                lists:flatmap(fun readable_file/1, filelib:wildcard(Pattern))
            end,
            Patterns
        )
    ).

readable_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular}} -> [Path];
        _ -> []
    end.

maybe_add_environment_fallback(Displays, Authorities, Config) ->
    case proplists:get_value(environment_fallback, Config, false) of
        true ->
            Display = env_string("DISPLAY"),
            XAuthority = env_string("XAUTHORITY"),
            {
                unique(Displays ++ maybe_single(Display)),
                unique(Authorities ++ maybe_readable(XAuthority))
            };
        false ->
            {Displays, Authorities};
        _Invalid ->
            {Displays, Authorities}
    end.

probe_x11(_Display, _Authority, _RuntimeDir, [], _Timeout) ->
    {error, no_x11_probe_command};
probe_x11(Display, Authority, RuntimeDir, [Command0 | Rest], Timeout) ->
    Command = to_string(Command0),
    case resolve_executable(Command) of
        false ->
            probe_x11(Display, Authority, RuntimeDir, Rest, Timeout);
        Executable ->
            Args = probe_args(filename:basename(Executable), Display),
            Env =
                compact_env([
                    {"DISPLAY", Display},
                    {"XAUTHORITY", Authority},
                    {"XDG_RUNTIME_DIR", RuntimeDir}
                ]),
            case run_probe(Executable, Args, Env, Timeout) of
                ok -> {ok, Executable};
                {error, _Reason} -> probe_x11(Display, Authority, RuntimeDir, Rest, Timeout)
            end
    end.

probe_args("xdpyinfo", Display) -> ["-display", Display];
probe_args("xset", Display) -> ["-display", Display, "q"];
probe_args("xprop", Display) -> ["-display", Display, "-root"];
probe_args(_Other, _Display) -> [].

run_probe(Executable, Args, Env, Timeout) ->
    try
        Port = open_port(
            {spawn_executable, Executable},
            [
                binary,
                exit_status,
                use_stdio,
                stderr_to_stdout,
                {args, Args},
                {env, Env}
            ]
        ),
        Timer = erlang:start_timer(Timeout, self(), {display_probe_timeout, Port}),
        wait_probe(Port, Timer)
    catch
        error:Reason -> {error, {probe_start_failed, Executable, Reason}}
    end.

wait_probe(Port, Timer) ->
    receive
        {Port, {data, _Data}} ->
            wait_probe(Port, Timer);
        {Port, {exit_status, 0}} ->
            cancel_probe_timer(Timer),
            ok;
        {Port, {exit_status, Status}} ->
            cancel_probe_timer(Timer),
            {error, {exit_status, Status}};
        {timeout, Timer, {display_probe_timeout, Port}} ->
            safe_port_close(Port),
            {error, timeout}
    end.

resolve_executable(Command) ->
    case filename:pathtype(Command) of
        absolute ->
            case filelib:is_regular(Command) of
                true -> Command;
                false -> false
            end;
        _ ->
            os:find_executable(Command)
    end.

%%%===================================================================
%%% Installation / cache
%%%===================================================================

install_session(Session) ->
    put_env("DISPLAY", proplists:get_value(display, Session)),
    put_env("XAUTHORITY", proplists:get_value(xauthority, Session)),
    put_env("XDG_RUNTIME_DIR", proplists:get_value(xdg_runtime_dir, Session)),
    ok.

session_env(Session) ->
    compact_env([
        {"DISPLAY", proplists:get_value(display, Session)},
        {"XAUTHORITY", proplists:get_value(xauthority, Session)},
        {"XDG_RUNTIME_DIR", proplists:get_value(xdg_runtime_dir, Session)}
    ]).

put_env(_Name, undefined) -> ok;
put_env(_Name, false) -> ok;
put_env(Name, Value) ->
    _ = os:putenv(Name, to_string(Value)),
    ok.

cache(Value) ->
    persistent_term:put(?CACHE_KEY, Value).

cached() ->
    persistent_term:get(?CACHE_KEY, undefined).

cached_or_ensure() ->
    case cached() of
        undefined -> ensure();
        Value -> Value
    end.

state_status(State) ->
    [
        {running, true},
        {enabled, enabled()},
        {current, State#state.current},
        {refresh_ms, State#state.refresh_ms},
        {consecutive_failures, State#state.consecutive_failures},
        {subscriber_count, length(State#state.subscribers)}
    ].

%%%===================================================================
%%% Configuration / OS helpers
%%%===================================================================

config() ->
    case application:get_env(erm, display, []) of
        List when is_list(List) -> List;
        undefined -> [];
        Invalid ->
            ?LOG_WARNING(
                "Ignoring invalid erm.display configuration ~p; expected a tuple list",
                [Invalid]
            ),
            []
    end.

proplist_value(Key, List, Default) when is_list(List) ->
    case proplists:get_value(Key, List, Default) of
        Value when is_list(Value) -> Value;
        _Invalid -> Default
    end.

current_uid() ->
    case file:read_file("/proc/self/status") of
        {ok, Binary} ->
            case re:run(Binary, <<"^Uid:[\\t ]+([0-9]+)">>, [
                multiline,
                {capture, [1], binary}
            ]) of
                {match, [UidBin]} -> {ok, binary_to_integer(UidBin)};
                nomatch -> {error, uid_not_found}
            end;
        {error, Reason} ->
            {error, {cannot_read_proc_status, Reason}}
    end.

runtime_dir(Uid) ->
    Path = "/run/user/" ++ integer_to_list(Uid),
    case filelib:is_dir(Path) of
        true -> Path;
        false -> undefined
    end.

home_dir(Uid) ->
    case file:read_file("/etc/passwd") of
        {ok, Binary} ->
            find_home(binary:split(Binary, <<"\n">>, [global]), Uid);
        {error, _} ->
            ""
    end.

find_home([Line | Rest], Uid) ->
    case binary:split(Line, <<":">>, [global]) of
        [_Name, _Passwd, UidBin, _Gid, _Gecos, HomeBin | _] ->
            case safe_binary_integer(UidBin) of
                Uid -> binary_to_list(HomeBin);
                _ -> find_home(Rest, Uid)
            end;
        _ ->
            find_home(Rest, Uid)
    end;
find_home([], _Uid) ->
    "".

safe_binary_integer(Binary) ->
    try binary_to_integer(Binary) catch _:_ -> undefined end.

expand_token(Value, Token, Replacement) ->
    lists:flatten(string:replace(Value, Token, Replacement, all)).

env_string(Name) ->
    case os:getenv(Name) of
        false -> undefined;
        "" -> undefined;
        Value -> Value
    end.

maybe_single(undefined) -> [];
maybe_single(Value) -> [Value].

maybe_readable(undefined) -> [];
maybe_readable(Path) -> readable_file(Path).

compact_env(Env) ->
    [{Name, to_string(Value)} || {Name, Value} <- Env, Value =/= undefined, Value =/= false].

unique(List) ->
    unique(List, []).

unique([], Acc) -> lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

decimal_string([]) -> false;
decimal_string(Value) -> lists:all(fun(Char) -> Char >= $0 andalso Char =< $9 end, Value).

positive_integer(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive_integer(_Value, Default) -> Default.

positive_or_infinity(infinity, _Default) -> infinity;
positive_or_infinity(Value, Default) -> positive_integer(Value, Default).

schedule_refresh(infinity) -> undefined;
schedule_refresh(Ms) -> erlang:send_after(Ms, self(), refresh).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

cancel_probe_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive
                {timeout, Ref, _Message} -> ok
            after 0 ->
                ok
            end;
        _ ->
            ok
    end.

safe_port_close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        error:badarg -> ok;
        _:_ -> ok
    end;
safe_port_close(_Port) ->
    ok.

to_string(Value) when is_list(Value) -> Value;
to_string(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_string(Value) when is_atom(Value) -> atom_to_list(Value);
to_string(Value) when is_integer(Value) -> integer_to_list(Value).
