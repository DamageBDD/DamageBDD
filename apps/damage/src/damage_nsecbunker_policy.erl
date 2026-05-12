%%--------------------------------------------------------------------
%% damage_nsecbunker_policy
%%
%% Narrow custody policy gate for generic NIP-46 signing.
%% Call this before invoking any signing backend.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_policy).

-export([
    default_policy/0,
    authorize/4,
    event_size/1,
    has_tag/2,
    required_tags_present/2
]).

-define(DEFAULT_SKEW_SECONDS, 600).
-define(DEFAULT_MAX_KIND1_BYTES, 4096).
-define(DEFAULT_MAX_KIND30023_BYTES, 131072).

-type policy() :: map().
-type request() :: map().
-type event() :: map().
-type audit_hints() :: map().

-spec default_policy() -> policy().
default_policy() ->
    #{
        bunker_pubkey_hex => <<"BUNKER_PUBKEY_HEX">>,
        contract_sha => <<"PHASE0_GHERKIN_SIGNOFF_COMMIT_SHA">>,
        authorized_clients => [<<"AUTHORISED_CLIENT_PUBKEY_HEX">>],
        allowed_methods => [
            <<"connect">>,
            <<"ping">>,
            <<"get_public_key">>,
            <<"sign_event">>
        ],
        allowed_kinds => [1, 30023],
        created_at_skew_seconds => ?DEFAULT_SKEW_SECONDS,
        max_event_bytes => #{
            1 => ?DEFAULT_MAX_KIND1_BYTES,
            30023 => ?DEFAULT_MAX_KIND30023_BYTES
        },
        required_tags => #{
            30023 => [<<"d">>, <<"title">>, <<"published_at">>]
        },
        reject_active_content => true,
        bunker_publishes => false,
        signing_timeout_ms => 10000,
        rate_limit => #{max_requests => 30, window_seconds => 60}
    }.

%% Request shape:
%% #{
%%    requester_pubkey := <<"hex">>,
%%    request_id := <<"nip46-request-id">>,
%%    method := <<"sign_event">>,
%%    created_at := UnixSeconds,
%%    event => #{kind := 30023, created_at := UnixSeconds, tags := [...], content := <<>>}
%% }
-spec authorize(request(), policy(), non_neg_integer(), binary()) -> {ok, audit_hints()} | {error, atom()}.
authorize(Request, Policy, NowUnix, VaultPubkeyHex) ->
    Checks = [
        fun() -> ensure_vault_pubkey_stable(Policy, VaultPubkeyHex) end,
        fun() -> ensure_client_allowed(Request, Policy) end,
        fun() -> ensure_method_allowed(Request, Policy) end,
        fun() -> ensure_request_time(Request, Policy, NowUnix) end,
        fun() -> ensure_not_publishing(Request, Policy) end,
        fun() -> ensure_method_specific_policy(Request, Policy, NowUnix) end
    ],
    case run_checks(Checks) of
        ok -> {ok, audit_hints(Request, Policy)};
        {error, Reason} -> {error, Reason}
    end.

run_checks([]) -> ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {error, Reason} -> {error, Reason}
    end.

ensure_vault_pubkey_stable(Policy, VaultPubkeyHex) ->
    Expected = maps:get(bunker_pubkey_hex, Policy, undefined),
    case Expected =:= VaultPubkeyHex of
        true -> ok;
        false -> {error, vault_pubkey_mismatch}
    end.

ensure_client_allowed(Request, Policy) ->
    Client = maps:get(requester_pubkey, Request, undefined),
    Allowed = maps:get(authorized_clients, Policy, []),
    case lists:member(Client, Allowed) of
        true -> ok;
        false -> {error, client_not_authorized}
    end.

ensure_method_allowed(Request, Policy) ->
    Method = maps:get(method, Request, undefined),
    Allowed = maps:get(allowed_methods, Policy, []),
    case lists:member(Method, Allowed) of
        true -> ok;
        false -> {error, method_not_allowed}
    end.

ensure_request_time(Request, Policy, NowUnix) ->
    case maps:find(created_at, Request) of
        error -> ok;
        {ok, CreatedAt} when is_integer(CreatedAt) ->
            Skew = maps:get(created_at_skew_seconds, Policy, ?DEFAULT_SKEW_SECONDS),
            Delta = CreatedAt - NowUnix,
            if
                Delta < -Skew -> {error, request_stale};
                Delta > Skew -> {error, request_from_future};
                true -> ok
            end;
        {ok, _Bad} -> {error, invalid_request_created_at}
    end.

ensure_not_publishing(Request, Policy) ->
    Method = maps:get(method, Request, undefined),
    BunkerPublishes = maps:get(bunker_publishes, Policy, false),
    case {Method, BunkerPublishes} of
        {<<"publish_event">>, false} -> {error, method_not_allowed};
        _ -> ok
    end.

ensure_method_specific_policy(#{method := <<"sign_event">>} = Request, Policy, NowUnix) ->
    case maps:find(event, Request) of
        error -> {error, missing_event};
        {ok, Event} -> ensure_sign_event(Event, Policy, NowUnix)
    end;
ensure_method_specific_policy(_Request, _Policy, _NowUnix) ->
    ok.

ensure_sign_event(Event, Policy, NowUnix) ->
    Checks = [
        fun() -> ensure_kind_allowed(Event, Policy) end,
        fun() -> ensure_event_time(Event, Policy, NowUnix) end,
        fun() -> ensure_event_size(Event, Policy) end,
        fun() -> ensure_required_tags(Event, Policy) end,
        fun() -> ensure_no_active_content(Event, Policy) end
    ],
    run_checks(Checks).

ensure_kind_allowed(Event, Policy) ->
    Kind = maps:get(kind, Event, undefined),
    Allowed = maps:get(allowed_kinds, Policy, []),
    case lists:member(Kind, Allowed) of
        true -> ok;
        false -> {error, kind_not_allowed}
    end.

ensure_event_time(Event, Policy, NowUnix) ->
    CreatedAt = maps:get(created_at, Event, undefined),
    Skew = maps:get(created_at_skew_seconds, Policy, ?DEFAULT_SKEW_SECONDS),
    case is_integer(CreatedAt) of
        false -> {error, invalid_event_created_at};
        true ->
            Delta = CreatedAt - NowUnix,
            if
                Delta < -Skew -> {error, event_stale};
                Delta > Skew -> {error, event_from_future};
                true -> ok
            end
    end.

ensure_event_size(Event, Policy) ->
    Kind = maps:get(kind, Event, undefined),
    MaxByKind = maps:get(max_event_bytes, Policy, #{}),
    Max = maps:get(Kind, MaxByKind, undefined),
    case Max of
        undefined -> {error, kind_not_allowed};
        _ when is_integer(Max) ->
            Size = event_size(Event),
            case Size =< Max of
                true -> ok;
                false -> {error, event_too_large}
            end
    end.

ensure_required_tags(Event, Policy) ->
    Kind = maps:get(kind, Event, undefined),
    RequiredByKind = maps:get(required_tags, Policy, #{}),
    Required = maps:get(Kind, RequiredByKind, []),
    case required_tags_present(Event, Required) of
        true -> ok;
        false -> {error, missing_required_tag}
    end.

ensure_no_active_content(Event, Policy) ->
    Reject = maps:get(reject_active_content, Policy, true),
    Kind = maps:get(kind, Event, undefined),
    Content = maps:get(content, Event, <<>>),
    case {Reject, Kind, contains_active_content(Content)} of
        {true, 30023, true} -> {error, active_content_not_allowed};
        _ -> ok
    end.

-spec event_size(event()) -> non_neg_integer().
event_size(Event) ->
    %% Use the project's JSON encoder to approximate the relay-facing event body.
    %% Final event-id calculation still belongs to damage_nostr_event.
    byte_size(iolist_to_binary(jsx:encode(Event))).

-spec required_tags_present(event(), [binary()]) -> boolean().
required_tags_present(Event, Required) ->
    lists:all(fun(TagName) -> has_tag(Event, TagName) end, Required).

-spec has_tag(event(), binary()) -> boolean().
has_tag(Event, TagName) ->
    Tags = maps:get(tags, Event, []),
    lists:any(
        fun
            ([TagName | _]) -> true;
            (_) -> false
        end,
        Tags
    ).

contains_active_content(Content) when is_binary(Content) ->
    Lower = lower_ascii(Content),
    Patterns = [
        <<"<script">>,
        <<"<iframe">>,
        <<"<object">>,
        <<"<embed">>,
        <<"javascript:">>,
        <<"onerror=">>,
        <<"onload=">>
    ],
    lists:any(fun(P) -> binary:match(Lower, P) =/= nomatch end, Patterns);
contains_active_content(_) ->
    true.

lower_ascii(Bin) ->
    << <<(lower_char(C))>> || <<C>> <= Bin >>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

audit_hints(Request, Policy) ->
    Event = maps:get(event, Request, #{}),
    #{
        requester_pubkey => maps:get(requester_pubkey, Request, <<>>),
        request_id => maps:get(request_id, Request, <<>>),
        method => maps:get(method, Request, <<>>),
        event_kind => maps:get(kind, Event, null),
        bunker_pubkey => maps:get(bunker_pubkey_hex, Policy, <<>>),
        contract_sha => maps:get(contract_sha, Policy, <<>>)
    }.
