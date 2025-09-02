-module(abduco_worker).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

%% PUBLIC API
-export([
    start_link/1,
    ping/1,
    status/1,
    send_signal/2,
    revive/1,
    stop/1
]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, cmd}).

%% ----- Public API ----------------------------------------------------------

start_link(#{name := Name, cmd := Cmd}) ->
    gen_server:start_link({via, gproc, {n, l, Name}}, ?MODULE, #{name => Name, cmd => Cmd}, []).

%% Cheap RPC liveness check for k8s/systemd/etc.
ping(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, ping, 2000).

%% Rich status
status(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, status, 5000).

%% Send a POSIX signal to the underlying process by pattern-matching the stored command.
%% Examples: send_signal(Name, hup) | send_signal(Name, term) | send_signal(Name, usr1) | send_signal(Name, 9).
send_signal(Name, Signal) ->
    gen_server:call({via, gproc, {n, l, Name}}, {signal, Signal}, 5000).

%% Re-run ensure_abduco_session/2 if the session died
revive(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, revive, 5000).

%% Try to stop underlying process(es) for this worker (best-effort).
stop(Name) ->
    gen_server:call({via, gproc, {n, l, Name}}, stop, 5000).

%% ----- gen_server ----------------------------------------------------------

init(#{name := Name, cmd := Cmd}) ->
    ensure_abduco_session(Name, Cmd),
    {ok, #state{name = Name, cmd = Cmd}}.

handle_call(ping, _From, S = #state{}) ->
    {reply, pong, S};
handle_call(status, _From, S = #state{name = Name, cmd = Cmd}) ->
    {Exists, Attached} = session_probe(Name),
    Pids = match_pids(Cmd),
    Reply = #{
        name => Name,
        command => Cmd,
        session_exists => Exists,
        session_attached => Attached,
        matched_pids => Pids,
        alive => Exists orelse (Pids =/= [])
    },
    {reply, Reply, S};
handle_call({signal, Sig}, _From, S = #state{cmd = Cmd}) ->
    SigStr = signal_string(Sig),
    CmdQ = shell_quote(Cmd),
    %% Send to all processes whose cmdline matches the stored command
    _ = os:cmd("pkill -f -" ++ SigStr ++ " -- " ++ CmdQ),
    {reply, ok, S};
handle_call(revive, _From, S = #state{name = N, cmd = C}) ->
    ok = ensure_abduco_session(N, C),
    {reply, ok, S};
handle_call(stop, _From, S = #state{cmd = Cmd}) ->
    CmdQ = shell_quote(Cmd),
    _ = os:cmd("pkill -f -- " ++ CmdQ),
    {reply, ok, S};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ----- Internal helpers ----------------------------------------------------

ensure_abduco_session(Name, Cmd) ->
    Sessions = os:cmd("abduco -l"),
    SessionList = string:tokens(Sessions, "\n"),
    case lists:any(fun(Line) -> string:find(Line, Name) =/= nomatch end, SessionList) of
        true ->
            ok;
        false ->
            Cmd0 = secrets:interpolate_template(Cmd),
            ?LOG_INFO("Starting abduco session ~s: ~s", [Name, Cmd0]),
            _ = os:cmd("abduco -n " ++ Name ++ " " ++ Cmd0),
            ok
    end.

%% Probe whether the session exists and whether someone is attached.
%% abduco -l format varies; we treat any line containing Name as exists,
%% and mark 'attached' if it contains '+' or 'attached' (defensive).
session_probe(Name) ->
    L = os:cmd("abduco -l"),
    case
        lists:filter(
            fun(Line) -> string:find(Line, Name) =/= nomatch end,
            string:tokens(L, "\n")
        )
    of
        [] ->
            {false, false};
        Lines ->
            Attached = lists:any(
                fun(Line) ->
                    (string:find(Line, "+") =/= nomatch) orelse
                        (string:find(string:lowercase(Line), "attached") =/= nomatch)
                end,
                Lines
            ),
            {true, Attached}
    end.

%% Find PIDs by matching the stored command on cmdline (best-effort).
match_pids(Cmd) ->
    CmdQ = shell_quote(Cmd),
    %% Return list of integers (PIDs); tolerate empty output
    Out = os:cmd("pgrep -f -- " ++ CmdQ ++ " 2>/dev/null"),
    case string:tokens(string:trim(Out), "\n") of
        [] -> [];
        Ns -> [list_to_integer(N) || N <- Ns, N =/= "", is_integer_string(N)]
    end.

is_integer_string(S) ->
    case catch list_to_integer(S) of
        I when is_integer(I) -> true;
        _ -> false
    end.

shell_quote(Str) ->
    %% Minimal single-quote shell escaping
    "'" ++ re:replace(Str, "'", "'\"'\"'", [global, {return, list}]) ++ "'".

signal_string(Sig) when is_integer(Sig) ->
    integer_to_list(Sig);
signal_string(Sig) when is_atom(Sig) ->
    string:to_upper(atom_to_list(Sig));
signal_string(Sig) when is_list(Sig) ->
    string:to_upper(Sig).
