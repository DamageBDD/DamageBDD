%%--------------------------------------------------------------------
%% Single wiring point before signing.
%% This module keeps the final requirements in one gate.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_gate).

-export([preflight/4]).

%% Request: NIP-46 request map before signing.
%% VaultState: map checked by damage_nsecbunker_vault_guard.
%% Policy: damage_nsecbunker_policy policy map.
%% NowUnix: bunker/server unix time.
-spec preflight(map(), map(), map(), non_neg_integer()) ->
    {ok, map()} | {duplicate_same_payload, map()} | {error, atom(), binary()}.
preflight(Request, VaultState, Policy, NowUnix) ->
    ExpectedPubkey = maps:get(bunker_pubkey_hex, Policy),
    PayloadHash = request_payload_hash(Request),
    BaseAudit = base_audit(Request, Policy, NowUnix, PayloadHash),
    Result =
        with_ok([
            fun() -> ensure_service(damage_nsecbunker_replay) end,
            fun() -> ensure_service(damage_nsecbunker_rate) end,
            fun() -> damage_nsecbunker_vault_guard:assert_ready(VaultState, ExpectedPubkey) end,
            fun() ->
                damage_nsecbunker_policy:authorize(
                    Request,
                    Policy,
                    NowUnix,
                    maps:get(pubkey_hex, VaultState, <<>>)
                )
            end,
            fun() -> replay_check(Request, PayloadHash) end,
            fun() -> rate_check(Request, Policy, NowUnix) end
        ]),
    audit_result(Result, BaseAudit, PayloadHash).
audit_result(ok, BaseAudit, PayloadHash) ->
    AuditLine =
        damage_nsecbunker_audit:canonical_line(
            BaseAudit#{decision => <<"allowed">>}
        ),
    {ok, #{payload_sha256 => PayloadHash, audit_line => AuditLine}};
audit_result({ok, duplicate_same_payload}, BaseAudit, PayloadHash) ->
    AuditLine =
        damage_nsecbunker_audit:canonical_line(
            BaseAudit#{decision => <<"duplicate_same_payload">>}
        ),
    {duplicate_same_payload, #{payload_sha256 => PayloadHash, audit_line => AuditLine}};
audit_result({error, Reason0}, BaseAudit, _PayloadHash) ->
    Reason = normalize_reason(Reason0),
    AuditLine =
        damage_nsecbunker_audit:canonical_line(
            BaseAudit#{
                decision => <<"rejected">>,
                deny_reason => atom_to_binary(Reason, utf8)
            }
        ),
    {error, Reason, AuditLine}.

normalize_reason({service_start_failed, _Module, _Reason}) ->
    service_unavailable;
normalize_reason(Reason) when is_atom(Reason) ->
    Reason;
normalize_reason(_) ->
    preflight_failed.

with_ok([]) ->
    ok;
with_ok([Fun | Rest]) ->
    case Fun() of
        ok -> with_ok(Rest);
        {ok, duplicate_same_payload} -> {ok, duplicate_same_payload};
        {ok, _Hints} -> with_ok(Rest);
        {error, Reason} -> {error, Reason}
    end.

rate_check(Request, Policy, NowUnix) ->
    case maps:get(skip_rate_limit, Request, false) of
        true ->
            ok;
        false ->
            #{max_requests := MaxRequests, window_seconds := WindowSeconds} =
                maps:get(rate_limit, Policy, #{max_requests => 30, window_seconds => 60}),
            Requester = maps:get(requester_pubkey, Request, <<>>),
            damage_nsecbunker_rate:check_and_mark(Requester, NowUnix, MaxRequests, WindowSeconds)
    end.

replay_check(Request, PayloadHash) ->
    Requester = maps:get(requester_pubkey, Request, <<>>),
    RequestId = maps:get(request_id, Request, <<>>),
    damage_nsecbunker_replay:check_and_mark(Requester, RequestId, PayloadHash).

request_payload_hash(Request) ->
    Event = maps:get(event, Request, #{}),
    crypto:hash(
        sha256,
        iolist_to_binary([
            maps:get(requester_pubkey, Request, <<>>),
            <<":">>,
            maps:get(request_id, Request, <<>>),
            <<":">>,
            maps:get(method, Request, <<>>),
            <<":">>,
            integer_to_binary(maps:get(created_at, Request, 0)),
            <<":">>,
            hex(canonical_event_hash(Event))
        ])
    ).

canonical_event_hash(Event) ->
    crypto:hash(
        sha256,
        iolist_to_binary([
            integer_to_binary(maps:get(kind, Event, 0)),
            <<":">>,
            integer_to_binary(maps:get(created_at, Event, 0)),
            <<":">>,
            jsx:encode(maps:get(tags, Event, [])),
            <<":">>,
            maps:get(content, Event, <<>>)
        ])
    ).

base_audit(Request, Policy, NowUnix, PayloadHash) ->
    Event = maps:get(event, Request, #{}),
    #{
        ts_unix => NowUnix,
        requester_pubkey => maps:get(requester_pubkey, Request, <<>>),
        request_id => maps:get(request_id, Request, <<>>),
        method => maps:get(method, Request, <<>>),
        event_kind => maps:get(kind, Event, null),
        event_id => maps:get(id, Event, <<>>),
        payload_sha256 => hex(PayloadHash),
        bunker_pubkey => maps:get(bunker_pubkey_hex, Policy, <<>>),
        contract_sha => maps:get(contract_sha, Policy, <<>>)
    }.

hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

ensure_service(Module) ->
    case whereis(Module) of
        undefined ->
            case Module:start_link() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, {service_start_failed, Module, Reason}}
            end;
        _Pid ->
            ok
    end.
