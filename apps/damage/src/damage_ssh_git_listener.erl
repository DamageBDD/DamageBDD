%% damage_ssh_git_listener.erl
%% OTP-managed SSH listener that only serves Git smart-SSH
%% Commands allowed:
%%   git-upload-pack  '<repo>.git'
%%   git-receive-pack '<repo>.git'

-module(damage_ssh_git_listener).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(gen_server).
-behaviour(ssh_server_channel).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([handle_msg/2, handle_ssh_msg/2]).

-record(state, {
    daemon_pid,
    %% string() path, e.g. "/srv/git"
    repos_root,
    %% #{<<"secure.git">> => [<<"ak_xxx">>, ...] | <<"*">> | all}
    allow_push = #{}
}).

-record(git_channel_state, {
    cm = undefined,
    channel_id = undefined,
    port = undefined,
    command = undefined,
    repo = undefined,
    timer_ref = undefined
}).

%%% ---------- Public

start_link() ->
    case app_env(enabled, true) of
        {ok, false} ->
            ?LOG_INFO("damage_ssh_git_listener disabled by config", []),
            ignore;
        _ ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [], [])
    end.

child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent, type => worker}.

%%% ---------- gen_server

init([]) ->
    %% App env (provide sane defaults)
    {ok, ListenAddr} = app_env(listen_addr, {127, 0, 0, 1}),
    {ok, Port} = app_env(port, 2222),
    {ok, SystemDir0} = app_env(system_dir, "/var/lib/damage/ssh/git/system"),
    {ok, UserDir0} = app_env(user_dir, "/var/lib/damage/ssh/git/user"),
    {ok, Repos0} = app_env(repos_root, "/var/lib/damage/git"),
    {ok, AllowPush} = app_env(allow_push, #{}),

    SystemDir = normalize_path(SystemDir0),
    UserDir = normalize_path(UserDir0),
    Repos = normalize_path(Repos0),
    ensure_dirs([SystemDir, UserDir, Repos]),
    ensure_host_key_hint(SystemDir),

    Opts = [
        {system_dir, SystemDir},
        {user_dir, UserDir},
        {auth_methods, "publickey"},
        {shell, disabled},
        {subsystems, []},
        %% Git smart-SSH needs a live channel so stdin from the SSH client can be
        %% forwarded into git-upload-pack/git-receive-pack and stdout can be
        %% streamed back. Do not use {exec,{direct,Fun}} here: that callback
        %% only receives the command/user/client info and cannot pump channel IO.
        {ssh_cli, {?MODULE, [git_cli]}},
        {connectfun, fun connect_fun/3},
        {failfun, fun fail_fun/3},
        {parallel_login, true},
        {idle_time, 600000},
        {id_string, "DamageGitSSH"},
        {tcpip_tunnel_in, false},
        {tcpip_tunnel_out, false}
    ],

    case ssh:daemon(ListenAddr, Port, Opts) of
        {ok, DaemonPid} ->
            ?LOG_INFO("Damage Git SSH daemon listening on ~p:~p repos=~s", [ListenAddr, Port, Repos]),
            {ok, #state{
                daemon_pid = DaemonPid,
                repos_root = Repos,
                allow_push = AllowPush
            }};
        {error, eaddrinuse} ->
            ?LOG_ERROR("Git SSH listener port already in use at ~p:~p", [ListenAddr, Port]),
            {stop, {ssh_port_in_use, ListenAddr, Port}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to start Git SSH daemon on ~p:~p reason=~p", [ListenAddr, Port, Reason]),
            {stop, {ssh_daemon_start_failed, Reason}}
    end;

%% ssh_server_channel callback for {ssh_cli, {?MODULE, [git_cli]}}
init([git_cli]) ->
    {ok, #git_channel_state{}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Vsn, State, _Extra) -> {ok, State}.

%%% ---------- SSH callbacks

connect_fun(User, Peer, Method) ->
    ?LOG_INFO("Git SSH connected user=~p from=~p via=~p", [User, Peer, Method]),
    ok.

fail_fun(User, Peer, Reason) ->
    ?LOG_WARNING("Git SSH auth failed user=~p from=~p reason=~p", [User, Peer, Reason]),
    ok.

handle_msg({ssh_channel_up, ChannelId, CM}, State) ->
    {ok, State#git_channel_state{cm = CM, channel_id = ChannelId}};
handle_msg({Port, {data, Bin}}, #git_channel_state{cm = CM, channel_id = ChannelId, port = Port} = State) ->
    _ = ssh_connection:send(CM, ChannelId, 0, Bin),
    {ok, State};
handle_msg({Port, {exit_status, Code}}, #git_channel_state{cm = CM, channel_id = ChannelId, port = Port} = State) ->
    cancel_timer(State#git_channel_state.timer_ref),
    _ = ssh_connection:send_eof(CM, ChannelId),
    _ = ssh_connection:exit_status(CM, ChannelId, Code),
    {stop, ChannelId, State#git_channel_state{port = undefined, timer_ref = undefined}};
handle_msg({'EXIT', Port, Reason}, #git_channel_state{cm = CM, channel_id = ChannelId, port = Port} = State) ->
    cancel_timer(State#git_channel_state.timer_ref),
    ?LOG_WARNING("Git helper port exited reason=~p", [Reason]),
    _ = ssh_connection:send(CM, ChannelId, 1, io_lib:format("git helper exited: ~p~n", [Reason])),
    _ = ssh_connection:exit_status(CM, ChannelId, 1),
    {stop, ChannelId, State#git_channel_state{port = undefined, timer_ref = undefined}};
handle_msg(git_timeout, #git_channel_state{port = Port, cm = CM, channel_id = ChannelId} = State) when is_port(Port) ->
    port_close(Port),
    _ = ssh_connection:send(CM, ChannelId, 1, <<"git helper timed out\n">>),
    _ = ssh_connection:exit_status(CM, ChannelId, 124),
    {stop, ChannelId, State#git_channel_state{port = undefined, timer_ref = undefined}};
handle_msg(_Msg, State) ->
    {ok, State}.

handle_ssh_msg({ssh_cm, CM, {exec, ChannelId, WantReply, Command}}, State) ->
    start_git_exec(CM, ChannelId, WantReply, Command, State);
handle_ssh_msg({ssh_cm, _CM, {data, _ChannelId, 0, Data}}, #git_channel_state{port = Port} = State)
    when is_port(Port) ->
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
handle_ssh_msg({ssh_cm, _CM, {window_change, _ChannelId, _Width, _Height, _PixWidth, _PixHeight}}, State) ->
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

%%% ---------- Helpers

app_env(Key, Default) ->
    case application:get_env(damage, ssh_git) of
        {ok, SSHConfig} when is_list(SSHConfig) ->
            {ok, proplists:get_value(Key, SSHConfig, Default)};
        _ ->
            {ok, Default}
    end.

ensure_dirs(Dirs) ->
    lists:foreach(fun ensure_dir/1, Dirs).

normalize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
normalize_path(Path) when is_list(Path) ->
    Path.

ensure_dir(D0) ->
    D = normalize_path(D0),
    %% ensure_dir expects a *file* path; we append "x" to create the directory tree for D
    case filelib:ensure_dir(filename:join(D, "x")) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(
                "Cannot create directory ~s (~p). Set damage ssh_git system_dir/user_dir/repos_root to writable paths or pre-create them.",
                [D, Reason]
            ),
            ok
    end.

host_key_files(SystemDir) ->
    [
        filename:join(SystemDir, "ssh_host_ed25519_key"),
        filename:join(SystemDir, "ssh_host_rsa_key"),
        filename:join(SystemDir, "ssh_host_ecdsa_key"),
        filename:join(SystemDir, "ssh_host_dsa_key")
    ].

ensure_host_key_hint(SystemDir) ->
    case lists:any(fun filelib:is_regular/1, host_key_files(SystemDir)) of
        true ->
            ok;
        false ->
            ?LOG_WARNING(
                "No Git SSH host key found in ~s. Generate one before enabling damage_ssh_git_listener, for example: ssh-keygen -t ed25519 -N '' -f ~s",
                [SystemDir, filename:join(SystemDir, "ssh_host_ed25519_key")]
            ),
            ok
    end.

%% Accept only: git-upload-pack 'repo.git' | git-receive-pack 'repo.git'
parse_git_cmd(Command0) ->
    Command =
        case Command0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L
        end,
    %% Preserve quoted repo path:
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
            start_git_helper(CM, ChannelId, WantReply, "/usr/bin/git-upload-pack", Repo, upload_pack, State);
        {receive_pack, Repo} ->
            case authorize_push(Repo, CM) of
                ok ->
                    start_git_helper(CM, ChannelId, WantReply, "/usr/bin/git-receive-pack", Repo, receive_pack, State);
                {error, E} ->
                    fail_exec(CM, ChannelId, WantReply, 1, io_lib:format("unauthorized: ~p~n", [E]), State)
            end;
        unknown ->
            fail_exec(CM, ChannelId, WantReply, 1, <<"forbidden\n">>, State)
    end.

start_git_helper(CM, ChannelId, WantReply, Cmd, Repo, CommandTag, State) ->
    case check_repo_path(Repo) of
        {ok, AbsRepo} ->
            _ = ssh_connection:reply_request(CM, WantReply, success, ChannelId),
            Port = open_port({spawn_executable, Cmd}, [
                binary,
                use_stdio,
                stream,
                exit_status,
                {args, [AbsRepo]}
            ]),
            {ok, TimeoutMs} = app_env(git_exec_timeout_ms, 600000),
            TimerRef = erlang:send_after(TimeoutMs, self(), git_timeout),
            {ok, State#git_channel_state{
                cm = CM,
                channel_id = ChannelId,
                port = Port,
                command = CommandTag,
                repo = AbsRepo,
                timer_ref = TimerRef
            }};
        {error, R} ->
            fail_exec(CM, ChannelId, WantReply, 1, io_lib:format("bad repo: ~p~n", [R]), State)
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

%% Only allow pushes for repos and accounts you approve.
authorize_push(Repo, _CM) ->
    case whereis(?MODULE) of
        P when is_pid(P) ->
            State = sys:get_state(P),
            RepoBase = list_to_binary(filename:basename(strip_leading_slashes(Repo))),
            case maps:get(RepoBase, State#state.allow_push, deny) of
                all ->
                    ok;
                <<"*">> ->
                    ok;
                deny ->
                    {error, not_allowed};
                List when is_list(List) ->
                    case lists:member(<<"*">>, List) of
                        true -> ok;
                        false -> {error, not_allowed}
                    end;
                _ ->
                    {error, not_allowed}
            end;
        _ ->
            {error, listener_not_ready}
    end.

strip_leading_slashes([$/ | Rest]) ->
    strip_leading_slashes(Rest);
strip_leading_slashes(Path) ->
    Path.

check_repo_path(Repo0) ->
    %% Harden against path traversal and require .git suffix. Git clients using
    %% ssh://host/repo.git often send '/repo.git'; treat that as 'repo.git'.
    RelRepo = strip_leading_slashes(Repo0),
    case (filename:basename(RelRepo) =:= RelRepo) andalso lists:suffix(".git", RelRepo) of
        true ->
            State = sys:get_state(?MODULE),
            Root = State#state.repos_root,
            Abs = filename:join(Root, RelRepo),
            case filelib:is_dir(Abs) of
                true -> {ok, Abs};
                false -> {error, enoent}
            end;
        false ->
            {error, invalid}
    end.
