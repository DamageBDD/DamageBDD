%% ipfs_util.erl
%% Helpers for initializing and configuring an IPFS repo using erlexec.
%% Public API:
%%   ensure_ipfs_repo/0,1
%%   set_config/2,3
%%   set_gateway_local_8082/0,1

-module(ipfs_util).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    ensure_ipfs_repo/0, ensure_ipfs_repo/1,
    set_config/0, set_config/2, set_config/3
]).


-define(DEFAULT_IPFS_DIR, ".ipfs").
-define(DEFAULT_IPFS_HOME, "/var/lib/ipfs/").

%% -----------------------------
%% Public API
%% -----------------------------

%% @doc Ensure IPFS repo exists. Uses $IPFS_PATH or ~/.ipfs.
ensure_ipfs_repo() ->
    ensure_ipfs_repo(#{}).

%% Opts:
%%  #{ path => "/var/lib/ipfs",
%%     ipfs_cmd => "ipfs",
%%     profiles => ["server"] }.
ensure_ipfs_repo(Opts0) when is_map(Opts0) ->
    IPFS = maps:get(ipfs_cmd, Opts0, os:find_executable("ipfs")),
    Path = resolve_path(
        maps:get(path, Opts0, filename:join([?DEFAULT_IPFS_HOME, ?DEFAULT_IPFS_DIR]))
    ),

    %% Check binary availability via your helper
    case damage_utils:exists_cmd(IPFS) of
        false ->
            {error, ipfs_not_found};
        true ->
            Result =
                case ipfs_repo_exists(Path) of
                    true ->
                        {ok, already_initialized};
                    false ->
                        ok = damage_utils:ensure_dir(Path ++ "/"),
                        InitCmd = build_init_cmd(IPFS, maps:get(profiles, Opts0, [])),
                        case run_env(Path, InitCmd) of
                            {ok, _Out} ->
                                case ipfs_repo_exists(Path) of
                                    true -> {ok, inited};
                                    false -> {error, init_failed}
                                end;
                            {error, Reason} ->
                                ?LOG_ERROR("ipfs init failed: ~p", [Reason]),
                                {error, {init_failed, Reason}}
                        end
                end,
            set_config(),
            Result
    end.

%% @doc Set an IPFS config key (string value).
set_config() ->
    {ok, IpfsConfig} = application:get_env(damage, ipfs),
    [set_config(K, V) || {K, V} <- IpfsConfig].
set_config(Key0, Val0) ->
    set_config(Key0, Val0, #{}).

%% Opts same as ensure_ipfs_repo/1 (path/ipfs_cmd).
set_config(Key0, Val0, Opts0) when is_map(Opts0) ->
    IPFS = maps:get(ipfs_cmd, Opts0, os:find_executable("ipfs")),
    Path = resolve_path(maps:get(path, Opts0, undefined)),
    Key = to_list(Key0),
    Val = to_list(Val0),

    case {damage_utils:exists_cmd(IPFS), ipfs_repo_exists(Path)} of
        {false, _} ->
            {error, ipfs_not_found};
        {_, false} ->
            {error, ipfs_repo_missing};
        {true, true} ->
            Cmd = [IPFS, "config", Key, Val],
            case run_env(Path, Cmd) of
                {ok, _Out} -> {ok, set};
                {error, Reason} -> {error, {nonzero_exit, Reason}}
            end
    end.
%% -----------------------------
%% Internals
%% -----------------------------

resolve_path(undefined) ->
    case os:getenv("IPFS_PATH") of
        false ->
            case os:getenv("HOME") of
                false -> filename:join([?DEFAULT_IPFS_HOME, ?DEFAULT_IPFS_DIR]);
                Home -> filename:join([Home, ?DEFAULT_IPFS_DIR])
            end;
        P ->
            expand_tilde(P)
    end;
resolve_path(P) ->
    expand_tilde(P).

expand_tilde(Path) when is_list(Path) ->
    case Path of
        [$~, $/ | Rest] ->
            case os:getenv("HOME") of
                false -> filename:join([?DEFAULT_IPFS_HOME, Rest]);
                Home -> filename:join([Home, Rest])
            end;
        _ ->
            Path
    end.

ipfs_repo_exists(Path) ->
    filelib:is_file(filename:join([Path, "config"])) andalso
        filelib:is_dir(filename:join([Path, "blocks"])).

%% Build `ipfs init` with profiles
build_init_cmd(IPFS, Profiles) ->
    %% "ipfs init --profile p1 --profile p2"
    case Profiles of
        [] ->
            [IPFS, "init"];
        Ps when is_list(Ps) ->
            [IPFS, "init", lists:flatten([lists:concat(["--profile", to_list(P)]) || P <- Ps])]
    end.

%% Run a command with IPFS_PATH in env using erlexec; capture exit + output.
run_env(Path, Cmd) ->
    Env = [{"IPFS_PATH", Path}],
    case exec:run(Cmd, [sync, stdout, stderr, {env, Env}]) of
        {ok, _Pid, Out} -> {ok, Out};
        {ok, Out} -> {ok, Out};
        {error, Reason} -> {error, Reason}
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L.
