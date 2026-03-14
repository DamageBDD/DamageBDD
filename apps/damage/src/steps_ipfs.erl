%% steps_ipfs.erl
%% IPFS verification steps for DamageBDD
%% Template adapted from steps_http.erl

-module(steps_ipfs).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([step/6]).
-export([test/0]).

-define(DEFAULT_HTTP_TIMEOUT, 30000).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/plain,*/*"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).

%%% ---------------------- helpers (kept similar to steps_http) -----------------

get_headers(Context, DefaultHeaders) ->
    maps:to_list(
        maps:merge(
            maps:from_list(DefaultHeaders),
            maps:from_list(maps:get(headers, Context, []))
        )
    ).

%% keep the same response tuple format as steps_http
response_to_list({StatusCode, Headers, Body}) ->
    [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

get_conn(Url) ->
    {Host0, Port0} =
        case uri_string:parse(Url) of
            #{scheme := "https", host := Host} ->
                {Host, 443};
            #{scheme := "http", host := Host, port := Port} ->
                {Host, Port};
            #{scheme := "http", host := Host} ->
                {Host, 80};
            #{host := Host, port := Port} ->
                {Host, Port}
        end,
    Opts =
        case Port0 of
            443 -> #{transport => tls, tls_opts => [{verify, verify_none}]};
            _ -> #{transport => tcp}
        end,
    ?LOG_DEBUG("open connection ~p ~p", [Host0, Port0]),
    gun:open(Host0, Port0, Opts#{connect_timeout => ?DEFAULT_HTTP_TIMEOUT}).

await(ConnPid, StreamRef, Context) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, Status, Headers} ->
            maps:put(response, response_to_list({Status, Headers, <<"">>}), Context);
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            maps:put(response, response_to_list({Status, Headers, Body}), Context);
        Other ->
            maps:put(fail, damage_utils:strf("Gun request failed: ~p", [Other]), Context)
    end.

%%% --------------------------- IPFS conveniences ------------------------------

%% Compose /api/v0/<cmd>?arg=<cid>&<k>=<v>...
ipfs_api_url(Cmd, Params0) ->
    Q = uri_string:compose_query(Params0),
    "/api/v0/" ++ Cmd ++ "?" ++ Q.

%% Uniform POST to IPFS API (some endpoints expect POST)
ipfs_post(GateWay, Path, Headers, Context) ->
    {ok, ConnPid} = get_conn(GateWay),
    await(ConnPid, gun:post(ConnPid, Path, Headers, <<>>), Context).

%% Uniform GET (for gateways or API GET-compatible calls)
ipfs_get(GateWay, Path, Headers, Context) ->
    {ok, ConnPid} = get_conn(GateWay),
    await(ConnPid, gun:get(ConnPid, Path, Headers), Context).

%%% ------------------------------- Steps --------------------------------------

step(_Cfg, Context, <<"Given">>, _N, ["I am using IPFS API at", Url], _) ->
    maps:put(ipfs_api, Url, Context);
step(_Cfg, Context, _, _N, ["I am using IPFS gateway", Url], _) ->
    maps:put(ipfs_gateway, Url, Context);
step(_Cfg, Context, <<"Given">>, _N, ["a CID", CID], _) ->
    maps:put(cid, CID, Context);
%% When I call IPFS "block/stat" for the CID
step(_Cfg, Context0, <<"When">>, _N, ["I call IPFS", Cmd, "for the CID"], _Body) ->
    Api = maps:get(ipfs_api, Context0, undefined),
    CID = maps:get(cid, Context0, undefined),
    case CID of
        undefined ->
            maps:put(fail, <<"CID not set">>, Context0);
        _ ->
            Url = ipfs_api_url(Cmd, [{"arg", CID}]),
            Headers = get_headers(Context0, ?DEFAULT_HEADERS),
            ipfs_post(Api, Url, Headers, Context0)
    end;
%% When I call IPFS "pin/ls" for the CID with type "all"
step(
    _Cfg,
    Context0,
    <<"When">>,
    _N,
    ["I call IPFS", Cmd, "for the CID with type", Type],
    _Body
) ->
    Api = maps:get(ipfs_api, Context0, undefined),
    CID = maps:get(cid, Context0, undefined),
    case CID of
        undefined ->
            maps:put(fail, <<"CID not set">>, Context0);
        _ ->
            Url = ipfs_api_url(Cmd, [{"arg", CID}, {"type", Type}]),
            Headers = get_headers(Context0, ?DEFAULT_HEADERS),
            ipfs_post(Api, Url, Headers, Context0)
    end;
%% When I GET "/ipfs/<cid>" from the gateway with Range "bytes=0-63"
step(
    Cfg,
    Context0,
    <<"When">>,
    _N,
    ["I GET", Path0, "from the gateway with Range", Range],
    _B
) ->
    Gw = maps:get(ipfs_gateway, Context0, undefined),
    CID = maps:get(cid, Context0, undefined),
    case {Gw, CID} of
        {undefined, _} ->
            maps:put(fail, <<"IPFS gateway not set">>, Context0);
        {_, undefined} ->
            maps:put(fail, <<"CID not set">>, Context0);
        {Gateway, _} ->
            Path = binary_to_list(
                binary:replace(list_to_binary(Path0), <<"<cid>">>, list_to_binary(CID), [global])
            ),
            Headers = [{<<"range">>, Range}, {<<"accept">>, "*/*"}],
            ?LOG_DEBUG("range url ~p ~p ~p", [Cfg, Path, Headers]),
            ipfs_get(Gateway, Path, Headers, Context0)
    end;
%% When I add the path "deb/" to IPFS and store the hash in "asset_hash"
step(
    Config,
    Context0,
    <<"When">>,
    _N,
    ["I add the path", Path0, "to IPFS and store the hash in", Var],
    _Body
) ->
    {run_dir, RunDir0} = lists:keyfind(run_dir, 1, Config),
    RunDir = filename:absname(RunDir0),

    Path = to_list(Path0),

    case safe_resolve_under_run_dir(RunDir, Path) of
        {ok, AbsPath} ->
            case add_path_to_ipfs(AbsPath) of
                {ok, HashList} ->
                    RootName = root_name_for_path(AbsPath),
                    case pick_root_hash(HashList, RootName) of
                        {ok, Cid} ->
                            maps:put(Var, Cid, maps:put(ipfs_add_result, HashList, Context0));
                        {error, Why} ->
                            maps:put(
                                fail,
                                damage_utils:strf(
                                    "ipfs add ok but cannot pick root cid: ~p",
                                    [Why]
                                ),
                                Context0
                            )
                    end;
                {error, Why} ->
                    maps:put(fail, damage_utils:strf("ipfs add failed: ~p", [Why]), Context0)
            end;
        {error, Why} ->
            maps:put(
                fail,
                damage_utils:strf("refusing path outside run_dir: ~p ~p ~p", [Why, RunDir, Path]),
                Context0
            )
    end;
%% Ensure IPFS asset (optional)
step(_Config, Context, _Phase, _N, ["I ensure IPFS asset", Hash, "at", OutPath], _Body) ->
    case filelib:is_file(OutPath) of
        true ->
            Context;
        false ->
            damage_utils:ensure_dir(filename:dirname(OutPath) ++ "/"),
            case damage_ipfs:get(Hash, OutPath) of
                {error, Reason} ->
                    ?LOG_WARNING("ipfs failed to fetch ~s -> ~s error: ~p", [Hash, OutPath, Reason]),
                    damage_utils:fail(Context, Reason);
                {ok, Result} ->
                    ?LOG_DEBUG("ensure ipfs asset result ~p", [Result]),

                    maps:put(ipfs_result, Result, Context)
            end
    end;
step(
    _Config,
    Context,
    _Phase,
    _N,
    ["I ensure IPFS asset", Hash, "at", OutPath, "as", Variable],
    _Body
) ->
    case filelib:is_file(OutPath) of
        true ->
            Context;
        false ->
            damage_utils:ensure_dir(filename:dirname(OutPath) ++ "/"),
            case damage_ipfs:get(Hash, OutPath) of
                {error, Reason} ->
                    ?LOG_WARNING("ipfs failed to fetch ~s -> ~s error: ~p", [Hash, OutPath, Reason]),
                    damage_utils:fail(Context, Reason);
                {ok, Result} ->
                    ?LOG_DEBUG("ensure ipfs asset result ~p", [Result]),

                    maps:put(ipfs_result, Result, maps:put(Variable, OutPath, Context))
            end
    end;
%% Then file exists (conditional on ipfs present)
step(
    _Config, Context, _Phase, _N, ["the file", Path, "should exist (if ipfs is installed)"], _Body
) ->
    case damage_utils:exists_cmd("ipfs") of
        % skip
        false ->
            Context;
        true ->
            case filelib:is_file(Path) of
                true -> Context;
                false -> damage_utils:fail(Context, {missing_file, Path})
            end
    end.
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

%% Resolve Path under RunDir and guarantee it cannot escape.
%% - Reject absolute paths
%% - Normalize/join, then canonicalize with realpath to defeat symlink escape
safe_resolve_under_run_dir(RunDirAbs, Path0) ->
    Path = string:trim(Path0),

    case filename:pathtype(Path) of
        absolute ->
            {error, absolute_path_not_allowed};
        _ ->
            %% Join under run dir
            Joined = filename:join(RunDirAbs, Path),
            Abs = filename:absname(Joined),

            %% If it doesn't exist, you may choose to reject early
            case file:read_file_info(Abs) of
                {ok, _} ->
                    %% Canonicalize to defeat symlink escapes
                    case realpath(Abs) of
                        {ok, RealAbs} ->
                            case is_within_dir(RealAbs, RunDirAbs) of
                                true -> {ok, RealAbs};
                                false -> {error, escaped_via_symlink_or_traversal}
                            end;
                        {error, R} ->
                            {error, {realpath_failed, R}}
                    end;
                {error, enoent} ->
                    {error, does_not_exist};
                {error, R} ->
                    {error, {file_info_failed, R}}
            end
    end.

%% Returns true if PathAbs is inside DirAbs (or equal to it).
is_within_dir(PathAbs0, DirAbs0) ->
    PathAbs = filename:absname(PathAbs0),
    DirAbs = filename:absname(DirAbs0),

    %% ensure trailing slash comparison is safe
    DirWithSep =
        case lists:last(DirAbs) of
            $/ -> DirAbs;
            _ -> DirAbs ++ "/"
        end,

    PathStr = PathAbs,
    (PathStr =:= DirAbs) orelse lists:prefix(DirWithSep, PathStr).

%% Minimal realpath wrapper (OTP 26+ has filelib:realpath/1; else emulate)
realpath(Path) ->
    %% Prefer filelib:realpath/1 if available:
    try
        {ok, filelib:realpath(Path)}
    catch
        _:_ ->
            %% Fallback: use filename:absname only (less secure vs symlinks)
            %% Better to require OTP with filelib:realpath in production.
            {ok, filename:absname(Path)}
    end.

add_path_to_ipfs(AbsPath) ->
    case filelib:is_dir(AbsPath) of
        true -> damage_ipfs:add({directory, AbsPath});
        false -> damage_ipfs:add({file, AbsPath})
    end.

root_name_for_path(AbsPath) ->
    filename:basename(AbsPath).

pick_root_hash(HashList, RootName0) ->
    RootName =
        case RootName0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L
        end,
    %% ipfs:add returns a list of maps: #{<<"Name">> := ..., <<"Hash">> := ...}
    Matches =
        [H || #{<<"Name">> := Name} = H <- HashList, string:equal(Name, RootName)],
    case Matches of
        [#{<<"Hash">> := Cid} | _] ->
            {ok, Cid};
        [] ->
            %% fallback: last entry (common for single-file adds)
            case lists:reverse(HashList) of
                [#{<<"Hash">> := Cid} | _] -> {ok, Cid};
                _ -> {error, no_hashes_returned}
            end
    end.

test() ->
    Headers = [{<<"range">>, "bytes=0-63"}, {<<"accept">>, "*/*"}],
    ipfs_get(
        "https://ipfs.io", "/ipfs/QmdF4hVR9nmJjxkqfr3YpD3Bre2xw9yg1ApnLDk1GLxfQf", Headers, #{}
    ).
