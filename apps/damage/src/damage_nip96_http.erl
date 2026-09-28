%%%-------------------------------------------------------------------
%%% NIP-96 HTTP file storage backed by the DamageBDD IPFS/Kubo service.
%%%
%%% Public identity is the original SHA-256 required by NIP-96.  IPFS CID is
%%% an internal immutable storage pointer.  No media transformations are made,
%%% therefore NIP-94 x == ox.
%%%-------------------------------------------------------------------
-module(damage_nip96_http).

-include_lib("kernel/include/logger.hrl").

-export([init/2, trails/0]).

-define(TRAILS_TAG, ["Nostr NIP-96"]).
-define(DEFAULT_MAX_BYTES, 67108864).
-define(DEFAULT_PAGE_COUNT, 20).
-define(DEFAULT_UPLOAD_TIMEOUT_MS, 120000).
-define(MAX_PAGE_COUNT, 100).
-define(MAX_FORM_FIELD_BYTES, 65536).
-define(MAX_FORM_FIELDS_BYTES, 262144).
-define(MAX_MULTIPART_PARTS, 32).
-define(READ_CHUNK_BYTES, 1048576).

trails() ->
    [
        trails:trail(
            "/.well-known/nostr/nip96.json",
            ?MODULE,
            #{action => config},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "NIP-96 file storage server capabilities.",
                    produces => ["application/json"]
                },
                options => #{tags => ?TRAILS_TAG}
            }
        ),
        trails:trail(
            "/api/nip96",
            ?MODULE,
            #{action => collection},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "List NIP-96 files owned by the authenticated Nostr pubkey.",
                    produces => ["application/json"]
                },
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Upload a file to NIP-96/IPFS storage.",
                    produces => ["application/json"]
                },
                options => #{tags => ?TRAILS_TAG}
            }
        ),
        trails:trail(
            "/api/nip96/:file",
            ?MODULE,
            #{action => object},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Download a NIP-96 file by original SHA-256.",
                    produces => ["application/octet-stream"]
                },
                delete => #{
                    tags => ?TRAILS_TAG,
                    description => "Delete the authenticated owner's NIP-96 claim.",
                    produces => ["application/json"]
                },
                options => #{tags => ?TRAILS_TAG}
            }
        )
    ].

init(Req0, State = #{action := config}) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Body = config_document(Req0),
            {ok, reply_json(200, Body, Req0), State};
        <<"OPTIONS">> ->
            {ok, reply_options(<<"GET, OPTIONS">>, Req0), State};
        _ ->
            {ok, reply_json(405, error_body(<<"Method not allowed.">>), Req0), State}
    end;
init(Req0, State = #{action := collection}) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_upload(Req0, State);
        <<"GET">> -> handle_list(Req0, State);
        <<"OPTIONS">> -> {ok, reply_options(<<"GET, POST, OPTIONS">>, Req0), State};
        _ -> {ok, reply_json(405, error_body(<<"Method not allowed.">>), Req0), State}
    end;
init(Req0, State = #{action := object}) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_download(Req0, State);
        <<"DELETE">> -> handle_delete(Req0, State);
        <<"OPTIONS">> -> {ok, reply_options(<<"GET, DELETE, OPTIONS">>, Req0), State};
        _ -> {ok, reply_json(405, error_body(<<"Method not allowed.">>), Req0), State}
    end.

%% ------------------------------------------------------------------
%% Discovery
%% ------------------------------------------------------------------

config_document(Req) ->
    MaxBytes = max_upload_bytes(),
    ApiUrl = api_url(Req),
    #{
        <<"api_url">> => ApiUrl,
        <<"download_url">> => ApiUrl,
        <<"supported_nips">> => [96, 98],
        <<"content_types">> => [<<"*/*">>],
        <<"plans">> => #{
            <<"free">> => #{
                <<"name">> => <<"DamageBDD IPFS">>,
                <<"is_nip98_required">> => true,
                <<"max_byte_size">> => MaxBytes,
                <<"file_expiration">> => [0, 0],
                <<"media_transformations">> => #{}
            }
        }
    }.

%% ------------------------------------------------------------------
%% Upload
%% ------------------------------------------------------------------

handle_upload(Req0, State) ->
    ExpectedUrl = public_request_url(Req0),
    case damage_nip98:verify(Req0, ExpectedUrl, <<"POST">>) of
        {ok, Auth} ->
            MaxBytes = max_upload_bytes(),
            case declared_request_too_large(Req0, MaxBytes) of
                true ->
                    {ok, reply_json(413, error_body(<<"File exceeds server upload limit.">>), Req0), State};
                false ->
                    case read_upload(Req0, MaxBytes) of
                        {ok, Upload, Req1} ->
                            finish_upload(Auth, Upload, Req1, State);
                        {error, too_large, Req1} ->
                            {ok, reply_json(413, error_body(<<"File exceeds server upload limit.">>), Req1), State};
                        {error, upload_timeout, Req1} ->
                            {ok, reply_json(408, error_body(<<"Upload timed out.">>), Req1), State};
                        {error, Reason, Req1} ->
                            ?LOG_WARNING("NIP-96 multipart upload rejected: ~p", [Reason]),
                            {ok, reply_json(400, error_body(<<"Invalid multipart upload.">>), Req1), State}
                    end
            end;
        {error, Reason} ->
            ?LOG_WARNING("NIP-96 upload NIP-98 authorization failed: ~p", [Reason]),
            {ok, reply_auth_error(Req0), State}
    end.

finish_upload(Auth, #{file := File, fields := Fields}, Req, State) ->
    TempPath = maps:get(temp_path, File),
    try
        HashHex = maps:get(sha256, File),
        case damage_nip98:validate_file_payload(Auth, HashHex) of
            ok ->
                case validate_upload_fields(Fields) of
                    {ok, OwnerFields} ->
                        Pubkey = maps:get(pubkey, Auth),
                        ContentType = choose_content_type(File, Fields),
                        Extension = extension_for_mime(ContentType),
                        Size = maps:get(size, File),
                        CreatedAt = erlang:system_time(second),
                        ObjectMeta0 = #{
                            hash => HashHex,
                            size => Size,
                            content_type => ContentType,
                            extension => Extension,
                            created_at => CreatedAt
                        },
                        OwnerMeta = maps:merge(
                            OwnerFields,
                            #{
                                created_at => CreatedAt,
                                original_filename => maps:get(filename, File, <<>>)
                            }
                        ),
                        store_upload(HashHex, Pubkey, TempPath, ObjectMeta0, OwnerMeta, Req, State);
                    {error, Reason} ->
                        ?LOG_WARNING("NIP-96 upload metadata rejected: ~p", [Reason]),
                        {ok, reply_json(400, error_body(<<"Invalid upload metadata.">>), Req), State}
                end;
            {error, payload_mismatch} ->
                {ok, reply_json(403, error_body(<<"Authorization payload does not match uploaded file.">>), Req), State}
        end
    after
        _ = file:delete(TempPath)
    end;
finish_upload(_Auth, _Upload, Req, State) ->
    {ok, reply_json(400, error_body(<<"Missing file field.">>), Req), State}.

store_upload(Hash, Pubkey, TempPath, ObjectMeta0, OwnerMeta, Req, State) ->
    case damage_nip96_store:lookup(Hash) of
        {ok, ExistingObject, _Owners} ->
            claim_and_reply(Hash, Pubkey, ExistingObject, OwnerMeta, existing, Req, State);
        {error, not_found} ->
            case extract_cid(damage_ipfs:add({file, to_bin(TempPath)})) of
                {ok, Cid} ->
                    ObjectMeta = ObjectMeta0#{cid => Cid},
                    case ensure_pin(Cid) of
                        ok ->
                            claim_and_reply(Hash, Pubkey, ObjectMeta, OwnerMeta, new, Req, State);
                        {error, Reason} ->
                            ?LOG_ERROR("NIP-96 failed to register IPFS pin cid=~p reason=~p", [Cid, Reason]),
                            {ok, reply_json(503, error_body(<<"IPFS persistence unavailable.">>), Req), State}
                    end;
                {error, Reason} ->
                    ?LOG_ERROR("NIP-96 IPFS add failed hash=~p reason=~p", [Hash, Reason]),
                    {ok, reply_json(503, error_body(<<"IPFS storage unavailable.">>), Req), State}
            end;
        {error, Reason} ->
            ?LOG_ERROR("NIP-96 store lookup failed hash=~p reason=~p", [Hash, Reason]),
            {ok, reply_json(503, error_body(<<"NIP-96 metadata store unavailable.">>), Req), State}
    end.

claim_and_reply(Hash, Pubkey, ObjectMeta, OwnerMeta, ExpectedNewness, Req, State) ->
    case damage_nip96_store:claim(Hash, Pubkey, ObjectMeta, OwnerMeta) of
        {ok, Newness0, StoredObject} ->
            %% A concurrent identical upload can turn our locally-new add into an
            %% existing object; response status follows durable store state.
            Newness =
                case {ExpectedNewness, Newness0} of
                    {existing, _} -> existing;
                    {_, existing} -> existing;
                    _ -> new
                end,
            Status = case Newness of new -> 201; existing -> 200 end,
            Message = case Newness of new -> <<"Upload successful.">>; existing -> <<"File already exists.">> end,
            Response = success_upload_body(Hash, StoredObject, OwnerMeta, Message, Req),
            {ok, reply_json(Status, Response, Req), State};
        {error, hash_cid_conflict} ->
            {ok, reply_json(409, error_body(<<"Stored hash conflicts with IPFS object.">>), Req), State};
        {error, Reason} ->
            ?LOG_ERROR("NIP-96 ownership persistence failed hash=~p reason=~p", [Hash, Reason]),
            {ok, reply_json(503, error_body(<<"NIP-96 metadata store unavailable.">>), Req), State}
    end.

success_upload_body(Hash, Object, Owner, Message, Req) ->
    #{
        <<"status">> => <<"success">>,
        <<"message">> => Message,
        <<"nip94_event">> => nip94_event(Hash, Object, Owner, Req)
    }.

%% ------------------------------------------------------------------
%% Download
%% ------------------------------------------------------------------

handle_download(Req0, State) ->
    case request_hash(Req0) of
        {ok, Hash} ->
            case damage_nip96_store:lookup(Hash) of
                {ok, #{cid := Cid} = Object, _Owners} ->
                    Limit = maps:get(size, Object, max_upload_bytes()),
                    case damage_ipfs:cat_binary(Cid, [{max_bytes, max(1, Limit)}]) of
                        {ok, Data} ->
                            case lower_hex(crypto:hash(sha256, Data)) of
                                Hash ->
                                    CType = maps:get(content_type, Object, <<"application/octet-stream">>),
                                    Headers = cors_headers(#{
                                        <<"content-type">> => CType,
                                        <<"content-length">> => integer_to_binary(byte_size(Data)),
                                        <<"etag">> => <<"\"", Hash/binary, "\"">>,
                                        <<"cache-control">> => <<"public, max-age=31536000, immutable">>,
                                        <<"x-content-type-options">> => <<"nosniff">>,
                                        <<"content-security-policy">> => <<"sandbox; default-src 'none'">>,
                                        <<"content-disposition">> => download_content_disposition(Hash, Object),
                                        <<"x-ipfs-cid">> => Cid
                                    }),
                                    {ok, cowboy_req:reply(200, Headers, Data, Req0), State};
                                _ ->
                                    ?LOG_ERROR("NIP-96 IPFS integrity mismatch hash=~p cid=~p", [Hash, Cid]),
                                    {ok, reply_json(502, error_body(<<"Stored object failed integrity verification.">>), Req0), State}
                            end;
                        {error, ipfs_object_too_large} ->
                            {ok, reply_json(502, error_body(<<"Stored object exceeds recorded size.">>), Req0), State};
                        {error, Reason} ->
                            ?LOG_WARNING("NIP-96 IPFS read failed hash=~p cid=~p reason=~p", [Hash, Cid, Reason]),
                            {ok, reply_json(503, error_body(<<"IPFS object unavailable.">>), Req0), State}
                    end;
                {error, not_found} ->
                    {ok, reply_json(404, error_body(<<"File not found.">>), Req0), State};
                {error, Reason} ->
                    ?LOG_ERROR("NIP-96 metadata lookup failed hash=~p reason=~p", [Hash, Reason]),
                    {ok, reply_json(503, error_body(<<"NIP-96 metadata store unavailable.">>), Req0), State}
            end;
        error ->
            {ok, reply_json(404, error_body(<<"File not found.">>), Req0), State}
    end.

%% ------------------------------------------------------------------
%% Delete
%% ------------------------------------------------------------------

handle_delete(Req0, State) ->
    case request_hash(Req0) of
        {ok, Hash} ->
            ExpectedUrl = public_request_url(Req0),
            case damage_nip98:verify(Req0, ExpectedUrl, <<"DELETE">>) of
                {ok, #{pubkey := Pubkey}} ->
                    case damage_nip96_store:release(Hash, Pubkey) of
                        {ok, last_owner, Object} ->
                            maybe_unpin_last_owner(Object),
                            {ok, reply_json(200, #{
                                <<"status">> => <<"success">>,
                                <<"message">> => <<"File deleted.">>
                            }, Req0), State};
                        {ok, shared, _Object} ->
                            {ok, reply_json(200, #{
                                <<"status">> => <<"success">>,
                                <<"message">> => <<"File deleted.">>
                            }, Req0), State};
                        {error, not_owner} ->
                            {ok, reply_json(403, error_body(<<"Authenticated pubkey does not own this file.">>), Req0), State};
                        {error, Reason} ->
                            ?LOG_ERROR("NIP-96 delete failed hash=~p reason=~p", [Hash, Reason]),
                            {ok, reply_json(503, error_body(<<"NIP-96 metadata store unavailable.">>), Req0), State}
                    end;
                {error, Reason} ->
                    ?LOG_WARNING("NIP-96 delete NIP-98 authorization failed: ~p", [Reason]),
                    {ok, reply_auth_error(Req0), State}
            end;
        error ->
            {ok, reply_json(404, error_body(<<"File not found.">>), Req0), State}
    end.

%% ------------------------------------------------------------------
%% Listing
%% ------------------------------------------------------------------

handle_list(Req0, State) ->
    ExpectedUrl = public_request_url(Req0),
    case damage_nip98:verify(Req0, ExpectedUrl, <<"GET">>) of
        {ok, #{pubkey := Pubkey}} ->
            {Page, Count} = page_args(Req0),
            case damage_nip96_store:list(Pubkey, Page, Count) of
                {ok, #{page := Page0, count := Count0, total := Total, files := Rows}} ->
                    Files = [nip94_listing_event(Hash, Object, Owner, Req0) || {Hash, Object, Owner} <- Rows],
                    Body = #{
                        <<"count">> => Count0,
                        <<"total">> => Total,
                        <<"page">> => Page0,
                        <<"files">> => Files
                    },
                    {ok, reply_json(200, Body, Req0), State};
                {error, Reason} ->
                    ?LOG_ERROR("NIP-96 list failed pubkey=~p reason=~p", [Pubkey, Reason]),
                    {ok, reply_json(503, error_body(<<"NIP-96 metadata store unavailable.">>), Req0), State}
            end;
        {error, Reason} ->
            ?LOG_WARNING("NIP-96 list NIP-98 authorization failed: ~p", [Reason]),
            {ok, reply_auth_error(Req0), State}
    end.

%% ------------------------------------------------------------------
%% Multipart handling
%% ------------------------------------------------------------------

read_upload(Req0, MaxBytes) ->
    ParsedContentType =
        try cowboy_req:parse_header(<<"content-type">>, Req0) of
            Value -> Value
        catch
            _:_ -> undefined
        end,
    case ParsedContentType of
        {<<"multipart">>, <<"form-data">>, _} ->
            Deadline = erlang:monotonic_time(millisecond) + upload_timeout_ms(),
            read_parts(Req0, MaxBytes, #{fields => #{}, parts => 0, field_bytes => 0}, Deadline);
        _ ->
            {error, not_multipart_form_data, Req0}
    end.

read_parts(Req0, MaxBytes, Acc0, Deadline) ->
    case remaining_upload_ms(Deadline) of
        timeout ->
            multipart_error(upload_timeout, Req0, Acc0);
        Period ->
            read_parts_with_period(Req0, MaxBytes, Acc0, Deadline, Period)
    end.

read_parts_with_period(Req0, MaxBytes, Acc0, Deadline, Period) ->
    case cowboy_req:read_part(Req0, #{length => 65536, period => Period}) of
        {ok, Headers, Req1} ->
            Parts = maps:get(parts, Acc0, 0) + 1,
            case Parts =< ?MAX_MULTIPART_PARTS of
                false ->
                    multipart_error(too_many_parts, Req1, Acc0);
                true ->
                    Acc1 = Acc0#{parts => Parts},
                    read_part(Headers, Req1, MaxBytes, Acc1, Deadline)
            end;
        {done, Req1} ->
            case maps:is_key(file, Acc0) of
                true -> {ok, Acc0, Req1};
                false -> {error, missing_file, Req1}
            end
    end.

read_part(Headers, Req1, MaxBytes, Acc0, Deadline) ->
    case parse_part(Headers) of
                {file, <<"file">>, Filename, CType} ->
                    case maps:is_key(file, Acc0) of
                        true ->
                            multipart_error(duplicate_file_field, Req1, Acc0);
                        false ->
                            case stream_file_part(Req1, MaxBytes, Deadline) of
                                {ok, TempPath, Size, HashHex, Req2} ->
                                    File = #{
                                        filename => safe_filename(Filename),
                                        content_type => normalize_content_type(CType),
                                        temp_path => TempPath,
                                        size => Size,
                                        sha256 => HashHex
                                    },
                                    read_parts(Req2, MaxBytes, Acc0#{file => File}, Deadline);
                                {error, too_large, Req2} ->
                                    multipart_error(too_large, Req2, Acc0);
                                {error, Reason, Req2} ->
                                    multipart_error(Reason, Req2, Acc0)
                            end
                    end;
        {file, _OtherName, _Filename, _CType} ->
            %% NIP-96 defines one file field named "file". Reject unexpected
            %% file parts immediately instead of draining attacker-controlled data.
            multipart_error(unexpected_file_field, Req1, Acc0);
                {data, Name} ->
                    case read_part_body_limited(Req1, ?MAX_FORM_FIELD_BYTES, Deadline) of
                        {ok, Value, Req2} ->
                            FieldBytes = maps:get(field_bytes, Acc0, 0) + byte_size(Name) + byte_size(Value),
                            case FieldBytes =< ?MAX_FORM_FIELDS_BYTES of
                                true ->
                                    Fields0 = maps:get(fields, Acc0),
                                    Fields = maps:put(Name, Value, Fields0),
                                    read_parts(
                                        Req2,
                                        MaxBytes,
                                        Acc0#{fields => Fields, field_bytes => FieldBytes},
                                        Deadline
                                    );
                                false ->
                                    multipart_error(form_fields_too_large, Req2, Acc0)
                            end;
                        {error, too_large, Req2} ->
                            multipart_error(form_field_too_large, Req2, Acc0);
                        {error, upload_timeout, Req2} ->
                            multipart_error(upload_timeout, Req2, Acc0)
                    end;
        error ->
            multipart_error(invalid_part_headers, Req1, Acc0)
    end.

multipart_error(Reason, Req, Acc) ->
    cleanup_upload_acc(Acc),
    {error, Reason, Req}.

cleanup_upload_acc(#{file := #{temp_path := Path}}) ->
    _ = file:delete(Path),
    ok;
cleanup_upload_acc(_) ->
    ok.

parse_part(Headers) ->
    try cow_multipart:form_data(Headers) of
        {file, Name, Filename, CType} -> {file, to_bin(Name), to_bin(Filename), CType};
        {data, Name} -> {data, to_bin(Name)};
        _ -> error
    catch
        _:_ -> error
    end.

stream_file_part(Req0, Limit, Deadline) ->
    case temp_upload_path() of
        {ok, Path} ->
            case file:open(Path, [write, binary, raw, exclusive]) of
                {ok, Fd} ->
                    Hash0 = crypto:hash_init(sha256),
                    Result =
                        try
                            stream_file_part(Req0, Limit, 0, Hash0, Fd, Deadline)
                        catch
                            Class:CatchReason ->
                                {error, {upload_stream_failed, Class, CatchReason}, Req0}
                        after
                            _ = file:close(Fd)
                        end,
                    case Result of
                        {ok, Size, HashState, Req1} ->
                            {ok, Path, Size, lower_hex(crypto:hash_final(HashState)), Req1};
                        {error, Reason, Req1} ->
                            _ = file:delete(Path),
                            {error, Reason, Req1}
                    end;
                {error, Reason} ->
                    {error, {temp_open_failed, Reason}, Req0}
            end;
        {error, Reason} ->
            {error, {temp_path_failed, Reason}, Req0}
    end.

stream_file_part(Req0, Limit, Size0, Hash0, Fd, Deadline) ->
    ReadLen = min(?READ_CHUNK_BYTES, max(1, Limit - Size0 + 1)),
    case remaining_upload_ms(Deadline) of
        timeout ->
            {error, upload_timeout, Req0};
        Period ->
            stream_file_part_read(Req0, Limit, Size0, Hash0, Fd, Deadline, ReadLen, Period)
    end.

stream_file_part_read(Req0, Limit, Size0, Hash0, Fd, Deadline, ReadLen, Period) ->
    case cowboy_req:read_part_body(Req0, #{length => ReadLen, period => Period}) of
        {more, Data, Req1} ->
            Size = Size0 + byte_size(Data),
            case Size =< Limit of
                true ->
                    ok = file:write(Fd, Data),
                    stream_file_part(Req1, Limit, Size, crypto:hash_update(Hash0, Data), Fd, Deadline);
                false ->
                    {error, too_large, Req1}
            end;
        {ok, Data, Req1} ->
            Size = Size0 + byte_size(Data),
            case Size =< Limit of
                true ->
                    ok = file:write(Fd, Data),
                    {ok, Size, crypto:hash_update(Hash0, Data), Req1};
                false ->
                    {error, too_large, Req1}
            end
    end.

temp_upload_path() ->
    C = damage_ipfs_config:load(),
    Dir = filename:join(maps:get(data_dir, C), "nip96_uploads"),
    Name = "upload-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++ ".tmp",
    Path = filename:join(Dir, Name),
    case filelib:ensure_dir(Path) of
        ok -> {ok, Path};
        {error, _} = Error -> Error
    end.

read_part_body_limited(Req0, Limit, Deadline) ->
    read_part_body_limited(Req0, Limit, 0, [], Deadline).

read_part_body_limited(Req0, Limit, Size0, Chunks, Deadline) ->
    ReadLen = min(?READ_CHUNK_BYTES, max(1, Limit - Size0 + 1)),
    case remaining_upload_ms(Deadline) of
        timeout ->
            {error, upload_timeout, Req0};
        Period ->
            case cowboy_req:read_part_body(Req0, #{length => ReadLen, period => Period}) of
                {more, Data, Req1} ->
                    Size = Size0 + byte_size(Data),
                    case Size =< Limit of
                        true -> read_part_body_limited(Req1, Limit, Size, [Data | Chunks], Deadline);
                        false -> {error, too_large, Req1}
                    end;
                {ok, Data, Req1} ->
                    Size = Size0 + byte_size(Data),
                    case Size =< Limit of
                        true -> {ok, iolist_to_binary(lists:reverse([Data | Chunks])), Req1};
                        false -> {error, too_large, Req1}
                    end
            end
    end.


validate_upload_fields(Fields) ->
    Exp0 = maps:get(<<"expiration">>, Fields, <<>>),
    MediaType = maps:get(<<"media_type">>, Fields, <<>>),
    NoTransform = maps:get(<<"no_transform">>, Fields, <<>>),
    case {parse_expiration(Exp0), valid_media_type(MediaType), valid_no_transform(NoTransform)} of
        {{ok, Expiration}, true, true} ->
            {ok, #{
                caption => maps:get(<<"caption">>, Fields, <<>>),
                alt => maps:get(<<"alt">>, Fields, <<>>),
                expiration => Expiration,
                media_type => MediaType,
                no_transform => true
            }};
        _ ->
            {error, invalid_fields}
    end.

parse_expiration(<<>>) -> {ok, 0};
parse_expiration(B) when is_binary(B) ->
    Now = erlang:system_time(second),
    try binary_to_integer(B) of
        I when I =:= 0 -> {ok, 0};
        I when I > Now -> {ok, I};
        _ -> {error, invalid_expiration}
    catch
        _:_ -> {error, invalid_expiration}
    end.

valid_media_type(<<>>) -> true;
valid_media_type(<<"avatar">>) -> true;
valid_media_type(<<"banner">>) -> true;
valid_media_type(_) -> false.

valid_no_transform(<<>>) -> true;
valid_no_transform(<<"true">>) -> true;
valid_no_transform(<<"false">>) -> true;
valid_no_transform(_) -> false.

choose_content_type(File, Fields) ->
    PartType = maps:get(content_type, File, <<>>),
    ClaimedType = maps:get(<<"content_type">>, Fields, <<>>),
    case PartType of
        <<>> -> normalize_content_type(ClaimedType);
        <<"application/octet-stream">> when ClaimedType =/= <<>> -> normalize_content_type(ClaimedType);
        _ -> PartType
    end.

normalize_content_type(undefined) -> <<"application/octet-stream">>;
normalize_content_type(<<>>) -> <<"application/octet-stream">>;
normalize_content_type({Type, SubType, _Params}) ->
    <<(to_bin(Type))/binary, "/", (to_bin(SubType))/binary>>;
normalize_content_type(B) when is_binary(B) ->
    Mime0 =
        case binary:split(B, <<";">>) of
            [MimePart, _] -> trim_binary(MimePart);
            [MimePart] -> trim_binary(MimePart)
        end,
    Mime = lower_ascii(Mime0),
    case valid_mime_type(Mime) of
        true -> Mime;
        false -> <<"application/octet-stream">>
    end;
normalize_content_type(L) when is_list(L) -> normalize_content_type(to_bin(L));
normalize_content_type(_) -> <<"application/octet-stream">>.

valid_mime_type(Mime) when is_binary(Mime), byte_size(Mime) =< 255 ->
    re:run(
        Mime,
        <<"\\A[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+\\z">>,
        [{capture, none}]
    ) =:= match;
valid_mime_type(_) -> false.

%% ------------------------------------------------------------------
%% NIP-94 response helpers
%% ------------------------------------------------------------------

nip94_event(Hash, Object, Owner, Req) ->
    #{
        <<"tags">> => nip94_tags(Hash, Object, Owner, Req),
        <<"content">> => maps:get(caption, Owner, <<>>)
    }.

nip94_listing_event(Hash, Object, Owner, Req) ->
    (nip94_event(Hash, Object, Owner, Req))#{
        <<"created_at">> => maps:get(created_at, Owner, maps:get(created_at, Object, 0))
    }.

nip94_tags(Hash, Object, Owner, Req) ->
    Url = download_url(Hash, Object, Req),
    CType = maps:get(content_type, Object, <<"application/octet-stream">>),
    Size = integer_to_binary(maps:get(size, Object, 0)),
    Base = [
        [<<"url">>, Url],
        [<<"ox">>, Hash],
        [<<"x">>, Hash],
        [<<"m">>, CType],
        [<<"size">>, Size]
    ],
    WithAlt = maybe_tag(<<"alt">>, maps:get(alt, Owner, <<>>), Base),
    WithExpiration =
        case maps:get(expiration, Owner, 0) of
            Exp when is_integer(Exp), Exp > 0 -> WithAlt ++ [[<<"expiration">>, integer_to_binary(Exp)]];
            _ -> WithAlt
        end,
    WithExpiration ++ [[<<"service">>, <<"nip96">>]].

maybe_tag(_Name, <<>>, Tags) -> Tags;
maybe_tag(Name, Value, Tags) -> Tags ++ [[Name, to_bin(Value)]].

%% ------------------------------------------------------------------
%% IPFS helpers
%% ------------------------------------------------------------------

extract_cid({ok, Value}) -> extract_cid(Value);
extract_cid(#{<<"Hash">> := Cid}) -> valid_cid_result(Cid);
extract_cid(#{hash := Cid}) -> valid_cid_result(Cid);
extract_cid(#{<<"hash">> := Cid}) -> valid_cid_result(Cid);
extract_cid(List) when is_list(List), List =/= [] ->
    case lists:all(fun erlang:is_integer/1, List) of
        true -> valid_cid_result(List);
        false -> extract_cid_from_results(lists:reverse(List))
    end;
extract_cid(Cid) when is_binary(Cid) -> valid_cid_result(Cid);
extract_cid({error, _} = Error) -> Error;
extract_cid(Other) -> {error, {invalid_ipfs_add_response, Other}}.

extract_cid_from_results([]) -> {error, missing_ipfs_cid};
extract_cid_from_results([H | T]) ->
    case extract_cid(H) of
        {ok, _} = Ok -> Ok;
        _ -> extract_cid_from_results(T)
    end.

valid_cid_result(Cid0) ->
    Cid = to_bin(Cid0),
    case damage_ipfs:valid_cid(Cid) of
        true -> {ok, Cid};
        false -> {error, invalid_ipfs_cid}
    end.

ensure_pin(Cid) ->
    case application:get_env(damage, nip96_pin_uploads, true) of
        false -> ok;
        _ ->
            case damage_ipfs:pin_async(Cid) of
                ok -> ok;
                {ok, _} -> ok;
                {error, _} = Error -> Error;
                Other -> {error, {invalid_pin_response, Other}}
            end
    end.

maybe_unpin_last_owner(#{cid := Cid}) ->
    %% Default false: IPFS is shared by other DamageBDD subsystems and the
    %% NIP-96 metadata store is not a global CID reference counter.
    case application:get_env(damage, nip96_unpin_on_delete, false) of
        true ->
            case damage_ipfs:unpin_async(Cid) of
                ok -> ok;
                {ok, _} -> ok;
                Error -> ?LOG_WARNING("NIP-96 async unpin failed cid=~p reason=~p", [Cid, Error])
            end;
        _ -> ok
    end;
maybe_unpin_last_owner(_) -> ok.

%% ------------------------------------------------------------------
%% Request / URL helpers
%% ------------------------------------------------------------------

request_hash(Req) ->
    try cowboy_req:binding(file, Req) of
        Segment when is_binary(Segment) -> parse_hash_segment(Segment);
        _ -> error
    catch
        _:_ -> error
    end.

parse_hash_segment(Segment) ->
    Hash0 = hd(binary:split(Segment, <<".">>, [global])),
    Hash = lower_ascii(Hash0),
    case byte_size(Hash) =:= 64 andalso
        re:run(Hash, <<"\\A[0-9a-f]{64}\\z">>, [{capture, none}]) =:= match
    of
        true -> {ok, Hash};
        false -> error
    end.

public_request_url(Req) ->
    Base = public_base_url(Req),
    Path = cowboy_req:path(Req),
    case cowboy_req:qs(Req) of
        <<>> -> <<Base/binary, Path/binary>>;
        Qs -> <<Base/binary, Path/binary, "?", Qs/binary>>
    end.

api_url(Req) ->
    <<(public_base_url(Req))/binary, "/api/nip96">>.

download_url(Hash, Object, Req) ->
    Ext = maps:get(extension, Object, <<>>),
    <<(api_url(Req))/binary, "/", Hash/binary, Ext/binary>>.

public_base_url(Req) ->
    case application:get_env(damage, nip96_public_base_url) of
        {ok, Value} -> trim_trailing_slash(to_bin(Value));
        undefined ->
            case application:get_env(damage, api_url) of
                {ok, Value} -> trim_trailing_slash(to_bin(Value));
                undefined -> request_origin(Req)
            end
    end.

request_origin(Req) ->
    Scheme = cowboy_req:scheme(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    case {Scheme, Port} of
        {<<"http">>, 80} -> <<"http://", Host/binary>>;
        {<<"https">>, 443} -> <<"https://", Host/binary>>;
        _ -> <<Scheme/binary, "://", Host/binary, ":", (integer_to_binary(Port))/binary>>
    end.

trim_trailing_slash(<<>>) -> <<>>;
trim_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> trim_trailing_slash(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

page_args(Req) ->
    Pairs = cowboy_req:parse_qs(Req),
    Page = qs_nonneg_int(<<"page">>, Pairs, 0, 1000000),
    Count = qs_nonneg_int(<<"count">>, Pairs, ?DEFAULT_PAGE_COUNT, ?MAX_PAGE_COUNT),
    {Page, max(1, Count)}.

qs_nonneg_int(Key, Pairs, Default, Max) ->
    case proplists:get_value(Key, Pairs) of
        undefined -> Default;
        V ->
            try binary_to_integer(V) of
                I when I >= 0 -> min(I, Max);
                _ -> Default
            catch
                _:_ -> Default
            end
    end.

max_upload_bytes() ->
    case application:get_env(damage, nip96_max_bytes) of
        {ok, I} when is_integer(I), I > 0 -> I;
        _ -> maps:get(max_request_bytes, damage_ipfs_config:load(), ?DEFAULT_MAX_BYTES)
    end.

upload_timeout_ms() ->
    case application:get_env(damage, nip96_upload_timeout_ms) of
        {ok, I} when is_integer(I), I > 0 -> I;
        _ -> ?DEFAULT_UPLOAD_TIMEOUT_MS
    end.

remaining_upload_ms(Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        true -> min(5000, Remaining);
        false -> timeout
    end.

declared_request_too_large(Req, MaxBytes) ->
    %% Multipart overhead is bounded loosely; the actual file part is still
    %% streamed with an exact MaxBytes cap below.
    case cowboy_req:header(<<"content-length">>, Req) of
        undefined ->
            false;
        B ->
            try binary_to_integer(B) of
                N when N >= 0 ->
                    N > MaxBytes + 1048576
            catch
                error:badarg ->
                    false
            end
    end.

safe_filename(Filename0) ->
    Filename = to_bin(Filename0),
    Base = to_bin(filename:basename(binary_to_list(Filename))),
    case byte_size(Base) =< 255 of
        true -> Base;
        false -> binary:part(Base, 0, 255)
    end.

download_content_disposition(Hash, Object) ->
    Ext = maps:get(extension, Object, <<>>),
    <<"inline; filename=\"", Hash/binary, Ext/binary, "\"">>.

extension_for_mime(<<"image/jpeg">>) -> <<".jpg">>;
extension_for_mime(<<"image/png">>) -> <<".png">>;
extension_for_mime(<<"image/gif">>) -> <<".gif">>;
extension_for_mime(<<"image/webp">>) -> <<".webp">>;
extension_for_mime(<<"image/avif">>) -> <<".avif">>;
extension_for_mime(<<"image/svg+xml">>) -> <<".svg">>;
extension_for_mime(<<"video/mp4">>) -> <<".mp4">>;
extension_for_mime(<<"video/webm">>) -> <<".webm">>;
extension_for_mime(<<"audio/mpeg">>) -> <<".mp3">>;
extension_for_mime(<<"audio/ogg">>) -> <<".ogg">>;
extension_for_mime(<<"audio/wav">>) -> <<".wav">>;
extension_for_mime(<<"application/pdf">>) -> <<".pdf">>;
extension_for_mime(<<"application/json">>) -> <<".json">>;
extension_for_mime(<<"text/plain">>) -> <<".txt">>;
extension_for_mime(_) -> <<>>.

%% ------------------------------------------------------------------
%% Response helpers
%% ------------------------------------------------------------------

error_body(Message) ->
    #{<<"status">> => <<"error">>, <<"message">> => Message}.

reply_auth_error(Req) ->
    Headers = cors_headers(#{
        <<"content-type">> => <<"application/json">>,
        <<"www-authenticate">> => <<"Nostr">>
    }),
    cowboy_req:reply(401, Headers, jsx:encode(error_body(<<"Valid NIP-98 authorization required.">>)), Req).

reply_json(Status, Body, Req) ->
    Headers = cors_headers(#{<<"content-type">> => <<"application/json">>}),
    cowboy_req:reply(Status, Headers, jsx:encode(Body), Req).

reply_options(Allow, Req) ->
    Headers = cors_headers(#{
        <<"allow">> => Allow,
        <<"access-control-allow-methods">> => Allow,
        <<"access-control-allow-headers">> => <<"authorization, content-type">>,
        <<"access-control-max-age">> => <<"86400">>
    }),
    cowboy_req:reply(204, Headers, <<>>, Req).

cors_headers(Headers) ->
    Headers#{<<"access-control-allow-origin">> => <<"*">>}.

lower_hex(Bin) ->
    << <<(hex_digit(B bsr 4)), (hex_digit(B band 15))>> || <<B>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).

lower_ascii(B) ->
    << <<(lower_char(C))>> || <<C>> <= B >>.
lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

trim_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B))).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
