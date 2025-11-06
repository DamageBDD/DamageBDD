%% damage_ssh_listener.erl
%% OTP-managed SSH listener that only serves Git smart-SSH
%% Commands allowed:
%%   git-upload-pack  '<repo>.git'
%%   git-receive-pack '<repo>.git'
%% https://chatgpt.com/c/68ae6f76-ca60-8322-a0ac-71b2f19ce3d0

-module(git_ssh_listener).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    daemon_pid,
    %% binary() path, e.g. <<"/srv/git">>
    repos_root,
    %% #{<<"secure.git">> => [<<"ak_xxx">>, ...]}
    allow_push = #{}
}).

%%% ---------- Public

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent, type => worker}.

%%% ---------- gen_server

init([]) ->
    %% App env (provide sane defaults)
    {ok, ListenAddr} = app_env(listen_addr, {127, 0, 0, 1}),
    {ok, Port} = app_env(port, 2222),
    {ok, SystemDir} = app_env(system_dir, "/var/lib/damage/ssh/system"),
    {ok, UserDir} = app_env(user_dir, "/var/lib/damage/ssh/user"),
    {ok, Repos} = app_env(repos_root, "/var/lib/damage/git"),
    {ok, AllowPush} = app_env(allow_push, false),

    ensure_dirs([SystemDir, UserDir, Repos]),

    Opts = [
        {system_dir, SystemDir},
        {user_dir, UserDir},
        {auth_methods, "publickey"},
        {shell, disabled},
        {subsystems, []},
        {exec, {direct, fun exec/3}},
        {connectfun, fun connect_fun/3},
        {failfun, fun fail_fun/3},
        {parallel_login, true},
        {idle_time, 600000},
        {id_string, "DamageSSH"}
    ],

    {ok, DaemonPid} = ssh:daemon(ListenAddr, Port, Opts),
    ?LOG_INFO("Damage SSH daemon listening on ~p:~p (repos ~s)", [ListenAddr, Port, Repos]),
    {ok, #state{daemon_pid = DaemonPid, repos_root = list_to_binary(Repos), allow_push = AllowPush}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Vsn, State, _Extra) -> {ok, State}.

%%% ---------- SSH callbacks (via {exec, {direct, Fun}})

connect_fun(User, Peer, Method) ->
    ?LOG_INFO("SSH connected user=~p from=~p via=~p", [User, Peer, Method]),
    ok.

fail_fun(User, Peer, Reason) ->
    ?LOG_WARNING("SSH auth failed user=~p from=~p reason=~p", [User, Peer, Reason]),
    ok.

%% exec/3 is called for "exec" channel requests
%% Args: (ConnectionRef, ChannelId, Command)
exec(CM, Ch, Command) ->
    %% Parse allowed commands
    case parse_git_cmd(Command) of
        {upload_pack, Repo} ->
            run_git(CM, Ch, "/usr/bin/git-upload-pack", Repo);
        {receive_pack, Repo} ->
            case authorize_push(Repo, CM) of
                ok ->
                    run_git(CM, Ch, "/usr/bin/git-receive-pack", Repo);
                {error, E} ->
                    ssh_connection:reply_request(CM, Ch, false),
                    ssh_connection:send(CM, Ch, io_lib:format("unauthorized: ~p~n", [E])),
                    ssh_connection:exit_status(CM, Ch, 1),
                    ssh_connection:close(CM, Ch)
            end;
        _ ->
            ssh_connection:reply_request(CM, Ch, false),
            ssh_connection:send(CM, Ch, <<"forbidden\n">>),
            ssh_connection:exit_status(CM, Ch, 1),
            ssh_connection:close(CM, Ch)
    end.

%%% ---------- Helpers

app_env(Key, Default) ->
    case application:get_env(damage, ssh) of
        {ok, SSHConfig} ->
            {ok, proplists:get_value(Key, SSHConfig, Default)};
        undefined ->
            {ok, Default}
    end.

ensure_dirs(Dirs) ->
    lists:foreach(fun ensure_dir/1, Dirs).

ensure_dir(D) ->
    %% ensure_dir expects a *file* path; we append "x" to create the directory tree for D
    case filelib:ensure_dir(filename:join(D, "x")) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(
                "Cannot create directory ~s (~p). Set damage system_dir/user_dir/repos_root to writable paths or pre-create them.",
                [D, Reason]
            ),
            %% don't crash; let ssh:daemon fail visibly if paths are still unusable
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
        {match, ["git-upload-pack", _, "" = Repo]} -> {upload_pack, Repo};
        {match, ["git-receive-pack", _, "" = Repo]} -> {receive_pack, Repo};
        {match, ["git-upload-pack", _, Repo]} -> {upload_pack, Repo};
        {match, ["git-receive-pack", _, Repo]} -> {receive_pack, Repo};
        nomatch -> unknown
    end.

%% Only allow pushes for repos and accounts you approve.
%% Here we demonstrate a trivial allowlist.
authorize_push(Repo, _CM) ->
    %% OPTIONAL: derive pusher identity from key fingerprint
    %% {ok, PubKey} = ssh:connection_info(CM, public_key),
    %% Fingerprint = ssh_file:fingerprint(PubKey),
    %% Map fingerprint -> Ae address; then check balance via damage_ae:balance/1 and spend after success.
    case whereis(?MODULE) of
        P when is_pid(P) ->
            State = sys:get_state(P),
            %% "<name>.git"
            RepoBase = filename:basename(Repo),
            case maps:get(list_to_binary(RepoBase), State#state.allow_push, all) of
                all ->
                    ok;
                List when is_list(List) ->
                    %% TODO: look up actual caller address; for now, deny unless explicitly allowed list has <<"*">>
                    case lists:member(<<"*">>, List) of
                        true -> ok;
                        false -> {error, not_allowed}
                    end
            end;
        _ ->
            ok
    end.

run_git(CM, Ch, Cmd, Repo) ->
    case check_repo_path(Repo) of
        {ok, AbsRepo} ->
            ssh_connection:reply_request(CM, Ch, true),
            Port = open_port({spawn_executable, Cmd}, [
                use_stdio, exit_status, binary, {args, [AbsRepo]}
            ]),
            pump(CM, Ch, Port);
        {error, R} ->
            ssh_connection:reply_request(CM, Ch, false),
            ssh_connection:send(CM, Ch, io_lib:format("bad repo: ~p~n", [R])),
            ssh_connection:exit_status(CM, Ch, 1),
            ssh_connection:close(CM, Ch)
    end.

check_repo_path(RelRepo) ->
    %% Harden against path traversal and require .git suffix
    case (filename:basename(RelRepo) =:= RelRepo) andalso lists:suffix(".git", RelRepo) of
        true ->
            {ok, State} = sys:get_state(?MODULE),
            Root = State#state.repos_root,
            Abs = filename:join(Root, list_to_binary(RelRepo)),
            case filelib:is_dir(Abs) of
                true -> {ok, Abs};
                false -> {error, enoent}
            end;
        false ->
            {error, invalid}
    end.

pump(CM, Ch, Port) ->
    %% Forward stdout/stderr from git-*pack and EOF/exit back to SSH channel.
    receive
        {Port, {data, Bin}} ->
            ssh_connection:send(CM, Ch, Bin),
            pump(CM, Ch, Port);
        {Port, {exit_status, Code}} ->
            ssh_connection:exit_status(CM, Ch, Code),
            ssh_connection:close(CM, Ch),
            ok
    after 600000 ->
        port_close(Port),
        ssh_connection:exit_status(CM, Ch, 124),
        ssh_connection:close(CM, Ch),
        ok
    end.
