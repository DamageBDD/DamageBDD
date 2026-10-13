%%--------------------------------------------------------------------
%% Authenticated dashboard boundary for Quick Index.
%%
%% POST /ecai/quick-index/inspect
%%   JSON: {"source_type":"url","url":"https://..."}
%%         {"source_type":"ipfs","cid":"bafy..."}
%%   file: application/octet-stream + X-ECAI-File-Name / X-ECAI-File-Type
%%
%% POST /ecai/quick-index
%%   same source plus the sha256 returned by inspect and an Idempotency-Key.
%%--------------------------------------------------------------------
-module(ecai_quick_index_http).

-export([
    trails/0,
    init/2,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    from_data/2,
    to_json/2
]).

-define(JSON, <<"application/json">>).
-define(TAG, ["ECAI Quick Index"]).
-define(DEFAULT_MAX_SOURCE_BYTES, 16777216).
-define(MAX_JSON_BYTES, 65536).

trails() ->
    [
        trails:trail(
            "/ecai/quick-index/inspect",
            ?MODULE,
            #{action => inspect},
            #{post => #{tags => ?TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/quick-index",
            ?MODULE,
            #{action => enqueue},
            #{post => #{tags => ?TAG, produces => ["application/json"]}}
        )
    ].

init(Req, State) -> {cowboy_rest, Req, State}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

allowed_methods(Req, State) -> {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_data},
            {{<<"application">>, <<"octet-stream">>, '*'}, from_data}
        ],
        Req,
        State
    }.

to_json(Req, State) -> reply_error(Req, 405, method_not_allowed, State).

from_data(Req0, #{action := Action} = State) ->
    case authenticated_owner(State) of
        undefined ->
            reply_error(Req0, 403, managed_account_required, State);
        Owner ->
            case read_source(Req0, max_source_bytes()) of
                {ok, Source, ExpectedSha, Req1} ->
                    handle_source(Action, Source, ExpectedSha, Owner, Req1, State);
                {error, Code, Reason, Req1} ->
                    reply_error(Req1, Code, Reason, State)
            end
    end.

handle_source(Action, Source, ExpectedSha, Owner, Req, State) ->
    MaxBytes = max_source_bytes(),
    case safe_call(fun() -> ecai_quick_index_source:acquire(Source, MaxBytes) end) of
        {ok, {ok, Bytes, Meta, SourceInfo0}} ->
            case safe_call(fun() -> ecai_quick_index_detector:analyze(Bytes, Meta) end) of
                {ok, {ok, Analysis}} ->
                    SourceInfo = SourceInfo0#{
                        bytes => Bytes,
                        filename => maps:get(filename, Meta, maps:get(title, SourceInfo0, <<"source.txt">>))
                    },
                    handle_analysis(Action, SourceInfo, Analysis, ExpectedSha, Owner, Req, State);
                {ok, {error, Reason}} -> reply_error(Req, 422, Reason, State);
                {error, Reason} -> reply_error(Req, 500, Reason, State)
            end;
        {ok, {error, Reason}} -> reply_error(Req, source_error_code(Reason), Reason, State);
        {error, Reason} -> reply_error(Req, 503, Reason, State)
    end.

handle_analysis(inspect, SourceInfo, Analysis, _ExpectedSha, _Owner, Req, State) ->
    reply_json(Req, 200, #{
        ok => true,
        source => ecai_index_job_codec:externalize(public_source(SourceInfo)),
        analysis => ecai_index_job_codec:externalize(Analysis)
    }, State);
handle_analysis(enqueue, SourceInfo, Analysis, ExpectedSha, Owner, Req, State) ->
    case validate_enqueue_preconditions(Analysis, ExpectedSha, Req) of
        {ok, IdempotencyKey} ->
            case safe_call(fun() -> ecai_quick_index_source:stage(SourceInfo, Analysis) end) of
                {ok, {ok, Staged}} -> enqueue_staged(Staged, Analysis, Owner, IdempotencyKey, Req, State);
                {ok, {error, Reason}} -> reply_error(Req, source_error_code(Reason), Reason, State);
                {error, Reason} -> reply_error(Req, 503, Reason, State)
            end;
        {error, Code, Reason} -> reply_error(Req, Code, Reason, State)
    end.

validate_enqueue_preconditions(Analysis, ExpectedSha0, Req) ->
    case maps:get(indexable, Analysis, false) of
        false -> {error, 422, {unsupported_source_format, maps:get(format, Analysis, unknown)}};
        true ->
            ActualSha = maps:get(sha256, Analysis),
            ExpectedSha = lowercase(ExpectedSha0),
            case valid_sha256(ExpectedSha) andalso ExpectedSha =:= ActualSha of
                false when ExpectedSha =:= <<>> -> {error, 400, inspection_sha256_required};
                false -> {error, 409, source_changed_since_inspection};
                true -> required_idempotency_key(Req)
            end
    end.

enqueue_staged(Staged, Analysis, Owner, IdempotencyKey, Req, State) ->
    Cid = maps:get(cid, Staged),
    Spec = #{
        <<"schema">> => ecai_index_job_codec:version(),
        <<"kind">> => <<"ipfs_cid">>,
        <<"owner">> => Owner,
        <<"source">> => #{
            <<"cid">> => Cid,
            <<"title">> => maps:get(title, Staged, <<>>),
            <<"source_key">> => maps:get(source_key, Staged, <<"ipfs://", Cid/binary>>)
        },
        <<"target">> => #{<<"mode">> => <<"searchable_disk">>},
        <<"options">> => #{<<"priority">> => 100, <<"batch_size">> => 1},
        <<"finalize">> => #{<<"build_nft_manifest">> => true, <<"publish_ipfs">> => false}
    },
    case safe_call(fun() ->
        ecai_index_jobs_srv:enqueue(Spec, #{idempotency_key => IdempotencyKey})
    end) of
        {ok, {ok, Job}} ->
            reply_json(Req, 202, #{
                ok => true,
                cid => Cid,
                source => ecai_index_job_codec:externalize(public_source(Staged)),
                analysis => ecai_index_job_codec:externalize(Analysis),
                job => ecai_index_job_codec:externalize(Job)
            }, State);
        {ok, {error, Reason}} -> reply_error(Req, enqueue_error_code(Reason), Reason, State);
        {error, Reason} -> reply_error(Req, 503, Reason, State)
    end.

read_source(Req0, MaxBytes) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req0, <<>>),
    case binary:match(ContentType, <<"application/octet-stream">>) of
        {0, _} -> read_file_source(Req0, MaxBytes);
        _ -> read_json_source(Req0)
    end.

read_file_source(Req0, MaxBytes) ->
    case read_body_limited(Req0, MaxBytes) of
        {ok, <<>>, Req1} -> {error, 400, empty_source, Req1};
        {ok, Bytes, Req1} ->
            Name0 = cowboy_req:header(<<"x-ecai-file-name">>, Req1, <<"source.txt">>),
            Name = percent_decode(Name0),
            Mime = cowboy_req:header(<<"x-ecai-file-type">>, Req1, <<"application/octet-stream">>),
            Expected = cowboy_req:header(<<"x-ecai-expected-sha256">>, Req1, <<>>),
            {ok, #{kind => file, bytes => Bytes, filename => Name, mime => Mime}, Expected, Req1};
        {error, Code, Reason, Req1} -> {error, Code, Reason, Req1}
    end.

read_json_source(Req0) ->
    case read_body_limited(Req0, ?MAX_JSON_BYTES) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> json_source(Map, Req1);
                _ -> {error, 400, json_object_required, Req1}
            catch
                _:_ -> {error, 400, invalid_json, Req1}
            end;
        Error -> Error
    end.

json_source(Map, Req) ->
    Expected = maps:get(<<"expected_sha256">>, Map, <<>>),
    case maps:get(<<"source_type">>, Map, undefined) of
        <<"url">> ->
            case maps:get(<<"url">>, Map, undefined) of
                Url when is_binary(Url), byte_size(Url) > 0, byte_size(Url) =< 4096 ->
                    {ok, #{kind => url, url => Url}, Expected, Req};
                _ -> {error, 400, invalid_url, Req}
            end;
        <<"ipfs">> ->
            case maps:get(<<"cid">>, Map, undefined) of
                Cid when is_binary(Cid), byte_size(Cid) > 0, byte_size(Cid) =< 512 ->
                    {ok, #{kind => ipfs, cid => Cid}, Expected, Req};
                _ -> {error, 400, invalid_ipfs_cid, Req}
            end;
        _ -> {error, 400, invalid_source_type, Req}
    end.

read_body_limited(Req0, Limit) ->
    case cowboy_req:read_body(Req0, #{length => Limit, period => 10000}) of
        {ok, Body, Req1} -> {ok, Body, Req1};
        {more, _Partial, Req1} -> {error, 413, payload_too_large, Req1}
    end.

public_source(Source) ->
    maps:filter(
        fun(Key, _Value) -> lists:member(Key, [kind, cid, title, source_key, filename]) end,
        maps:remove(bytes, Source)
    ).

max_source_bytes() ->
    IngestMax = positive_env(ingest_max_source_bytes, 67108864),
    Requested = positive_env(quick_index_max_source_bytes, ?DEFAULT_MAX_SOURCE_BYTES),
    erlang:min(IngestMax, Requested).

positive_env(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

authenticated_owner(State) ->
    case damage_auth:authenticated_account(State) of
        {ok, Owner} -> Owner;
        {error, unauthenticated} -> undefined
    end.

required_idempotency_key(Req) ->
    case cowboy_req:header(<<"idempotency-key">>, Req, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 256 -> {ok, Value};
        undefined -> {error, 400, idempotency_key_required};
        <<>> -> {error, 400, idempotency_key_required};
        _ -> {error, 400, invalid_idempotency_key}
    end.

valid_sha256(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    re:run(Value, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
valid_sha256(_) -> false.

source_error_code({source_too_large, _, _}) -> 413;
source_error_code(source_too_large) -> 413;
source_error_code(url_redirect_not_allowed) -> 422;
source_error_code(url_private_address_not_allowed) -> 422;
source_error_code(url_host_not_allowed) -> 422;
source_error_code(url_nonstandard_port_not_allowed) -> 422;
source_error_code(url_userinfo_not_allowed) -> 422;
source_error_code(url_fragment_not_allowed) -> 422;
source_error_code(url_dns_failed) -> 422;
source_error_code(invalid_url) -> 400;
source_error_code(invalid_ipfs_cid) -> 400;
source_error_code({url_http_status, _}) -> 422;
source_error_code(_) -> 502.

enqueue_error_code({idempotency_conflict, _Existing, _Requested}) -> 409;
enqueue_error_code({queue_capacity_exceeded, _Current, _Limit}) -> 429;
enqueue_error_code({owner_queue_capacity_exceeded, _Owner, _Current, _Limit}) -> 429;
enqueue_error_code(_) -> 422.

safe_call(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        exit:Reason -> {error, {quick_index_unavailable, Reason}};
        Class:Reason -> {error, {quick_index_failed, Class, Reason}}
    end.

reply_error(Req, Code, Reason, State) ->
    reply_json(Req, Code, #{ok => false, error => ecai_index_job_codec:externalize(Reason)}, State).

reply_json(Req0, Code, Map, State) ->
    Req1 = cowboy_req:reply(Code, #{<<"content-type">> => ?JSON}, jsx:encode(Map), Req0),
    {stop, Req1, State}.

lowercase(Bin) when is_binary(Bin) -> string:lowercase(Bin);
lowercase(_) -> <<>>.

percent_decode(Bin) when is_binary(Bin) ->
    try unicode:characters_to_binary(uri_string:percent_decode(Bin))
    catch _:_ -> Bin end.
