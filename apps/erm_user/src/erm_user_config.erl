-module(erm_user_config).
-include_lib("kernel/include/file.hrl").
-export([prepare/0, uid/0, config_home/0, token_file/0, read_token/1,
         trusted_file/2, validate_socket/2, load_user_config/1, private_directory/1, safe_user_path/1]).

prepare() ->
    ok = restore_desktop_home(),
    case [A || {A, _, _} <- application:which_applications(),
               A =:= damage orelse A =:= ecai] of
        [] -> prepare_user();
        _ -> {error, privileged_application_running}
    end.

%% erlexec captures HOME as its single -home boot argument. The launcher
%% temporarily sets it to a fresh private cookie home, then this callback
%% restores the desktop HOME before any user config or native process runs.
restore_desktop_home() ->
    case os:getenv("ERM_USER_DESKTOP_HOME") of
        false -> ok;
        Home ->
            case filename:pathtype(Home) =:= absolute of
                true -> true = os:putenv("HOME", Home), ok;
                false -> error(invalid_desktop_home)
            end
    end.

prepare_user() ->
    case application:load(erm) of
        ok -> ok;
        {error, {already_loaded, erm}} -> ok;
        LoadError -> error({erm_code_unavailable, LoadError})
    end,
    Defaults = [{media_enabled, false}, {tts, [{enabled, false}]},
                {whisper_trigger, [{enabled, false}]}, {lens, [{enabled, false}]},
                {share, [{enabled, false}]}, {gtknode4, [{enabled, false}]}],
    lists:foreach(fun({K, V}) ->
        case application:get_env(erm, K) of
            undefined -> application:set_env(erm, K, V);
            _ -> ok
        end
    end, Defaults),
    Config = case os:getenv("ERM_USER_CONFIG") of
        false -> filename:join([config_home(), "erm", "user.config"]);
        P -> P
    end,
    case load_user_config(Config) of
        ok ->
            %% These are invariant boundaries of the separate entry point.
            application:set_env(erm, http_enabled, false),
            application:set_env(erm, display_manager, [{mode, disabled}]),
            case prepare_paths() of
                ok -> validate_distribution();
                Error -> Error
            end;
        Error -> Error
    end.

load_user_config(Path) ->
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, _} ->
            case trusted_file(Path, config) of
                ok ->
                    case file:consult(Path) of
                        {ok, [Apps]} when is_list(Apps) -> apply_config(Apps);
                        _ -> {error, invalid_user_config}
                    end;
                Error -> Error
            end;
        _ -> {error, user_config_unreadable}
    end.

apply_config(Apps) ->
    case lists:all(fun
        ({App, Values}) when App =:= erm; App =:= erm_user ->
            is_list(Values) andalso lists:all(fun
                ({Key, _}) when is_atom(Key) -> true;
                (_) -> false
            end, Values);
        (_) -> false
    end, Apps) of
        true ->
            lists:foreach(fun({App, Values}) ->
                lists:foreach(fun({K, V}) -> application:set_env(App, K, V) end, Values)
            end, Apps),
            ok;
        false -> {error, forbidden_user_config_application}
    end.

prepare_paths() ->
    State = filename:join(xdg("XDG_STATE_HOME", [".local", "state"]), "erm"),
    Cache = filename:join(xdg("XDG_CACHE_HOME", [".cache"]), "erm"),
    case {private_directory(State), private_directory(Cache)} of
        {ok, ok} ->
            case application:get_env(erm, playlist_state_file) of
                undefined -> application:set_env(erm, playlist_state_file,
                                                filename:join(State, "playlist.term"));
                _ -> ok
            end,
            application:set_env(erm_user, state_dir, State),
            application:set_env(erm_user, cache_dir, Cache),
            ok;
        _ -> {error, unsafe_user_state_directory}
    end.

private_directory(Path) ->
    case filename:pathtype(Path) =:= absolute andalso
         not lists:member("..", filename:split(Path)) of
        true ->
            case safe_create_dirs(filename:split(Path), "") of
                ok ->
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory, uid = Owner}} ->
                            case Owner =:= uid() of
                                true -> file:change_mode(Path, 8#700);
                                false -> {error, wrong_owner}
                            end;
                        _ -> {error, unsafe_directory}
                    end;
                Error -> Error
            end;
        _ -> {error, relative_directory}
    end.

%% Root-owned sticky directories such as /tmp are safe ancestors for an
%% exclusive user-owned child. Ordinary writable directories and symlinks are
%% rejected, avoiding a bearer-file rename/symlink race by another account.
safe_user_path(Path) ->
    case filename:pathtype(Path) =:= absolute andalso
         not lists:member("..", filename:split(Path)) of
        true -> check_user_dirs(filename:split(Path), "");
        false -> {error, unsafe_user_path}
    end.
check_user_dirs([], _) -> ok;
check_user_dirs([P | Rest], Acc) ->
    Path = filename:join(Acc, P),
    case safe_directory_info(Path) of
        ok -> check_user_dirs(Rest, Path);
        Error -> Error
    end.
safe_directory_info(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory, uid = Owner, mode = Mode}} ->
            Trusted = Owner =:= 0 orelse Owner =:= uid(),
            Private = Mode band 8#022 =:= 0,
            Sticky = Owner =:= 0 andalso Mode band 8#1000 =/= 0,
            case Trusted andalso (Private orelse Sticky) of
                true -> ok; false -> {error, unsafe_user_path}
            end;
        _ -> {error, unsafe_user_path}
    end.
safe_create_dirs([], _) -> ok;
safe_create_dirs([P | Rest], Acc) ->
    Path = filename:join(Acc, P),
    case file:read_link_info(Path) of
        {error, enoent} ->
            case file:make_dir(Path) of
                ok -> ok = file:change_mode(Path, 8#700), safe_create_dirs(Rest, Path);
                _ -> {error, unsafe_directory}
            end;
        _ ->
            case safe_directory_info(Path) of
                ok -> safe_create_dirs(Rest, Path);
                Error -> Error
            end
    end.

validate_distribution() ->
    Gtk = application:get_env(erm, gtknode4, []),
    Enabled = option(enabled, Gtk, false),
    Requires = Enabled =:= true andalso option(mode, Gtk, local_cnode) =/= fake,
    Local = application:get_env(erm_user, local_distribution, false),
    case {Requires, Local} of
        {true, false} -> {error, gtk_requires_private_local_distribution};
        {_, false} when node() =:= nonode@nohost -> ok;
        {_, true} ->
            case erm_user_distribution:start() of
                ok -> unique_cnode_name(Gtk), ok;
                Error -> Error
            end;
        {_, false} -> {error, distributed_boot_forbidden};
        _ -> {error, invalid_local_distribution}
    end.

unique_cnode_name(Gtk0) ->
    Gtk = as_map(Gtk0),
    case maps:get(mode, Gtk, local_cnode) of
        local_cnode ->
            Port = as_map(maps:get(port, Gtk, #{})),
            case maps:get(cnode_node, Port, undefined) of
                undefined ->
                    [_Name, Host] = string:split(atom_to_list(node()), "@", all),
                    CNode = "gtknode4_" ++ integer_to_list(uid()) ++ "@" ++ Host,
                    application:set_env(erm, gtknode4, Gtk#{port => Port#{cnode_node => CNode}});
                _ -> ok
            end;
        _ -> ok
    end.
as_map(M) when is_map(M) -> M;
as_map(L) when is_list(L) -> maps:from_list(L).

option(K, M, D) when is_map(M) -> maps:get(K, M, D);
option(K, L, D) when is_list(L) -> proplists:get_value(K, L, D);
option(_, _, D) -> D.

config_home() -> xdg("XDG_CONFIG_HOME", [".config"]).
token_file() ->
    case application:get_env(erm_user, bridge_token_file, default) of
        default -> filename:join([config_home(), "erm", "damage.token"]);
        P -> P
    end.
xdg(Var, Suffix) ->
    case os:getenv(Var) of
        false -> filename:join([home() | Suffix]);
        "" -> filename:join([home() | Suffix]);
        P -> P
    end.
home() ->
    case os:getenv("HOME") of false -> error(home_unavailable); P -> P end.
uid() ->
    {ok, #file_info{uid = Uid}} = file:read_file_info("/proc/self"),
    Uid.

trusted_file(Path, Kind) ->
    case safe_user_path(filename:dirname(Path)) of
        ok -> trusted_leaf(Path, Kind);
        Error -> Error
    end.
trusted_leaf(Path, Kind) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, uid = Owner, mode = Mode, size = Size}}
          when Size =< 1048576 ->
            Mask = case Kind of token -> 8#077; config -> 8#022 end,
            case Owner =:= uid() andalso Mode band Mask =:= 0 of
                true -> ok;
                false -> {error, unsafe_file_permissions}
            end;
        _ -> {error, unsafe_file}
    end.

read_token(Path) ->
    case trusted_file(Path, token) of
        ok ->
            case file:read_file(Path) of
                {ok, B} when byte_size(B) =< 256 ->
                    Token = case lists:all(fun(C) -> C < 128 end, binary_to_list(B)) of
                        true -> string:trim(B); false -> <<>>
                    end,
                    case byte_size(Token) =:= 64 andalso
                         lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                                             (C >= $a andalso C =< $f) end,
                                   binary_to_list(Token)) of
                        true -> {ok, Token};
                        false -> {error, invalid_credential}
                    end;
                _ -> {error, credential_unreadable}
            end;
        _ -> {error, unsafe_credential}
    end.

%% Check each filesystem component before sending a bearer credential. A peer
%% in a writable or symlinked socket directory must never receive the token.
validate_socket(Path, ExpectedUid) when is_list(Path), is_integer(ExpectedUid), ExpectedUid >= 0 ->
    case filename:pathtype(Path) =:= absolute andalso
         not lists:member("..", filename:split(Path)) of
        true -> validate_components(filename:split(Path), "", ExpectedUid);
        false -> {error, unsafe_socket_path}
    end;
validate_socket(_, _) -> {error, unsafe_socket_path}.
validate_components([], _, _) -> {error, unsafe_socket_path};
validate_components([P], Acc, Uid) ->
    Path = filename:join(Acc, P),
    case file:read_link_info(Path) of
        {ok, #file_info{type = other, uid = Owner}} when Owner =:= Uid; Owner =:= 0 -> ok;
        {error, enoent} -> {error, unavailable};
        _ -> {error, untrusted_socket}
    end;
validate_components([P | Ps], Acc, Uid) ->
    Path = filename:join(Acc, P),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory, uid = Owner, mode = Mode}}
          when (Owner =:= 0 orelse Owner =:= Uid), Mode band 8#022 =:= 0 ->
            validate_components(Ps, Path, Uid);
        {error, enoent} -> {error, unavailable};
        _ -> {error, unsafe_socket_directory}
    end.
