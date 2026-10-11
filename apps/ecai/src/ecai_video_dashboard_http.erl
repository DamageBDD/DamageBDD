%%--------------------------------------------------------------------
%% Account-scoped same-origin gateway for the optional ECAI Video Fastpath.
%% No customer credential or service token is ever returned to the browser.
%% Deploy the matching Fastpath bridge-auth update and configure the same
%% ECAI_VIDEO_BRIDGE_SECRET on both processes before enabling this endpoint.
%%--------------------------------------------------------------------
-module(ecai_video_dashboard_http).
-export([trails/0, init/2, tenant_for/1, bridge_token/5, route/3]).

-define(JSON_MAX, 32768).
-define(MEDIA_MAX, 25 * 1024 * 1024).
-define(TAGS, ["ECAI Video"]).

trails() ->
    [
        trail("/ecai/video/status", status, get),
        trail("/ecai/video/backends", backends, both),
        trail("/ecai/video/backend-connection-policy", connection_policy, get),
        trail("/ecai/video/projects", projects, both),
        trail("/ecai/video/projects/:project/versions", versions, both),
        trail("/ecai/video/projects/:project/generations", generate, post),
        trail("/ecai/video/projects/:project/assets", upload, post),
        trail("/ecai/video/projects/:project/jobs", project_jobs, get),
        trail("/ecai/video/projects/:project/graph", graph, get),
        trail("/ecai/video/projects/:project/value", value, get),
        trail("/ecai/video/jobs/:id", job, get),
        trail("/ecai/video/jobs/:id/retry", retry, post),
        trail("/ecai/video/versions/:id", version, get),
        trail("/ecai/video/versions/:id/verify", verify, get),
        trail("/ecai/video/versions/:id/manifest", manifest, get),
        trail("/ecai/video/versions/:id/video", video, get),
        trail("/ecai/video/versions/:id/nft-draft", nft_draft, post)
    ].

trail(Path, Action, Allowed) ->
    Get = #{get => #{tags => ?TAGS, produces => ["application/json"]}},
    Post = #{post => #{tags => ?TAGS, produces => ["application/json"]}},
    Meta = case Allowed of get -> Get; post -> Post; both -> maps:merge(Get, Post) end,
    trails:trail(Path, ?MODULE, #{action => Action}, Meta).

init(Req0, #{action := Action} = State) ->
    process_flag(sensitive, true),
    Method = cowboy_req:method(Req0),
    case Action of
        status when Method =:= <<"GET">> ->
            {Enabled, Reason} = case settings() of
                {ok, _, _} -> {true, <<"ready">>};
                {error, Why} -> {false, Why}
            end,
            response(Req0, 200, #{enabled => Enabled, status => Reason}, State);
        status -> response(Req0, 405, #{error => method_not_allowed}, State);
        _ ->
            handle_request(Req0, State, Action, Method)
    end.

handle_request(Req, State, Action, Method) ->
    case route(Action, Method, Req) of
        {error, Reason} -> response(Req, 405, #{error => Reason}, State);
        {ok, Path, Kind} ->
            case settings() of
                {error, Why} -> response(Req, 503, #{error => Why}, State);
                {ok, Base, Secret} ->
                    case actor(Req, Method) of
                        {error, Error} -> response(Req, 403, #{error => Error}, State);
                        {ok, Principal} ->
                            proxy_request(Req, State, Method, Kind, Base, Secret, Principal, Path)
                    end
            end
    end.

%% Construct upstream paths only from fixed route components and hex IDs.
%% Never accept a URL or upstream path supplied by the browser.
route(backends, M, _) when M =:= <<"GET">>; M =:= <<"POST">> ->
    {ok, <<"/v1/backends">>, json};
route(connection_policy, <<"GET">>, _) -> {ok, <<"/v1/backend-connection-policy">>, json};
route(projects, M, _) when M =:= <<"GET">>; M =:= <<"POST">> ->
    {ok, <<"/v1/projects">>, json};
route(Action, Method, Req) when Action =:= versions; Action =:= generate;
                                 Action =:= upload; Action =:= graph; Action =:= value;
                                 Action =:= project_jobs ->
    Project = cowboy_req:binding(project, Req),
    Valid = case Action of
        versions -> Method =:= <<"GET">> orelse Method =:= <<"POST">>;
        graph -> Method =:= <<"GET">>;
        project_jobs -> Method =:= <<"GET">>;
        value -> Method =:= <<"GET">>;
        _ -> Method =:= <<"POST">>
    end,
    case valid_id(Project) andalso Valid of
        true ->
            Segment = case Action of
                versions -> <<"versions">>;
                generate -> <<"generations">>;
                upload -> <<"assets">>;
                graph -> <<"graph">>;
                project_jobs -> <<"jobs">>;
                value -> <<"value">>
            end,
            {ok, <<"/v1/projects/", Project/binary, "/", Segment/binary>>,
                case Action of upload -> media; _ -> json end};
        false -> {error, invalid_project_or_method}
    end;
route(Action, Method, Req) when Action =:= job; Action =:= retry;
                                 Action =:= version; Action =:= verify;
                                 Action =:= manifest; Action =:= video;
                                 Action =:= nft_draft ->
    Id = cowboy_req:binding(id, Req),
    Allowed = case Action of retry -> <<"POST">>; nft_draft -> <<"POST">>; _ -> <<"GET">> end,
    case valid_id(Id) andalso Method =:= Allowed of
        true ->
            {Path, Kind} = case Action of
                job -> {<<"/v1/jobs/", Id/binary>>, json};
                retry -> {<<"/v1/jobs/", Id/binary, "/retry">>, json};
                version -> {<<"/v1/versions/", Id/binary>>, json};
                verify -> {<<"/v1/versions/", Id/binary, "/verify">>, json};
                manifest -> {<<"/v1/versions/", Id/binary, "/manifest">>, json};
                video -> {<<"/v1/versions/", Id/binary, "/video">>, binary_video};
                nft_draft -> {<<"/v1/versions/", Id/binary, "/nft-draft">>, json}
            end,
            {ok, Path, Kind};
        false -> {error, invalid_identifier_or_method}
    end;
route(_, _, _) -> {error, method_not_allowed}.

valid_id(B) when is_binary(B), byte_size(B) =:= 32 ->
    re:run(B, <<"^[0-9a-f]{32}$">>, [{capture, none}]) =:= match;
valid_id(_) -> false.

%% Writes require an EXPLICIT validated bearer; cookies alone never authorize
%% generation, provider setup or other mutations. Wallet sessions are read-only.
actor(Req, Method) ->
    Auth = case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 10,
                                         byte_size(Token) =< 8192 ->
            damage_auth:resolve_oauth(Token, #{});
        _ when Method =:= <<"GET">> -> damage_auth:authenticate(Req, #{});
        _ -> {error, bearer_required}
    end,
    case Auth of
        {ok, Context} when is_map(Context) ->
            case {maps:get(auth_mode, Context, undefined), damage_auth:authenticated_account(Context)} of
                {custodial, {ok, Principal}} when is_binary(Principal), byte_size(Principal) > 0 ->
                    {ok, Principal};
                _ -> {error, authenticated_account_required}
            end;
        _ -> {error, managed_session_required}
    end.

%% The public key is a stable account ID; a hash prevents leaking account keys
%% through sidecar tenant storage layout and avoids unsafe path characters.
tenant_for(Principal) when is_binary(Principal), byte_size(Principal) > 0 ->
    Digest = lower_hex(crypto:hash(sha256, Principal)),
    <<"ecai_", (binary:part(Digest, 0, 40))/binary>>.

%% Exact same message framing as ecai_video_fastpath.bridge_auth.message().
bridge_token(Secret, Principal, Timestamp, Method, Path) ->
    Tenant = tenant_for(Principal),
    Message = <<Tenant/binary, "\n", Timestamp/binary, "\n", Method/binary, "\n", Path/binary>>,
    Signature = lower_hex(crypto:mac(hmac, sha256, Secret, Message)),
    <<"bridge1.", Tenant/binary, ".", Timestamp/binary, ".", Signature/binary>>.

lower_hex(Bytes) ->
    %% binary:encode_hex/1 may default to uppercase; Python uses hexdigest().
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).

settings() ->
    case os:getenv("ECAI_VIDEO_BRIDGE_SECRET") of
        Secret when is_list(Secret), length(Secret) >= 32 ->
            Url0 = case os:getenv("ECAI_VIDEO_URL") of
                false -> "http://127.0.0.1:9011";
                U -> U
            end,
            Url = string:trim(Url0, trailing, "/"),
            Allowed = lists:prefix("http://127.0.0.1:", Url) orelse
                      lists:prefix("http://localhost:", Url) orelse
                      lists:prefix("https://", Url),
            case Allowed andalso not lists:member($?, Url) andalso
                 not lists:member($#, Url) of
                true -> {ok, Url, unicode:characters_to_binary(Secret)};
                false -> {error, video_backend_url_invalid}
            end;
        _ -> {error, video_bridge_not_configured}
    end.

proxy_request(Req0, State, Method, Kind, Base, Secret, Principal, Path) ->
    IsPost = Method =:= <<"POST">>,
    case read_payload(Req0, IsPost, Kind) of
        {error, Code, Why, Req1} -> response(Req1, Code, #{error => Why}, State);
        {ok, Payload, CType, Req1} ->
            Stamp = integer_to_binary(erlang:system_time(second)),
            AuthToken = bridge_token(Secret, Principal, Stamp, Method, Path),
            Uri = Base ++ binary_to_list(Path),
            case upstream(Uri, AuthToken, Method, Payload, CType) of
                {ok, Status, Body, _Headers} when Kind =:= binary_video, Status >= 200, Status < 300 ->
                    case byte_size(Body) =< ?MEDIA_MAX of
                        true -> reply_bytes(Req1, Status, Body, State);
                        false -> response(Req1, 413, #{error => preview_limit_25_mib}, State)
                    end;
                {ok, Status, Body, _Headers} when Status >= 200, Status < 300 ->
                    %% Upstream must actually return JSON, not raw HTML errors.
                    case is_json(Body) of
                        true -> reply_json(Req1, Status, Body, State);
                        false -> response(Req1, 502, #{error => invalid_video_service_response}, State)
                    end;
                {ok, Status, Body, _} ->
                    Code = case Status >= 400 andalso Status < 500 of true -> Status; false -> 502 end,
                    Detail = case is_json(Body) andalso byte_size(Body) =< 8192 of
                        true -> jsx:decode(Body, [return_maps]);
                        false -> #{detail => <<"Video service rejected this operation">>}
                    end,
                    response(Req1, Code, #{error => video_service_error, detail => Detail}, State);
                {error, _} -> response(Req1, 503, #{error => video_service_unavailable}, State)
            end
    end.

read_payload(Req, false, _Kind) -> {ok, <<>>, <<"application/json">>, Req};
read_payload(Req, true, media) ->
    case cowboy_req:header(<<"content-type">>, Req, <<>>) of
        <<"video/mp4">> ->
            case read_all(Req, [], 0, ?MEDIA_MAX, erlang:monotonic_time(millisecond) + 60000) of
                {ok, MP4, Req1} when byte_size(MP4) > 0 ->
                    Boundary = <<"ecai", (binary:encode_hex(crypto:strong_rand_bytes(12)))/binary>>,
                    Multipart = iolist_to_binary([
                        <<"--">>, Boundary, <<"\r\nContent-Disposition: form-data; name=\"file\"; filename=\"video.mp4\"\r\n">>,
                        <<"Content-Type: video/mp4\r\n\r\n">>, MP4,
                        <<"\r\n--">>, Boundary, <<"--\r\n">>
                    ]),
                    {ok, Multipart, <<"multipart/form-data; boundary=", Boundary/binary>>, Req1};
                {ok, _, Req1} -> {error, 422, empty_video, Req1};
                {error, Req1} -> {error, 413, media_limit_or_timeout, Req1}
            end;
        _ -> {error, 415, mp4_required, Req}
    end;
read_payload(Req, true, json) ->
    case cowboy_req:header(<<"content-type">>, Req, <<>>) of
        <<"application/json", _/binary>> ->
            case read_all(Req, [], 0, ?JSON_MAX, erlang:monotonic_time(millisecond) + 15000) of
                {ok, Data, Req1} ->
                    case is_json_object(Data) of
                        true -> {ok, Data, <<"application/json">>, Req1};
                        false -> {error, 400, json_object_required, Req1}
                    end;
                {error, Req1} -> {error, 413, payload_limit_or_timeout, Req1}
            end;
        _ -> {error, 415, json_required, Req}
    end.

is_json_object(Data) ->
    try is_map(jsx:decode(Data, [return_maps])) catch _:_ -> false end.
is_json(Data) ->
    try
        _ = jsx:decode(Data, [return_maps]), true
    catch _:_ -> false end.

read_all(Req, Parts, Size, Limit, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, Req};
        true ->
            case cowboy_req:read_body(Req, #{length => 65536, period => min(5000, Remaining)}) of
                {Tag, Chunk, Req1} when Tag =:= ok; Tag =:= more ->
                    NewSize = Size + byte_size(Chunk),
                    case NewSize > Limit of
                        true -> {error, Req1};
                        false when Tag =:= ok -> {ok, iolist_to_binary(lists:reverse([Chunk | Parts])), Req1};
                        false -> read_all(Req1, [Chunk | Parts], NewSize, Limit, Deadline)
                    end
            end
    end.

upstream(Uri, Token, Method, Body, CType) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)}, {"accept", "application/json"}],
    Request = case Method of
        <<"GET">> -> {Uri, Headers};
        <<"POST">> -> {Uri, Headers, binary_to_list(CType), Body}
    end,
    Ssl = case lists:prefix("https://", Uri) of
        true -> [{ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]}];
        false -> []
    end,
    Verb = case Method of <<"GET">> -> get; <<"POST">> -> post end,
    case httpc:request(Verb, Request, [{timeout, 120000}, {autoredirect, false} | Ssl], [{body_format, binary}]) of
        {ok, {{_, Code, _}, RespHeaders, RespBody}} -> {ok, Code, RespBody, RespHeaders};
        {error, Reason} -> {error, Reason}
    end.

headers(ContentType) -> #{
    <<"content-type">> => ContentType,
    <<"cache-control">> => <<"private, no-store">>,
    <<"pragma">> => <<"no-cache">>,
    <<"x-content-type-options">> => <<"nosniff">>
}.
response(Req, Code, Payload, State) ->
    reply_json(Req, Code, jsx:encode(Payload), State).
reply_json(Req, Code, Body, State) ->
    R = cowboy_req:reply(Code, headers(<<"application/json; charset=utf-8">>), Body, Req),
    {ok, R, State}.
reply_bytes(Req, Code, Body, State) ->
    R = cowboy_req:reply(Code, maps:put(<<"content-disposition">>, <<"inline">>,
        headers(<<"video/mp4">>)), Body, Req),
    {ok, R, State}.
