-module(ecai_code_paths).

-export([
    state_root/0,
    state_root/1,
    ensure_layout/1,
    dets_file/2,
    log_file/2,
    patch_root/1,
    worktree_root/1,
    integration_root/1,
    integration_worktree_root/1,
    integration_log_root/1,
    security_git_root/1
]).

-define(SYSTEM_STATE_ROOT, "/var/lib/damage").

state_root() ->
    state_root(#{}).

state_root(Opts) when is_map(Opts) ->
    case maps:get(state_root, Opts, undefined) of
        undefined ->
            resolve_default_state_root();
        Root0 ->
            Root = path_to_list(Root0),
            case ensure_layout(Root) of
                ok -> {ok, Root};
                {error, Reason} -> {error, {explicit_state_root_unusable, Root, Reason}}
            end
    end.

ensure_layout(Root0) ->
    Root = path_to_list(Root0),
    Dirs = [
        "dets",
        "git",
        "keys",
        "logs",
        "runtime",
        "ssh",
        "tor",
        "wallets",
        filename:join(["git", "security"]),
        filename:join(["git", "security", "patches"]),
        filename:join(["git", "security", "worktrees"]),
        filename:join(["git", "security", "integration"]),
        filename:join(["git", "security", "integration", "worktrees"]),
        filename:join(["logs", "integration"])
    ],
    Writable = [
        "dets",
        "logs",
        filename:join(["git", "security", "patches"]),
        filename:join(["git", "security", "worktrees"]),
        filename:join(["git", "security", "integration"]),
        filename:join(["git", "security", "integration", "worktrees"]),
        filename:join(["logs", "integration"])
    ],
    case ensure_dirs(Root, Dirs) of
        ok -> ensure_writable_dirs(Root, Writable);
        {error, _} = Error -> Error
    end.

dets_file(Root, Name0) ->
    filename:join([path_to_list(Root), "dets", path_to_list(Name0)]).

log_file(Root, Name0) ->
    filename:join([path_to_list(Root), "logs", path_to_list(Name0)]).

security_git_root(Root) ->
    filename:join([path_to_list(Root), "git", "security"]).

patch_root(Root) ->
    filename:join([security_git_root(Root), "patches"]).

worktree_root(Root) ->
    filename:join([security_git_root(Root), "worktrees"]).

integration_root(Root) ->
    filename:join([security_git_root(Root), "integration"]).

integration_worktree_root(Root) ->
    filename:join([integration_root(Root), "worktrees"]).

integration_log_root(Root) ->
    filename:join([path_to_list(Root), "logs", "integration"]).

resolve_default_state_root() ->
    case ensure_layout(?SYSTEM_STATE_ROOT) of
        ok ->
            {ok, ?SYSTEM_STATE_ROOT};
        {error, SystemReason} ->
            case user_state_root() of
                {ok, Root} ->
                    case ensure_layout(Root) of
                        ok ->
                            {ok, Root};
                        {error, UserReason} ->
                            {error,
                                {no_usable_state_root, {?SYSTEM_STATE_ROOT, SystemReason},
                                    {Root, UserReason}}}
                    end;
                {error, UserRootReason} ->
                    {error,
                        {no_usable_state_root, {?SYSTEM_STATE_ROOT, SystemReason}, UserRootReason}}
            end
    end.

user_state_root() ->
    case os:getenv("XDG_STATE_HOME") of
        Xdg when is_list(Xdg), Xdg =/= [] ->
            case filename:pathtype(Xdg) of
                absolute -> {ok, filename:join(Xdg, "damage")};
                _ -> user_state_root_from_home()
            end;
        _ ->
            user_state_root_from_home()
    end.

user_state_root_from_home() ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= [] ->
            {ok, filename:join([Home, ".local", "state", "damage"])};
        _ ->
            {error, no_xdg_state_home_or_home}
    end.

ensure_dirs(_Root, []) ->
    ok;
ensure_dirs(Root, [Rel | Rest]) ->
    Dir = filename:join(Root, Rel),
    Dummy = filename:join(Dir, ".keep"),
    case filelib:ensure_dir(Dummy) of
        ok -> ensure_dirs(Root, Rest);
        {error, Reason} -> {error, {cannot_create_directory, Dir, Reason}}
    end.

ensure_writable_dirs(_Root, []) ->
    ok;
ensure_writable_dirs(Root, [Rel | Rest]) ->
    Dir = filename:join(Root, Rel),
    case writable_probe(Dir) of
        ok -> ensure_writable_dirs(Root, Rest);
        {error, _} = Error -> Error
    end.

writable_probe(Dir) ->
    Probe = filename:join(
        Dir,
        ".ecai_code_probe_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    case file:write_file(Probe, <<>>) of
        ok ->
            _ = file:delete(Probe),
            ok;
        {error, Reason} ->
            {error, {not_writable, Dir, Reason}}
    end.

path_to_list(Path) when is_list(Path) -> Path;
path_to_list(Path) when is_binary(Path) -> binary_to_list(Path).
