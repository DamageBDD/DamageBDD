%% damage_ssh_git_channel.erl
%% SSH channel implementation for the Damage Git smart-SSH listener.

-module(damage_ssh_git_channel).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(ssh_server_channel).

-include_lib("kernel/include/logger.hrl").

-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2]).

-record(state, {
    cm = undefined,
    channel_id = undefined,
    port = undefined,
    command = undefined,
    repo = undefined,
    timer_ref = undefined
}).

init([git_cli]) ->
    {ok, #state{}};
init(Args) ->
    {stop, {invalid_git_channel_args, Args}}.

handle_msg({ssh_channel_up, ChannelId, CM}, State) ->
    {ok, State#state{cm = CM, channel_id = ChannelId}};
handle_msg(
    {Port, {data, Bin}}, #state{cm = CM, channel_id = ChannelId, port = Port} = State
) ->
    _ = ssh_connection:send(CM, ChannelId, 0, Bin),
    {ok, State};
handle_msg(
    {Port, {exit_status, Code}},
    #state{cm = CM, channel_id = ChannelId, port = Port} = State
) ->
    cancel_timer(State#state.timer_ref),
    _ = ssh_connection:send_eof(CM, ChannelId),
    _ = ssh_connection:exit_status(CM, ChannelId, Code),
    {stop, ChannelId, State#state{port = undefined, timer_ref = undefined}};
handle_msg(
    {'EXIT', Port, Reason}, #state{cm = CM, channel_id = ChannelId, port = Port} = State
) ->
    cancel_timer(State#state.timer_ref),
    ?LOG_WARNING("Git helper port exited reason=~p", [Reason]),
    _ = ssh_connection:send(CM, ChannelId, 1, io_lib:format("git helper exited: ~p~n", [Reason])),
    _ = ssh_connection:exit_status(CM, ChannelId, 1),
    {stop, ChannelId, State#state{port = undefined, timer_ref = undefined}};
handle_msg(git_timeout, #state{port = Port, cm = CM, channel_id = ChannelId} = State) when
    is_port(Port)
->
    port_close(Port),
    _ = ssh_connection:send(CM, ChannelId, 1, <<"git helper timed out\n">>),
    _ = ssh_connection:exit_status(CM, ChannelId, 124),
    {stop, ChannelId, State#state{port = undefined, timer_ref = undefined}};
handle_msg(_Msg, State) ->
    {ok, State}.

handle_ssh_msg({ssh_cm, CM, {exec, ChannelId, WantReply, Command}}, State) ->
    start_git_exec(CM, ChannelId, WantReply, Command, State);
handle_ssh_msg({ssh_cm, _CM, {data, _ChannelId, 0, Data}}, #state{port = Port} = State) when
    is_port(Port)
->
    true = port_command(Port, Data),
    {ok, State};
handle_ssh_msg({ssh_cm, _CM, {data, _ChannelId, 1, _Data}}, State) ->
    %% Ignore client stderr data.
    {ok, State};
handle_ssh_msg({ssh_cm, _CM, {eof, _ChannelId}}, State) ->
    %% Git smart protocol sends its own flush packet. Keep the helper alive so it
    %% can finish and return output; the port exit_status closes the SSH channel.
    {ok, State};
handle_ssh_msg({ssh_cm, CM, {shell, ChannelId, WantReply}}, State) ->
    _ = ssh_connection:reply_request(CM, WantReply, failure, ChannelId),
    _ = ssh_connection:send(CM, ChannelId, 1, <<"shell disabled; Git commands only\n">>),
    _ = ssh_connection:exit_status(CM, ChannelId, 1),
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, CM, {pty, ChannelId, WantReply, _Pty}}, State) ->
    _ = ssh_connection:reply_request(CM, WantReply, failure, ChannelId),
    {ok, State};
handle_ssh_msg({ssh_cm, CM, {env, ChannelId, WantReply, _Var, _Value}}, State) ->
    %% Allow harmless env requests from Git clients.
    _ = ssh_connection:reply_request(CM, WantReply, success, ChannelId),
    {ok, State};
handle_ssh_msg(
    {ssh_cm, _CM, {window_change, _ChannelId, _Width, _Height, _PixWidth, _PixHeight}}, State
) ->
    {ok, State};
handle_ssh_msg({ssh_cm, _CM, {signal, _ChannelId, _SignalName}}, State) ->
    {ok, State};
handle_ssh_msg({ssh_cm, _CM, {exit_signal, ChannelId, _Signal, _Error, _Lang}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, _CM, {exit_status, ChannelId, _Status}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg({ssh_cm, _CM, {closed, ChannelId}}, State) ->
    {stop, ChannelId, State};
handle_ssh_msg(_Msg, State) ->
    {ok, State}.

terminate(_Reason, #state{timer_ref = TimerRef}) ->
    cancel_timer(TimerRef),
    ok.

%% Accept only: git-upload-pack 'repo.git' | git-receive-pack 'repo.git'
parse_git_cmd(Command0) ->
    Command =
        case Command0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L
        end,
    %% Preserve quoted repo path.
    case
        re:run(Command, "^(git-(upload|receive)-pack)\\s+'([^']+)'\\s*$", [
            {capture, all_but_first, list}
        ])
    of
        {match, ["git-upload-pack", _, Repo]} -> {upload_pack, Repo};
        {match, ["git-receive-pack", _, Repo]} -> {receive_pack, Repo};
        nomatch -> unknown
    end.

start_git_exec(CM, ChannelId, WantReply, Command, State) ->
    case parse_git_cmd(Command) of
        {upload_pack, Repo} ->
            start_git_helper(
                CM, ChannelId, WantReply, "/usr/bin/git-upload-pack", Repo, upload_pack, State
            );
        {receive_pack, Repo} ->
            case damage_ssh_git_listener:authorize_push(Repo, CM) of
                ok ->
                    start_git_helper(
                        CM,
                        ChannelId,
                        WantReply,
                        "/usr/bin/git-receive-pack",
                        Repo,
                        receive_pack,
                        State
                    );
                {error, Error} ->
                    fail_exec(
                        CM,
                        ChannelId,
                        WantReply,
                        1,
                        io_lib:format("unauthorized: ~p~n", [Error]),
                        State
                    )
            end;
        unknown ->
            fail_exec(CM, ChannelId, WantReply, 1, <<"forbidden\n">>, State)
    end.

start_git_helper(CM, ChannelId, WantReply, Cmd, Repo, CommandTag, State) ->
    case damage_ssh_git_listener:check_repo_path(Repo) of
        {ok, AbsRepo} ->
            _ = ssh_connection:reply_request(CM, WantReply, success, ChannelId),
            Port = open_port({spawn_executable, Cmd}, [
                binary,
                use_stdio,
                stream,
                exit_status,
                {args, [AbsRepo]}
            ]),
            {ok, TimeoutMs} = damage_ssh_git_listener:app_env(git_exec_timeout_ms, 600000),
            TimerRef = erlang:send_after(TimeoutMs, self(), git_timeout),
            {ok, State#state{
                cm = CM,
                channel_id = ChannelId,
                port = Port,
                command = CommandTag,
                repo = AbsRepo,
                timer_ref = TimerRef
            }};
        {error, Reason} ->
            fail_exec(
                CM,
                ChannelId,
                WantReply,
                1,
                io_lib:format("bad repo: ~p~n", [Reason]),
                State
            )
    end.

fail_exec(CM, ChannelId, WantReply, Code, Msg, State) ->
    _ = ssh_connection:reply_request(CM, WantReply, failure, ChannelId),
    _ = ssh_connection:send(CM, ChannelId, 1, Msg),
    _ = ssh_connection:exit_status(CM, ChannelId, Code),
    {stop, ChannelId, State}.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.
