-module(ecai_image_renderer).

-export([render/3, seed/2]).

render(JobId, ImageSpec, Opts) when is_map(ImageSpec), is_map(Opts) ->
    Backend = maps:get(
        backend,
        Opts,
        application:get_env(ecai, content_image_backend, a1111)
    ),
    Prompt = ecai_content_util:to_binary(ecai_content_util:mget(<<"prompt">>, ImageSpec, <<>>)),
    Negative = ecai_content_util:to_binary(
        ecai_content_util:mget(<<"negative_prompt">>, ImageSpec, <<>>)
    ),
    Width = int_value(ecai_content_util:mget(<<"width">>, ImageSpec, 1200), 1200),
    Height = int_value(ecai_content_util:mget(<<"height">>, ImageSpec, 627), 627),
    Seed = seed(JobId, Prompt),
    case Backend of
        a1111 -> render_a1111(JobId, Prompt, Negative, Width, Height, Seed, Opts);
        openai_compatible -> render_openai(JobId, Prompt, Width, Height, Seed, Opts);
        Other -> {error, {unsupported_image_backend, Other}}
    end.

seed(JobId, Prompt) ->
    <<I:64/unsigned-big, _/binary>> = crypto:hash(
        sha256,
        <<(ecai_content_util:to_binary(JobId))/binary, 0, Prompt/binary>>
    ),
    I band 16#7fffffff.

render_a1111(JobId, Prompt, Negative, Width, Height, Seed, Opts) ->
    Host = maps:get(host, Opts, application:get_env(ecai, content_image_host, "127.0.0.1")),
    Port = maps:get(port, Opts, application:get_env(ecai, content_image_port, 7860)),
    Path = maps:get(path, Opts, application:get_env(ecai, content_image_path, "/sdapi/v1/txt2img")),
    Tls = maps:get(tls, Opts, application:get_env(ecai, content_image_tls, false)),
    Steps = maps:get(steps, Opts, application:get_env(ecai, content_image_steps, 28)),
    Cfg = maps:get(cfg_scale, Opts, application:get_env(ecai, content_image_cfg_scale, 6.5)),
    Body = jsx:encode(#{
        <<"prompt">> => Prompt,
        <<"negative_prompt">> => Negative,
        <<"width">> => Width,
        <<"height">> => Height,
        <<"seed">> => Seed,
        <<"steps">> => Steps,
        <<"cfg_scale">> => Cfg,
        <<"batch_size">> => 1,
        <<"n_iter">> => 1
    }),
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    GunOpts0 = #{
        transport => Transport,
        proxy => direct,
        protocols => [http],
        connect_timeout => 10000,
        timeout => 300000,
        close => true,
        decode => json
    },
    GunOpts =
        case Transport of
            tls -> GunOpts0#{tls_opts => damage_gun:tls_opts(Host)};
            tcp -> GunOpts0
        end,
    case
        damage_gun:post(
            Host,
            Port,
            Path,
            [{<<"content-type">>, <<"application/json">>}],
            Body,
            GunOpts
        )
    of
        {ok, #{status := Status, json := Json}} when Status >= 200, Status < 300 ->
            Images = ecai_content_util:mget(<<"images">>, Json, []),
            case Images of
                [First | _] -> persist_image(JobId, First, Seed, Width, Height, a1111);
                _ -> {error, {image_backend_missing_image, Json}}
            end;
        {ok, Resp} ->
            {error,
                {image_backend_http_error, maps:get(status, Resp, undefined),
                    maps:get(body, Resp, <<>>)}};
        {error, _} = Error ->
            Error
    end.

render_openai(JobId, Prompt, Width, Height, Seed, Opts) ->
    Url = maps:get(
        url,
        Opts,
        application:get_env(ecai, content_image_url, "http://127.0.0.1:8080/v1/images/generations")
    ),
    Model = maps:get(
        model, Opts, application:get_env(ecai, content_image_model, "local-image-model")
    ),
    case ecai_content_util:endpoint(Url) of
        {ok, Ep} ->
            Size = iolist_to_binary([integer_to_binary(Width), <<"x">>, integer_to_binary(Height)]),
            Body = jsx:encode(#{
                <<"model">> => ecai_content_util:to_binary(Model),
                <<"prompt">> => Prompt,
                <<"size">> => Size,
                <<"response_format">> => <<"b64_json">>,
                <<"seed">> => Seed,
                <<"n">> => 1
            }),
            Headers = [{<<"content-type">>, <<"application/json">>}],
            H = maps:get(host, Ep),
            P = maps:get(port, Ep),
            Path = maps:get(path, Ep),
            case
                damage_gun:post(
                    H,
                    P,
                    Path,
                    Headers,
                    Body,
                    ecai_content_util:http_opts(Ep, 300000, json)
                )
            of
                {ok, #{status := Status, json := Json}} when Status >= 200, Status < 300 ->
                    Data = ecai_content_util:mget(<<"data">>, Json, []),
                    case Data of
                        [First | _] when is_map(First) ->
                            B64 = ecai_content_util:mget(<<"b64_json">>, First, undefined),
                            case B64 of
                                undefined ->
                                    {error, {image_backend_missing_b64_json, Json}};
                                _ ->
                                    persist_image(
                                        JobId, B64, Seed, Width, Height, openai_compatible
                                    )
                            end;
                        _ ->
                            {error, {image_backend_missing_data, Json}}
                    end;
                {ok, Resp} ->
                    {error,
                        {image_backend_http_error, maps:get(status, Resp, undefined),
                            maps:get(body, Resp, <<>>)}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

persist_image(JobId, B64_0, Seed, Width, Height, Backend) ->
    B64 = strip_data_uri(ecai_content_util:to_binary(B64_0)),
    try base64:decode(B64) of
        Bytes ->
            case detect_image(Bytes) of
                {ok, Mime, Ext} ->
                    {ok, Path} = ecai_content_store:artifact_path(JobId, <<"image.", Ext/binary>>),
                    case ecai_content_util:atomic_write(Path, Bytes) of
                        ok ->
                            {ok, #{
                                path => ecai_content_util:to_binary(Path),
                                mime_type => Mime,
                                sha256 => ecai_content_util:sha256_hex(Bytes),
                                seed => Seed,
                                width => Width,
                                height => Height,
                                backend => Backend
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    catch
        Class:Reason -> {error, {invalid_base64_image, Class, Reason}}
    end.

strip_data_uri(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<",">>) of
        [_Meta, Data] -> Data;
        _ -> Rest
    end;
strip_data_uri(Bin) ->
    Bin.

detect_image(<<16#89, "PNG", 16#0d, 16#0a, 16#1a, 16#0a, _/binary>>) ->
    {ok, <<"image/png">>, <<"png">>};
detect_image(<<16#ff, 16#d8, 16#ff, _/binary>>) ->
    {ok, <<"image/jpeg">>, <<"jpg">>};
detect_image(_) ->
    {error, unsupported_generated_image_format}.

int_value(I, _Default) when is_integer(I) -> I;
int_value(_, Default) -> Default.
