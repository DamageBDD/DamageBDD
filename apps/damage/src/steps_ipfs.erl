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
%% An embedded Dockerfile can be published by a remote /execute_feature call
%% without requiring a repository checkout on the DamageBDD execution node.
-define(STEP_PUBLISH_DOCKERFILE_TO_IPFS_AND_STORE_HASH, [
    "I publish the following Dockerfile to IPFS and store the hash in", Variable
]).
%% Base64 prevents Gherkin/step templating from consuming Bash/Dockerfile braces.
%% Decoding happens only after the step's ordinary context rendering completes.
-define(STEP_PUBLISH_BASE64_DOCKERFILE_TO_IPFS_AND_STORE_HASH, [
    "I publish the following base64 encoded Dockerfile to IPFS and store the hash in", Variable
]).
-define(MAX_INLINE_DOCKERFILE_BYTES, 262144).
-define(MAX_BASE64_DOCKERFILE_BYTES, ((?MAX_INLINE_DOCKERFILE_BYTES + 2) div 3) * 4).
-define(MAX_BASE64_DOCSTRING_BYTES, (?MAX_BASE64_DOCKERFILE_BYTES + 16384)).

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

%% Human-readable failures for the common damage_gun error shapes.
ipfs_request_error_message({await_up_failed, Reason}) ->
    ipfs_request_error_message(Reason);
ipfs_request_error_message({await_response_failed, Reason}) ->
    ipfs_request_error_message(Reason);
ipfs_request_error_message({await_body_failed, Reason}) ->
    ipfs_request_error_message(Reason);
ipfs_request_error_message({gun_open_exit, Reason}) ->
    ipfs_request_error_message(Reason);
ipfs_request_error_message({gun_not_started, Reason}) ->
    damage_utils:strf(
        "IPFS HTTP client is unavailable. Ensure Gun is started. Underlying error: ~p",
        [Reason]
    );
ipfs_request_error_message(econnrefused) ->
    <<"IPFS connection refused. Check that the IPFS API/gateway is running and the host/port are correct.">>;
ipfs_request_error_message(nxdomain) ->
    <<"IPFS hostname could not be resolved. Check the configured hostname and DNS.">>;
ipfs_request_error_message(enetunreach) ->
    <<"IPFS network is unreachable. Check routing, firewall, and endpoint configuration.">>;
ipfs_request_error_message(ehostunreach) ->
    <<"IPFS host is unreachable. Check routing, firewall, and endpoint configuration.">>;
ipfs_request_error_message(timeout) ->
    damage_utils:strf(
        "IPFS request timed out after ~p ms. Check IPFS daemon/gateway health and network reachability.",
        [?DEFAULT_HTTP_TIMEOUT]
    );
ipfs_request_error_message({tls_alert, Reason}) ->
    damage_utils:strf(
        "IPFS TLS connection failed. Check the HTTPS hostname, certificate, and trusted CA chain. "
        "Underlying error: ~p",
        [Reason]
    );
ipfs_request_error_message(Reason) ->
    damage_utils:strf(
        "IPFS request failed. Check the configured endpoint and IPFS service logs. "
        "Underlying error: ~p",
        [Reason]
    ).

ipfs_endpoint_error_message({unsupported_scheme, Scheme}) ->
    damage_utils:strf(
        "Unsupported IPFS URL scheme ~p. Use an absolute http:// or https:// URL.",
        [Scheme]
    );
ipfs_endpoint_error_message({bad_url, BaseUrl, _}) ->
    damage_utils:strf(
        "Invalid IPFS endpoint ~p. Use an absolute URL such as http://127.0.0.1:5001.",
        [BaseUrl]
    );
ipfs_endpoint_error_message(Reason) ->
    damage_utils:strf("Invalid IPFS endpoint: ~p", [Reason]).

ipfs_path_error_message(absolute_path_not_allowed, RunDir, Path) ->
    damage_utils:strf(
        "IPFS add path ~p must be relative to run_dir ~p; absolute paths are not allowed.",
        [Path, RunDir]
    );
ipfs_path_error_message(does_not_exist, RunDir, Path) ->
    damage_utils:strf(
        "IPFS add path ~p does not exist under run_dir ~p.",
        [Path, RunDir]
    );
ipfs_path_error_message(escaped_via_symlink_or_traversal, RunDir, Path) ->
    damage_utils:strf(
        "IPFS add path ~p resolves outside run_dir ~p; traversal and symlink escapes are refused.",
        [Path, RunDir]
    );
ipfs_path_error_message(Reason, RunDir, Path) ->
    damage_utils:strf(
        "Cannot use IPFS add path ~p under run_dir ~p: ~p",
        [Path, RunDir, Reason]
    ).

%% -------------------------------------------------------------------
%% damage_gun-backed IPFS connection/request helpers
%% -------------------------------------------------------------------
%% Uniform POST to IPFS API. IPFS API endpoints usually expect POST.
ipfs_post(undefined, _Path, _Headers, Context) ->
    maps:put(
        fail,
        <<
            "IPFS API URL is not set. Add `Given I am using IPFS API at "
            "\"http://127.0.0.1:5001\"` before this step."
        >>,
        Context
    );
ipfs_post(ApiUrl, Path, Headers, Context) ->
    ipfs_request(post, ApiUrl, Path, Headers, <<>>, Context).

%% Uniform GET for gateways or API GET-compatible calls.
ipfs_get(undefined, _Path, _Headers, Context) ->
    maps:put(
        fail,
        <<
            "IPFS gateway URL is not set. Add `Given I am using IPFS gateway "
            "\"http://127.0.0.1:8080\"` before this step."
        >>,
        Context
    );
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
                    maps:put(fail, ipfs_request_error_message(Reason), Context)
            end;
        {error, Reason} ->
            ?LOG_ERROR(
                "Invalid IPFS endpoint base=~p path=~p reason=~p",
                [BaseUrl, Path0, Reason]
            ),
            maps:put(fail, ipfs_endpoint_error_message(Reason), Context)
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
            maps:put(
                fail,
                <<"CID is not set. Add `Given a CID \"<cid>\"` before calling IPFS for the CID.">>,
                Context0
            );
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
            maps:put(
                fail,
                <<"CID is not set. Add `Given a CID \"<cid>\"` before calling IPFS for the CID.">>,
                Context0
            );
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
            maps:put(
                fail,
                <<
                    "IPFS gateway URL is not set. Add `Given I am using IPFS gateway "
                    "\"http://127.0.0.1:8080\"` before this step."
                >>,
                Context0
            );
        {_, undefined} ->
            maps:put(
                fail,
                <<"CID is not set. Add `Given a CID \"<cid>\"` before requesting gateway content.">>,
                Context0
            );
        {Gateway, _} ->
            Path = binary_to_list(
                binary:replace(list_to_binary(Path0), <<"<cid>">>, list_to_binary(CID), [global])
            ),
            Headers = [{<<"range">>, Range}, {<<"accept">>, "*/*"}],
            ?LOG_DEBUG("range url ~p ~p ~p", [Cfg, Path, Headers]),
            ipfs_get(Gateway, Path, Headers, Context0)
    end;
%% Publish an inline Dockerfile, keeping backwards compatibility for raw input.
%% The base64 variant avoids placeholder validation consuming Bash/PKGCONFIG braces
%% before the Dockerfile reaches this step.  The decoded bytes are published.
step(
    Config,
    Context0,
    <<"When">>,
    _N,
    ?STEP_PUBLISH_DOCKERFILE_TO_IPFS_AND_STORE_HASH,
    Body
) ->
    publish_dockerfile_step(Config, Context0, Variable, inline_dockerfile_bytes(Body));
step(
    Config,
    Context0,
    <<"When">>,
    _N,
    ?STEP_PUBLISH_BASE64_DOCKERFILE_TO_IPFS_AND_STORE_HASH,
    Body
) ->
    publish_dockerfile_step(Config, Context0, Variable, inline_base64_dockerfile_bytes(Body));
%% When I add the path "deb/" to IPFS and store the hash in "asset_hash"
step(
    Config,
    Context0,
    _,
    _N,
    ?STEP_ADD_PATH_TO_IPFS_AND_STORE_HASH,
    _Body
) ->
    case lists:keyfind(run_dir, 1, Config) of
        false ->
            maps:put(
                fail,
                <<"IPFS add requires `run_dir` in the DamageBDD execution config.">>,
                Context0
            );
        {run_dir, RunDir0} ->
            RunDir = filename:absname(RunDir0),
            Path = to_list(Path),

            case safe_resolve_under_run_dir(RunDir, Path) of
                {ok, AbsPath} ->
                    case add_path_to_ipfs(AbsPath) of
                        {ok, HashList} ->
                            RootName = root_name_for_path(AbsPath),
                            case pick_root_hash(HashList, RootName) of
                                {ok, Cid} ->
                                    maps:put(
                                        Variable,
                                        Cid,
                                        maps:put(ipfs_add_result, HashList, Context0)
                                    );
                                {error, Why} ->
                                    maps:put(
                                        fail,
                                        damage_utils:strf(
                                            "IPFS add succeeded but no root CID was returned: ~p",
                                            [Why]
                                        ),
                                        Context0
                                    )
                            end;
                        {error, Why} ->
                            maps:put(
                                fail,
                                damage_utils:strf(
                                    "IPFS add failed for ~p. Check the IPFS service and asset path. "
                                    "Underlying error: ~p",
                                    [AbsPath, Why]
                                ),
                                Context0
                            )
                    end;
                {error, Why} ->
                    maps:put(fail, ipfs_path_error_message(Why, RunDir, Path), Context0)
            end
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
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "IPFS fetch failed for CID ~p to ~p. Check that the CID exists, "
                            "IPFS is reachable, and the destination is writable. Error: ~p",
                            [Hash, OutPath, Reason]
                        ),
                        Context
                    );
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
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "IPFS fetch failed for CID ~p to ~p. Check that the CID exists, "
                            "IPFS is reachable, and the destination is writable. Error: ~p",
                            [Hash, OutPath, Reason]
                        ),
                        Context
                    );
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

%% Reuse the same publication path for raw and base64-encoded docstrings.
publish_dockerfile_step(Config, Context0, Variable, BytesResult) ->
    case {proplists:get_value(run_dir, Config), BytesResult} of
        {undefined, _} ->
            maps:put(fail, <<"IPFS Dockerfile publication requires run_dir">>, Context0);
        {_, {error, Reason}} ->
            maps:put(fail, damage_utils:strf("Invalid inline Dockerfile: ~p", [Reason]), Context0);
        {RunDir0, {ok, Bytes}} ->
            RunDir = filename:absname(to_list(RunDir0)),
            case publish_inline_dockerfile(RunDir, Bytes) of
                {ok, Cid, HashList} ->
                    maps:put(Variable, Cid, maps:put(ipfs_add_result, HashList, Context0));
                {error, Reason} ->
                    maps:put(
                        fail,
                        damage_utils:strf("Inline Dockerfile IPFS publication failed: ~p", [Reason]),
                        Context0
                    )
            end
    end.

%% Keep inline input bounded. Body is a rendered Gherkin docstring, not a path.
inline_dockerfile_bytes(Body) when is_binary(Body) ->
    validate_inline_dockerfile(Body);
inline_dockerfile_bytes(Body) when is_list(Body) ->
    try validate_inline_dockerfile(iolist_to_binary(Body))
    catch error:badarg -> {error, invalid_body} end;
inline_dockerfile_bytes(_) ->
    {error, invalid_body}.

%% Strict RFC 4648 padded base64, optionally wrapped over multiple lines.
%% Bound encoded length before normalising/decoding to prevent oversized input.
inline_base64_dockerfile_bytes(Body) when is_binary(Body) ->
    decode_inline_base64_dockerfile(Body);
inline_base64_dockerfile_bytes(Body) when is_list(Body) ->
    try decode_inline_base64_dockerfile(iolist_to_binary(Body))
    catch error:badarg -> {error, invalid_body} end;
inline_base64_dockerfile_bytes(_) ->
    {error, invalid_body}.

decode_inline_base64_dockerfile(<<>>) ->
    {error, empty_body};
decode_inline_base64_dockerfile(Bytes)
    when byte_size(Bytes) > ?MAX_BASE64_DOCSTRING_BYTES ->
    {error, too_large};
decode_inline_base64_dockerfile(Bytes) ->
    %% Gherkin implementations differ in docstring line joining/indentation.
    %% Remove ASCII whitespace only; reject any other non-base64 input.
    Encoded = lists:foldl(
        fun(Whitespace, Data) -> binary:replace(Data, Whitespace, <<>>, [global]) end,
        Bytes,
        [<<"\n">>, <<"\r">>, <<"\t">>, <<" ">>]
    ),
    case byte_size(Encoded) of
        0 -> {error, empty_body};
        N when N > ?MAX_BASE64_DOCKERFILE_BYTES -> {error, too_large};
        _ ->
            Pattern = <<"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$">>,
            case re:run(Encoded, Pattern, [{capture, none}]) of
                match ->
                    try validate_inline_dockerfile(base64:decode(Encoded))
                    catch error:_ -> {error, invalid_base64} end;
                nomatch -> {error, invalid_base64}
            end
    end.

validate_inline_dockerfile(<<>>) ->
    {error, empty_body};
validate_inline_dockerfile(Bytes) when byte_size(Bytes) > ?MAX_INLINE_DOCKERFILE_BYTES ->
    {error, too_large};
validate_inline_dockerfile(Bytes) ->
    case binary:match(Bytes, <<0>>) of
        nomatch -> {ok, Bytes};
        _ -> {error, nul_byte}
    end.

%% Use an unguessable, exclusive file under the trusted run directory. The
%% Dockerfile is retained in IPFS, never in the run directory after this step.
publish_inline_dockerfile(RunDir, Bytes) ->
    case filelib:is_dir(RunDir) of
        false -> {error, run_dir_missing};
        true ->
            Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
            Temp = filename:join(RunDir, "inline-dockerfile-" ++ Suffix ++ ".Dockerfile"),
            case file:open(Temp, [write, exclusive, binary]) of
                {error, OpenError} -> {error, {open_failed, OpenError}};
                {ok, File} ->
                    try
                        case write_inline_file(File, Temp, Bytes) of
                            ok ->
                                case add_path_to_ipfs(Temp) of
                                    {ok, HashList} ->
                                        case pick_root_hash(HashList, root_name_for_path(Temp)) of
                                            {ok, Cid} -> {ok, Cid, HashList};
                                            {error, PickError} -> {error, {missing_ipfs_root_cid, PickError}}
                                        end;
                                    {error, AddError} -> {error, {ipfs_add_failed, AddError}}
                                end;
                            {error, WriteError} -> {error, {write_failed, WriteError}}
                        end
                    after
                        _ = file:delete(Temp)
                    end
            end
    end.

write_inline_file(File, Temp, Bytes) ->
    ModeResult = file:change_mode(Temp, 8#600),
    WriteResult = case ModeResult of
        ok -> file:write(File, Bytes);
        {error, _} = Error -> Error
    end,
    CloseResult = file:close(File),
    case {WriteResult, CloseResult} of
        {ok, ok} -> ok;
        {{error, Reason}, _} -> {error, Reason};
        {ok, {error, Reason}} -> {error, Reason}
    end.


-ifdef(TEST).
inline_dockerfile_validation_test() ->
    ?assertEqual({ok, <<"FROM scratch\n">>}, inline_dockerfile_bytes(<<"FROM scratch\n">>)),
    ?assertEqual({error, empty_body}, inline_dockerfile_bytes(<<>>)),
    ?assertEqual({error, nul_byte}, inline_dockerfile_bytes(<<"FROM ", 0, "scratch">>)),
    ?assertEqual({error, invalid_body}, inline_dockerfile_bytes(42)),
    ?assertEqual({error, too_large},
        inline_dockerfile_bytes(binary:copy(<<"a">>, ?MAX_INLINE_DOCKERFILE_BYTES + 1))),
    ?assertEqual({error, too_large},
        inline_dockerfile_bytes([binary:copy(<<"a">>, ?MAX_INLINE_DOCKERFILE_BYTES + 1)])),
    ?assertEqual({error, run_dir_missing},
        publish_inline_dockerfile("/does/not/exist/damagebdd-inline", <<"FROM scratch">>)).

inline_base64_dockerfile_test() ->
    Expected = <<"FROM scratch\n">>,
    Encoded = base64:encode(Expected),
    ?assertEqual({ok, Expected}, inline_base64_dockerfile_bytes(Encoded)),
    ?assertEqual({ok, Expected},
        inline_base64_dockerfile_bytes(<<"RlJPTSBzY3Jh\n  dGNoCg==">>)),
    ?assertEqual({error, empty_body}, inline_base64_dockerfile_bytes(<<>>)),
    ?assertEqual({error, invalid_body}, inline_base64_dockerfile_bytes(42)),
    ?assertEqual({error, invalid_base64}, inline_base64_dockerfile_bytes(<<"not base64!">>)),
    ?assertEqual({error, invalid_base64}, inline_base64_dockerfile_bytes(<<"RlJPTSBzY3JhdGNoCg=">>)),
    ?assertEqual({error, too_large},
        inline_base64_dockerfile_bytes(binary:copy(<<"A">>, ?MAX_BASE64_DOCSTRING_BYTES + 1))),
    ?assertEqual({error, too_large},
        inline_base64_dockerfile_bytes(binary:copy(<<"A">>, ?MAX_BASE64_DOCKERFILE_BYTES))).
-endif.

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
