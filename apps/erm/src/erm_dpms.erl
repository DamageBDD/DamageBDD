%% erm_dpms.erl
%% X11 ScreenSaver/DPMS manager for ERM.
%% Apache-2.0
%%
%% The OTP process owns one XCB connection. Screen-saver transitions come from
%% the X11 ScreenSaver extension; DPMS is controlled with the X11 DPMS
%% extension. No xset/xssstate subprocesses are used for X state/control.

-module(erm_dpms).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-on_load(load_nif/0).

-define(APP, erm).

-export([
    start_link/0,
    start_link/1,
    stop/0,
    status/0,
    sleep/0,
    wake/0,
    enable_dpms/0,
    disable_dpms/0,
    force_dpms/1,
    set_screensaver_timeout/1,
    set_dpms_timeouts/3,
    inhibit/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% NIF entry points. These stubs are replaced by priv/erm_dpms_nif.so.
-export([
    x11_open/0,
    x11_close/1,
    x11_screensaver_info/1,
    x11_screensaver_events/1,
    x11_get_screensaver/1,
    x11_set_screensaver_timeout/2,
    x11_force_screensaver/2,
    x11_screensaver_suspend/2,
    x11_dpms_info/1,
    x11_get_dpms_timeouts/1,
    x11_set_dpms_timeouts/4,
    x11_dpms_enable/1,
    x11_dpms_disable/1,
    x11_dpms_force/2
]).

-export_type([
    dpms_level/0,
    hook/0
]).

-define(DEFAULT_POLL_MS, 100).
-define(DEFAULT_ON_START_DELAY_SECONDS, 0).
-define(HOOK_OUTPUT_LIMIT, 8192).
-define(HOOK_TIMEOUT_MS, 30000).
-define(MAX_SCREENSAVER_TIMEOUT, 32767).
-define(MAX_DPMS_TIMEOUT, 65535).

-type dpms_level() :: on | standby | suspend | off.
-type hook() ::
    undefined
    | fun(() -> term())
    | {module(), atom(), [term()]}
    | {exec, string() | binary(), [string() | binary()]}
    | {shell, string() | binary()}.

%% ------------------------------------------------------------------
%% Public API
%% ------------------------------------------------------------------

start_link() ->
    start_link(dpms_config()).

start_link(Opts) when is_list(Opts); is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

dpms_config() ->
    case application:get_env(?APP, dpms) of
        {ok, Opts} ->
            strip_enabled(Opts);
        undefined ->
            case application:get_env(?APP, ?MODULE) of
                {ok, Opts} -> strip_enabled(Opts);
                undefined -> []
            end
    end.

strip_enabled(Opts) when is_map(Opts) ->
    maps:remove(enabled, Opts);
strip_enabled(Opts) when is_list(Opts) ->
    proplists:delete(enabled, Opts).


stop() ->
    gen_server:stop(?MODULE).

status() ->
    gen_server:call(?MODULE, status).

sleep() ->
    gen_server:call(?MODULE, sleep).

wake() ->
    gen_server:call(?MODULE, wake).

enable_dpms() ->
    gen_server:call(?MODULE, enable_dpms).

disable_dpms() ->
    gen_server:call(?MODULE, disable_dpms).

-spec force_dpms(dpms_level()) -> ok | {error, term()}.
force_dpms(Level) when Level =:= on; Level =:= standby; Level =:= suspend; Level =:= off ->
    gen_server:call(?MODULE, {force_dpms, Level}).

set_screensaver_timeout(Seconds)
        when is_integer(Seconds),
             Seconds >= 0,
             Seconds =< ?MAX_SCREENSAVER_TIMEOUT ->
    gen_server:call(?MODULE, {set_screensaver_timeout, Seconds}).

set_dpms_timeouts(Standby, Suspend, Off)
        when is_integer(Standby), Standby >= 0, Standby =< ?MAX_DPMS_TIMEOUT,
             is_integer(Suspend), Suspend >= 0, Suspend =< ?MAX_DPMS_TIMEOUT,
             is_integer(Off), Off >= 0, Off =< ?MAX_DPMS_TIMEOUT ->
    gen_server:call(?MODULE, {set_dpms_timeouts, Standby, Suspend, Off}).

inhibit(Bool) when is_boolean(Bool) ->
    gen_server:call(?MODULE, {inhibit, Bool}).

%% ------------------------------------------------------------------
%% gen_server
%% ------------------------------------------------------------------

init(Opts0) ->
    Opts = normalize_opts(Opts0),
    case x11_open() of
        {ok, X11} ->
            case configure_x11(X11, Opts) of
                ok ->
                    case x11_screensaver_info(X11) of
                        {ok, SSInfo} ->
                            State = #{
                                x11 => X11,
                                poll_ms => maps:get(poll_ms, Opts),
                                saver_state => maps:get(state, SSInfo),
                                dpms_on_saver => maps:get(dpms_on_saver, Opts),
                                on_start => maps:get(on_start, Opts),
                                on_start_delay => maps:get(on_start_delay, Opts),
                                on_start_pending => undefined,
                                on_stop => maps:get(on_stop, Opts),
                                inhibited => false
                            },
                            ?LOG_INFO(
                                "ERM DPMS started: screensaver=~p idle_ms=~p "
                                "dpms_on_saver=~p on_start_delay=~Bs",
                                [
                                    maps:get(state, SSInfo),
                                    maps:get(idle_ms, SSInfo),
                                    maps:get(dpms_on_saver, Opts),
                                    maps:get(on_start_delay, Opts)
                                ]
                            ),
                            schedule_poll(State),
                            {ok, State};
                        {error, Reason} ->
                            safe_x11_close(X11),
                            {stop, {screensaver_query_failed, Reason}}
                    end;
                {error, Reason} ->
                    safe_x11_close(X11),
                    {stop, {x11_configuration_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {x11_open_failed, Reason}}
    end.

handle_call(status, _From, State = #{x11 := X11}) ->
    Reply = #{
        screensaver => query_or_error(fun() -> x11_screensaver_info(X11) end),
        screensaver_config => query_or_error(fun() -> x11_get_screensaver(X11) end),
        dpms => query_or_error(fun() -> x11_dpms_info(X11) end),
        dpms_timeouts => query_or_error(fun() -> x11_get_dpms_timeouts(X11) end),
        transition_state => maps:get(saver_state, State),
        on_start_delay => maps:get(on_start_delay, State),
        on_start_pending_ms => pending_start_remaining_ms(State),
        inhibited => maps:get(inhibited, State)
    },
    {reply, Reply, State};

handle_call(sleep, _From, State = #{x11 := X11}) ->
    Reply = x11_force_screensaver(X11, active),
    {reply, Reply, State};

handle_call(wake, _From, State0 = #{x11 := X11}) ->
    %% Cancel first so an explicit wake cannot race the delayed start hook
    %% while the XScreenSaver reset event is waiting for the next poll.
    State = cancel_pending_start_hook(State0),
    %% Bring the monitor up before resetting the saver. Both operations are
    %% explicit X11 protocol requests; user activity normally does this too.
    R1 =
        case ensure_dpms_enabled(X11) of
            ok -> x11_dpms_force(X11, on);
            Error -> Error
        end,
    R2 = x11_force_screensaver(X11, reset),
    {reply, first_error([R1, R2]), State};

handle_call(enable_dpms, _From, State = #{x11 := X11}) ->
    {reply, x11_dpms_enable(X11), State};

handle_call(disable_dpms, _From, State = #{x11 := X11}) ->
    {reply, x11_dpms_disable(X11), State};

handle_call({force_dpms, Level}, _From, State = #{x11 := X11})
        when Level =:= on; Level =:= standby; Level =:= suspend; Level =:= off ->
    Reply =
        case ensure_dpms_enabled(X11) of
            ok -> x11_dpms_force(X11, Level);
            Error -> Error
        end,
    {reply, Reply, State};

handle_call({set_screensaver_timeout, Seconds}, _From, State = #{x11 := X11})
        when is_integer(Seconds),
             Seconds >= 0,
             Seconds =< ?MAX_SCREENSAVER_TIMEOUT ->
    {reply, x11_set_screensaver_timeout(X11, Seconds), State};

handle_call({set_dpms_timeouts, Standby, Suspend, Off}, _From, State = #{x11 := X11})
        when is_integer(Standby), Standby >= 0, Standby =< ?MAX_DPMS_TIMEOUT,
             is_integer(Suspend), Suspend >= 0, Suspend =< ?MAX_DPMS_TIMEOUT,
             is_integer(Off), Off >= 0, Off =< ?MAX_DPMS_TIMEOUT ->
    {reply, x11_set_dpms_timeouts(X11, Standby, Suspend, Off), State};

handle_call({inhibit, Bool}, _From, State = #{inhibited := Bool}) when is_boolean(Bool) ->
    %% XScreenSaverSuspend is reference-counted by the X server. Keep this API
    %% idempotent so repeated inhibit(true) calls do not require matching
    %% repeated inhibit(false) calls.
    {reply, ok, State};
handle_call({inhibit, Bool}, _From, State = #{x11 := X11}) when is_boolean(Bool) ->
    case x11_screensaver_suspend(X11, Bool) of
        ok -> {reply, ok, State#{inhibited => Bool}};
        Error -> {reply, Error, State}
    end;

handle_call(Request, _From, State) ->
    {reply, {error, {unknown_call, Request}}, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("ERM DPMS ignoring cast ~p", [Msg]),
    {noreply, State}.

handle_info(poll_x11, State0 = #{x11 := X11}) ->
    State1 =
        case x11_screensaver_events(X11) of
            {ok, Events} ->
                lists:foldl(fun handle_screensaver_event/2, State0, Events);
            {error, connection_lost} ->
                exit(x11_connection_lost);
            {error, Reason} ->
                ?LOG_WARNING("ERM DPMS X11 event poll failed: ~p", [Reason]),
                State0
        end,
    schedule_poll(State1),
    {noreply, State1};

handle_info(
        {run_delayed_start_hook, Token},
        State0 = #{on_start_pending := #{token := Token}}
    ) ->
    State1 = State0#{on_start_pending => undefined},
    case delayed_start_is_valid(State1) of
        true ->
            ?LOG_INFO("ERM DPMS start-hook delay elapsed; running hook", []),
            run_hook_async(start, maps:get(on_start, State1)),
            {noreply, State1};
        false ->
            %% Re-check the live XScreenSaver state. This covers physical input
            %% that wakes the display just before the next poll is processed.
            ?LOG_DEBUG("Ignoring delayed start hook because the saver is inactive", []),
            {noreply, State1}
    end;
handle_info({run_delayed_start_hook, _StaleToken}, State) ->
    %% cancel_timer/1 can race with delivery. Tokens ensure an old timer can
    %% never start a process during a later sleep cycle.
    ?LOG_DEBUG("Ignoring stale ERM DPMS delayed start-hook timer", []),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_DEBUG("ERM DPMS ignoring info ~p", [Info]),
    {noreply, State}.

terminate(Reason, State0) ->
    State = cancel_pending_start_hook(State0),
    safe_x11_close(maps:get(x11, State, undefined)),
    ?LOG_INFO("ERM DPMS stopped: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

safe_x11_close(undefined) ->
    ok;
safe_x11_close(X11) ->
    try x11_close(X11) of
        _ ->
            ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(
                "Ignoring X11 close failure during shutdown (~p): ~p; stacktrace=~p",
                [Class, Reason, Stacktrace]
            ),
            ok
    end.

%% ------------------------------------------------------------------
%% State transitions
%% ------------------------------------------------------------------

handle_screensaver_event(
        #{state := NewSaverState} = Event,
        State0 = #{saver_state := OldSaverState}
    )
        when NewSaverState =:= on;
             NewSaverState =:= off;
             NewSaverState =:= cycle;
             NewSaverState =:= disabled ->
    State1 = State0#{saver_state => NewSaverState},
    case {saver_active(OldSaverState), saver_active(NewSaverState)} of
        {false, true} ->
            ?LOG_INFO("X11 screensaver started: ~p", [Event]),
            maybe_power_down(State1),
            schedule_start_hook(State1);
        {true, false} ->
            ?LOG_INFO("X11 screensaver stopped: ~p", [Event]),
            State2 = cancel_pending_start_hook(State1),
            maybe_power_up(State2),
            run_hook_async(stop, maps:get(on_stop, State2)),
            State2;
        _ ->
            State1
    end;
handle_screensaver_event(_Event, State) ->
    State.

saver_active(on) -> true;
saver_active(cycle) -> true;
saver_active(_) -> false.

schedule_start_hook(State0 = #{on_start := undefined}) ->
    cancel_pending_start_hook(State0);
schedule_start_hook(State0 = #{on_start_delay := 0, on_start := Hook}) ->
    State = cancel_pending_start_hook(State0),
    run_hook_async(start, Hook),
    State;
schedule_start_hook(State0 = #{on_start_delay := DelaySeconds}) ->
    State = cancel_pending_start_hook(State0),
    Token = make_ref(),
    TimerRef = erlang:send_after(
        DelaySeconds * 1000,
        self(),
        {run_delayed_start_hook, Token}
    ),
    ?LOG_INFO(
        "Delaying ERM DPMS start hook for ~B seconds; wake cancels it",
        [DelaySeconds]
    ),
    State#{on_start_pending => #{timer => TimerRef, token => Token}}.

cancel_pending_start_hook(State) ->
    case maps:get(on_start_pending, State, undefined) of
        #{timer := TimerRef} ->
            _ = erlang:cancel_timer(TimerRef),
            ?LOG_DEBUG("Cancelled pending ERM DPMS start hook", []),
            State#{on_start_pending => undefined};
        undefined ->
            State
    end.

pending_start_remaining_ms(State) ->
    case maps:get(on_start_pending, State, undefined) of
        #{timer := TimerRef} ->
            case erlang:read_timer(TimerRef) of
                false -> 0;
                RemainingMs -> RemainingMs
            end;
        undefined ->
            false
    end.

delayed_start_is_valid(#{x11 := X11, saver_state := CachedState}) ->
    case x11_screensaver_info(X11) of
        {ok, #{state := CurrentState}} ->
            saver_active(CurrentState);
        {error, Reason} ->
            ?LOG_WARNING(
                "Could not confirm X11 saver state before delayed start hook: ~p "
                "(cached_state=~p); suppressing hook",
                [Reason, CachedState]
            ),
            false
    end.

maybe_power_down(#{dpms_on_saver := ignore}) ->
    ok;
maybe_power_down(#{x11 := X11, dpms_on_saver := Level}) ->
    case ensure_dpms_enabled(X11) of
        ok ->
            case x11_dpms_force(X11, Level) of
                ok -> ok;
                Error -> ?LOG_WARNING("Failed to force DPMS ~p: ~p", [Level, Error])
            end;
        Error ->
            ?LOG_WARNING("Failed to enable DPMS: ~p", [Error])
    end.

maybe_power_up(#{dpms_on_saver := ignore}) ->
    ok;
maybe_power_up(#{x11 := X11}) ->
    case ensure_dpms_enabled(X11) of
        ok ->
            case x11_dpms_force(X11, on) of
                ok -> ok;
                Error -> ?LOG_WARNING("Failed to force DPMS on: ~p", [Error])
            end;
        Error ->
            ?LOG_WARNING("Failed to enable DPMS while waking: ~p", [Error])
    end.

ensure_dpms_enabled(X11) ->
    case x11_dpms_info(X11) of
        {ok, #{capable := false}} ->
            {error, dpms_not_capable};
        {ok, #{enabled := true}} ->
            ok;
        {ok, #{enabled := false}} ->
            x11_dpms_enable(X11);
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% Configuration
%% ------------------------------------------------------------------

normalize_opts(Opts) when is_list(Opts) ->
    normalize_opts(maps:from_list(Opts));
normalize_opts(Opts) when is_map(Opts) ->
    Defaults = #{
        poll_ms => ?DEFAULT_POLL_MS,
        screensaver_timeout => keep,
        dpms_timeouts => keep,
        dpms_on_saver => off,
        on_start => undefined,
        on_start_delay => ?DEFAULT_ON_START_DELAY_SECONDS,
        on_stop => undefined
    },
    validate_opts(maps:merge(Defaults, Opts)).

validate_opts(Opts) ->
    Poll = maps:get(poll_ms, Opts),
    true = is_integer(Poll) andalso Poll >= 20,
    Level = maps:get(dpms_on_saver, Opts),
    true = lists:member(Level, [ignore, standby, suspend, off]),
    StartDelay = maps:get(on_start_delay, Opts),
    true = is_integer(StartDelay) andalso StartDelay >= 0,
    Opts.

configure_x11(X11, Opts) ->
    case configure_screensaver_timeout(X11, maps:get(screensaver_timeout, Opts)) of
        ok ->
            configure_dpms_timeouts(X11, maps:get(dpms_timeouts, Opts));
        Error ->
            Error
    end.

configure_screensaver_timeout(_X11, keep) ->
    ok;
configure_screensaver_timeout(X11, Seconds)
        when is_integer(Seconds),
             Seconds >= 0,
             Seconds =< ?MAX_SCREENSAVER_TIMEOUT ->
    x11_set_screensaver_timeout(X11, Seconds);
configure_screensaver_timeout(_X11, Bad) ->
    {error, {bad_screensaver_timeout, Bad}}.

configure_dpms_timeouts(_X11, keep) ->
    ok;
configure_dpms_timeouts(X11, {Standby, Suspend, Off})
        when is_integer(Standby), Standby >= 0, Standby =< ?MAX_DPMS_TIMEOUT,
             is_integer(Suspend), Suspend >= 0, Suspend =< ?MAX_DPMS_TIMEOUT,
             is_integer(Off), Off >= 0, Off =< ?MAX_DPMS_TIMEOUT ->
    x11_set_dpms_timeouts(X11, Standby, Suspend, Off);
configure_dpms_timeouts(_X11, Bad) ->
    {error, {bad_dpms_timeouts, Bad}}.

schedule_poll(#{poll_ms := PollMs}) ->
    erlang:send_after(PollMs, self(), poll_x11).

query_or_error(Fun) ->
    case Fun() of
        {ok, Value} -> Value;
        {error, Reason} -> {error, Reason}
    end.

first_error([]) ->
    ok;
first_error([ok | Rest]) ->
    first_error(Rest);
first_error([{error, _} = Error | _]) ->
    Error.

%% ------------------------------------------------------------------
%% Hooks
%% ------------------------------------------------------------------

-spec run_hook_async(start | stop, hook()) -> ok.
run_hook_async(_Name, undefined) ->
    ok;
run_hook_async(Name, Hook) ->
    _ = spawn(fun() -> execute_hook_safely(Name, Hook) end),
    ok.

execute_hook_safely(Name, Hook) ->
    try execute_hook(Hook) of
        ok ->
            ?LOG_DEBUG("ERM DPMS ~p hook completed", [Name]);
        {ok, _} ->
            ?LOG_DEBUG("ERM DPMS ~p hook completed", [Name]);
        {error, Reason} ->
            ?LOG_WARNING("ERM DPMS ~p hook failed: ~p", [Name, Reason]);
        Other ->
            ?LOG_DEBUG("ERM DPMS ~p hook returned ~p", [Name, Other])
    catch
        Class:CrashReason:Stacktrace ->
            ?LOG_WARNING(
                "ERM DPMS ~p hook crashed (~p): ~p; stacktrace=~p",
                [Name, Class, CrashReason, Stacktrace]
            )
    end.

execute_hook(Fun) when is_function(Fun, 0) ->
    Fun();
execute_hook({M, F, A}) when is_atom(M), is_atom(F), is_list(A) ->
    apply(M, F, A);
execute_hook({exec, Executable, Args}) when is_list(Args) ->
    run_executable(Executable, Args);
execute_hook({shell, Command}) ->
    run_executable("/bin/sh", ["-lc", to_list(Command)]);
execute_hook(Bad) ->
    {error, {bad_hook, Bad}}.

run_executable(Executable0, Args0) ->
    Executable = to_list(Executable0),
    Args = [to_list(A) || A <- Args0],
    Port = open_port(
        {spawn_executable, Executable},
        [binary, use_stdio, stderr_to_stdout, exit_status, {args, Args}]
    ),
    collect_port(Port, <<>>).

collect_port(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, keep_tail(Output, Data));
        {Port, {exit_status, 0}} ->
            {ok, Output};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, Output}}
    after ?HOOK_TIMEOUT_MS ->
        close_port_safely(Port),
        {error, hook_timeout}
    end.

close_port_safely(Port) ->
    try erlang:port_close(Port) of
        true ->
            ok
    catch
        error:badarg ->
            %% The port may have closed immediately before the timeout fired.
            ok;
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(
                "Ignoring hook port close failure (~p): ~p; stacktrace=~p",
                [Class, Reason, Stacktrace]
            ),
            ok
    end.

keep_tail(Old, New) ->
    Joined = <<Old/binary, New/binary>>,
    Size = byte_size(Joined),
    case Size =< ?HOOK_OUTPUT_LIMIT of
        true -> Joined;
        false -> binary:part(Joined, Size - ?HOOK_OUTPUT_LIMIT, ?HOOK_OUTPUT_LIMIT)
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A).

%% ------------------------------------------------------------------
%% NIF loader/stubs
%% ------------------------------------------------------------------

load_nif() ->
    Beam = code:which(?MODULE),
    AppDir = filename:dirname(filename:dirname(Beam)),
    SoName = filename:join([AppDir, "priv", "erm_dpms_nif"]),
    case erlang:load_nif(SoName, 0) of
        ok -> ok;
        {error, {reload, _}} -> ok;
        {error, Reason} ->
            logger:error("Unable to load ERM DPMS NIF ~ts: ~p", [SoName, Reason]),
            ok
    end.

x11_open() -> {error, nif_not_loaded}.
x11_close(_X11) -> erlang:nif_error(nif_not_loaded).
x11_screensaver_info(_X11) -> erlang:nif_error(nif_not_loaded).
x11_screensaver_events(_X11) -> erlang:nif_error(nif_not_loaded).
x11_get_screensaver(_X11) -> erlang:nif_error(nif_not_loaded).
x11_set_screensaver_timeout(_X11, _Seconds) -> erlang:nif_error(nif_not_loaded).
x11_force_screensaver(_X11, _Mode) -> erlang:nif_error(nif_not_loaded).
x11_screensaver_suspend(_X11, _Bool) -> erlang:nif_error(nif_not_loaded).
x11_dpms_info(_X11) -> erlang:nif_error(nif_not_loaded).
x11_get_dpms_timeouts(_X11) -> erlang:nif_error(nif_not_loaded).
x11_set_dpms_timeouts(_X11, _Standby, _Suspend, _Off) -> erlang:nif_error(nif_not_loaded).
x11_dpms_enable(_X11) -> erlang:nif_error(nif_not_loaded).
x11_dpms_disable(_X11) -> erlang:nif_error(nif_not_loaded).
x11_dpms_force(_X11, _Level) -> erlang:nif_error(nif_not_loaded).
