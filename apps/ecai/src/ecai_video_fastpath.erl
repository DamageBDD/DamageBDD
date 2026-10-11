%%%-------------------------------------------------------------------
%%% ECAI Video Fastpath bridge (optional sidecar integration).
%%%
%%% Small, self-contained adapter for the Python fast-path video service.
%%% No ECAI supervisor/routing changes; call from an authenticated ECAI
%%% handler, an operator shell, or a DamageBDD step as needed.
%%%
%%% Configure:
%%%   ECAI_VIDEO_URL=http://127.0.0.1:9011
%%%   ECAI_VIDEO_TOKEN=<tenant bearer key>
%%%
%%% This module never accepts caller-controlled upstream HTTP hostnames;
%%% those are managed by the Fastpath server with an explicit host policy.
%%%-------------------------------------------------------------------
-module(ecai_video_fastpath).
-include_lib("kernel/include/file.hrl").

-export([
    projects/0, create_project/3, backends/0,
    connect_backend/1, generate/3, job/1, retry/1,
    upload_mp4/2, versions/1, revise/4,
    version/1, verify/1, manifest/1, graph/1, value/1,
    nft_draft/2, demo/0
]).

-type result() :: {ok, map() | list()} | {error, term()}.

-spec projects() -> result().
projects() -> request(get, "/v1/projects", undefined).

-spec create_project(binary(), binary(), [binary()]) -> result().
create_project(Title, License, Tags) ->
    request(post, "/v1/projects", #{title => Title, license => License, tags => Tags}).

-spec backends() -> result().
backends() -> request(get, "/v1/backends", undefined).

-spec connect_backend(map()) -> result().
connect_backend(Config) when is_map(Config) ->
    %% Credentials are sent only over the configured localhost/TLS sidecar
    %% connection and are encrypted by the sidecar, not stored in this module.
    request(post, "/v1/backends", Config).

-spec generate(binary(), binary(), binary()) -> result().
generate(ProjectId, BackendId, Prompt) when is_binary(BackendId), is_binary(Prompt) ->
    path_request(post, ["/v1/projects/", ProjectId, "/generations"],
                 #{backend_id => BackendId, prompt => Prompt}).

-spec job(binary()) -> result().
job(JobId) -> path_request(get, ["/v1/jobs/", JobId], undefined).

-spec retry(binary()) -> result().
retry(JobId) -> path_request(post, ["/v1/jobs/", JobId, "/retry"], #{}).

-spec versions(binary()) -> result().
versions(ProjectId) -> path_request(get, ["/v1/projects/", ProjectId, "/versions"], undefined).

-spec revise(binary(), binary(), binary(), map()) -> result().
revise(ProjectId, ParentVersionId, Operation, Opts)
  when is_binary(Operation), is_map(Opts) ->
    case valid_id(ParentVersionId) of
        true ->
            path_request(post, ["/v1/projects/", ProjectId, "/versions"],
                         #{parent_version_id => ParentVersionId,
                           operation => Operation, options => Opts});
        false -> {error, invalid_version_id}
    end.

-spec version(binary()) -> result().
version(Id) -> path_request(get, ["/v1/versions/", Id], undefined).

-spec verify(binary()) -> result().
verify(Id) -> path_request(get, ["/v1/versions/", Id, "/verify"], undefined).

-spec manifest(binary()) -> result().
manifest(Id) -> path_request(get, ["/v1/versions/", Id, "/manifest"], undefined).

-spec graph(binary()) -> result().
graph(ProjectId) -> path_request(get, ["/v1/projects/", ProjectId, "/graph"], undefined).

-spec value(binary()) -> result().
value(ProjectId) -> path_request(get, ["/v1/projects/", ProjectId, "/value"], undefined).

-spec nft_draft(binary(), binary()) -> result().
nft_draft(Id, VideoCid) when is_binary(VideoCid) ->
    path_request(post, ["/v1/versions/", Id, "/nft-draft"], #{video_cid => VideoCid}).

%% Small MP4 only: the bridge caps memory usage at 25MB. Larger assets should
%% be uploaded via /studio or streamed via a dedicated ingestion gateway.
-spec upload_mp4(binary(), file:filename_all()) -> result().
upload_mp4(ProjectId, Path) ->
    case valid_id(ProjectId) of
        false -> {error, invalid_project_id};
        true ->
            case file:read_file_info(Path) of
                {ok, #file_info{size = Size}} when Size =< 25 * 1024 * 1024 ->
                    case file:read_file(Path) of
                        {ok, Data} -> multipart(ProjectId, Data);
                        Error -> Error
                    end;
                {ok, _} -> {error, upload_too_large_for_erlang_bridge};
                Error -> Error
            end
    end.

multipart(ProjectId, MP4) ->
    case settings() of
        {ok, Base, Token} ->
            Boundary = "ecai" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
            Content = iolist_to_binary([
                "--", Boundary, "\r\n",
                "Content-Disposition: form-data; name=\"file\"; filename=\"video.mp4\"\r\n",
                "Content-Type: video/mp4\r\n\r\n", MP4, "\r\n--", Boundary, "--\r\n"
            ]),
            Uri = Base ++ "/v1/projects/" ++ binary_to_list(ProjectId) ++ "/assets",
            CType = "multipart/form-data; boundary=" ++ Boundary,
            send(post, Uri, Token, Content, CType);
        Error -> Error
    end.

path_request(Method, Parts, Body) ->
    Ids = [Part || Part <- Parts, is_binary(Part)],
    case lists:all(fun valid_id/1, Ids) of
        true -> request(Method, lists:flatten([part(P) || P <- Parts]), Body);
        false -> {error, invalid_identifier}
    end.

part(B) when is_binary(B) -> binary_to_list(B);
part(L) when is_list(L) -> L.

valid_id(B) when is_binary(B), byte_size(B) == 32 ->
    re:run(B, <<"^[0-9a-f]{32}$">>, [{capture, none}]) =:= match;
valid_id(_) -> false.

request(Method, Path, Body) ->
    case settings() of
        {ok, Base, Token} ->
            Data = case Body of undefined -> <<>>; _ -> jsx:encode(Body) end,
            send(Method, Base ++ Path, Token, Data, "application/json");
        Error -> Error
    end.

settings() ->
    case os:getenv("ECAI_VIDEO_TOKEN") of
        false -> {error, missing_ecai_video_token};
        "" -> {error, missing_ecai_video_token};
        Token ->
            Base0 = case os:getenv("ECAI_VIDEO_URL") of
                        false -> "http://127.0.0.1:9011";
                        Url -> Url
                    end,
            Base = string:trim(Base0, trailing, "/"),
            case lists:prefix("http://127.0.0.1:", Base) orelse
                 lists:prefix("http://localhost:", Base) orelse
                 lists:prefix("https://", Base) of
                true -> {ok, Base, Token};
                false -> {error, insecure_sidecar_url}
            end
    end.

send(Method, Uri, Token, Data, CType) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Headers = [{"authorization", "Bearer " ++ Token}, {"accept", "application/json"}],
    Request = case Method of
                  get -> {Uri, Headers};
                  post -> {Uri, Headers, CType, Data}
              end,
    HOpts = case lists:prefix("https://", Uri) of
                true -> [{timeout, 180000},
                         {ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]}];
                false -> [{timeout, 180000}]
            end,
    case httpc:request(Method, Request, HOpts, [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Response}} when Code >= 200, Code < 300 ->
            try jsx:decode(Response, [return_maps]) of
                Parsed -> {ok, Parsed}
            catch _:_ -> {error, invalid_sidecar_json} end;
        {ok, {{_, Code, _}, _, Response}} ->
            {error, {http_status, Code, Response}};
        {error, Reason} -> {error, Reason}
    end.

-spec demo() -> result().
demo() ->
    %% Generates a video asynchronously via the synthetic, free demo backend.
    %% A real provider requires a connection in /studio or server config.
    case create_project(<<"ECAI Fastpath Demo">>, <<"all-rights-reserved">>, [<<"demo">>]) of
        {ok, #{<<"id">> := ProjectId}} ->
            generate(ProjectId, <<"demo">>, <<"Synthetic test pattern (not AI)">>);
        Other -> Other
    end.
