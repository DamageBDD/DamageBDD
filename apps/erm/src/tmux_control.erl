%%%-------------------------------------------------------------------
%%% tmux_control.erl
%%%
%%% A gen_server that manages a persistent `tmux -C` control-mode client.
%%% It correlates synchronous calls to tmux responses using %begin/%end.
%%%
%%% Requires: tmux in PATH (or set tmux_path option).
%%%-------------------------------------------------------------------

-module(tmux_control).
-behaviour(gen_server).

-export([start_link/1, stop/1]).
-export([cmd/2, cmd/3]).
-export([list_sessions/1, new_session/3, new_window/3, kill_session/2]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_TMUX, "/usr/bin/tmux").

-record(st, {
    port,
    tmux_path = ?DEFAULT_TMUX,
    % e.g. "/tmp/steven/tmux_outer_socket0"
    socket_path = undefined,
    % e.g. "/home/steven/.tmux/outer.conf"
    config_file = undefined,
    % our own tag for "sent queue"
    next_tag = 1,
    % queue of {Tag, From}
    sent_q = queue:new(),
    % tmux_id() => #{from:=From, out:=[], err:=[], begun:=boolean()}
    by_id = #{},
    % Tag => tmux_id() once %begin arrives
    by_tag = #{}
}).

%%%========================
%%% Public API
%%%========================

-spec start_link(map() | proplists:proplist()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) ->
    gen_server:cast(Pid, stop).

%% Run a tmux command line (string/binary) and return collected output.
-spec cmd(pid(), iodata()) ->
    {ok, #{stdout := [binary()], stderr := [binary()]}}
    | {error, term(), #{stdout := [binary()], stderr := [binary()]}}.
cmd(Pid, Line) ->
    cmd(Pid, Line, 5000).

-spec cmd(pid(), iodata(), timeout()) -> {ok, map()} | {error, term(), map()}.
cmd(Pid, Line, Timeout) ->
    gen_server:call(Pid, {cmd, Line}, Timeout).

%% Convenience wrappers
list_sessions(Pid) ->
    cmd(Pid, <<"list-sessions">>).

new_session(Pid, SessionName, StartDir) ->
    Line = iolist_to_binary([
        "new-session -d -s ",
        SessionName,
        " -c ",
        StartDir
    ]),
    cmd(Pid, Line).

new_window(Pid, SessionName, WindowName) ->
    %% -t session: targets a session; -n names the new window
    Line = iolist_to_binary([
        "new-window -t ",
        SessionName,
        " -n ",
        WindowName
    ]),
    cmd(Pid, Line).

kill_session(Pid, SessionName) ->
    Line = iolist_to_binary(["kill-session -t ", SessionName]),
    cmd(Pid, Line).

%%%========================
%%% gen_server
%%%========================

init(Opts0) ->
    Opts = normalize_opts(Opts0),
    TmuxPath = maps:get(tmux_path, Opts, ?DEFAULT_TMUX),
    Socket = maps:get(socket_path, Opts, undefined),
    Conf = maps:get(config_file, Opts, undefined),

    Port = open_tmux_control_port(TmuxPath, Socket, Conf),

    process_flag(trap_exit, true),
    {ok, #st{
        port = Port,
        tmux_path = TmuxPath,
        socket_path = Socket,
        config_file = Conf
    }}.

handle_call({cmd, Line0}, From, St0 = #st{port = Port, next_tag = Tag, sent_q = Q0}) ->
    Line = ensure_line(Line0),
    port_command(Port, Line),
    Q1 = queue:in({Tag, From}, Q0),
    St1 = St0#st{next_tag = Tag + 1, sent_q = Q1},
    {noreply, St1};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_request}, St}.

handle_cast(stop, St = #st{port = Port}) ->
    catch port_close(Port),
    {stop, normal, St};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({Port, {data, LineBin}}, St0 = #st{port = Port}) ->
    %% We opened the port with {packet, line}, so each message is a line without "\n".
    St1 = handle_tmux_line(LineBin, St0),
    {noreply, St1};
handle_info({Port, closed}, St = #st{port = Port}) ->
    {stop, {tmux_port_closed, Port}, St};
handle_info({'EXIT', Port, Reason}, St = #st{port = Port}) ->
    {stop, {tmux_port_exit, Reason}, St};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, #st{port = Port}) ->
    catch port_close(Port),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%%%========================
%%% Control-mode parsing
%%%========================

handle_tmux_line(Line0, St0) ->
    Line = strip_cr(Line0),
    case Line of
        <<"%begin ", Rest/binary>> ->
            %% %begin <id> <command...>
            {Id, _Cmd} = split_id_and_rest(Rest),
            assign_begin(Id, St0);
        <<"%end ", Rest/binary>> ->
            %% %end <id>
            {Id, _} = split_id_and_rest(Rest),
            finish_cmd(Id, ok, St0);
        <<"%error ", Rest/binary>> ->
            %% %error <id> <message...>
            {Id, Msg} = split_id_and_rest(Rest),
            add_err(Id, Msg, St0);
        <<"%output ", Rest/binary>> ->
            %% %output <id> <line...>
            {Id, Msg} = split_id_and_rest(Rest),
            add_out(Id, Msg, St0);
        %% Some tmux builds emit plain lines too; treat as "unattributed output"
        _Other ->
            St0
    end.

assign_begin(Id, St0 = #st{sent_q = Q0, by_id = ById0, by_tag = ByTag0}) ->
    case queue:out(Q0) of
        {{value, {Tag, From}}, Q1} ->
            %% Tie tmux's Id to the oldest outstanding call.
            Entry = #{from => From, out => [], err => [], begun => true},
            ById1 = maps:put(Id, Entry, ById0),
            ByTag1 = maps:put(Tag, Id, ByTag0),
            St0#st{sent_q = Q1, by_id = ById1, by_tag = ByTag1};
        {empty, _Q} ->
            %% Unexpected begin without a queued call; track anyway.
            Entry = #{from => undefined, out => [], err => [], begun => true},
            St0#st{by_id = maps:put(Id, Entry, ById0)}
    end.

add_out(Id, Msg, St0 = #st{by_id = ById0}) ->
    Entry0 = maps:get(Id, ById0, #{from => undefined, out => [], err => [], begun => false}),
    Out0 = maps:get(out, Entry0, []),
    Entry1 = Entry0#{out => [Msg | Out0]},
    St0#st{by_id = maps:put(Id, Entry1, ById0)}.

add_err(Id, Msg, St0 = #st{by_id = ById0}) ->
    Entry0 = maps:get(Id, ById0, #{from => undefined, out => [], err => [], begun => false}),
    Err0 = maps:get(err, Entry0, []),
    Entry1 = Entry0#{err => [Msg | Err0]},
    St0#st{by_id = maps:put(Id, Entry1, ById0)}.

finish_cmd(Id, Status, St0 = #st{by_id = ById0}) ->
    case maps:take(Id, ById0) of
        {Entry, ById1} ->
            From = maps:get(from, Entry, undefined),
            OutR = lists:reverse(maps:get(out, Entry, [])),
            ErrR = lists:reverse(maps:get(err, Entry, [])),
            ReplyMap = #{stdout => OutR, stderr => ErrR},
            do_reply(From, Status, ReplyMap),
            St0#st{by_id = ById1};
        error ->
            St0
    end.

do_reply(undefined, _Status, _ReplyMap) ->
    ok;
do_reply(From, ok, ReplyMap) ->
    gen_server:reply(From, {ok, ReplyMap});
do_reply(From, Err, ReplyMap) ->
    gen_server:reply(From, {error, Err, ReplyMap}).

%%%========================
%%% Port setup / helpers
%%%========================

open_tmux_control_port(TmuxPath, Socket, Conf) ->
    Args0 = ["-C"],
    Args1 =
        case Conf of
            undefined -> Args0;
            _ -> Args0 ++ ["-f", Conf]
        end,
    Args2 =
        case Socket of
            undefined -> Args1;
            _ -> Args1 ++ ["-S", Socket]
        end,
    open_port(
        {spawn_executable, TmuxPath},
        [
            {args, Args2},
            exit_status,
            use_stdio,
            stderr_to_stdout,
            binary,
            %% deliver whole lines as binaries
            {packet, line}
        ]
    ).

normalize_opts(M) when is_map(M) -> M;
normalize_opts(L) when is_list(L) -> maps:from_list(L).

ensure_line(Bin) when is_binary(Bin) ->
    case (byte_size(Bin) > 0) andalso (binary:last(Bin) =:= $\n) of
        true -> Bin;
        false -> <<Bin/binary, $\n>>
    end;
ensure_line(Io) ->
    ensure_line(iolist_to_binary(Io)).

strip_cr(Bin) when is_binary(Bin) ->
    case (byte_size(Bin) > 0) andalso (binary:last(Bin) =:= $\r) of
        true -> binary:part(Bin, 0, byte_size(Bin) - 1);
        false -> Bin
    end.

split_id_and_rest(Rest) ->
    %% Rest = <<"123 whatever...">> or <<"123">>
    case binary:split(Rest, <<" ">>, [global]) of
        [IdBin] ->
            {to_id(IdBin), <<>>};
        [IdBin | Tail] ->
            {to_id(IdBin), iolist_to_binary(join_with_space(Tail))}
    end.

join_with_space([]) -> [];
join_with_space([H]) -> [H];
join_with_space([H | T]) -> [H, <<" ">> | join_with_space(T)].

to_id(IdBin) ->
    %% tmux ids are decimal integers
    binary_to_integer(IdBin).
