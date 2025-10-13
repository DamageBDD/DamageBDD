%%%-------------------------------------------------------------------
%%% Create relx release tarballs + publish to IPFS + hot-upgrade
%%%-------------------------------------------------------------------
-module(damage_upgrade).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    %% --- NEW: build/publish ---
    create_release/0,
    % #{repo_dir := "...", profile => "prod"|"dev"|..., rebar3 => "/path/to/rebar3"}
    create_release/1,
    % creates and ipfs-adds; returns #{tar_path := Path, cid := Cid}
    create_release_and_publish/1,

    %% --- Existing upgrade API ---
    upgrade_from_ipfs/1,
    upgrade_from_ipfs/2
]).

%%%==================================================================
%%% PUBLIC: CREATE
%%%==================================================================

create_release() ->
    Repo = application:get_env(damage, app_dir, "/opt/workspace/DamageBDD"),

    create_release(#{
        % required
        repo_dir => Repo,
        % default "prod"
        profile => "prod"
    }).
%% Create a release tarball with rebar3.
%% Options:
%%  - repo_dir (required): project root containing rebar.config
%%  - profile (optional): rebar3 profile, default "prod"
%%  - rebar3  (optional): explicit path, default from PATH
create_release(Opts0) ->
    Opts = normalize_build_opts(Opts0),
    Rebar3 = maps:get(rebar3, Opts, find_rebar3()),
    Repo = maps:get(repo_dir, Opts),
    Profile = maps:get(profile, Opts, "prod"),

    ?LOG_INFO("Building release with ~s as ~s in ~s", [Rebar3, Profile, Repo]),

    case exec:run([Rebar3, "as", Profile, "tar"], [sync, stdout, stderr]) of
        {ok, _} ->
            TarPath = find_tarball(Profile, Repo),
            ?LOG_INFO("Release tar created: ~s", [TarPath]),
            {ok, TarPath};
        {error, Reason} ->
            ?LOG_ERROR("rebar3 tar failed (~p)", [Reason]),
            {error, Reason}
    end.

%% Create and publish to IPFS. Returns both tar path and CID.
create_release_and_publish(Opts0) ->
    case create_release(Opts0) of
        {ok, Tar} ->
            case publish_to_ipfs(Tar) of
                {ok, Cid} ->
                    ?LOG_INFO("Published to IPFS CID=~s", [Cid]),
                    {ok, #{tar_path => Tar, cid => Cid}};
                {error, Why} ->
                    {error, {ipfs_publish_failed, Why}}
            end;
        Error ->
            Error
    end.

%%%==================================================================
%%% PUBLIC: UPGRADE (existing)
%%%==================================================================

upgrade_from_ipfs(CID) ->
    upgrade_from_ipfs(CID, #{}).

%% Opts: #{out_dir => "/path", out_name => "/path/file.tar.gz", sha256 => "hex"}
upgrade_from_ipfs(CID, Opts0) ->
    Opts = normalize_out_opts(Opts0),
    TarPath = ensure_tar_present(CID, Opts),
    maybe_verify(TarPath, maps:get(sha256, Opts, undefined)),
    do_upgrade(TarPath).

%%%==================================================================
%%% INTERNALS: BUILD
%%%==================================================================

normalize_build_opts(#{repo_dir := _} = Opts) -> Opts;
normalize_build_opts(Other) -> error({missing_required_opt, repo_dir, Other}).

find_rebar3() ->
    case os:find_executable("rebar3") of
        false -> error({rebar3_not_found_in_path});
        Path -> Path
    end.

find_tarball(Profile, RepoDir) ->
    RelRoot = filename:join([RepoDir, "_build", Profile, "rel"]),
    %% find */*.tar.gz under rel root and pick newest
    Dirs =
        case file:list_dir(RelRoot) of
            {ok, L} -> [filename:join(RelRoot, D) || D <- L];
            _ -> []
        end,
    TarPaths = lists:flatten([find_tars_in_dir(D) || D <- Dirs]),
    case TarPaths of
        [] -> error({tar_not_found, RelRoot});
        _ -> latest_by_mtime(TarPaths)
    end.

find_tars_in_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            [
                filename:join(Dir, F)
             || F <- Files, lists:suffix(".tar.gz", F)
            ];
        _ ->
            []
    end.

latest_by_mtime(Paths) ->
    {Path, _Time} =
        lists:max([{P, filelib:last_modified(P)} || P <- Paths]),
    Path.

%%%==================================================================
%%% INTERNALS: IPFS FETCH/PUBLISH
%%%==================================================================

normalize_out_opts(Opts0) when is_map(Opts0) ->
    OutDir = maps:get(out_dir, Opts0, "/tmp"),
    OutName = maps:get(out_name, Opts0, filename:join(OutDir, "release_from_ipfs.tar.gz")),
    Opts0#{out_dir => OutDir, out_name => OutName};
normalize_out_opts([]) ->
    normalize_out_opts(#{}).

ensure_tar_present(CID0, #{out_name := OutPath}) ->
    CID = to_list(CID0),
    ok = ensure_dir(filename:dirname(OutPath)),
    case filelib:is_file(OutPath) of
        true ->
            OutPath;
        false ->
            damage_ipfs:ensure_ipfs_asset(CID, OutPath)
    end.

publish_to_ipfs(TarPath) ->
    %% Prefer damage_ipfs first; fallback to `ipfs add -Q`
    damage_ipfs:add_file(TarPath).

%%%==================================================================
%%% INTERNALS: VERIFY & UPGRADE
%%%==================================================================

maybe_verify(_Path, undefined) ->
    ok;
maybe_verify(Path, ShaHex) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Calc = sha256_hex(Bin),
            LowerCalc = string:lowercase(Calc),
            LowerExpected = string:lowercase(ShaHex),
            case LowerCalc of
                LowerExpected ->
                    ?LOG_INFO("SHA256 OK ~s", [Calc]),
                    ok;
                _ ->
                    error({checksum_mismatch, #{expected => ShaHex, got => Calc}})
            end;
        Err ->
            error({checksum_read_failed, Err})
    end.

do_upgrade(TarPath) ->
    case release_handler:unpack_release(TarPath) of
        {ok, Vsn} ->
            case release_handler:install_release(Vsn) of
                {ok, From, _To, _} ->
                    case release_handler:make_permanent(Vsn) of
                        ok ->
                            {ok, Vsn};
                        {error, Reason} ->
                            _ = safe_downgrade(From),
                            error({make_permanent_failed, Reason})
                    end;
                {error, Why} ->
                    _ = safe_uninstall(Vsn),
                    error({install_failed, Why})
            end;
        {error, Reason} ->
            error({unpack_failed, Reason})
    end.

safe_downgrade(From) ->
    catch release_handler:install_release(From),
    catch release_handler:make_permanent(From),
    ok.

safe_uninstall(Vsn) ->
    catch release_handler:uninstall_release(Vsn),
    ok.

%%%==================================================================
%%% INTERNALS: UTIL
%%%==================================================================

ensure_dir(D) ->
    case filelib:is_dir(D) of
        true -> ok;
        false -> filelib:ensure_dir(filename:join(D, "x"))
    end.

sha256_hex(Bin) when is_binary(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
