%%%-------------------------------------------------------------------
%%% tmux_py.erl
%%%
%%% Erlang replacement for tmux.py built on tmux_control.
%%%-------------------------------------------------------------------
-module(tmux_py).

-export([
    start/2,
    start/3,
    kill/2,
    list/1,
    attach/2,
    default_opts/0
]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_WINDOWS_CONFIG, "~/.tmux/configs/default.yml").
-define(DEFAULT_TMUX_BIN, "/usr/bin/tmux").
-define(DEFAULT_TMPDIR, "/tmp").
-define(DEFAULT_INNER_CONF, "~/.tmux/inner.conf").

default_opts() ->
    #{
        detached => false,
        remote => false,
        windows_config => ?DEFAULT_WINDOWS_CONFIG,
        tmux_path => ?DEFAULT_TMUX_BIN,
        tmpdir => ?DEFAULT_TMPDIR
    }.

start(Server, Session) ->
    start(Server, Session, #{}).

start(Server0, Session0, Opts0) ->
    Opts = maps:merge(default_opts(), normalize_opts(Opts0)),
    Server = to_list(Server0),
    Session = to_list(Session0),

    WindowsConfig = get_config(maps:get(windows_config, Opts)),
    TmuxConfig = get_config(Server ++ ".conf"),
    Socket = filename:join(maps:get(tmpdir, Opts), "tmux_" ++ Server ++ "_socket"),

    {ok, Ctl} = tmux_control:start_link(#{
        tmux_path => maps:get(tmux_path, Opts),
        socket_path => Socket,
        config_file => TmuxConfig
    }),

    try
        HostConfig = load_host_config(WindowsConfig),
        SessionConfig = session_config(Session, HostConfig),
        ok = ensure_session(Ctl, Session, SessionConfig),
        ok = build_windows(Ctl, Session, pad_windows(Session, SessionConfig)),
        ok = setup_session(Ctl, Session, HostConfig, maps:get(remote, Opts)),

        case maps:get(detached, Opts) of
            true ->
                {ok, Ctl};
            false ->
                tmux_control:cmd(Ctl, ["detach-client -s ", shell(Session)], 5000),
                attach(Server, Session, Opts)
        end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("tmux_py start failed ~p:~p ~p", [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

kill(Server, Session) ->
    kill(Server, Session, #{}).

kill(Server0, Session0, Opts0) ->
    Opts = maps:merge(default_opts(), normalize_opts(Opts0)),
    Server = to_list(Server0),
    Session = to_list(Session0),
    TmuxConfig = get_config(Server ++ ".conf"),
    Socket = filename:join(maps:get(tmpdir, Opts), "tmux_" ++ Server ++ "_socket"),
    {ok, Ctl} = tmux_control:start_link(#{
        tmux_path => maps:get(tmux_path, Opts),
        socket_path => Socket,
        config_file => TmuxConfig
    }),
    tmux_control:kill_session(Ctl, Session).

list(Server) ->
    list(Server, #{}).

list(Server0, Opts0) ->
    Opts = maps:merge(default_opts(), normalize_opts(Opts0)),
    Server = to_list(Server0),
    TmuxConfig = get_config(Server ++ ".conf"),
    Socket = filename:join(maps:get(tmpdir, Opts), "tmux_" ++ Server ++ "_socket"),
    {ok, Ctl} = tmux_control:start_link(#{
        tmux_path => maps:get(tmux_path, Opts),
        socket_path => Socket,
        config_file => TmuxConfig
    }),
    tmux_control:list_sessions(Ctl).

attach(Server, Session) ->
    attach(Server, Session, #{}).

attach(Server0, Session0, Opts0) ->
    Opts = maps:merge(default_opts(), normalize_opts(Opts0)),
    Server = to_list(Server0),
    Session = to_list(Session0),
    TmuxConfig = get_config(Server ++ ".conf"),
    Socket = filename:join(maps:get(tmpdir, Opts), "tmux_" ++ Server ++ "_socket"),
    Tmux = maps:get(tmux_path, Opts),

    %% tmux attach must replace the foreground process like Python os.execvpe.
    Args = [
        "-f",
        TmuxConfig,
        "-S",
        Socket,
        "attach-session",
        "-t",
        Session
    ],
    os:cmd(string:join([Tmux | lists:map(fun shell/1, Args)], " ")).

ensure_session(Ctl, Session, SConf) ->
    StartDir = maps:get(start_directory, SConf, "~/"),
    case tmux_control:new_session(Ctl, Session, expand(StartDir)) of
        {ok, _} ->
            ok;
        {error, _, _} ->
            %% Already exists is fine; tmux.py also tolerates it.
            ok
    end.

build_windows(Ctl, Session, Windows) ->
    lists:foreach(
        fun(W) ->
            Name = maps:get(window_name, W, Session),
            StartDir = maps:get(start_directory, W, "~/"),
            Cmd = first_pane_cmd(W),
            tmux_control:cmd(
                Ctl,
                [
                    "new-window -t ",
                    shell(Session),
                    " -n ",
                    shell(Name),
                    " -c ",
                    shell(expand(StartDir))
                ],
                5000
            ),
            case Cmd of
                undefined ->
                    ok;
                _ ->
                    tmux_control:cmd(
                        Ctl,
                        [
                            "send-keys -t ",
                            shell(Session ++ ":" ++ Name),
                            " ",
                            shell(Cmd),
                            " C-m"
                        ],
                        5000
                    ),
                    ok
            end
        end,
        Windows
    ),
    ok.

setup_session(Ctl, Session, HostConfig, Remote) ->
    {StatusRight, StatusLeft} = status_line(HostConfig, Remote),

    ok_cmd(Ctl, ["set-option -t ", shell(Session), " status-right ", shell(StatusRight)]),
    ok_cmd(Ctl, ["set-option -t ", shell(Session), " status-left ", shell(StatusLeft)]),

    set_env_if_present(Ctl, Session, "SSH_AUTH_SOCK"),
    set_env_if_present(Ctl, Session, "SSH_AGENT_PID"),

    case Remote of
        true ->
            ok;
        false ->
            ok_cmd(Ctl, ["set-environment -t ", shell(Session), " -gu SSH_HOST_STR"]),
            ok_cmd(Ctl, ["set-environment -t ", shell(Session), " -gu SSH_TTY_SET"])
    end,

    ok_cmd(Ctl, ["set-option -t ", shell(Session), " -g automatic-rename on"]),
    ok.

ok_cmd(Ctl, Cmd) ->
    _ = tmux_control:cmd(Ctl, Cmd, 5000),
    ok.

set_env_if_present(Ctl, Session, Name) ->
    case os:getenv(Name) of
        false ->
            ok;
        Value ->
            ok_cmd(Ctl, [
                "set-environment -t ",
                shell(Session),
                " ",
                Name,
                " ",
                shell(Value)
            ])
    end.

load_host_config(File) ->
    {ok, [Yaml]} = yamerl_constr:file(File),
    Map = yaml_to_map(Yaml),
    Windows = maps:get("windows", Map, #{}),
    maps:map(
        fun(Outer, Inners) ->
            gen_session_config(Outer, Inners)
        end,
        Windows
    ).

gen_session_config(Name, ConfigMap) ->
    Windows0 = maps:get("windows", ConfigMap, #{}),
    #{
        session_name => Name,
        windows => [
            gen_window_config(WName, WConf)
         || {WName, WConf} <- maps:to_list(Windows0)
        ],
        options => #{"base-index" => 0},
        start_directory => maps:get("start_directory", ConfigMap, "~/"),
        shell_command => maps:get("shell_command", ConfigMap, undefined)
    }.

gen_window_config(Name, WindowConfig) ->
    #{
        window_name => Name,
        start_directory => maps:get("start_directory", WindowConfig, "~/"),
        panes => [
            #{
                shell_command => [
                    #{
                        cmd => maps:get(
                            "shell_command",
                            WindowConfig,
                            default_inner_cmd(Name)
                        )
                    }
                ]
            }
        ]
    }.

session_config(Session, HostConfig) ->
    maps:get(Session, HostConfig, gen_session_config(Session, #{})).

pad_windows(Session, SConf) ->
    Windows0 = maps:get(windows, SConf, []),
    Need = max(0, 10 - length(Windows0)),
    Windows0 ++
        [
            #{
                window_name => Session,
                start_directory => maps:get(start_directory, SConf, "~/"),
                panes => [
                    #{shell_command => []}
                ]
            }
         || _ <- lists:seq(1, Need)
        ].

first_pane_cmd(W) ->
    case maps:get(panes, W, []) of
        [#{shell_command := [#{cmd := Cmd} | _]} | _] -> Cmd;
        _ -> undefined
    end.

status_line(HostConfig, Remote) ->
    Bg =
        case Remote of
            true -> maps:get("bg", HostConfig, "red");
            false -> "green"
        end,
    Fg =
        case Remote of
            true -> maps:get("fg", HostConfig, "white");
            false -> "black"
        end,
    {
        "#[fg=" ++ Fg ++ ",bg=" ++ Bg ++ ",bold] #h %H:%M:%S",
        "#[fg=" ++ Fg ++ ",bg=" ++ Bg ++ ",bold] #S #[fg=colour238,bg=colour234,nobold]"
    }.

default_inner_cmd(Name) ->
    "tmux_py inner -w ~/.tmux/configs/default.yml " ++ Name.

get_config(Conf0) ->
    Conf = expand(Conf0),
    Base = filename:basename(Conf),
    Candidates = [
        Conf,
        expand("~/.tmux/" ++ Base),
        expand("~/.tmuxpy/" ++ Base),
        expand("~/.local/etc/tmuxpy/" ++ Base),
        "/usr/local/etc/tmuxpy/" ++ Base,
        "/etc/tmuxpy/" ++ Base
    ],
    case [C || C <- Candidates, filelib:is_file(C)] of
        [Found | _] ->
            Found;
        [] ->
            error({tmux_config_not_found, Conf, Candidates})
    end.

yaml_to_map(List) when is_list(List) ->
    maps:from_list([{to_list(K), yaml_to_map(V)} || {K, V} <- List]);
yaml_to_map(V) ->
    V.

expand([$~, $/ | Rest]) ->
    filename:join(os:getenv("HOME"), Rest);
expand(Path) when is_binary(Path) ->
    expand(binary_to_list(Path));
expand(Path) ->
    Path.

shell(S) when is_binary(S) ->
    shell(binary_to_list(S));
shell(S) ->
    "'" ++ string:replace(S, "'", "'\"'\"'", all) ++ "'".

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L.

normalize_opts(M) when is_map(M) -> M;
normalize_opts(L) when is_list(L) -> maps:from_list(L).
