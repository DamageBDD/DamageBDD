%%--------------------------------------------------------------------
%% Shared ECAI filesystem layout.
%%
%% Durable/runtime ECAI state follows the Damage XDG state root:
%%   $XDG_STATE_HOME/damage
%%   $HOME/.local/state/damage
%% with explicit application configuration taking precedence.
%%--------------------------------------------------------------------
-module(ecai_paths).

-export([
    state_dir/0,
    runtime_dir/0,
    ipfs_index_dir/0,
    index_state_dir/0,
    index_snapshot_path/0,
    search_context_file/0,
    normalize/1,
    ensure_dir/1,
    ensure_parent/1
]).

-spec state_dir() -> file:filename().
state_dir() ->
    case configured_path([
        {ecai, state_dir},
        {damage, state_dir},
        {damage, secrets_state_dir}
    ]) of
        {ok, Path} ->
            Path;
        not_found ->
            default_state_dir()
    end.

-spec runtime_dir() -> file:filename().
runtime_dir() ->
    filename:join([state_dir(), "runtime", "ecai"]).

-spec ipfs_index_dir() -> file:filename().
ipfs_index_dir() ->
    case application:get_env(ecai, ipfs_index_dir) of
        {ok, Path} when is_binary(Path); is_list(Path) ->
            normalize(Path);
        undefined ->
            filename:join(runtime_dir(), "ipfs-index");
        _ ->
            erlang:error({invalid_ecai_path_config, ipfs_index_dir})
    end.

-spec index_state_dir() -> file:filename().
index_state_dir() ->
    filename:join(runtime_dir(), "state").

-spec index_snapshot_path() -> file:filename().
index_snapshot_path() ->
    case application:get_env(ecai, index_snapshot_path) of
        {ok, Path} when is_binary(Path); is_list(Path) ->
            normalize(Path);
        undefined ->
            filename:join(index_state_dir(), "ecai_index.snap");
        _ ->
            erlang:error({invalid_ecai_path_config, index_snapshot_path})
    end.

-spec search_context_file() -> file:filename().
search_context_file() ->
    case application:get_env(ecai, search_context_file) of
        {ok, Path} when is_binary(Path); is_list(Path) ->
            normalize(Path);
        undefined ->
            filename:join(index_state_dir(), "default.ctx");
        _ ->
            erlang:error({invalid_ecai_path_config, search_context_file})
    end.

-spec normalize(binary() | list()) -> file:filename().
normalize(Path0) ->
    Path1 = path_list(Path0),
    Path2 = expand_home(Path1),
    filename:absname(Path2).

-spec ensure_dir(file:filename_all()) -> ok | {error, term()}.
ensure_dir(Dir0) ->
    Dir = normalize(Dir0),
    case filelib:ensure_dir(filename:join(Dir, ".keep")) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {directory_create_failed, Dir, Reason}}
    end.

-spec ensure_parent(file:filename_all()) -> ok | {error, term()}.
ensure_parent(Path0) ->
    Path = normalize(Path0),
    case filelib:ensure_dir(Path) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {directory_create_failed, filename:dirname(Path), Reason}}
    end.

configured_path([{App, Key} | Rest]) ->
    case application:get_env(App, Key) of
        {ok, Path} when is_binary(Path); is_list(Path) ->
            {ok, normalize(Path)};
        undefined ->
            configured_path(Rest);
        _ ->
            erlang:error({invalid_ecai_path_config, {App, Key}})
    end;
configured_path([]) ->
    not_found.

default_state_dir() ->
    case os:getenv("XDG_STATE_HOME") of
        Xdg when is_list(Xdg), Xdg =/= "" ->
            case filename:pathtype(expand_home(Xdg)) of
                absolute ->
                    filename:join(expand_home(Xdg), "damage");
                _ ->
                    home_state_dir()
            end;
        _ ->
            home_state_dir()
    end.

home_state_dir() ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            filename:join([Home, ".local", "state", "damage"]);
        _ ->
            "/var/lib/damage"
    end.

path_list(Path) when is_binary(Path), byte_size(Path) > 0 ->
    case unicode:characters_to_list(Path) of
        List when is_list(List), List =/= [] ->
            List;
        _ ->
            erlang:error({invalid_ecai_path, Path})
    end;
path_list(Path) when is_list(Path), Path =/= [] ->
    Path;
path_list(Path) ->
    erlang:error({invalid_ecai_path, Path}).

expand_home("~") ->
    require_home("~");
expand_home([$~, $/ | Rest] = Path) ->
    filename:join(require_home(Path), Rest);
expand_home(Path) ->
    Path.

require_home(Path) ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            Home;
        _ ->
            erlang:error({home_directory_unavailable, Path})
    end.
