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
-import(damage_utils, [to_bin/1]).
-import(steps_utils, [set_fail/3]).

-define(DEFAULT_HTTP_TIMEOUT, 30000).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/plain,*/*"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).
-define(STEP_ADD_PATH_TO_IPFS_AND_STORE_HASH, [
    "I add the path", Path, "to IPFS and store the hash in", Variable
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

%% -------------------------------------------------------------------
%% damage_gun-backed IPFS connection/request helpers
%% -------------------------------------------------------------------
%% Uniform POST to IPFS API. IPFS API endpoints usually expect POST.
ipfs_post(undefined, _Path, _Headers, Context) ->
    maps:put(fail, <<"IPFS API URL not set">>, Context);
ipfs_post(ApiUrl, Path, Headers, Context) ->
    ipfs_request(post, ApiUrl, Path, Headers, <<>>, Context).

%% Uniform GET for gateways or API GET-compatible calls.
ipfs_get(undefined, _Path, _Headers, Context) ->
    maps:put(fail, <<"IPFS gateway URL not set">>, Context);
ipfs_get(GatewayUrl, Path, Headers, Context) ->
    ipfs_request(get, GatewayUrl, Path, Headers, <<>>, Context).

ipfs_request(Method, BaseUrl, Path0, Headers, Body, Context) ->
    case ipfs_endpoint(BaseUrl, Path0) of
        {ok, #{host := Host, port := Port, path := Path, transport := Transport} = Ep} ->
            Opts = ipfs_damage_gun_opts(Host, Transport),

            ?LOG_DEBUG(
                "IPFS damage_gun request method=~p endpoint=~p headers=~p",
                [Method, Ep, Headers]
            ),

            Result =
                case Method of
                    get ->
                        damage_gun:get(Host, Port, Path, Headers, Opts);
                    post ->
                        damage_gun:post(Host, Port, Path, Headers, Body, Opts)
                end,

            case Result of
                {ok, #{status := Status, headers := RespHeaders, body := RespBody}} ->
                    maps:put(
                        response,
                        response_to_list({Status, RespHeaders, RespBody}),
                        Context
                    );
                {ok, #{status := Status, headers := RespHeaders}} ->
                    maps:put(
                        response,
                        response_to_list({Status, RespHeaders, <<>>}),
                        Context
                    );
                {error, Reason} ->
                    ?LOG_ERROR(
                        "IPFS damage_gun request failed method=~p base=~p path=~p reason=~p",
                        [Method, BaseUrl, Path, Reason]
                    ),
                    maps:put(
                        fail,
                        damage_utils:strf("IPFS request failed: ~p", [Reason]),
                        Context
                    )
            end;
        {error, Reason} ->
            ?LOG_ERROR(
                "Invalid IPFS endpoint base=~p path=~p reason=~p",
                [BaseUrl, Path0, Reason]
            ),
            maps:put(
                fail,
                damage_utils:strf("Invalid IPFS endpoint: ~p", [Reason]),
                Context
            )
    end.

ipfs_damage_gun_opts(Host, Transport) ->
    Base = #{
        transport => Transport,
        proxy => direct,
        protocols => [http],
        connect_timeout => ?DEFAULT_HTTP_TIMEOUT,
        timeout => ?DEFAULT_HTTP_TIMEOUT,
        close => true,
        decode => raw
    },

    case Transport of
        tls ->
            Base#{tls_opts => damage_gun:tls_opts(Host)};
        tcp ->
            Base
    end.

ipfs_endpoint(BaseUrl0, Path0) ->
    BaseUrl = normalize_url(BaseUrl0),
    Path = normalize_path_list(Path0),

    case uri_string:parse(BaseUrl) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            case normalize_scheme(Scheme0) of
                "http" = Scheme ->
                    ipfs_endpoint_from_parsed(Scheme, Host0, Parsed, Path);
                "https" = Scheme ->
                    ipfs_endpoint_from_parsed(Scheme, Host0, Parsed, Path);
                OtherScheme ->
                    {error, {unsupported_scheme, OtherScheme}}
            end;
        Other ->
            {error, {bad_url, BaseUrl, Other}}
    end.
ipfs_endpoint_from_parsed(Scheme, Host0, Parsed, Path) ->
    Host = normalize_host(Host0),
    Port = maps:get(port, Parsed, default_port(Scheme)),
    BasePath = maps:get(path, Parsed, ""),
    ReqPath = join_url_paths(BasePath, Path),
    {ok, #{
        scheme => Scheme,
        host => Host,
        port => Port,
        path => ReqPath,
        transport => transport_for_scheme(Scheme)
    }}.

normalize_url(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
normalize_url(List) when is_list(List) ->
    List.

normalize_scheme(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
normalize_scheme(List) when is_list(List) ->
    List.

normalize_host(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
normalize_host(List) when is_list(List) ->
    List.

normalize_path_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
normalize_path_list(List) when is_list(List) ->
    List.

default_port("https") -> 443;
default_port("http") -> 80.

transport_for_scheme("https") -> tls;
transport_for_scheme("http") -> tcp.

join_url_paths(BasePath0, Path0) ->
    BasePath = normalize_path_list(BasePath0),
    Path = ensure_leading_slash(normalize_path_list(Path0)),

    case BasePath of
        "" ->
            Path;
        "/" ->
            Path;
        _ ->
            string:trim(BasePath, trailing, "/") ++ Path
    end.

ensure_leading_slash("/" ++ _ = Path) ->
    Path;
ensure_leading_slash(Path) ->
    "/" ++ Path.
%%% --------------------------- IPFS conveniences ------------------------------

%% Compose /api/v0/<cmd>?arg=<cid>&<k>=<v>...
ipfs_api_url(Cmd, Params0) ->
    Q = uri_string:compose_query(Params0),
    "/api/v0/" ++ Cmd ++ "?" ++ Q.

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
    ?STEP_ADD_PATH_TO_IPFS_AND_STORE_HASH,
    _Body
) ->
    {run_dir, RunDir0} = lists:keyfind(run_dir, 1, Config),
    RunDir = filename:absname(RunDir0),

    Path = to_list(Path),

    case safe_resolve_under_run_dir(RunDir, Path) of
        {ok, AbsPath} ->
            case add_path_to_ipfs(AbsPath) of
                {ok, HashList} ->
                    RootName = root_name_for_path(AbsPath),
                    case pick_root_hash(HashList, RootName) of
                        {ok, Cid} ->
                            maps:put(Variable, Cid, maps:put(ipfs_add_result, HashList, Context0));
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

add_path_to_ipfs(AbsPath0) ->
    AbsPath = to_bin(AbsPath0),
    case filelib:is_dir(binary_to_list(AbsPath)) of
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
