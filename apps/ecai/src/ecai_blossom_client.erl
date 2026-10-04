-module(ecai_blossom_client).

-export([upload/1, upload/2, default_server/0]).

-define(DEFAULT_SERVER, "https://media.damagebdd.com").

default_server() -> application:get_env(ecai, content_blossom_server, ?DEFAULT_SERVER).

upload(Path) -> upload(Path, #{}).

upload(Path0, Opts) when is_map(Opts) ->
    Path = ecai_content_util:to_list(Path0),
    case file:read_file(Path) of
        {ok, Bytes} ->
            Mime = maps:get(mime_type, Opts, mime_type(Path, Bytes)),
            Sha = ecai_content_util:sha256_hex(Bytes),
            Server = maps:get(server, Opts, default_server()),
            case ecai_content_util:endpoint(Server) of
                {ok, Ep0} ->
                    Ep = Ep0#{path => <<"/upload">>},
                    case auth_header(Sha, Ep, Opts) of
                        {ok, Auth} -> do_upload(Bytes, Sha, Mime, Ep, Auth);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {cannot_read_blossom_upload, Path, Reason}}
    end.

auth_header(Sha, Ep, Opts) ->
    Now = erlang:system_time(second),
    Expiry =
        Now +
            maps:get(
                auth_ttl_seconds,
                Opts,
                application:get_env(ecai, content_blossom_auth_ttl_seconds, 300)
            ),
    Host = maps:get(host, Ep),
    Event = #{
        kind => 24242,
        created_at => Now,
        content => <<"Authorize ECAI publication media upload">>,
        tags => [
            [<<"t">>, <<"upload">>],
            [<<"x">>, Sha],
            [<<"expiration">>, integer_to_binary(Expiry)],
            [<<"server">>, Host]
        ]
    },
    case ecai_nostr_signer:sign_event(Event, maps:get(signer, Opts, #{})) of
        {ok, Signed} ->
            {ok,
                <<"Nostr ",
                    (base64:encode(jsx:encode(ecai_content_util:json_safe(Signed))))/binary>>};
        {error, _} = Error ->
            Error
    end.

do_upload(Bytes, Sha, Mime0, Ep, Auth) ->
    Mime = ecai_content_util:to_binary(Mime0),
    Headers = [
        {<<"authorization">>, Auth},
        {<<"content-type">>, Mime},
        {<<"content-length">>, integer_to_binary(byte_size(Bytes))},
        {<<"x-sha-256">>, Sha},
        {<<"accept">>, <<"application/json">>}
    ],
    Host = maps:get(host, Ep),
    Port = maps:get(port, Ep),
    Path = maps:get(path, Ep),
    case
        damage_gun:put(
            Host,
            Port,
            Path,
            Headers,
            Bytes,
            ecai_content_util:http_opts(Ep, 120000, json)
        )
    of
        {ok, #{status := Status, json := Json}} when Status =:= 200; Status =:= 201 ->
            verify_descriptor(Json, Sha);
        {ok, Resp} ->
            {error,
                {blossom_upload_failed, maps:get(status, Resp, undefined),
                    maps:get(body, Resp, <<>>)}};
        {error, _} = Error ->
            Error
    end.

verify_descriptor(Json, Sha) when is_map(Json) ->
    Url = ecai_content_util:to_binary(ecai_content_util:mget(<<"url">>, Json, <<>>)),
    ReturnedSha = ecai_content_util:to_binary(ecai_content_util:mget(<<"sha256">>, Json, Sha)),
    case {Url, ReturnedSha =:= Sha} of
        {<<>>, _} ->
            {error, {blossom_missing_url, Json}};
        {_, false} ->
            {error, {blossom_sha_mismatch, Sha, ReturnedSha}};
        _ ->
            {ok, #{
                url => Url,
                sha256 => Sha,
                size => ecai_content_util:mget(<<"size">>, Json, undefined),
                type => ecai_content_util:mget(<<"type">>, Json, undefined),
                descriptor => Json
            }}
    end;
verify_descriptor(Other, _Sha) ->
    {error, {invalid_blossom_descriptor, Other}}.

mime_type(Path, Bytes) ->
    Ext = string:lowercase(filename:extension(Path)),
    case {Ext, Bytes} of
        {".png", _} -> <<"image/png">>;
        {".jpg", _} -> <<"image/jpeg">>;
        {".jpeg", _} -> <<"image/jpeg">>;
        {_, <<16#89, "PNG", _/binary>>} -> <<"image/png">>;
        {_, <<16#ff, 16#d8, 16#ff, _/binary>>} -> <<"image/jpeg">>;
        _ -> <<"application/octet-stream">>
    end.
