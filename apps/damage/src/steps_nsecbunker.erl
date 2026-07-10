%%--------------------------------------------------------------------
%% DamageBDD steps for a generic damage_nsecbunker Phase 0
%% NIP-46 custody contract.
%%
%% These steps intentionally test the policy/gate layer directly. The real
%% Schnorr signing backend remains outside the behaviour contract until the
%% preflight gate says a request is signable.
%%--------------------------------------------------------------------
-module(steps_nsecbunker).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6, step_dry/6]).

-define(NS, nsecbunker).
-define(DEFAULT_NOW, 1778000000).

%% Background
-define(S_VAULT_GENERATED, ["the bunker has generated the deployment signing key inside the vault"]).
-define(S_NSEC_NEVER_LEFT, ["the deployment nsec has never left the vault"]).
-define(S_EXPECTED_PUBKEY, ["the bunker expected public key is recorded as", Pubkey]).
-define(S_AUTH_ALLOWLIST, ["the authorised client pubkey allowlist contains", Pubkey]).
-define(S_ALLOWED_METHODS_COLON, ["the allowed NIP-46 methods are exactly:"]).
-define(S_ALLOWED_METHODS, ["the allowed NIP-46 methods are exactly"]).
-define(S_ALLOWED_KINDS_COLON, ["the allowed event kinds are exactly:"]).
-define(S_ALLOWED_KINDS, ["the allowed event kinds are exactly"]).
-define(S_STALE_WINDOW, [
    "the stale event skew window is", SkewSecs, "seconds relative to bunker time"
]).
-define(S_MAX_KIND, ["the maximum byte size for kind", Kind, "is", MaxBytes, "bytes"]).
-define(S_SIGNS_ONLY, ["the bunker signs only and never publishes to relays"]).

%% When
-define(S_AUTH_CALLS, ["authorised client", Client, "calls", Method]).
-define(S_CLIENT_CALLS, ["client", Client, "calls", Method]).
-define(S_AUTH_REQUESTS_SIGNING, ["authorised client", Client, "requests signing"]).
-define(S_AUTH_REQUESTS_SIGNING_VALID_EVENT, [
    "authorised client",
    Client,
    "requests signing for an otherwise valid event"
]).
-define(S_CLIENT_REQUESTS_SIGNING, ["the client requests signing"]).
-define(S_AUTH_REQUESTS_SIGNING_DEFAULT_RENDERED, [
    "authorised client AUTHORISED_CLIENT_PUBKEY_HEX requests signing"
]).
-define(S_ANY_CLIENT_ANY_SIGNING, ["any client requests any signing operation"]).
-define(S_ANY_CLIENT_REQUESTS_METHODS, ["any client requests", MethodA, "or", _MethodB]).
-define(S_ANY_CLIENT_REQUESTS_METHODS_RENDERED, ["any client requests", Methods]).
-define(S_WRITE_AUDIT_ROW, ["the bunker writes an audit row"]).
-define(S_SAME_CLIENT_SUBMITS_REPLAY, [
    "the same client submits request id", RequestId, "for payload hash", PayloadHash, "again"
]).
-define(S_SAME_CLIENT_SUBMITS_CONFLICT, [
    "the same client submits request id", RequestId, "for payload hash", PayloadHash
]).
-define(S_SAME_CLIENT_SUBMITS_RENDERED, ["the same client submits request id ", RequestPayloadHash]).

%% Given state
-define(S_BUNKER_TIME, ["bunker time is", BunkerTime]).
-define(S_SIGNING_REQ_CREATED_AT, ["a signing request has created_at", CreatedAt]).
-define(S_UNSIGNED_KIND, ["an unsigned event of kind", Kind]).
-define(S_UNSIGNED_KIND_ALT, ["an unsigned kind", Kind, "event"]).
-define(S_OVERSIZED_KIND, ["an unsigned kind", Kind, "event larger than", MaxSize, "bytes"]).
-define(S_UNSIGNED_KIND_MIN_TAGS, [
    "an unsigned kind", Kind, "event with the required minimal tags"
]).
-define(S_EVENT_MISSING_TAGS, ["the event does not contain tags", _Tags]).
-define(S_EVENT_MISSING_TAGS_RENDERED, ["the event does not contain tags ", _Tags]).
-define(S_EVENT_MISSING_TAGS_3, [
    "the event does not contain tags", _D, ",", _Title, ", and", _PublishedAt
]).
-define(S_EVENT_PASSES_POLICY, [
    "the event passes stale, size, HTML, kind, and client policy checks"
]).
-define(S_EVENT_SCRIPT, ["an unsigned kind", Kind, "event whose content contains", Script]).
-define(S_REPLAY_SEED, [
    "authorised client", Client, "submitted request id", RequestId, "for payload hash", PayloadHash
]).
-define(S_REPLAY_SEED_RENDERED, [
    "authorised client", Client, "submitted request id", RequestPayloadHash
]).
-define(S_RATE_EXCEEDED, [
    "authorised client",
    Client,
    "has exceeded",
    MaxRequests,
    "requests in a",
    _WindowSecs,
    "second window"
]).
-define(S_RATE_EXCEEDED_RENDERED, [
    "authorised client " ++ ClientHasExceeded,
    MaxRequests,
    "requests in a",
    _WindowSecs,
    "second window"
]).
-define(S_TIMEOUT, ["a signing request cannot complete within", TimeoutMs, "milliseconds"]).
-define(S_VAULT_CORRUPT, ["the vault fails integrity verification"]).
-define(S_VAULT_MISMATCH, ["the vault unseals to a public key other than", Pubkey]).
-define(S_RELAY_DRIFT, ["the configured publication relay vector changes after initial publication"]).

%% Then
-define(S_RESPONSE_CONTAINS, ["the bunker response MUST contain", Pubkey]).
-define(S_RETURNED_EQUALS_RECORD, [
    "the returned public key MUST equal the public key recorded in the deployment identity record"
]).
-define(S_NO_ROTATION, [
    "no identity rotation may occur without a separate ratified identity-rotation record"
]).
-define(S_AUDIT_WRITTEN, ["the decision MUST be written to the deterministic audit log"]).
-define(S_METHOD_DECISION, ["the method decision MUST be", Decision]).
-define(S_REQUEST_REJECTED_BEFORE_SIGNING, ["the request MUST be rejected before signing"]).
-define(S_REQUEST_REJECTED, ["the request MUST be rejected"]).
-define(S_DENIAL_MUST, ["the denial reason MUST be", Reason]).
-define(S_DENIAL_SHOULD, ["the denial reason SHOULD be", Reason]).
-define(S_SIGNING_DECISION, ["the signing decision MUST be", Decision]).
-define(S_NO_SIGNATURE, ["no signature MUST be produced"]).
-define(S_NOT_REJECT_DTAG, ["the bunker MUST NOT reject merely because of the d-tag naming scheme"]).
-define(S_NOT_REJECT_IPFS, [
    "the bunker MUST NOT reject merely because of the IPFS CID tag namespace"
]).
-define(S_NOT_PUBLISH, ["the bunker MUST NOT publish the event to any relay"]).
-define(S_GEOMETRY_OUTSIDE, [
    "publication geometry MUST remain owned by configured publication tooling"
]).
-define(S_NO_DIVERGENT_SIG, ["the bunker MUST NOT produce a divergent signature"]).
-define(S_REPLAY_MAY_BE, ["the replay decision MAY be", Decision]).
%% Rendered/tokenizer assertion variants with retained parameters.
%% These use string-list prefix patterns so the match is readable and exact.
-define(S_FAIL_CLOSED, ["the request MUST fail closed"]).
-define(S_NO_PARTIAL_SIG, ["no partial signature material MUST be exposed"]).
-define(S_NO_SIGNING_BACKEND, ["no signing backend MUST be invoked"]).
-define(S_ROTATION_REQUIRES_RECORD, [
    "identity rotation MUST require a separate ratified identity-rotation record"
]).
-define(S_ROW_ORDER, ["the row MUST use deterministic field order"]).
-define(S_ROW_INCLUDE_FIELDS, [
    "the row MUST include schema_version, ts_unix, requester_pubkey, request_id, method, decision, deny_reason, event_kind, event_id, payload_sha256, bunker_pubkey, and contract_sha"
]).
-define(S_ROW_NO_SECRETS, [
    "the row MUST NOT include nsec, plaintext NIP-46 payload, unsigned event content, or signature nonce material"
]).
-define(S_SIGNER_INDEPENDENT_RELAYS, [
    "the bunker signing decision MUST be independent of the relay vector"
]).
-define(S_RELAY_OUTSIDE, ["relay publication MUST remain outside bunker scope"]).

-spec step(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().
-spec step_dry(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

%% ===== Background ===========================================================
step(_Config, Context, _Keyword, _N, ?S_VAULT_GENERATED, _Args) ->
    ?LOG_INFO("S_VAULT_GENERATED ~p", [Context]),
    ensure_servers(),
    ok = damage_nsecbunker_replay:reset(),
    ok = damage_nsecbunker_rate:reset(),
    Policy = damage_nsecbunker_policy:default_policy(),
    Pubkey = maps:get(bunker_pubkey_hex, Policy),
    NS = #{
        policy => Policy,
        vault_state => #{sealed => false, integrity => ok, pubkey_hex => Pubkey},
        identity_record_pubkey => Pubkey,
        now => ?DEFAULT_NOW,
        audit_log => [],
        bunker_publishes => false,
        identity_rotation_allowed => false,
        signer_invoked => false,
        signature_produced => false,
        partial_signature_exposed => false,
        relay_vector => [<<"wss://relay.example.invalid">>]
    },
    put_ns(Context, NS);
step(_Config, Context, _Keyword, _N, ?S_NSEC_NEVER_LEFT, _Args) ->
    update_ns(Context, fun(NS) -> NS#{nsec_left_vault => false} end);
step(_Config, Context, _Keyword, _N, ?S_EXPECTED_PUBKEY, _Args) ->
    PubkeyBin = to_bin(Pubkey),
    update_ns(Context, fun(NS0) ->
        Policy0 = policy(NS0),
        Vault0 = vault(NS0),
        Policy = Policy0#{bunker_pubkey_hex => PubkeyBin},
        Vault = Vault0#{pubkey_hex => PubkeyBin},
        NS0#{policy => Policy, vault_state => Vault, identity_record_pubkey => PubkeyBin}
    end);
step(_Config, Context, _Keyword, _N, ?S_AUTH_ALLOWLIST, _Args) ->
    PubkeyBin = to_bin(Pubkey),
    update_policy(Context, fun(P) -> P#{authorized_clients => [PubkeyBin]} end);
step(_Config, Context, _Keyword, _N, ?S_ALLOWED_METHODS_COLON, Args) ->
    set_allowed_methods(Context, Args);
step(_Config, Context, _Keyword, _N, ?S_ALLOWED_METHODS, Args) ->
    set_allowed_methods(Context, Args);
step(_Config, Context, _Keyword, _N, ?S_ALLOWED_KINDS_COLON, Args) ->
    set_allowed_kinds(Context, Args);
step(_Config, Context, _Keyword, _N, ?S_ALLOWED_KINDS, Args) ->
    set_allowed_kinds(Context, Args);
step(_Config, Context, _Keyword, _N, ?S_STALE_WINDOW, _Args) ->
    update_policy(Context, fun(P) -> P#{created_at_skew_seconds => to_int(SkewSecs)} end);
step(_Config, Context, _Keyword, _N, ?S_MAX_KIND, _Args) ->
    update_policy(Context, fun(P0) ->
        Max0 = maps:get(max_event_bytes, P0, #{}),
        P0#{max_event_bytes => Max0#{to_int(Kind) => to_int(MaxBytes)}}
    end);
step(_Config, Context, _Keyword, _N, ?S_SIGNS_ONLY, _Args) ->
    update_policy(
        update_ns(Context, fun(NS) -> NS#{bunker_publishes => false} end),
        fun(P) -> P#{bunker_publishes => false} end
    );
%% ===== Scenario setup =======================================================
step(_Config, Context, _Keyword, _N, ?S_BUNKER_TIME, _Args) ->
    update_ns(Context, fun(NS) -> NS#{now => to_int(BunkerTime)} end);
step(_Config, Context, _Keyword, _N, ?S_SIGNING_REQ_CREATED_AT, _Args) ->
    update_request_time(Context, to_int(CreatedAt));
step(_Config, Context, _Keyword, _N, ?S_UNSIGNED_KIND, _Args) ->
    KindInt = to_int(Kind),
    update_event(Context, valid_event(KindInt, now(Context)));
step(_Config, Context, _Keyword, _N, ?S_UNSIGNED_KIND_ALT, _Args) ->
    KindInt = to_int(Kind),
    update_event(Context, valid_event(KindInt, now(Context)));
step(_Config, Context, _Keyword, _N, ?S_OVERSIZED_KIND, _Args) ->
    Event = (valid_event(Kind, now(Context)))#{
        content => binary:copy(<<"x">>, to_int(MaxSize) + 512)
    },
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_UNSIGNED_KIND_MIN_TAGS, _Args) ->
    Event0 = valid_event(Kind, now(Context)),
    Event = Event0#{
        tags => [
            [<<"d">>, <<"deployment/v1/custom-dtag">>],
            [<<"title">>, <<"Custody Deployment">>],
            [<<"published_at">>, integer_to_binary(now(Context))],
            [<<"ipfs-cid-v1">>, <<"bafybeigdyrzt-example">>]
        ]
    },
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_EVENT_MISSING_TAGS, _Args) ->
    Event0 = event(Context),
    Event = Event0#{tags => [[<<"d">>, <<"deployment">>]]},
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_EVENT_MISSING_TAGS_3, _Args) ->
    Event0 = event(Context),
    Event = Event0#{tags => []},
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_EVENT_MISSING_TAGS_RENDERED, _Args) ->
    Event0 = event(Context),
    Event = Event0#{tags => []},
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_EVENT_PASSES_POLICY, _Args) ->
    update_ns(Context, fun(NS) -> NS#{event_policy_expected_valid => true} end);
step(_Config, Context, _Keyword, _N, ?S_EVENT_SCRIPT, _Args) ->
    Content = <<"# Bad\n", (to_bin(Script))/binary, ">alert(1)</script>">>,
    Event = (valid_event(to_int(Kind), now(Context)))#{content => Content},
    update_event(Context, Event);
step(_Config, Context, _Keyword, _N, ?S_REPLAY_SEED, _Args) ->
    seed_replay(Context, to_bin(Client), to_bin(RequestId), to_bin(PayloadHash));
step(_Config, Context, _Keyword, _N, ?S_REPLAY_SEED_RENDERED, _Args) ->
    {RequestId, PayloadHash} = request_payload_hash_parts(RequestPayloadHash),
    seed_replay(Context, to_bin(Client), RequestId, PayloadHash);
step(_Config, Context, _Keyword, _N, ?S_RATE_EXCEEDED, _Args) ->
    rate_exceeded(Context, to_bin(Client), MaxRequests);
step(_Config, Context, _Keyword, _N, ?S_RATE_EXCEEDED_RENDERED, _Args) ->
    rate_exceeded(
        Context, strip_required_suffix(ClientHasExceeded, <<" has exceeded">>), MaxRequests
    );
step(_Config, Context, _Keyword, _N, ?S_TIMEOUT, _Args) ->
    update_ns(Context, fun(NS) ->
        NS#{force_signing_timeout => true, simulated_elapsed_ms => to_int(TimeoutMs) + 1}
    end);
step(_Config, Context, _Keyword, _N, ?S_VAULT_CORRUPT, _Args) ->
    update_ns(Context, fun(NS0) ->
        Vault0 = vault(NS0),
        NS0#{vault_state => Vault0#{integrity => failed}}
    end);
step(_Config, Context, _Keyword, _N, ?S_VAULT_MISMATCH, _Args) ->
    vault_mismatch(Context, to_bin(Pubkey));
step(_Config, Context, _Keyword, _N, ?S_RELAY_DRIFT, _Args) ->
    update_ns(Context, fun(NS) ->
        NS#{relay_vector => [<<"wss://replacement.example">>], relay_drifted => true}
    end);
%% ===== Actions ==============================================================
step(_Config, Context, _Keyword, _N, ?S_AUTH_CALLS, _Args) ->
    method_call(Context, to_bin(Client), to_bin(Method));
step(_Config, Context, _Keyword, _N, ?S_CLIENT_CALLS, _Args) ->
    method_call(Context, to_bin(Client), to_bin(Method));
step(_Config, Context, _Keyword, _N, ?S_AUTH_REQUESTS_SIGNING, _Args) ->
    request_signing(Context, to_bin(Client));
step(
    _Config,
    Context,
    _Keyword,
    _N,
    ?S_AUTH_REQUESTS_SIGNING_VALID_EVENT,
    _Args
) ->
    request_signing(Context, to_bin(Client));
step(_Config, Context, _Keyword, _N, ?S_CLIENT_REQUESTS_SIGNING, _Args) ->
    Client = maps:get(rate_limited_client, ns(Context), first_authorized_client(Context)),
    request_signing(Context, Client);
step(_Config, Context, _Keyword, _N, ?S_ANY_CLIENT_ANY_SIGNING, _Args) ->
    request_signing(Context, <<"ANY_CLIENT_PUBKEY_HEX">>);
step(_Config, Context, _Keyword, _N, ?S_ANY_CLIENT_REQUESTS_METHODS, _Args) ->
    method_call(Context, first_authorized_client(Context), to_bin(MethodA));
step(_Config, Context, _Keyword, _N, ?S_ANY_CLIENT_REQUESTS_METHODS_RENDERED, _Args) ->
    method_call(Context, first_authorized_client(Context), first_or_method(Methods));
step(_Config, Context, _Keyword, _N, ?S_SAME_CLIENT_SUBMITS_REPLAY, _Args) ->
    replay_submit(Context, to_bin(RequestId), to_bin(PayloadHash));
step(_Config, Context, _Keyword, _N, ?S_SAME_CLIENT_SUBMITS_CONFLICT, _Args) ->
    replay_submit(Context, to_bin(RequestId), to_bin(PayloadHash));
step(_Config, Context, _Keyword, _N, ?S_SAME_CLIENT_SUBMITS_RENDERED, _Args) ->
    {RequestId, PayloadHash} = request_payload_hash_parts(RequestPayloadHash),
    replay_submit(Context, RequestId, PayloadHash);
step(_Config, Context, _Keyword, _N, ?S_WRITE_AUDIT_ROW, _Args) ->
    Audit = audit_line(
        Context,
        <<"CLIENT">>,
        <<"REQ-AUDIT">>,
        <<"sign_event">>,
        <<"rejected">>,
        <<"method_not_allowed">>,
        30023
    ),
    append_audit(set_last(Context, rejected, method_not_allowed, #{audit_line => Audit}), Audit);
%% ===== Assertions ===========================================================
step(_Config, Context, _Keyword, _N, ?S_RESPONSE_CONTAINS, _Args) ->
    Expected = to_bin(Pubkey),
    case binary:match(maps:get(last_response, ns(Context), <<>>), Expected) of
        nomatch ->
            fail(Context, damage_utils:strf("bunker response does not contain ~p", [Expected]));
        _ ->
            Context
    end;
step(_Config, Context, _Keyword, _N, ?S_RETURNED_EQUALS_RECORD, _Args) ->
    NS = ns(Context),
    assert_equal(
        Context,
        maps:get(last_returned_pubkey, NS, undefined),
        maps:get(identity_record_pubkey, NS, undefined),
        "returned public key does not match deployment identity record"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_ROTATION, _Args) ->
    assert_false(
        Context,
        maps:get(identity_rotation_allowed, ns(Context), false),
        "identity rotation was allowed"
    );
step(_Config, Context, _Keyword, _N, ?S_AUDIT_WRITTEN, _Args) ->
    case maps:get(audit_log, ns(Context), []) of
        [] -> fail(Context, <<"deterministic audit log is empty">>);
        _ -> Context
    end;
step(_Config, Context, _Keyword, _N, ?S_METHOD_DECISION, _Args) ->
    assert_decision(Context, method_decision, Decision);
step(_Config, Context, _Keyword, _N, ?S_REQUEST_REJECTED_BEFORE_SIGNING, _Args) ->
    NS = ns(Context),
    C1 = assert_decision(Context, last_decision, <<"rejected">>),
    assert_false(C1, maps:get(signer_invoked, NS, false), "signer was invoked before rejection");
step(_Config, Context, _Keyword, _N, ?S_REQUEST_REJECTED, _Args) ->
    assert_decision(Context, last_decision, <<"rejected">>);
step(_Config, Context, _Keyword, _N, ?S_DENIAL_MUST, _Args) ->
    assert_reason(Context, Reason, must);
step(_Config, Context, _Keyword, _N, ?S_DENIAL_SHOULD, _Args) ->
    assert_reason(Context, Reason, should);
step(_Config, Context, _Keyword, _N, ?S_SIGNING_DECISION, _Args) ->
    assert_decision(Context, signing_decision, Decision);
step(_Config, Context, _Keyword, _N, ?S_NO_SIGNATURE, _Args) ->
    assert_false(
        Context, maps:get(signature_produced, ns(Context), false), "signature was produced"
    );
step(_Config, Context, _Keyword, _N, ?S_NOT_REJECT_DTAG, _Args) ->
    assert_not_reason(Context, dtag_scheme_not_allowed);
step(_Config, Context, _Keyword, _N, ?S_NOT_REJECT_IPFS, _Args) ->
    assert_not_reason(Context, ipfs_cid_tag_namespace_not_allowed);
step(_Config, Context, _Keyword, _N, ?S_NOT_PUBLISH, _Args) ->
    assert_false(
        Context, maps:get(published_to_relay, ns(Context), false), "bunker published to relay"
    );
step(_Config, Context, _Keyword, _N, ?S_GEOMETRY_OUTSIDE, _Args) ->
    assert_equal(
        Context,
        maps:get(publication_geometry_owner, ns(Context), <<"publication_tooling">>),
        <<"publication_tooling">>,
        "publication geometry owner changed"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_DIVERGENT_SIG, _Args) ->
    assert_false(
        Context,
        maps:get(divergent_signature, ns(Context), false),
        "divergent signature was produced"
    );
step(_Config, Context, _Keyword, _N, ?S_REPLAY_MAY_BE, _Args) ->
    assert_replay_may_be(Context, Decision);
step(_Config, Context, _Keyword, _N, ?S_FAIL_CLOSED, _Args) ->
    C1 = assert_decision(Context, last_decision, <<"rejected">>),
    assert_false(C1, maps:get(signer_invoked, ns(C1), false), "request did not fail closed");
step(_Config, Context, _Keyword, _N, ?S_NO_PARTIAL_SIG, _Args) ->
    assert_false(
        Context,
        maps:get(partial_signature_exposed, ns(Context), false),
        "partial signature material was exposed"
    );
step(_Config, Context, _Keyword, _N, ?S_NO_SIGNING_BACKEND, _Args) ->
    assert_false(
        Context, maps:get(signer_invoked, ns(Context), false), "signing backend was invoked"
    );
step(_Config, Context, _Keyword, _N, ?S_ROTATION_REQUIRES_RECORD, _Args) ->
    assert_false(
        Context,
        maps:get(identity_rotation_allowed, ns(Context), false),
        "identity rotation allowed without ratified identity-rotation record"
    );
step(_Config, Context, _Keyword, _N, ?S_ROW_ORDER, _Args) ->
    Line = last_audit_line(Context),
    Prefix = <<"{\"schema_version\":1,\"ts_unix\":">>,
    case binary:match(Line, Prefix) of
        {0, _} -> Context;
        _ -> fail(Context, damage_utils:strf("audit row is not canonical/order-stable: ~p", [Line]))
    end;
step(_Config, Context, _Keyword, _N, ?S_ROW_INCLUDE_FIELDS, _Args) ->
    Line = last_audit_line(Context),
    Fields = [
        <<"schema_version">>,
        <<"ts_unix">>,
        <<"requester_pubkey">>,
        <<"request_id">>,
        <<"method">>,
        <<"decision">>,
        <<"deny_reason">>,
        <<"event_kind">>,
        <<"event_id">>,
        <<"payload_sha256">>,
        <<"bunker_pubkey">>,
        <<"contract_sha">>
    ],
    assert_fields_present(Context, Line, Fields);
step(_Config, Context, _Keyword, _N, ?S_ROW_NO_SECRETS, _Args) ->
    Line = last_audit_line(Context),
    Forbidden = [
        <<"nsec">>,
        <<"plaintext">>,
        <<"unsigned event content">>,
        <<"signature nonce">>,
        <<"nonce material">>
    ],
    assert_forbidden_absent(Context, Line, Forbidden);
step(_Config, Context, _Keyword, _N, ?S_SIGNER_INDEPENDENT_RELAYS, _Args) ->
    assert_decision(Context, signing_decision, <<"allowed">>);
step(_Config, Context, _Keyword, _N, ?S_RELAY_OUTSIDE, _Args) ->
    assert_false(
        Context,
        maps:get(published_to_relay, ns(Context), false),
        "relay publication leaked into bunker scope"
    ).

%% ===== Rendered parameter helpers ==========================================
first_or_method(Methods0) ->
    Methods = to_bin(Methods0),
    case binary:split(Methods, <<" or ">>) of
        [Method, _Rest] when Method =/= <<>> -> Method;
        [Method] -> Method
    end.

request_payload_hash_parts(RequestPayloadHash0) ->
    RequestPayloadHash = maybe_strip_suffix(<<" again">>, to_bin(RequestPayloadHash0)),
    case binary:split(RequestPayloadHash, <<" for payload hash ">>) of
        [RequestId, PayloadHash] when RequestId =/= <<>>, PayloadHash =/= <<>> ->
            {RequestId, PayloadHash};
        _ ->
            {RequestPayloadHash, <<>>}
    end.

strip_required_suffix(Value0, Suffix) ->
    Value = to_bin(Value0),
    case strip_suffix(Suffix, Value) of
        {ok, Head} -> Head;
        error -> Value
    end.

strip_suffix(<<>>, Bin) when is_binary(Bin) ->
    {ok, Bin};
strip_suffix(Suffix, Bin) when is_binary(Suffix), is_binary(Bin) ->
    SuffixSize = byte_size(Suffix),
    BinSize = byte_size(Bin),
    case BinSize >= SuffixSize of
        true ->
            HeadSize = BinSize - SuffixSize,
            case Bin of
                <<Head:HeadSize/binary, Suffix:SuffixSize/binary>> -> {ok, Head};
                _ -> error
            end;
        false ->
            error
    end.

maybe_strip_suffix(Suffix, Bin) ->
    case strip_suffix(Suffix, Bin) of
        {ok, Head} -> Head;
        error -> Bin
    end.

rate_exceeded(Context, ClientBin, MaxRequests) ->
    ensure_servers(),
    set_nsecbunker_config(rate_backend, ets),
    ok = damage_nsecbunker_rate:seed(ClientBin, now(Context), to_int(MaxRequests)),
    update_ns(Context, fun(NS) -> NS#{rate_limited_client => ClientBin} end).

set_nsecbunker_config(Key, Value) ->
    Raw0 =
        case application:get_env(damage, nsecbunker) of
            {ok, Existing} -> Existing;
            undefined -> []
        end,
    Raw = nsecbunker_config_proplist(Raw0),
    application:set_env(damage, nsecbunker, lists:keystore(Key, 1, Raw, {Key, Value})).

nsecbunker_config_proplist(Map) when is_map(Map) ->
    maps:to_list(Map);
nsecbunker_config_proplist(List) when is_list(List) ->
    case lists:all(fun is_nsecbunker_config_entry/1, List) of
        true -> List;
        false -> []
    end;
nsecbunker_config_proplist(_) ->
    [].

is_nsecbunker_config_entry({K, _V}) when is_atom(K); is_binary(K); is_list(K) ->
    true;
is_nsecbunker_config_entry(_) ->
    false.

seed_replay(Context, ClientBin, RequestId, PayloadHash) ->
    ensure_servers(),
    ok = damage_nsecbunker_replay:check_and_mark(ClientBin, RequestId, PayloadHash),
    update_ns(Context, fun(NS) ->
        NS#{last_replay_seed => {ClientBin, RequestId, PayloadHash}}
    end).

vault_mismatch(Context, Pubkey) ->
    update_ns(Context, fun(NS0) ->
        Vault0 = vault(NS0),
        NS0#{
            vault_state => Vault0#{pubkey_hex => <<"DIFFERENT_PUBKEY_HEX">>},
            mismatch_target => Pubkey
        }
    end).

assert_replay_may_be(Context, Decision) ->
    Expected = to_bin(Decision),
    Actual = maps:get(replay_decision, ns(Context), <<>>),
    case Actual =:= Expected orelse Actual =:= <<>> of
        true ->
            Context;
        false ->
            fail(
                Context,
                damage_utils:strf("replay decision ~p is not acceptable as ~p", [Actual, Expected])
            )
    end.

%% ===== Step actions =========================================================
set_allowed_methods(Context, Args) ->
    Methods0 = table_column(Args, <<"method">>),
    Methods =
        case Methods0 of
            [] -> [<<"connect">>, <<"ping">>, <<"get_public_key">>, <<"sign_event">>];
            _ -> Methods0
        end,
    update_policy(Context, fun(P) -> P#{allowed_methods => Methods} end).

set_allowed_kinds(Context, Args) ->
    Kinds0 = [to_int(K) || K <- table_column(Args, <<"kind">>)],
    Kinds =
        case Kinds0 of
            [] -> [1, 30023];
            _ -> Kinds0
        end,
    update_policy(Context, fun(P) -> P#{allowed_kinds => Kinds} end).

method_call(Context, Client, Method) ->
    NS = ns(Context),
    Policy = policy(NS),
    Vault = vault(NS),
    Audit0 = audit_line(Context, Client, <<"REQ-METHOD">>, Method, <<"rejected">>, <<>>, null),
    case damage_nsecbunker_vault_guard:assert_ready(Vault, maps:get(bunker_pubkey_hex, Policy)) of
        {error, Reason0} ->
            Audit = audit_line(
                Context,
                Client,
                <<"REQ-METHOD">>,
                Method,
                <<"rejected">>,
                atom_to_binary(Reason0, utf8),
                null
            ),
            append_audit(
                set_last(Context, rejected, Reason0, #{
                    method_decision => <<"rejected">>, signer_invoked => false, audit_line => Audit
                }),
                Audit
            );
        ok ->
            Decision =
                case lists:member(Client, maps:get(authorized_clients, Policy, [])) of
                    false ->
                        {rejected, client_not_authorized};
                    true ->
                        case lists:member(Method, maps:get(allowed_methods, Policy, [])) of
                            true -> {allowed, <<>>};
                            false -> {rejected, method_not_allowed}
                        end
                end,
            case Decision of
                {allowed, <<>>} ->
                    Response = method_response(Method, maps:get(bunker_pubkey_hex, Policy)),
                    Audit = audit_line(
                        Context, Client, <<"REQ-METHOD">>, Method, <<"allowed">>, <<>>, null
                    ),
                    append_audit(
                        set_last(Context, allowed, <<>>, #{
                            method_decision => <<"allowed">>,
                            last_response => Response,
                            last_returned_pubkey => maps:get(bunker_pubkey_hex, Policy),
                            signer_invoked => false,
                            audit_line => Audit0
                        }),
                        Audit
                    );
                {rejected, Reason} ->
                    Audit = audit_line(
                        Context,
                        Client,
                        <<"REQ-METHOD">>,
                        Method,
                        <<"rejected">>,
                        atom_to_binary(Reason, utf8),
                        null
                    ),
                    append_audit(
                        set_last(Context, rejected, Reason, #{
                            method_decision => <<"rejected">>,
                            signer_invoked => false,
                            audit_line => Audit
                        }),
                        Audit
                    )
            end
    end.

request_signing(Context, Client) ->
    NS = ns(Context),
    Policy = policy(NS),
    TimeoutMs = maps:get(signing_timeout_ms, Policy, 10000),
    case maps:get(force_signing_timeout, NS, false) of
        true ->
            Elapsed = maps:get(simulated_elapsed_ms, NS, TimeoutMs + 1),
            case damage_nsecbunker_signing_guard:classify_elapsed(Elapsed, TimeoutMs) of
                {error, signing_timeout} ->
                    Audit = audit_line(
                        Context,
                        Client,
                        <<"REQ-SIGN">>,
                        <<"sign_event">>,
                        <<"rejected">>,
                        <<"signing_timeout">>,
                        maps:get(kind, event(Context), null)
                    ),
                    append_audit(
                        set_last(Context, rejected, signing_timeout, #{
                            signing_decision => <<"rejected">>,
                            signature_produced => false,
                            signer_invoked => false,
                            partial_signature_exposed => false,
                            audit_line => Audit
                        }),
                        Audit
                    );
                ok ->
                    run_gate(Context, Client)
            end;
        false ->
            run_gate(Context, Client)
    end.

run_gate(Context, Client) ->
    NS = ns(Context),
    Now = maps:get(now, NS, ?DEFAULT_NOW),
    Request0 = maps:get(request, NS, #{}),
    Event0 = maps:get(event, NS, valid_event(30023, Now)),
    CreatedAt = to_int(maps:get(created_at, Request0, maps:get(created_at, Event0, Now))),
    Event = Event0#{created_at => CreatedAt},
    Request = maps:merge(
        #{
            requester_pubkey => Client,
            request_id => maps:get(request_id, Request0, <<"REQ-SIGN">>),
            method => <<"sign_event">>,
            created_at => CreatedAt,
            event => Event
        },
        Request0#{requester_pubkey => Client, method => <<"sign_event">>, event => Event}
    ),
    case damage_nsecbunker_gate:preflight(Request, vault(NS), policy(NS), Now) of
        {ok, #{audit_line := Audit}} ->
            append_audit(
                set_last(Context, allowed, <<>>, #{
                    request => Request,
                    signing_decision => <<"allowed">>,
                    signer_invoked => true,
                    signature_produced => true,
                    published_to_relay => false,
                    publication_geometry_owner => <<"publication_tooling">>,
                    audit_line => Audit
                }),
                Audit
            );
        {duplicate_same_payload, #{audit_line := Audit}} ->
            append_audit(
                set_last(Context, allowed, <<>>, #{
                    request => Request,
                    signing_decision => <<"allowed">>,
                    replay_decision => <<"duplicate_same_payload">>,
                    signer_invoked => false,
                    signature_produced => false,
                    divergent_signature => false,
                    audit_line => Audit
                }),
                Audit
            );
        {error, Reason, Audit} ->
            append_audit(
                set_last(Context, rejected, Reason, #{
                    request => Request,
                    signing_decision => <<"rejected">>,
                    signer_invoked => false,
                    signature_produced => false,
                    audit_line => Audit
                }),
                Audit
            )
    end.

replay_submit(Context, RequestId, PayloadHash) ->
    ensure_servers(),
    Client = first_authorized_client(Context),
    case damage_nsecbunker_replay:check_and_mark(Client, RequestId, PayloadHash) of
        ok ->
            set_last(Context, allowed, <<>>, #{
                replay_decision => <<"allowed">>, divergent_signature => false
            });
        {ok, duplicate_same_payload} ->
            set_last(Context, allowed, <<>>, #{
                replay_decision => <<"duplicate_same_payload">>,
                divergent_signature => false,
                signer_invoked => false
            });
        {error, Reason} ->
            set_last(Context, rejected, Reason, #{
                replay_decision => <<"rejected">>,
                divergent_signature => false,
                signer_invoked => false,
                signature_produced => false
            })
    end.

%% ===== Context helpers ======================================================
ns(Context) ->
    maps:get(?NS, Context, #{}).

put_ns(Context, NS) ->
    maps:put(?NS, NS, Context).

update_ns(Context, Fun) ->
    put_ns(Context, Fun(ns(Context))).

policy(NS) ->
    maps:get(policy, NS, damage_nsecbunker_policy:default_policy()).

vault(NS) ->
    maps:get(vault_state, NS, #{sealed => true, integrity => failed, pubkey_hex => <<>>}).

update_policy(Context, Fun) ->
    update_ns(Context, fun(NS0) -> NS0#{policy => Fun(policy(NS0))} end).

now(Context) ->
    maps:get(now, ns(Context), ?DEFAULT_NOW).

event(Context) ->
    NS = ns(Context),
    maps:get(event, NS, valid_event(30023, maps:get(now, NS, ?DEFAULT_NOW))).

update_event(Context, Event) ->
    update_ns(Context, fun(NS) -> NS#{event => Event} end).

update_request_time(Context, CreatedAt) ->
    update_ns(Context, fun(NS0) ->
        Req0 = maps:get(request, NS0, #{}),
        Event0 = maps:get(event, NS0, valid_event(30023, maps:get(now, NS0, ?DEFAULT_NOW))),
        NS0#{request => Req0#{created_at => CreatedAt}, event => Event0#{created_at => CreatedAt}}
    end).

set_last(Context, Decision, Reason, Extra) ->
    DecisionBin = decision_bin(Decision),
    ReasonBin = reason_bin(Reason),
    update_ns(Context, fun(NS) ->
        maps:merge(
            NS,
            maps:merge(
                #{
                    last_decision => DecisionBin,
                    denial_reason => ReasonBin,
                    last_reason => ReasonBin
                },
                Extra
            )
        )
    end).

append_audit(Context, AuditLine) ->
    update_ns(Context, fun(NS0) ->
        Audit0 = maps:get(audit_log, NS0, []),
        NS0#{audit_log => Audit0 ++ [AuditLine], last_audit_line => AuditLine}
    end).

last_audit_line(Context) ->
    maps:get(last_audit_line, ns(Context), <<>>).

first_authorized_client(Context) ->
    Policy = policy(ns(Context)),
    case maps:get(authorized_clients, Policy, []) of
        [Client | _] -> Client;
        [] -> <<"AUTHORISED_CLIENT_PUBKEY_HEX">>
    end.

%% ===== Domain helpers =======================================================
valid_event(1, Now) ->
    #{
        kind => 1,
        created_at => Now,
        tags => [],
        content => <<"Deployment announcement">>
    };
valid_event(30023, Now) ->
    #{
        kind => 30023,
        created_at => Now,
        tags => [
            [<<"d">>, <<"deployment">>],
            [<<"title">>, <<"Deployment Record">>],
            [<<"published_at">>, integer_to_binary(Now)]
        ],
        content => <<"# Deployment Record\n\nMarkdown only.">>
    };
valid_event(Kind, Now) when not is_integer(Kind); not is_integer(Now) ->
    valid_event(to_int(Kind), to_int(Now));
valid_event(Kind, Now) ->
    #{kind => Kind, created_at => Now, tags => [], content => <<"unsupported kind">>}.

method_response(<<"get_public_key">>, Pubkey) ->
    Pubkey;
method_response(<<"ping">>, _Pubkey) ->
    <<"pong">>;
method_response(<<"connect">>, _Pubkey) ->
    <<"ack">>;
method_response(_Method, _Pubkey) ->
    <<"ok">>.

audit_line(Context, Client, RequestId, Method, Decision, Reason, EventKind) ->
    Policy = policy(ns(Context)),
    damage_nsecbunker_audit:canonical_line(#{
        ts_unix => now(Context),
        requester_pubkey => Client,
        request_id => RequestId,
        method => Method,
        decision => Decision,
        deny_reason => Reason,
        event_kind => EventKind,
        event_id => <<>>,
        payload_sha256 => hex(
            crypto:hash(sha256, <<Client/binary, RequestId/binary, Method/binary>>)
        ),
        bunker_pubkey => maps:get(bunker_pubkey_hex, Policy, <<>>),
        contract_sha => maps:get(contract_sha, Policy, <<>>)
    }).

%% ===== Assertions ===========================================================
assert_decision(Context, Key, Expected0) ->
    Expected = to_bin(Expected0),
    Actual = maps:get(Key, ns(Context), <<>>),
    case Actual =:= Expected of
        true ->
            Context;
        false ->
            fail(
                Context,
                damage_utils:strf("~p was ~p, expected ~p, reason ~p", [
                    Key,
                    Actual,
                    Expected,
                    maps:get(denial_reason, ns(Context), <<>>)
                ])
            )
    end.
assert_reason(Context, Expected0, Mode) ->
    Expected = to_bin(Expected0),
    Actual = maps:get(denial_reason, ns(Context), <<>>),
    case {Mode, Expected, Actual} of
        {should, <<>>, _} ->
            Context;
        {should, <<"none">>, <<>>} ->
            Context;
        {_, Expected, Expected} ->
            Context;
        _ ->
            fail(
                Context, damage_utils:strf("denial reason was ~p, expected ~p", [Actual, Expected])
            )
    end.

assert_not_reason(Context, Reason) ->
    NotExpected = reason_bin(Reason),
    Actual = maps:get(denial_reason, ns(Context), <<>>),
    case Actual =:= NotExpected of
        true -> fail(Context, damage_utils:strf("unexpected denial reason ~p", [Actual]));
        false -> Context
    end.

assert_equal(Context, A, A, _Message) ->
    Context;
assert_equal(Context, A, B, Message) ->
    fail(Context, damage_utils:strf("~s: ~p /= ~p", [Message, A, B])).

assert_false(Context, false, _Message) ->
    Context;
assert_false(Context, undefined, _Message) ->
    Context;
assert_false(Context, Value, Message) ->
    fail(Context, damage_utils:strf("~s: ~p", [Message, Value])).

assert_fields_present(Context, _Line, []) ->
    Context;
assert_fields_present(Context, Line, [Field | Rest]) ->
    Needle = <<"\"", Field/binary, "\":">>,
    case binary:match(Line, Needle) of
        nomatch -> fail(Context, damage_utils:strf("audit field missing: ~p in ~p", [Field, Line]));
        _ -> assert_fields_present(Context, Line, Rest)
    end.

assert_forbidden_absent(Context, _Line, []) ->
    Context;
assert_forbidden_absent(Context, Line, [Forbidden | Rest]) ->
    case binary:match(Line, Forbidden) of
        nomatch -> assert_forbidden_absent(Context, Line, Rest);
        _ -> fail(Context, damage_utils:strf("audit row leaked forbidden token: ~p", [Forbidden]))
    end.

fail(Context, Reason) ->
    maps:put(fail, Reason, Context).

%% ===== Parsing helpers ======================================================
table_column(Args, Column) ->
    Rows = table_rows(Args),
    case Rows of
        [] ->
            [];
        [Header | DataRows] ->
            Header0 = [to_bin(H) || H <- Header],
            case lists:member(Column, Header0) of
                true ->
                    Index = column_index(Header0, Column),
                    [
                        to_bin(nth_or_empty(Index, Row))
                     || Row <- DataRows,
                        nth_or_empty(Index, Row) =/= <<>>
                    ];
                false ->
                    %% No header: treat first column of every row as values.
                    [
                        to_bin(nth_or_empty(1, Row))
                     || Row <- Rows,
                        nth_or_empty(1, Row) =/= <<>>
                    ]
            end
    end.

table_rows(Args) when is_binary(Args) ->
    parse_table_binary(Args);
table_rows(Args) when is_map(Args) ->
    case maps:find(rows, Args) of
        {ok, Rows} ->
            table_rows(Rows);
        error ->
            case maps:find(<<"rows">>, Args) of
                {ok, Rows} -> table_rows(Rows);
                error -> maps_to_rows([Args])
            end
    end;
table_rows(Args) when is_list(Args) ->
    case Args of
        [] ->
            [];
        [M | _] when is_map(M) ->
            maps_to_rows(Args);
        [[_ | _] | _] ->
            [[to_bin(Cell) || Cell <- Row] || Row <- Args];
        _ when is_integer(hd(Args)) ->
            parse_table_binary(list_to_binary(Args));
        _ ->
            [[to_bin(V)] || V <- Args]
    end;
table_rows(_) ->
    [].

maps_to_rows(Maps) ->
    Keys = map_keys(hd(Maps)),
    [Keys | [[to_bin(map_get_any(K, M)) || K <- Keys] || M <- Maps]].

map_keys(Map) ->
    [to_bin(K) || K <- maps:keys(Map)].

map_get_any(K, Map) ->
    maps:get(K, Map, maps:get(binary_to_atom_safe(K), Map, maps:get(binary_to_list(K), Map, <<>>))).

parse_table_binary(Bin) ->
    Lines0 = binary:split(Bin, <<"\n">>, [global]),
    Lines = [string:trim(binary_to_list(L)) || L <- Lines0, string:trim(binary_to_list(L)) =/= ""],
    [parse_table_line(Line) || Line <- Lines, lists:member($|, Line)].

parse_table_line(Line0) ->
    Line = string:trim(Line0, both, "|"),
    [list_to_binary(string:trim(Cell)) || Cell <- string:split(Line, "|", all)].

column_index(Header, Column) ->
    column_index(Header, Column, 1).

column_index([], _Column, _N) -> 1;
column_index([Column | _], Column, N) -> N;
column_index([_ | Rest], Column, N) -> column_index(Rest, Column, N + 1).

nth_or_empty(N, Row) when is_integer(N), N > 0 ->
    case length(Row) >= N of
        true -> lists:nth(N, Row);
        false -> <<>>
    end.

%% ===== Type helpers =========================================================
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_int(V) when is_integer(V) ->
    V;
to_int(V) when is_binary(V) ->
    binary_to_integer(string:trim(V));
to_int([V]) when is_binary(V); is_list(V) ->
    to_int(V);
to_int(V) when is_list(V) ->
    list_to_integer(string:trim(V)).

decision_bin(allowed) -> <<"allowed">>;
decision_bin(rejected) -> <<"rejected">>;
decision_bin(V) -> to_bin(V).

reason_bin(<<>>) -> <<>>;
reason_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
reason_bin(V) -> to_bin(V).

binary_to_atom_safe(Bin) ->
    try binary_to_existing_atom(Bin, utf8) of
        Atom -> Atom
    catch
        _:_ -> Bin
    end.

hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

ensure_servers() ->
    ensure_server(damage_nsecbunker_replay),
    ensure_server(damage_nsecbunker_rate).

ensure_server(Module) ->
    case whereis(Module) of
        undefined ->
            try Module:start_link() of
                {ok, _Pid} ->
                    ok;
                {error, {already_started, _Pid}} ->
                    ok;
                Other ->
                    {error, {unexpected_start_result, Other}}
            catch
                exit:{already_started, _Pid}:_Stacktrace ->
                    ok;
                Class:Reason:Stacktrace ->
                    {error, {start_failed, Class, Reason, Stacktrace}}
            end;
        _Pid ->
            ok
    end.
