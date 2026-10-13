-module(damage_nsecbunker_phase2_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1778000000).

setup() ->
    set_nsecbunker_config(rate_backend, ets),
    ensure_server(damage_nsecbunker_replay),
    ensure_server(damage_nsecbunker_rate),
    ok = damage_nsecbunker_replay:reset(),
    ok = damage_nsecbunker_rate:reset(),
    ok.

policy() ->
    P0 = damage_nsecbunker_policy:default_policy(),
    P0#{
        bunker_pubkey_hex => <<"BUNKER_PUBKEY_HEX">>,
        contract_sha => <<"PHASE2A_TEST_CONTRACT_SHA">>,
        authorized_clients => [<<"AUTHORISED_CLIENT_PUBKEY_HEX">>],
        allowed_methods => [<<"connect">>, <<"ping">>, <<"get_public_key">>, <<"sign_event">>],
        allowed_kinds => [1, 30023],
        created_at_skew_seconds => 600,
        max_event_bytes => #{1 => 4096, 30023 => 131072},
        required_tags => #{30023 => [<<"d">>, <<"title">>, <<"published_at">>]},
        reject_active_content => true,
        bunker_publishes => false,
        signing_timeout_ms => 10000,
        rate_limit => #{max_requests => 30, window_seconds => 60}
    }.

vault_pubkey() ->
    maps:get(bunker_pubkey_hex, policy()).

valid_event(1) ->
    #{kind => 1, created_at => ?NOW, tags => [], content => <<"Deployment announcement">>};
valid_event(30023) ->
    #{
        kind => 30023,
        created_at => ?NOW,
        tags => [
            [<<"d">>, <<"deployment">>],
            [<<"title">>, <<"Deployment Record">>],
            [<<"published_at">>, integer_to_binary(?NOW)]
        ],
        content => <<"# Deployment Record\n\nMarkdown only.">>
    }.

request(Method) ->
    #{
        requester_pubkey => <<"AUTHORISED_CLIENT_PUBKEY_HEX">>,
        request_id => <<"REQ-1">>,
        method => Method,
        created_at => ?NOW,
        params => []
    }.

sign_request(Event) ->
    (request(<<"sign_event">>))#{event => Event}.

authorized_ping_allowed_test() ->
    setup(),
    ?assertMatch(
        {ok, _},
        damage_nsecbunker_policy:authorize(request(<<"ping">>), policy(), ?NOW, vault_pubkey())
    ).

unknown_client_rejected_test() ->
    setup(),
    Req = (request(<<"get_public_key">>))#{requester_pubkey => <<"UNKNOWN_CLIENT_PUBKEY_HEX">>},
    ?assertEqual(
        {error, client_not_authorized},
        damage_nsecbunker_policy:authorize(Req, policy(), ?NOW, vault_pubkey())
    ).

unsupported_method_rejected_test() ->
    setup(),
    Req = request(<<"publish_event">>),
    ?assertEqual(
        {error, method_not_allowed},
        damage_nsecbunker_policy:authorize(Req, policy(), ?NOW, vault_pubkey())
    ).

kind1_signing_allowed_by_policy_test() ->
    setup(),
    ?assertMatch(
        {ok, _},
        damage_nsecbunker_policy:authorize(
            sign_request(valid_event(1)), policy(), ?NOW, vault_pubkey()
        )
    ).

kind30023_signing_allowed_by_policy_test() ->
    setup(),
    ?assertMatch(
        {ok, _},
        damage_nsecbunker_policy:authorize(
            sign_request(valid_event(30023)), policy(), ?NOW, vault_pubkey()
        )
    ).

unsupported_kind_rejected_test() ->
    setup(),
    Event = #{kind => 4, created_at => ?NOW, tags => [], content => <<"no">>},
    ?assertEqual(
        {error, kind_not_allowed},
        damage_nsecbunker_policy:authorize(sign_request(Event), policy(), ?NOW, vault_pubkey())
    ).

stale_request_rejected_test() ->
    setup(),
    Event = (valid_event(1))#{created_at => ?NOW - 1000},
    Req = (sign_request(Event))#{created_at => ?NOW - 1000},
    ?assertEqual(
        {error, request_stale},
        damage_nsecbunker_policy:authorize(Req, policy(), ?NOW, vault_pubkey())
    ).

future_request_rejected_test() ->
    setup(),
    Event = (valid_event(1))#{created_at => ?NOW + 1000},
    Req = (sign_request(Event))#{created_at => ?NOW + 1000},
    ?assertEqual(
        {error, request_from_future},
        damage_nsecbunker_policy:authorize(Req, policy(), ?NOW, vault_pubkey())
    ).

kind30023_missing_tags_rejected_test() ->
    setup(),
    Event = (valid_event(30023))#{tags => []},
    ?assertEqual(
        {error, missing_required_tag},
        damage_nsecbunker_policy:authorize(sign_request(Event), policy(), ?NOW, vault_pubkey())
    ).

kind30023_active_content_rejected_test() ->
    setup(),
    Event = (valid_event(30023))#{content => <<"# Bad\n<script>alert(1)</script>">>},
    ?assertEqual(
        {error, active_content_not_allowed},
        damage_nsecbunker_policy:authorize(sign_request(Event), policy(), ?NOW, vault_pubkey())
    ).

replay_duplicate_same_payload_is_idempotent_test() ->
    setup(),
    ?assertEqual(
        ok, damage_nsecbunker_replay:check_and_mark(<<"client">>, <<"REQ">>, <<"HASH-A">>)
    ),
    ?assertEqual(
        {ok, duplicate_same_payload},
        damage_nsecbunker_replay:check_and_mark(<<"client">>, <<"REQ">>, <<"HASH-A">>)
    ).

replay_conflict_rejected_test() ->
    setup(),
    ?assertEqual(
        ok, damage_nsecbunker_replay:check_and_mark(<<"client">>, <<"REQ">>, <<"HASH-A">>)
    ),
    ?assertEqual(
        {error, replay_conflict},
        damage_nsecbunker_replay:check_and_mark(<<"client">>, <<"REQ">>, <<"HASH-B">>)
    ).

rate_limited_client_rejected_test() ->
    setup(),
    ok = damage_nsecbunker_rate:seed(<<"client">>, ?NOW, 30),
    ?assertEqual(
        {error, rate_limited}, damage_nsecbunker_rate:check_and_mark(<<"client">>, ?NOW, 30, 60)
    ).

vault_integrity_failure_rejected_test() ->
    setup(),
    Vault = #{sealed => false, integrity => failed, pubkey_hex => vault_pubkey()},
    ?assertEqual(
        {error, vault_integrity_failed},
        damage_nsecbunker_vault_guard:assert_ready(Vault, vault_pubkey())
    ).

vault_pubkey_mismatch_rejected_test() ->
    setup(),
    Vault = #{sealed => false, integrity => ok, pubkey_hex => <<"DIFFERENT">>},
    ?assertEqual(
        {error, vault_pubkey_mismatch},
        damage_nsecbunker_vault_guard:assert_ready(Vault, vault_pubkey())
    ).

audit_line_is_ordered_and_redacted_test() ->
    Line = damage_nsecbunker_audit:canonical_line(#{
        ts_unix => ?NOW,
        requester_pubkey => <<"client">>,
        request_id => <<"REQ-AUDIT">>,
        method => <<"sign_event">>,
        decision => <<"rejected">>,
        deny_reason => <<"method_not_allowed">>,
        event_kind => 30023,
        event_id => <<>>,
        payload_sha256 => <<"HASH">>,
        bunker_pubkey => vault_pubkey(),
        contract_sha => <<"CONTRACT">>,
        nsec => <<"SHOULD_NOT_APPEAR">>
    }),
    ?assertMatch({0, _}, binary:match(Line, <<"{\"schema_version\":1,\"ts_unix\":">>)),
    ?assert(binary:match(Line, <<"\"requester_pubkey\":">>) =/= nomatch),
    ?assert(binary:match(Line, <<"\"contract_sha\":">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Line, <<"SHOULD_NOT_APPEAR">>)),
    ?assertEqual(nomatch, binary:match(Line, <<"nsec">>)).

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

ensure_server(Module) ->
    case whereis(Module) of
        undefined ->
            case Module:start_link() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok
            end;
        _Pid ->
            ok
    end.
