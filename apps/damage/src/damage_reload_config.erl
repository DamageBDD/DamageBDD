%% Node-local, operator-controlled development configuration. No maps in sys.config.
-module(damage_reload_config).
-export([read/0, normalize/2, path/1, within/2, excluded/0]).
-include_lib("kernel/include/file.hrl").

read() ->
    normalize(
        application:get_env(damage, code_reload, []),
        persistent_term:get({damage_reload, shell_root}, undefined)
    ).

normalize(Options, ShellRoot) ->
    try
        true = is_list(Options),
        true = lists:all(
            fun
                ({K, _}) -> is_atom(K);
                (_) -> false
            end,
            Options
        ),
        Known = [
            enabled,
            mode,
            root,
            apps,
            source_dirs,
            include_dirs,
            modules,
            erl_opts,
            reuse_compile_opts,
            profile,
            rebar3,
            build_dir,
            debounce_ms,
            retry_ms,
            rescan_ms,
            build_timeout_ms,
            load_on_start,
            exclude_modules
        ],
        [] = [K || {K, _} <- Options, not lists:member(K, Known)],
        Keys = [K || {K, _} <- Options],
        true = length(Keys) =:= length(lists:usort(Keys)),
        Enabled = proplists:get_value(enabled, Options, dev),
        case Enabled of
            false -> disabled;
            dev when ShellRoot =:= undefined -> disabled;
            dev -> {ok, config(Options, ShellRoot)};
            true -> {ok, config(Options, ShellRoot)};
            _ -> error({invalid_enabled, Enabled})
        end
    catch
        Class:Reason -> {error, {invalid_code_reload_config, Class, Reason}}
    end.

config(O, ShellRoot) ->
    Mode = proplists:get_value(
        mode,
        O,
        case ShellRoot of
            undefined -> sources;
            _ -> rebar
        end
    ),
    Base = #{
        mode => Mode,
        debounce_ms => positive(debounce_ms, O, 300),
        retry_ms => positive(retry_ms, O, 1000),
        rescan_ms => positive(rescan_ms, O, 5000),
        build_timeout_ms => positive(build_timeout_ms, O, 300000),
        load_on_start => boolean(load_on_start, O, false),
        exclude_modules => lists:usort(excluded() ++ atoms(exclude_modules, O, []))
    },
    Cfg =
        case Mode of
            rebar -> rebar_config(O, ShellRoot, Base);
            sources -> source_config(O, Base);
            _ -> error({invalid_mode, Mode})
        end,
    Dirs = lists:usort(maps:get(source_dirs, Cfg) ++ maps:get(include_dirs, Cfg)),
    true = Dirs =/= [],
    true = length(Dirs) =< 32,
    %% fs backend commands use shell quoting internally. Reject shell-sensitive
    %% watch-root names; individual file names are never interpolated in commands.
    lists:foreach(fun watch_path/1, Dirs),
    Cfg#{watch_dirs => Dirs}.

rebar_config(O, ShellRoot, Base) ->
    Root = directory(proplists:get_value(root, O, ShellRoot)),
    true = filelib:is_regular(filename:join(Root, "rebar.config")),
    DefaultApps = [
        A
     || A <- [damage, nosternity, erm, ecai, vanillae, bop],
        filelib:is_dir(filename:join([Root, "apps", atom_to_list(A)]))
    ],
    Apps = atoms(apps, O, DefaultApps),
    true = Apps =/= [],
    AppDirs = [
        {A, directory(filename:join([Root, "apps", atom_to_list(A)]))}
     || A <- Apps
    ],
    Src = [directory(filename:join(D, "src")) || {_, D} <- AppDirs],
    Inc = lists:usort(
        [
            P
         || {_, D} <- AppDirs,
            P <- [filename:join(D, "include")],
            filelib:is_dir(P)
        ] ++
            [directory(P) || P <- proplists:get_value(include_dirs, O, [])] ++
            [P || P <- [filename:join(Root, "include")], filelib:is_dir(P)]
    ),
    Profile = proplists:get_value(profile, O, "default"),
    true = is_list(Profile),
    match = re:run(Profile, "^[a-zA-Z0-9_-]+$", [{capture, none}]),
    Build0 = proplists:get_value(
        build_dir,
        O,
        filename:join([Root, "_build", "damage_reload"])
    ),
    %% Resolve even a not-yet-created output directory without writing during
    %% validation. Refuse output overlapping any live ebin directory.
    Build = path(Build0),
    true = within(Build, Root),
    true = Build =/= Root,
    false = lists:any(fun(D) -> within(D, Build) orelse within(Build, D) end, Src ++ Inc),
    %% Code paths are not recursive. An ancestor such as "." is harmless;
    %% a live ebin inside staging is not. Skip virtual escript/archive paths.
    LiveDirs = [path(filename:absname(P)) || P <- code:get_path(), filelib:is_dir(P)],
    false = lists:any(fun(D) -> within(D, Build) end, LiveDirs),
    Base#{
        root => Root,
        apps => Apps,
        source_dirs => Src,
        include_dirs => Inc,
        profile => Profile,
        build_dir => Build,
        rebar3 => proplists:get_value(rebar3, O, "rebar3")
    }.

source_config(O, Base) ->
    Src = [directory(P) || P <- proplists:get_value(source_dirs, O, [])],
    true = Src =/= [],
    Mods = atoms(modules, O, []),
    %% Explicit atoms, not a prefix or wildcard, authorize new names and overrides.
    true = Mods =/= [],
    [] = [M || M <- Mods, lists:member(M, maps:get(exclude_modules, Base))],
    Opts = proplists:get_value(erl_opts, O, [debug_info]),
    true = is_list(Opts),
    Base#{
        source_dirs => Src,
        include_dirs => [directory(P) || P <- proplists:get_value(include_dirs, O, [])],
        modules => Mods,
        erl_opts => Opts,
        reuse_compile_opts => boolean(reuse_compile_opts, O, true)
    }.

excluded() ->
    [
        damage_reload,
        damage_reload_build,
        damage_reload_config,
        damage_app,
        damage_sup,
        damage_build_info
    ].

positive(Key, O, Default) ->
    N = proplists:get_value(Key, O, Default),
    true = is_integer(N) andalso N > 0 andalso N =< 16#ffffffff,
    N.

boolean(Key, O, Default) ->
    V = proplists:get_value(Key, O, Default),
    true = is_boolean(V),
    V.

atoms(Key, O, Default) ->
    L = proplists:get_value(Key, O, Default),
    true = is_list(L),
    true = lists:all(fun erlang:is_atom/1, L),
    lists:usort(L).

directory(P) ->
    Abs = path(P),
    true = filelib:is_dir(Abs),
    Abs.

path({app, App, Subdir}) when is_atom(App), (Subdir =:= src orelse Subdir =:= include) ->
    case code:lib_dir(App) of
        {error, Reason} -> error({application_path, App, Reason});
        Dir -> path(filename:join(Dir, atom_to_list(Subdir)))
    end;
path(P) when is_binary(P) -> path(unicode:characters_to_list(P));
path(P) when is_list(P), P =/= [] ->
    case filename:pathtype(P) of
        absolute -> resolve(filename:split(P), [], 40);
        _ -> error({absolute_path_required, P})
    end;
path(P) ->
    error({absolute_path_required, P}).

%% OTP has no portable filelib:realpath/1 API to rely on. Resolve components,
%% including symlinks followed by '..', and bound symlink traversal explicitly.
resolve([], Acc, _) ->
    filename:join(Acc);
resolve(["." | Rest], Acc, N) ->
    resolve(Rest, Acc, N);
resolve([".." | Rest], Acc, N) ->
    Parent =
        case Acc of
            [_] -> Acc;
            _ -> lists:droplast(Acc)
        end,
    resolve(Rest, Parent, N);
resolve([Part | Rest], Acc, N) ->
    Next = filename:join(Acc ++ [Part]),
    case file:read_link_info(Next) of
        {ok, #file_info{type = symlink}} when N > 0 ->
            {ok, Target} = file:read_link(Next),
            Parts =
                case filename:pathtype(Target) of
                    absolute -> filename:split(Target);
                    _ -> Acc ++ filename:split(Target)
                end,
            resolve(Parts ++ Rest, [], N - 1);
        {ok, #file_info{type = symlink}} ->
            error({symlink_loop, Next});
        {ok, _} ->
            resolve(Rest, Acc ++ [Part], N);
        {error, enoent} ->
            resolve(Rest, Acc ++ [Part], N);
        {error, Why} ->
            error({path_error, Next, Why})
    end.

within(Path, Dir) ->
    lists:prefix(filename:split(Dir), filename:split(Path)).

watch_path(P) ->
    %% Whitelist instead of attempting to mirror fs's platform-specific quoting.
    match = re:run(P, "^[a-zA-Z0-9_./ :@+,-]+$", [{capture, none}]),
    ok.
