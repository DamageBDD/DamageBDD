%%%-------------------------------------------------------------------
%%% Blossom HTTP facade over DamageBDD's IPFS-backed content store.
%%%
%%% Implements the core interoperable Blossom surface:
%%%   BUD-01 GET/HEAD /<sha256>[.ext] + range/CORS
%%%   BUD-02 PUT /upload + Blob Descriptor
%%%   BUD-06 HEAD /upload preflight
%%%   BUD-11 kind:24242 Nostr authorization for upload/delete
%%%   BUD-12 DELETE /<sha256> and optional GET /list/<pubkey>
%%%
%%% Blob bytes are immutable and stored in IPFS. Blossom's sha256 is the
%%% public address; the IPFS CID is retained as additional descriptor metadata.
%%%-------------------------------------------------------------------
-module(damage_blossom_http).

-include_lib("kernel/include/logger.hrl").

-export([init/2, trails/0]).

-define(DEFAULT_MAX_BYTES, 67108864).
-define(ABSOLUTE_MAX_BYTES, 268435456).
-define(DEFAULT_UPLOAD_TIMEOUT_MS, 120000).
-define(MIN_UPLOAD_TIMEOUT_MS, 5000).
-define(MAX_UPLOAD_TIMEOUT_MS, 300000).
-define(DEFAULT_LIST_LIMIT, 20).
-define(MAX_LIST_LIMIT, 100).
-define(READ_CHUNK_BYTES, 1048576).
-define(SNIFF_BYTES, 65536).
-define(LOG_DOMAIN, [damage, blossom]).

-define(DEFAULT_UPLOAD_IP_RATE, 60).
-define(DEFAULT_UPLOAD_PUBKEY_RATE, 20).
-define(DEFAULT_DELETE_IP_RATE, 60).
-define(DEFAULT_DELETE_PUBKEY_RATE, 30).
-define(DEFAULT_DOWNLOAD_IP_RATE, 600).
-define(DEFAULT_LIST_IP_RATE, 60).

trails() ->
    [
        trails:trail(
            "/upload",
            ?MODULE,
            #{action => upload},
            #{
                put => #{
                    tags => ["Blossom"],
                    description => "Upload a Blossom blob to IPFS-backed storage.",
                    produces => ["application/json"]
                },
                head => #{
                    tags => ["Blossom"],
                    description => "Check Blossom upload requirements (BUD-06)."
                },
                options => #{tags => ["Blossom"]}
            }
        ),
        trails:trail(
            "/list/:pubkey",
            ?MODULE,
            #{action => list},
            #{
                get => #{
                    tags => ["Blossom"],
                    description => "List blobs claimed by a Nostr pubkey (BUD-12).",
                    produces => ["application/json"]
                },
                options => #{tags => ["Blossom"]}
            }
        ),
        %% Keep this catch-all last, and register damage_blossom_http last in
        %% damage_app:get_trails/0, so existing one-segment DamageBDD routes win.
        trails:trail(
            "/:blob",
            ?MODULE,
            #{action => blob},
            #{
                get => #{
                    tags => ["Blossom"],
                    description => "Retrieve a Blossom blob by SHA-256.",
                    produces => ["application/octet-stream"]
                },
                head => #{
                    tags => ["Blossom"],
                    description => "Check whether a Blossom blob exists."
                },
                delete => #{
                    tags => ["Blossom"],
                    description => "Delete the authenticated Blossom ownership claim."
                },
                options => #{tags => ["Blossom"]}
            }
        )
    ].

init(Req0, State = #{action := upload}) ->
    set_blossom_log_context(Req0),
    case cowboy_req:method(Req0) of
        <<"PUT">> -> handle_upload(Req0, State);
        <<"HEAD">> -> handle_upload_preflight(Req0, State);
        <<"OPTIONS">> -> {ok, reply_options(Req0), State};
        _ -> {ok, reply_error(405, <<"Method not allowed">>, Req0), State}
    end;
init(Req0, State = #{action := list}) ->
    set_blossom_log_context(Req0),
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_list(Req0, State);
        <<"OPTIONS">> -> {ok, reply_options(Req0), State};
        _ -> {ok, reply_error(405, <<"Method not allowed">>, Req0), State}
    end;
init(Req0, State = #{action := blob}) ->
    set_blossom_log_context(Req0),
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_get(Req0, State);
        <<"HEAD">> -> handle_head(Req0, State);
        <<"DELETE">> -> handle_delete(Req0, State);
        <<"OPTIONS">> -> {ok, reply_options(Req0), State};
        _ -> {ok, reply_error(405, <<"Method not allowed">>, Req0), State}
    end.

%% Keep all Blossom request/auth/storage logs on a dedicated OTP Logger
%% domain. damage_blossom_auth runs in this same Cowboy request process, so
%% any logging added there also inherits [damage, blossom]. Do not log the
%% Authorization value: a BUD-11 token is a short-lived signed capability.
set_blossom_log_context(Req) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Host = cowboy_req:host(Req),
    HasAuthorization = cowboy_req:header(<<"authorization">>, Req) =/= undefined,
    XSha256 = cowboy_req:header(<<"x-sha-256">>, Req),
    ok = logger:update_process_metadata(#{
        domain => ?LOG_DOMAIN,
        blossom_method => Method,
        blossom_path => Path,
        blossom_host => Host
    }),
    ?LOG_DEBUG(
        "Blossom request method=~p path=~p host=~p authorization_present=~p x_sha256=~p content_type=~p content_length=~p",
        [
            Method,
            Path,
            Host,
            HasAuthorization,
            XSha256,
            cowboy_req:header(<<"content-type">>, Req),
            cowboy_req:header(<<"content-length">>, Req)
        ]
    ),
    ok.

%% ------------------------------------------------------------------
%% BUD-02 / BUD-06 upload
%% ------------------------------------------------------------------

handle_upload_preflight(Req0, State) ->
    case rate_check_ip(upload_ip, Req0) of
        ok ->
            case preflight_headers(Req0) of
                {ok, Hash, Size, _ContentType} ->
                    case Size =< max_upload_bytes() of
                        false ->
                            {ok, reply_head_error(413, <<"Blob exceeds server size limit">>, Req0), State};
                        true ->
                            case damage_blossom_auth:verify(Req0, <<"upload">>, Hash) of
                                {ok, _Auth} ->
                                    Headers = cors_headers(#{}),
                                    {ok, cowboy_req:reply(200, Headers, <<>>, Req0), State};
                                {error, Reason} ->
                                    ?LOG_WARNING("Blossom upload preflight auth failed: ~p", [Reason]),
                                    {ok, reply_head_auth_error(Req0), State}
                            end
                    end;
                {error, missing_length} ->
                    {ok, reply_head_error(411, <<"X-Content-Length is required">>, Req0), State};
                {error, unsupported_type} ->
                    {ok, reply_head_error(415, <<"Unsupported media type">>, Req0), State};
                {error, _} ->
                    {ok, reply_head_error(400, <<"Malformed Blossom upload headers">>, Req0), State}
            end;
        RateError ->
            {ok, reply_head_rate_error(RateError, Req0), State}
    end.

handle_upload(Req0, State) ->
    case rate_check_ip(upload_ip, Req0) of
        ok ->
            case put_upload_headers(Req0) of
                {ok, HeaderHash, DeclaredSize, ContentType} ->
                    case DeclaredSize =< max_upload_bytes() of
                        false ->
                            {ok, reply_error(413, <<"Blob exceeds server size limit">>, Req0), State};
                        true ->
                            handle_upload_authorized(
                                Req0, State, HeaderHash, DeclaredSize, ContentType
                            )
                    end;
                {error, missing_length} ->
                    {ok, reply_error(411, <<"Content-Length is required">>, Req0), State};
                {error, unsupported_type} ->
                    {ok, reply_error(415, <<"Unsupported media type">>, Req0), State};
                {error, _} ->
                    {ok, reply_error(400, <<"Malformed Blossom upload headers">>, Req0), State}
            end;
        RateError ->
            {ok, reply_rate_error(RateError, Req0), State}
    end.

handle_upload_authorized(Req0, State, undefined, DeclaredSize, ContentType) ->
    %% BUD-02 makes X-SHA-256 optional for PUT /upload and Amethyst may omit
    %% it. First validate the signed token without consuming the body, then
    %% stream/hash the bounded body and re-validate the same token against the
    %% computed hash before storing it. This keeps the upload hash-bound while
    %% avoiding unauthenticated disk I/O.
    case damage_blossom_auth:verify_deferred_hash(Req0, <<"upload">>) of
        {ok, #{pubkey := Pubkey}} ->
            case rate_check_pubkey(upload_pubkey, Pubkey) of
                ok ->
                    case read_upload_body(Req0, DeclaredSize) of
                        {ok, TempPath, Size, ActualHash, Req1} ->
                            try
                                case damage_blossom_auth:verify(Req1, <<"upload">>, ActualHash) of
                                    {ok, #{pubkey := Pubkey}} ->
                                        validate_and_store_upload(
                                            ActualHash,
                                            Pubkey,
                                            TempPath,
                                            Size,
                                            ContentType,
                                            Req1,
                                            State
                                        );
                                    {ok, _OtherAuth} ->
                                        {ok, reply_auth_error(Req1), State};
                                    {error, Reason} ->
                                        ?LOG_WARNING(
                                            "Blossom upload hash-scope auth failed: ~p",
                                            [Reason]
                                        ),
                                        {ok, reply_auth_error(Req1), State}
                                end
                            after
                                _ = file:delete(TempPath)
                            end;
                        {error, too_large, Req1} ->
                            {ok, reply_error(
                                413,
                                <<"Blob exceeds declared or server size limit">>,
                                Req1
                            ), State};
                        {error, upload_timeout, Req1} ->
                            {ok, reply_error(408, <<"Upload timed out">>, Req1), State};
                        {error, Reason, Req1} ->
                            ?LOG_WARNING("Blossom body read failed: ~p", [Reason]),
                            {ok, reply_error(400, <<"Malformed upload body">>, Req1), State}
                    end;
                RateError ->
                    {ok, reply_rate_error(RateError, Req0), State}
            end;
        {error, Reason} ->
            ?LOG_WARNING("Blossom upload auth failed before body read: ~p", [Reason]),
            {ok, reply_auth_error(Req0), State}
    end;
handle_upload_authorized(Req0, State, HeaderHash, DeclaredSize, ContentType) ->
    %% When X-SHA-256 is supplied retain the strict early hash-scoped auth
    %% path and verify the body actually matches the declared hash.
    case damage_blossom_auth:verify(Req0, <<"upload">>, HeaderHash) of
        {ok, #{pubkey := Pubkey}} ->
            case rate_check_pubkey(upload_pubkey, Pubkey) of
                ok ->
                    case read_upload_body(Req0, DeclaredSize) of
                        {ok, TempPath, Size, ActualHash, Req1} ->
                            try
                                case ActualHash =:= HeaderHash of
                                    true ->
                                        validate_and_store_upload(
                                            HeaderHash,
                                            Pubkey,
                                            TempPath,
                                            Size,
                                            ContentType,
                                            Req1,
                                            State
                                        );
                                    false ->
                                        {ok, reply_error(
                                            409,
                                            <<"X-SHA-256 does not match request body">>,
                                            Req1
                                        ), State}
                                end
                            after
                                _ = file:delete(TempPath)
                            end;
                        {error, too_large, Req1} ->
                            {ok, reply_error(
                                413,
                                <<"Blob exceeds declared or server size limit">>,
                                Req1
                            ), State};
                        {error, upload_timeout, Req1} ->
                            {ok, reply_error(408, <<"Upload timed out">>, Req1), State};
                        {error, Reason, Req1} ->
                            ?LOG_WARNING("Blossom body read failed: ~p", [Reason]),
                            {ok, reply_error(400, <<"Malformed upload body">>, Req1), State}
                    end;
                RateError ->
                    {ok, reply_rate_error(RateError, Req0), State}
            end;
        {error, Reason} ->
            ?LOG_WARNING("Blossom upload auth failed: ~p", [Reason]),
            {ok, reply_auth_error(Req0), State}
    end.

preflight_headers(Req) ->
    Hash0 = cowboy_req:header(<<"x-sha-256">>, Req),
    Length0 = cowboy_req:header(<<"x-content-length">>, Req),
    CType0 = cowboy_req:header(<<"x-content-type">>, Req),
    case Length0 of
        undefined -> {error, missing_length};
        _ -> parse_upload_headers(Hash0, Length0, CType0, true)
    end.

put_upload_headers(Req) ->
    Hash0 = cowboy_req:header(<<"x-sha-256">>, Req),
    Length0 = cowboy_req:header(<<"content-length">>, Req),
    CType0 = cowboy_req:header(<<"content-type">>, Req, <<"application/octet-stream">>),
    case Length0 of
        undefined -> {error, missing_length};
        _ -> parse_put_upload_headers(Hash0, Length0, CType0)
    end.

parse_put_upload_headers(Hash0, Length0, CType0) ->
    HashResult =
        case Hash0 of
            undefined -> {ok, undefined};
            _ -> parse_hash(Hash0)
        end,
    case {HashResult, parse_size(Length0), normalize_upload_content_type(CType0)} of
        {{ok, Hash}, {ok, Size}, {ok, ContentType}} ->
            {ok, Hash, Size, ContentType};
        {{error, _}, _, _} ->
            {error, invalid_hash};
        {_, {error, _}, _} ->
            {error, invalid_length};
        {_, _, {error, _}} ->
            {error, unsupported_type}
    end.

parse_upload_headers(Hash0, Length0, CType0, RequireType) ->
    case {parse_hash(Hash0), parse_size(Length0), normalize_upload_content_type(CType0)} of
        {{ok, Hash}, {ok, Size}, {ok, ContentType}} ->
            {ok, Hash, Size, ContentType};
        {{error, _}, _, _} ->
            {error, invalid_hash};
        {_, {error, _}, _} ->
            {error, invalid_length};
        {_, _, {error, missing}} when RequireType ->
            {error, unsupported_type};
        {_, _, {error, _}} ->
            {error, unsupported_type}
    end.

read_upload_body(Req0, DeclaredSize) ->
    MaxBytes = max_upload_bytes(),
    Limit = min(DeclaredSize, MaxBytes),
    Deadline = erlang:monotonic_time(millisecond) + upload_timeout_ms(),
    case temp_upload_path() of
        {ok, Path} ->
            case file:open(Path, [write, binary, raw, exclusive]) of
                {ok, Fd} ->
                    case file:change_mode(Path, 8#600) of
                        ok ->
                            Hash0 = crypto:hash_init(sha256),
                            Result =
                                try stream_body(Req0, Limit, 0, Hash0, Fd, Deadline)
                                after file:close(Fd)
                                end,
                            case Result of
                                {ok, DeclaredSize, HashState, Req1} ->
                                    Hash = lower_hex(crypto:hash_final(HashState)),
                                    {ok, Path, DeclaredSize, Hash, Req1};
                                {ok, _OtherSize, _HashState, Req1} ->
                                    _ = file:delete(Path),
                                    {error, content_length_mismatch, Req1};
                                {error, Reason, Req1} ->
                                    _ = file:delete(Path),
                                    {error, Reason, Req1}
                            end;
                        {error, Reason} ->
                            _ = file:close(Fd),
                            _ = file:delete(Path),
                            {error, {temp_chmod_failed, Reason}, Req0}
                    end;
                {error, Reason} ->
                    {error, {temp_open_failed, Reason}, Req0}
            end;
        {error, Reason} ->
            {error, {temp_path_failed, Reason}, Req0}
    end.

stream_body(Req0, Limit, Size0, Hash0, Fd, Deadline) ->
    ReadLen = min(?READ_CHUNK_BYTES, max(1, Limit - Size0 + 1)),
    case remaining_upload_ms(Deadline) of
        timeout ->
            {error, upload_timeout, Req0};
        Period ->
            case cowboy_req:read_body(Req0, #{length => ReadLen, period => Period}) of
                {more, Data, Req1} ->
                    Size = Size0 + byte_size(Data),
                    case Size =< Limit of
                        true ->
                            case file:write(Fd, Data) of
                                ok -> stream_body(Req1, Limit, Size, crypto:hash_update(Hash0, Data), Fd, Deadline);
                                {error, Reason} -> {error, {temp_write_failed, Reason}, Req1}
                            end;
                        false ->
                            {error, too_large, Req1}
                    end;
                {ok, Data, Req1} ->
                    Size = Size0 + byte_size(Data),
                    case Size =< Limit of
                        true ->
                            case file:write(Fd, Data) of
                                ok -> {ok, Size, crypto:hash_update(Hash0, Data), Req1};
                                {error, Reason} -> {error, {temp_write_failed, Reason}, Req1}
                            end;
                        false ->
                            {error, too_large, Req1}
                    end
            end
    end.

validate_and_store_upload(Hash, Pubkey, TempPath, Size, ContentType, Req, State) ->
    case validate_uploaded_file(TempPath, Size, ContentType) of
        ok ->
            store_upload(Hash, Pubkey, TempPath, Size, ContentType, Req, State);
        {error, Reason} ->
            ?LOG_WARNING(
                "Blossom rejected uploaded data hash=~p content_type=~p size=~p reason=~p",
                [Hash, ContentType, Size, Reason]
            ),
            {ok,
                reply_error(
                    415,
                    <<"Uploaded data does not match an allowed media type">>,
                    Req
                ),
                State}
    end.

validate_uploaded_file(_TempPath, Size, _ContentType) when Size =< 0 ->
    {error, empty_upload};
validate_uploaded_file(TempPath, Size, ContentType) ->
    case content_type_allowed(ContentType) of
        false ->
            {error, content_type_not_allowed};
        true ->
            ReadBytes = min(Size, ?SNIFF_BYTES),
            case file:open(TempPath, [read, binary, raw]) of
                {ok, Fd} ->
                    Result =
                        try file:read(Fd, ReadBytes) of
                            {ok, Head} when is_binary(Head), byte_size(Head) > 0 ->
                                validate_content_signature(ContentType, Head);
                            eof ->
                                {error, empty_upload};
                            {error, Reason} ->
                                {error, {security_read_failed, Reason}}
                        after
                            _ = file:close(Fd)
                        end,
                    Result;
                {error, Reason} ->
                    {error, {security_open_failed, Reason}}
            end
    end.

validate_content_signature(<<"image/jpeg">>, <<16#FF, 16#D8, 16#FF, _/binary>>) -> ok;
validate_content_signature(<<"image/png">>, <<137, 80, 78, 71, 13, 10, 26, 10, _/binary>>) -> ok;
validate_content_signature(<<"image/gif">>, <<"GIF87a", _/binary>>) -> ok;
validate_content_signature(<<"image/gif">>, <<"GIF89a", _/binary>>) -> ok;
validate_content_signature(<<"image/webp">>, <<"RIFF", _Size:32/little, "WEBP", _/binary>>) -> ok;
validate_content_signature(<<"image/avif">>, Head) ->
    validate_isobmff_brand(Head, [<<"avif">>, <<"avis">>]);
validate_content_signature(<<"image/heic">>, Head) ->
    validate_isobmff_brand(
        Head,
        [<<"heic">>, <<"heix">>, <<"hevc">>, <<"hevx">>, <<"mif1">>, <<"msf1">>]
    );
validate_content_signature(<<"image/heif">>, Head) ->
    validate_content_signature(<<"image/heic">>, Head);
validate_content_signature(<<"video/mp4">>, Head) ->
    validate_isobmff_brand(
        Head,
        [
            <<"isom">>, <<"iso2">>, <<"mp41">>, <<"mp42">>, <<"avc1">>,
            <<"dash">>, <<"M4V ">>, <<"MSNV">>, <<"3gp4">>, <<"3gp5">>
        ]
    );
validate_content_signature(<<"video/quicktime">>, Head) ->
    validate_isobmff_brand(Head, [<<"qt  ">>]);
validate_content_signature(<<"video/webm">>, <<16#1A, 16#45, 16#DF, 16#A3, _/binary>>) -> ok;
validate_content_signature(<<"audio/mpeg">>, <<"ID3", _/binary>>) -> ok;
validate_content_signature(<<"audio/mpeg">>, <<16#FF, B, _/binary>>) when (B band 16#E0) =:= 16#E0 -> ok;
validate_content_signature(<<"audio/ogg">>, <<"OggS", _/binary>>) -> ok;
validate_content_signature(<<"audio/wav">>, <<"RIFF", _Size:32/little, "WAVE", _/binary>>) -> ok;
validate_content_signature(<<"application/pdf">>, <<"%PDF-", _/binary>>) -> ok;
validate_content_signature(<<"application/octet-stream">>, _Head) ->
    case application:get_env(damage, blossom_allow_octet_stream, false) of
        true -> ok;
        _ -> {error, unverified_octet_stream}
    end;
validate_content_signature(_ContentType, _Head) ->
    {error, magic_mismatch}.

validate_isobmff_brand(
    <<_BoxSize:32/big, "ftyp", Major:4/binary, _Minor:4/binary, Compat/binary>>,
    Allowed
) ->
    Brands = [Major | isobmff_compatible_brands(Compat, 16, [])],
    case lists:any(fun(B) -> lists:member(B, Allowed) end, Brands) of
        true -> ok;
        false -> {error, unexpected_isobmff_brand}
    end;
validate_isobmff_brand(_, _) ->
    {error, invalid_isobmff_header}.

isobmff_compatible_brands(_Bin, 0, Acc) ->
    lists:reverse(Acc);
isobmff_compatible_brands(<<Brand:4/binary, Rest/binary>>, N, Acc) ->
    isobmff_compatible_brands(Rest, N - 1, [Brand | Acc]);
isobmff_compatible_brands(_, _N, Acc) ->
    lists:reverse(Acc).

store_upload(Hash, Pubkey, TempPath, Size, ContentType, Req, State) ->
    Extension = extension_for_mime(ContentType),
    CreatedAt = erlang:system_time(second),
    OwnerMeta = #{created_at => CreatedAt, expiration => 0, protocol => blossom},
    case damage_nip96_store:lookup(Hash) of
        {ok, ExistingObject, _Owners} ->
            claim_and_reply(Hash, Pubkey, ExistingObject, OwnerMeta, existing, Req, State);
        {error, not_found} ->
            case extract_cid(damage_ipfs:add({file, to_bin(TempPath)})) of
                {ok, Cid} ->
                    ObjectMeta = #{
                        hash => Hash,
                        cid => Cid,
                        size => Size,
                        content_type => ContentType,
                        extension => Extension,
                        created_at => CreatedAt
                    },
                    case ensure_pin(Cid) of
                        ok -> claim_and_reply(Hash, Pubkey, ObjectMeta, OwnerMeta, new, Req, State);
                        {error, Reason} ->
                            ?LOG_ERROR("Blossom failed to register IPFS pin cid=~p reason=~p", [Cid, Reason]),
                            {ok, reply_error(503, <<"IPFS persistence unavailable">>, Req), State}
                    end;
                {error, Reason} ->
                    ?LOG_ERROR("Blossom IPFS add failed hash=~p reason=~p", [Hash, Reason]),
                    {ok, reply_error(503, <<"IPFS storage unavailable">>, Req), State}
            end;
        {error, Reason} ->
            ?LOG_ERROR("Blossom metadata lookup failed hash=~p reason=~p", [Hash, Reason]),
            {ok, reply_error(503, <<"Blob metadata store unavailable">>, Req), State}
    end.

claim_and_reply(Hash, Pubkey, Object, Owner, ExpectedNewness, Req, State) ->
    case damage_nip96_store:claim_source(blossom, Hash, Pubkey, Object, Owner) of
        {ok, Newness0, StoredObject} ->
            Newness =
                case {ExpectedNewness, Newness0} of
                    {existing, _} -> existing;
                    {_, existing} -> existing;
                    _ -> new
                end,
            Status = case Newness of new -> 201; existing -> 200 end,
            {ok, reply_json(Status, blob_descriptor(Hash, StoredObject, Owner, Req), Req), State};
        {error, hash_cid_conflict} ->
            {ok, reply_error(409, <<"SHA-256 conflicts with stored IPFS object">>, Req), State};
        {error, Reason} ->
            ?LOG_ERROR("Blossom ownership persistence failed hash=~p reason=~p", [Hash, Reason]),
            {ok, reply_error(503, <<"Blob metadata store unavailable">>, Req), State}
    end.

%% ------------------------------------------------------------------
%% BUD-01 retrieval
%% ------------------------------------------------------------------

handle_get(Req0, State) ->
    case rate_check_ip(download_ip, Req0) of
        ok ->
            case request_hash(Req0) of
                {ok, Hash} -> serve_blob(get, Hash, Req0, State);
                error -> {ok, reply_error(400, <<"Invalid SHA-256 path">>, Req0), State}
            end;
        RateError ->
            {ok, reply_rate_error(RateError, Req0), State}
    end.

handle_head(Req0, State) ->
    case rate_check_ip(download_ip, Req0) of
        ok ->
            case request_hash(Req0) of
                {ok, Hash} -> serve_blob(head, Hash, Req0, State);
                error -> {ok, reply_head_error(400, <<"Invalid SHA-256 path">>, Req0), State}
            end;
        RateError ->
            {ok, reply_head_rate_error(RateError, Req0), State}
    end.

serve_blob(Method, Hash, Req0, State) ->
    case damage_nip96_store:lookup(Hash) of
        {ok, #{cid := Cid} = Object, _Owners} ->
            case load_verified_blob(Hash, Cid, Object) of
                {ok, Data} ->
                    serve_verified_blob(Method, Hash, Cid, Object, Data, Req0, State);
                {error, integrity_mismatch} ->
                    ?LOG_ERROR("Blossom IPFS integrity mismatch hash=~p cid=~p", [Hash, Cid]),
                    {ok, method_error(Method, 502, <<"Stored blob failed integrity verification">>, Req0), State};
                {error, Reason} ->
                    ?LOG_WARNING("Blossom IPFS read failed hash=~p cid=~p reason=~p", [Hash, Cid, Reason]),
                    {ok, method_error(Method, 503, <<"Blob temporarily unavailable">>, Req0), State}
            end;
        {error, not_found} ->
            {ok, method_error(Method, 404, <<"Blob not found">>, Req0), State};
        {error, Reason} ->
            ?LOG_ERROR("Blossom metadata lookup failed hash=~p reason=~p", [Hash, Reason]),
            {ok, method_error(Method, 503, <<"Blob metadata store unavailable">>, Req0), State}
    end.

load_verified_blob(Hash, Cid, Object) ->
    MaxServeBytes = max_serve_bytes(),
    case maps:get(size, Object, undefined) of
        RecordedSize when
            is_integer(RecordedSize),
            RecordedSize > 0,
            RecordedSize =< MaxServeBytes
        ->
            case damage_ipfs:cat_binary(Cid, [{max_bytes, RecordedSize}]) of
                {ok, Data} ->
                    case {byte_size(Data), lower_hex(crypto:hash(sha256, Data))} of
                        {RecordedSize, Hash} ->
                            {ok, Data};
                        _ ->
                            {error, integrity_mismatch}
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, invalid_recorded_size}
    end.

serve_verified_blob(Method, Hash, Cid, Object, Data, Req0, State) ->
    ETag = <<"\"", Hash/binary, "\"">>,
    case if_none_match(Req0, ETag) of
        true ->
            Headers = blob_headers(Hash, Cid, Object, byte_size(Data)),
            {ok, cowboy_req:reply(304, Headers, <<>>, Req0), State};
        false when Method =:= head ->
            Headers = blob_headers(Hash, Cid, Object, byte_size(Data)),
            {ok, cowboy_req:reply(200, Headers, <<>>, Req0), State};
        false ->
            serve_get_range(Hash, Cid, Object, Data, Req0, State)
    end.

serve_get_range(Hash, Cid, Object, Data, Req0, State) ->
    Size = byte_size(Data),
    case cowboy_req:header(<<"range">>, Req0) of
        undefined ->
            Headers = blob_headers(Hash, Cid, Object, Size),
            {ok, cowboy_req:reply(200, Headers, Data, Req0), State};
        RangeHeader ->
            case parse_byte_range(RangeHeader, Size) of
                {ok, Start, End} ->
                    Length = End - Start + 1,
                    Part = binary:part(Data, Start, Length),
                    Headers = (blob_headers(Hash, Cid, Object, Length))#{
                        <<"content-range">> => content_range(Start, End, Size)
                    },
                    {ok, cowboy_req:reply(206, Headers, Part, Req0), State};
                error ->
                    Headers = cors_headers(#{
                        <<"content-range">> => <<"bytes */", (integer_to_binary(Size))/binary>>,
                        <<"x-reason">> => <<"Invalid or unsatisfiable byte range">>
                    }),
                    {ok, cowboy_req:reply(416, Headers, <<>>, Req0), State}
            end
    end.

blob_headers(Hash, Cid, Object, ContentLength) ->
    CType = maps:get(content_type, Object, <<"application/octet-stream">>),
    cors_headers(#{
        <<"content-type">> => CType,
        <<"content-length">> => integer_to_binary(ContentLength),
        <<"accept-ranges">> => <<"bytes">>,
        <<"etag">> => <<"\"", Hash/binary, "\"">>,
        <<"cache-control">> => <<"public, max-age=31536000, immutable">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"content-security-policy">> => <<"sandbox; default-src 'none'">>,
        <<"content-disposition">> => content_disposition(Hash, Object),
        <<"x-ipfs-cid">> => Cid
    }).

if_none_match(Req, ETag) ->
    case cowboy_req:header(<<"if-none-match">>, Req) of
        ETag -> true;
        <<"*">> -> true;
        _ -> false
    end.

parse_byte_range(_Header, 0) -> error;
parse_byte_range(Header, Size) when is_binary(Header), Size > 0 ->
    case Header of
        <<"bytes=", Spec/binary>> ->
            case binary:match(Spec, <<",">>) of
                nomatch -> parse_single_range(Spec, Size);
                _ -> error
            end;
        _ -> error
    end.

parse_single_range(Spec, Size) ->
    case binary:split(Spec, <<"-">>) of
        [<<>>, Suffix0] ->
            case parse_positive_int(Suffix0) of
                {ok, Suffix} ->
                    Length = min(Suffix, Size),
                    {ok, Size - Length, Size - 1};
                error -> error
            end;
        [Start0, <<>>] ->
            case parse_nonneg_int(Start0) of
                {ok, Start} when Start < Size -> {ok, Start, Size - 1};
                _ -> error
            end;
        [Start0, End0] ->
            case {parse_nonneg_int(Start0), parse_nonneg_int(End0)} of
                {{ok, Start}, {ok, End0I}} when Start < Size, End0I >= Start ->
                    {ok, Start, min(End0I, Size - 1)};
                _ -> error
            end;
        _ -> error
    end.

content_range(Start, End, Size) ->
    <<"bytes ", (integer_to_binary(Start))/binary, "-", (integer_to_binary(End))/binary,
        "/", (integer_to_binary(Size))/binary>>.

%% ------------------------------------------------------------------
%% BUD-12 delete/list
%% ------------------------------------------------------------------

handle_delete(Req0, State) ->
    case rate_check_ip(delete_ip, Req0) of
        ok ->
            case request_hash(Req0) of
                {ok, Hash} ->
                    case damage_blossom_auth:verify(Req0, <<"delete">>, Hash) of
                        {ok, #{pubkey := Pubkey}} ->
                            case rate_check_pubkey(delete_pubkey, Pubkey) of
                                ok ->
                                    case damage_nip96_store:release_source(
                                        blossom, Hash, Pubkey
                                    ) of
                                        {ok, last_owner, Object} ->
                                            maybe_unpin_last_owner(Object),
                                            {ok, cowboy_req:reply(
                                                204, cors_headers(#{}), <<>>, Req0
                                            ), State};
                                        {ok, shared, _Object} ->
                                            {ok, cowboy_req:reply(
                                                204, cors_headers(#{}), <<>>, Req0
                                            ), State};
                                        {error, not_owner} ->
                                            {ok, reply_error(
                                                404,
                                                <<"Blob is not owned by authenticated pubkey">>,
                                                Req0
                                            ), State};
                                        {error, Reason} ->
                                            ?LOG_ERROR(
                                                "Blossom delete failed hash=~p reason=~p",
                                                [Hash, Reason]
                                            ),
                                            {ok, reply_error(
                                                503,
                                                <<"Blob metadata store unavailable">>,
                                                Req0
                                            ), State}
                                    end;
                                RateError ->
                                    {ok, reply_rate_error(RateError, Req0), State}
                            end;
                        {error, Reason} ->
                            ?LOG_WARNING("Blossom delete auth failed: ~p", [Reason]),
                            {ok, reply_auth_error(Req0), State}
                    end;
                error ->
                    {ok, reply_error(400, <<"Invalid SHA-256 path">>, Req0), State}
            end;
        RateError ->
            {ok, reply_rate_error(RateError, Req0), State}
    end.

handle_list(Req0, State) ->
    case rate_check_ip(list_ip, Req0) of
        ok ->
            case blossom_list_enabled() of
                false ->
                    {ok, reply_error(404, <<"Blob listing is disabled">>, Req0), State};
                true ->
                    case request_pubkey(Req0) of
                        {ok, Pubkey} -> handle_list_pubkey(Pubkey, Req0, State);
                        error -> {ok, reply_error(400, <<"Invalid pubkey">>, Req0), State}
                    end
            end;
        RateError ->
            {ok, reply_rate_error(RateError, Req0), State}
    end.

handle_list_pubkey(Pubkey, Req0, State) ->
    case authorize_list(Pubkey, Req0) of
        ok ->
            case list_args(Req0) of
                {ok, Cursor, Limit} ->
                    case damage_nip96_store:list_cursor(blossom, Pubkey, Cursor, Limit) of
                        {ok, #{files := Rows}} ->
                            Body = [blob_descriptor(Hash, Object, Owner, Req0) || {Hash, Object, Owner} <- Rows],
                            {ok, reply_json(200, Body, Req0), State};
                        {error, cursor_not_found} ->
                            {ok, reply_error(400, <<"Cursor does not identify a blob in this list">>, Req0), State};
                        {error, Reason} ->
                            ?LOG_ERROR("Blossom list failed pubkey=~p reason=~p", [Pubkey, Reason]),
                            {ok, reply_error(503, <<"Blob metadata store unavailable">>, Req0), State}
                    end;
                {error, _} ->
                    {ok, reply_error(400, <<"Malformed list cursor or limit">>, Req0), State}
            end;
        {error, unauthorized} ->
            {ok, reply_auth_error(Req0), State};
        {error, forbidden} ->
            {ok, reply_error(403, <<"Listing another pubkey is not allowed">>, Req0), State}
    end.

authorize_list(Pubkey, Req) ->
    RequireAuth = application:get_env(damage, blossom_list_require_auth, false),
    AllowOthers = application:get_env(damage, blossom_list_allow_others, true),
    case {RequireAuth, AllowOthers} of
        {false, true} ->
            ok;
        _ ->
            case damage_blossom_auth:verify(Req, <<"list">>, undefined) of
                {ok, #{pubkey := AuthPubkey}} ->
                    case AllowOthers orelse AuthPubkey =:= Pubkey of
                        true -> ok;
                        false -> {error, forbidden}
                    end;
                {error, _} ->
                    {error, unauthorized}
            end
    end.

%% ------------------------------------------------------------------
%% Shared descriptor/IPFS helpers
%% ------------------------------------------------------------------

blob_descriptor(Hash, Object, Owner, Req) ->
    Cid = maps:get(cid, Object),
    #{
        <<"url">> => blob_url(Hash, Object, Req),
        <<"sha256">> => Hash,
        <<"size">> => maps:get(size, Object, 0),
        <<"type">> => maps:get(content_type, Object, <<"application/octet-stream">>),
        <<"uploaded">> => maps:get(created_at, Owner, maps:get(created_at, Object, 0)),
        <<"ipfs">> => <<"ipfs://", Cid/binary>>
    }.

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
    case application:get_env(
        damage,
        blossom_pin_uploads,
        application:get_env(damage, nip96_pin_uploads, true)
    ) of
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
    %% False by default because IPFS pins can be referenced outside the HTTP
    %% ownership metadata store by other DamageBDD subsystems.
    case application:get_env(damage, blossom_unpin_on_delete, false) of
        true ->
            case damage_ipfs:unpin_async(Cid) of
                ok -> ok;
                {ok, _} -> ok;
                Error -> ?LOG_WARNING("Blossom async unpin failed cid=~p reason=~p", [Cid, Error])
            end;
        _ -> ok
    end;
maybe_unpin_last_owner(_) -> ok.

%% ------------------------------------------------------------------
%% URL/path/query helpers
%% ------------------------------------------------------------------

request_hash(Req) ->
    try cowboy_req:binding(blob, Req) of
        Segment when is_binary(Segment) ->
            case parse_hash_segment(Segment) of
                {ok, _} = Ok -> Ok;
                _ -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

request_pubkey(Req) ->
    try cowboy_req:binding(pubkey, Req) of
        Pubkey0 when is_binary(Pubkey0) ->
            case parse_hash(Pubkey0) of
                {ok, _} = Ok -> Ok;
                _ -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

parse_hash_segment(Segment) ->
    Hash0 = hd(binary:split(Segment, <<".">>, [global])),
    parse_hash(Hash0).

parse_hash(undefined) -> {error, missing};
parse_hash(Hash0) ->
    Hash = lower_ascii(to_bin(Hash0)),
    case byte_size(Hash) =:= 64 andalso
        re:run(Hash, <<"\\A[0-9a-f]{64}\\z">>, [{capture, none}]) =:= match
    of
        true -> {ok, Hash};
        false -> {error, invalid}
    end.

blob_url(Hash, Object, Req) ->
    Ext = case maps:get(extension, Object, <<>>) of <<>> -> <<".bin">>; V -> V end,
    <<(public_base_url(Req))/binary, "/", Hash/binary, Ext/binary>>.

public_base_url(Req) ->
    case application:get_env(damage, blossom_public_base_url) of
        {ok, Value} -> trim_trailing_slash(to_bin(Value));
        undefined ->
            case application:get_env(damage, nip96_public_base_url) of
                {ok, Value} -> trim_trailing_slash(to_bin(Value));
                undefined ->
                    case application:get_env(damage, api_url) of
                        {ok, Value} -> trim_trailing_slash(to_bin(Value));
                        undefined -> request_origin(Req)
                    end
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

list_args(Req) ->
    Pairs = cowboy_req:parse_qs(Req),
    Cursor0 = proplists:get_value(<<"cursor">>, Pairs),
    Limit0 = proplists:get_value(<<"limit">>, Pairs),
    case {parse_cursor(Cursor0), parse_limit(Limit0)} of
        {{ok, Cursor}, {ok, Limit}} -> {ok, Cursor, Limit};
        _ -> {error, invalid_query}
    end.

parse_cursor(undefined) -> {ok, undefined};
parse_cursor(Bin) -> parse_hash(Bin).

parse_limit(undefined) -> {ok, ?DEFAULT_LIST_LIMIT};
parse_limit(Bin) ->
    case parse_positive_int(Bin) of
        {ok, I} -> {ok, min(I, ?MAX_LIST_LIMIT)};
        error -> {error, invalid}
    end.

parse_size(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        I when I > 0, I =< ?ABSOLUTE_MAX_BYTES -> {ok, I};
        _ -> {error, invalid}
    catch
        _:_ -> {error, invalid}
    end;
parse_size(_) -> {error, invalid}.

parse_nonneg_int(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try binary_to_integer(Bin) of
        I when I >= 0 -> {ok, I};
        _ -> error
    catch
        _:_ -> error
    end;
parse_nonneg_int(_) -> error.

parse_positive_int(Bin) ->
    case parse_nonneg_int(Bin) of
        {ok, I} when I > 0 -> {ok, I};
        _ -> error
    end.

normalize_content_type(undefined) -> {error, missing};
normalize_content_type(<<>>) -> {error, missing};
normalize_content_type(Bin0) ->
    Bin = to_bin(Bin0),
    Mime0 = hd(binary:split(Bin, <<";">>, [global])),
    Mime = lower_ascii(trim_binary(Mime0)),
    case valid_mime_type(Mime) of
        true -> {ok, Mime};
        false -> {error, invalid}
    end.

normalize_upload_content_type(Bin0) ->
    case normalize_content_type(Bin0) of
        {ok, ContentType} ->
            case content_type_allowed(ContentType) of
                true -> {ok, ContentType};
                false -> {error, unsupported}
            end;
        {error, _} = Error ->
            Error
    end.

content_type_allowed(<<"application/octet-stream">>) ->
    application:get_env(damage, blossom_allow_octet_stream, false) =:= true;
content_type_allowed(ContentType) ->
    lists:member(ContentType, allowed_content_types()).

allowed_content_types() ->
    Default = [
        <<"image/jpeg">>,
        <<"image/png">>,
        <<"image/gif">>,
        <<"image/webp">>,
        <<"image/avif">>,
        <<"image/heic">>,
        <<"image/heif">>,
        <<"video/mp4">>,
        <<"video/quicktime">>,
        <<"video/webm">>,
        <<"audio/mpeg">>,
        <<"audio/ogg">>,
        <<"audio/wav">>,
        <<"application/pdf">>
    ],
    case application:get_env(damage, blossom_allowed_content_types) of
        {ok, Values} when is_list(Values) ->
            Normalized = [
                lower_ascii(to_bin(V))
             || V <- Values,
                is_binary(V) orelse is_list(V) orelse is_atom(V)
            ],
            case Normalized of
                [] -> Default;
                _ -> Normalized
            end;
        _ ->
            Default
    end.

valid_mime_type(Mime) when is_binary(Mime), byte_size(Mime) =< 255 ->
    re:run(Mime, <<"\\A[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+\\z">>, [{capture, none}]) =:= match;
valid_mime_type(_) -> false.

blossom_list_enabled() ->
    application:get_env(damage, blossom_list_enabled, false) =:= true.

max_upload_bytes() ->
    Configured =
        case application:get_env(damage, blossom_max_bytes) of
            {ok, I} when is_integer(I), I > 0 -> I;
            _ ->
                case application:get_env(damage, nip96_max_bytes) of
                    {ok, I} when is_integer(I), I > 0 -> I;
                    _ -> maps:get(
                        max_request_bytes,
                        damage_ipfs_config:load(),
                        ?DEFAULT_MAX_BYTES
                    )
                end
        end,
    min(max(1, Configured), ?ABSOLUTE_MAX_BYTES).

max_serve_bytes() ->
    case application:get_env(damage, blossom_max_serve_bytes) of
        {ok, I} when is_integer(I), I > 0 ->
            min(I, ?ABSOLUTE_MAX_BYTES);
        _ ->
            max_upload_bytes()
    end.

upload_timeout_ms() ->
    Configured =
        case application:get_env(damage, blossom_upload_timeout_ms) of
            {ok, I} when is_integer(I), I > 0 -> I;
            _ ->
                case application:get_env(damage, nip96_upload_timeout_ms) of
                    {ok, I} when is_integer(I), I > 0 -> I;
                    _ -> ?DEFAULT_UPLOAD_TIMEOUT_MS
                end
        end,
    min(max(?MIN_UPLOAD_TIMEOUT_MS, Configured), ?MAX_UPLOAD_TIMEOUT_MS).

remaining_upload_ms(Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        true -> min(5000, Remaining);
        false -> timeout
    end.

temp_upload_path() ->
    C = damage_ipfs_config:load(),
    Dir = filename:join(maps:get(data_dir, C), "blossom_uploads"),
    Name = "upload-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++ ".tmp",
    Path = filename:join(Dir, Name),
    case filelib:ensure_dir(Path) of
        ok -> {ok, Path};
        {error, _} = Error -> Error
    end.

content_disposition(Hash, Object) ->
    Ext = case maps:get(extension, Object, <<>>) of <<>> -> <<".bin">>; V -> V end,
    ContentType = maps:get(content_type, Object, <<"application/octet-stream">>),
    Disposition =
        case safe_inline_content_type(ContentType) of
            true -> <<"inline">>;
            false -> <<"attachment">>
        end,
    <<Disposition/binary, "; filename=\"", Hash/binary, Ext/binary, "\"">>.

safe_inline_content_type(<<"image/jpeg">>) -> true;
safe_inline_content_type(<<"image/png">>) -> true;
safe_inline_content_type(<<"image/gif">>) -> true;
safe_inline_content_type(<<"image/webp">>) -> true;
safe_inline_content_type(<<"image/avif">>) -> true;
safe_inline_content_type(<<"image/heic">>) -> true;
safe_inline_content_type(<<"image/heif">>) -> true;
safe_inline_content_type(<<"video/mp4">>) -> true;
safe_inline_content_type(<<"video/quicktime">>) -> true;
safe_inline_content_type(<<"video/webm">>) -> true;
safe_inline_content_type(<<"audio/mpeg">>) -> true;
safe_inline_content_type(<<"audio/ogg">>) -> true;
safe_inline_content_type(<<"audio/wav">>) -> true;
safe_inline_content_type(_) -> false.

extension_for_mime(<<"image/jpeg">>) -> <<".jpg">>;
extension_for_mime(<<"image/png">>) -> <<".png">>;
extension_for_mime(<<"image/gif">>) -> <<".gif">>;
extension_for_mime(<<"image/webp">>) -> <<".webp">>;
extension_for_mime(<<"image/avif">>) -> <<".avif">>;
extension_for_mime(<<"image/heic">>) -> <<".heic">>;
extension_for_mime(<<"image/heif">>) -> <<".heif">>;
extension_for_mime(<<"image/svg+xml">>) -> <<".svg">>;
extension_for_mime(<<"video/mp4">>) -> <<".mp4">>;
extension_for_mime(<<"video/quicktime">>) -> <<".mov">>;
extension_for_mime(<<"video/webm">>) -> <<".webm">>;
extension_for_mime(<<"audio/mpeg">>) -> <<".mp3">>;
extension_for_mime(<<"audio/ogg">>) -> <<".ogg">>;
extension_for_mime(<<"audio/wav">>) -> <<".wav">>;
extension_for_mime(<<"application/pdf">>) -> <<".pdf">>;
extension_for_mime(<<"application/json">>) -> <<".json">>;
extension_for_mime(<<"text/plain">>) -> <<".txt">>;
extension_for_mime(_) -> <<".bin">>.

%% ------------------------------------------------------------------
%% Rate limiting
%% ------------------------------------------------------------------

rate_check_ip(Scope, Req) ->
    Subject = damage_utils:get_ip(Req),
    {Limit, Window} = rate_policy(Scope),
    rate_check(Scope, Subject, Limit, Window).

rate_check_pubkey(Scope, Pubkey) ->
    {Limit, Window} = rate_policy(Scope),
    rate_check(Scope, Pubkey, Limit, Window).

rate_check(Scope, Subject, Limit, Window) ->
    try damage_blossom_rate:check(Scope, Subject, Limit, Window) of
        ok -> ok;
        {error, {rate_limited, RetryAfter}} ->
            ?LOG_WARNING(
                "Blossom rate limit exceeded scope=~p retry_after=~p",
                [Scope, RetryAfter]
            ),
            {error, {rate_limited, RetryAfter}};
        {error, rate_limiter_capacity} ->
            ?LOG_ERROR("Blossom rate limiter capacity reached scope=~p", [Scope]),
            {error, rate_limiter_unavailable};
        Other ->
            ?LOG_ERROR("Blossom rate limiter unexpected result scope=~p result=~p", [
                Scope, Other
            ]),
            {error, rate_limiter_unavailable}
    catch
        Class:Reason ->
            ?LOG_ERROR(
                "Blossom rate limiter unavailable scope=~p class=~p reason=~p",
                [Scope, Class, Reason]
            ),
            {error, rate_limiter_unavailable}
    end.

rate_policy(upload_ip) ->
    {
        configured_int(blossom_upload_ip_requests_per_minute, ?DEFAULT_UPLOAD_IP_RATE, 1, 10000),
        60
    };
rate_policy(upload_pubkey) ->
    {
        configured_int(
            blossom_upload_pubkey_requests_per_minute,
            ?DEFAULT_UPLOAD_PUBKEY_RATE,
            1,
            10000
        ),
        60
    };
rate_policy(delete_ip) ->
    {
        configured_int(blossom_delete_ip_requests_per_minute, ?DEFAULT_DELETE_IP_RATE, 1, 10000),
        60
    };
rate_policy(delete_pubkey) ->
    {
        configured_int(
            blossom_delete_pubkey_requests_per_minute,
            ?DEFAULT_DELETE_PUBKEY_RATE,
            1,
            10000
        ),
        60
    };
rate_policy(download_ip) ->
    {
        configured_int(
            blossom_download_ip_requests_per_minute,
            ?DEFAULT_DOWNLOAD_IP_RATE,
            1,
            100000
        ),
        60
    };
rate_policy(list_ip) ->
    {
        configured_int(blossom_list_ip_requests_per_minute, ?DEFAULT_LIST_IP_RATE, 1, 10000),
        60
    }.

configured_int(Key, Default, Min, Max) ->
    case application:get_env(damage, Key, Default) of
        I when is_integer(I), I >= Min, I =< Max -> I;
        I when is_integer(I), I > Max -> Max;
        _ -> Default
    end.

%% ------------------------------------------------------------------
%% Response helpers
%% ------------------------------------------------------------------

method_error(head, Status, Reason, Req) -> reply_head_error(Status, Reason, Req);
method_error(_, Status, Reason, Req) -> reply_error(Status, Reason, Req).

reply_json(Status, Body, Req) ->
    Headers = cors_headers(#{<<"content-type">> => <<"application/json">>}),
    cowboy_req:reply(Status, Headers, jsx:encode(Body), Req).

reply_error(Status, Reason, Req) ->
    Headers = cors_headers(#{
        <<"content-type">> => <<"text/plain; charset=utf-8">>,
        <<"x-reason">> => Reason
    }),
    cowboy_req:reply(Status, Headers, Reason, Req).

reply_head_error(Status, Reason, Req) ->
    Headers = cors_headers(#{<<"x-reason">> => Reason}),
    cowboy_req:reply(Status, Headers, <<>>, Req).

reply_auth_error(Req) ->
    Headers = cors_headers(#{
        <<"content-type">> => <<"text/plain; charset=utf-8">>,
        <<"www-authenticate">> => <<"Nostr">>,
        <<"x-reason">> => <<"Valid BUD-11 authorization required">>
    }),
    cowboy_req:reply(401, Headers, <<"Valid BUD-11 authorization required">>, Req).

reply_head_auth_error(Req) ->
    Headers = cors_headers(#{
        <<"www-authenticate">> => <<"Nostr">>,
        <<"x-reason">> => <<"Valid BUD-11 authorization required">>
    }),
    cowboy_req:reply(401, Headers, <<>>, Req).

reply_rate_error({error, {rate_limited, RetryAfter}}, Req) ->
    Headers = cors_headers(#{
        <<"content-type">> => <<"text/plain; charset=utf-8">>,
        <<"retry-after">> => integer_to_binary(RetryAfter),
        <<"x-reason">> => <<"Rate limit exceeded">>
    }),
    cowboy_req:reply(429, Headers, <<"Rate limit exceeded">>, Req);
reply_rate_error(_RateError, Req) ->
    reply_error(503, <<"Blossom rate limiter unavailable">>, Req).

reply_head_rate_error({error, {rate_limited, RetryAfter}}, Req) ->
    Headers = cors_headers(#{
        <<"retry-after">> => integer_to_binary(RetryAfter),
        <<"x-reason">> => <<"Rate limit exceeded">>
    }),
    cowboy_req:reply(429, Headers, <<>>, Req);
reply_head_rate_error(_RateError, Req) ->
    reply_head_error(503, <<"Blossom rate limiter unavailable">>, Req).

reply_options(Req) ->
    Headers = cors_headers(#{
        <<"allow">> => <<"GET, HEAD, PUT, DELETE, OPTIONS">>,
        <<"access-control-allow-methods">> => <<"GET, HEAD, PUT, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> =>
            <<"Authorization, Content-Type, X-SHA-256, X-Content-Type, X-Content-Length, *">>,
        <<"access-control-max-age">> => <<"86400">>
    }),
    cowboy_req:reply(204, Headers, <<>>, Req).

cors_headers(Headers) ->
    Headers#{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-expose-headers">> =>
            <<"Content-Length, Content-Range, ETag, X-Reason, X-IPFS-CID">>
    }.

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
