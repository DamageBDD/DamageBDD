-module(ecai_linkedin_client).

-export([publish_image_post/3, initialize_image/2, upload_image/3, upload_image/4, create_post/4]).

-define(API, "https://api.linkedin.com").
-define(DEFAULT_VERSION, "202609").

publish_image_post(Pack, ImageMeta, Opts) when is_map(Pack), is_map(ImageMeta), is_map(Opts) ->
    case credentials(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Cfg} ->
            Path = ecai_content_util:to_list(maps:get(path, ImageMeta)),
            case initialize_image(Cfg, Opts) of
                {ok, #{upload_url := UploadUrl, image_urn := ImageUrn} = Init} ->
                    case upload_image(UploadUrl, Path, ImageMeta, Cfg) of
                        ok ->
                            Commentary = ecai_content_util:to_binary(
                                ecai_content_util:mget(
                                    <<"commentary">>,
                                    ecai_content_util:mget(<<"linkedin">>, Pack, #{}),
                                    <<>>
                                )
                            ),
                            AltText = ecai_content_util:to_binary(
                                ecai_content_util:mget(
                                    <<"alt_text">>,
                                    ecai_content_util:mget(<<"linkedin">>, Pack, #{}),
                                    <<>>
                                )
                            ),
                            case create_post(Cfg, Commentary, ImageUrn, AltText) of
                                {ok, Post} ->
                                    {ok, Post#{image_urn => ImageUrn, initialize => Init}};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

initialize_image(Cfg, _Opts) ->
    Body = jsx:encode(#{<<"initializeUploadRequest">> => #{<<"owner">> => maps:get(author, Cfg)}}),
    case linkedin_request(post, <<"/rest/images?action=initializeUpload">>, Body, Cfg) of
        {ok, #{status := Status, body := RespBody}} when Status >= 200, Status < 300 ->
            try jsx:decode(RespBody, [return_maps]) of
                Json ->
                    Value = ecai_content_util:mget(<<"value">>, Json, #{}),
                    Upload = ecai_content_util:to_binary(
                        ecai_content_util:mget(<<"uploadUrl">>, Value, <<>>)
                    ),
                    Urn = ecai_content_util:to_binary(
                        ecai_content_util:mget(<<"image">>, Value, <<>>)
                    ),
                    case {Upload, Urn} of
                        {<<>>, _} -> {error, {linkedin_missing_upload_url, Json}};
                        {_, <<>>} -> {error, {linkedin_missing_image_urn, Json}};
                        _ -> {ok, #{upload_url => Upload, image_urn => Urn, raw => Json}}
                    end
            catch
                Class:Reason -> {error, {linkedin_invalid_initialize_json, Class, Reason, RespBody}}
            end;
        {ok, Resp} ->
            {error,
                {linkedin_initialize_failed, maps:get(status, Resp, undefined),
                    maps:get(body, Resp, <<>>)}};
        {error, _} = Error ->
            Error
    end.

upload_image(UploadUrl, Path, ImageMeta) ->
    case credentials(#{}) of
        {ok, Cfg} -> upload_image(UploadUrl, Path, ImageMeta, Cfg);
        {error, _} = Error -> Error
    end.

upload_image(UploadUrl, Path0, ImageMeta, Cfg) ->
    Path = ecai_content_util:to_list(Path0),
    case {ecai_content_util:endpoint(UploadUrl), file:read_file(Path)} of
        {{ok, Ep}, {ok, Bytes}} ->
            Mime = ecai_content_util:to_binary(maps:get(mime_type, ImageMeta, <<"image/png">>)),
            Headers = [
                {<<"authorization">>, <<"Bearer ", (maps:get(token, Cfg))/binary>>},
                {<<"content-type">>, Mime},
                {<<"content-length">>, integer_to_binary(byte_size(Bytes))}
            ],
            case
                damage_gun:put(
                    maps:get(host, Ep),
                    maps:get(port, Ep),
                    maps:get(path, Ep),
                    Headers,
                    Bytes,
                    ecai_content_util:http_opts(Ep, 120000, raw)
                )
            of
                {ok, #{status := Status}} when Status >= 200, Status < 300 -> ok;
                {ok, Resp} ->
                    {error,
                        {linkedin_image_upload_failed, maps:get(status, Resp, undefined),
                            maps:get(body, Resp, <<>>)}};
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, Reason}} ->
            {error, {cannot_read_linkedin_image, Path, Reason}}
    end.

create_post(Cfg, Commentary, ImageUrn, AltText) ->
    Payload = #{
        <<"author">> => maps:get(author, Cfg),
        <<"commentary">> => Commentary,
        <<"visibility">> => <<"PUBLIC">>,
        <<"distribution">> => #{
            <<"feedDistribution">> => <<"MAIN_FEED">>,
            <<"targetEntities">> => [],
            <<"thirdPartyDistributionChannels">> => []
        },
        <<"content">> => #{<<"media">> => #{<<"altText">> => AltText, <<"id">> => ImageUrn}},
        <<"lifecycleState">> => <<"PUBLISHED">>,
        <<"isReshareDisabledByAuthor">> => false
    },
    case linkedin_request(post, <<"/rest/posts">>, jsx:encode(Payload), Cfg) of
        {ok, #{status := 201, headers := Headers} = Resp} ->
            PostId =
                case ecai_content_util:header(<<"x-restli-id">>, Headers) of
                    undefined -> <<>>;
                    V -> V
                end,
            {ok, #{post_urn => PostId, status => 201, response_body => maps:get(body, Resp, <<>>)}};
        {ok, #{status := Status} = Resp} when Status >= 500 ->
            {error, {linkedin_post_ambiguous, {http_status, Status, maps:get(body, Resp, <<>>)}}};
        {ok, Resp} ->
            {error,
                {linkedin_post_failed, maps:get(status, Resp, undefined),
                    maps:get(body, Resp, <<>>)}};
        {error, Reason} ->
            {error, {linkedin_post_ambiguous, Reason}}
    end.

linkedin_request(Method, Path, Body, Cfg) ->
    {ok, Ep0} = ecai_content_util:endpoint(?API),
    Ep = Ep0#{path => Path},
    Headers = [
        {<<"authorization">>, <<"Bearer ", (maps:get(token, Cfg))/binary>>},
        {<<"accept">>, <<"application/json">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"linkedin-version">>, maps:get(version, Cfg)},
        {<<"x-restli-protocol-version">>, <<"2.0.0">>},
        {<<"user-agent">>, <<"damagebdd-ecai-content/1.0">>}
    ],
    case Method of
        post ->
            damage_gun:post(
                maps:get(host, Ep),
                maps:get(port, Ep),
                maps:get(path, Ep),
                Headers,
                Body,
                ecai_content_util:http_opts(Ep, 60000, raw)
            )
    end.

credentials(Opts) ->
    Author = ecai_content_util:to_binary(
        maps:get(
            author,
            Opts,
            application:get_env(ecai, content_linkedin_author, undefined)
        )
    ),
    Version = ecai_content_util:to_binary(
        maps:get(
            version,
            Opts,
            application:get_env(ecai, content_linkedin_version, ?DEFAULT_VERSION)
        )
    ),
    Token = token(Opts),
    case {Author, Token} of
        {<<>>, _} -> {error, content_linkedin_author_not_configured};
        {_, <<>>} -> {error, content_linkedin_token_not_configured};
        _ -> {ok, #{author => Author, version => Version, token => Token}}
    end.

token(Opts) ->
    case maps:get(token, Opts, undefined) of
        undefined ->
            EnvName = ecai_content_util:to_list(
                application:get_env(
                    ecai,
                    content_linkedin_token_env,
                    "LINKEDIN_ACCESS_TOKEN"
                )
            ),
            case os:getenv(EnvName) of
                false -> <<>>;
                V -> ecai_content_util:to_binary(V)
            end;
        V ->
            ecai_content_util:to_binary(V)
    end.
