-module(damage_nsecbunker_config_tests).

-include_lib("eunit/include/eunit.hrl").

standard_sys_config_proplist_is_canonicalised_test() ->
    Pubkey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    Client = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    Raw = [
        {enabled, true},
        {relay_client_enabled, false},
        {mode, "phase4b_damagebdd_production"},
        {crypto_backend_cmd, "/opt/damage/bin/damage-nsecbunker-crypto-c"},
        {crypto_timeout_ms, 5000},
        {vault_path, "/var/lib/damage/nsecbunker/damagebdd_node_production.vault"},
        {audit_log, "/var/log/damage/nsecbunker_audit.log"},
        {bunker_pubkey_hex, Pubkey},
        {bunker_npub, "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"},
        {contract_sha, "contract-sha"},
        {authorized_clients, [Client]},
        {allowed_methods, ["connect", "ping", "get_public_key", "sign_event"]},
        {allowed_kinds, [1, 30023]},
        {relays, ["wss://relay.damus.io", "wss://nos.lol"]},
        {limits, [
            {created_at_skew_seconds, 600},
            {max_kind_1_bytes, 4096},
            {max_kind_30023_bytes, 131072},
            {rate_limit_per_minute, 12},
            {rate_limit_window_seconds, 60}
        ]},
        {kind_30023, [
            {require_tags, ["d", "title", "published_at"]},
            {reject_html, true}
        ]},
        {phase4a_dev_key_script,
            "/opt/damage/scripts/nsecbunker/phase4a_create_dev_damagebdd_key.sh"},
        {phase4b_production_key_script,
            "/opt/damage/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh"}
    ],
    application:set_env(damage, nsecbunker, Raw),
    Config = damage_nsecbunker:config(),
    Policy = damage_nsecbunker:policy(Config),

    ?assertEqual(true, maps:get(enabled, Config)),
    ?assertEqual(false, maps:get(relay_client_enabled, Config)),
    ?assertEqual("phase4b_damagebdd_production", maps:get(mode, Config)),
    ?assertEqual(
        "/opt/damage/bin/damage-nsecbunker-crypto-c", maps:get(crypto_backend_cmd, Config)
    ),
    ?assertEqual(
        "/var/lib/damage/nsecbunker/damagebdd_node_production.vault", maps:get(vault_path, Config)
    ),
    ?assert(is_map(maps:get(limits, Config))),
    ?assert(is_map(maps:get(kind_30023, Config))),

    ?assertEqual(list_to_binary(Pubkey), maps:get(bunker_pubkey_hex, Policy)),
    ?assertEqual([list_to_binary(Client)], maps:get(authorized_clients, Policy)),
    ?assertEqual(
        [<<"connect">>, <<"ping">>, <<"get_public_key">>, <<"sign_event">>],
        maps:get(allowed_methods, Policy)
    ),
    ?assertEqual([1, 30023], maps:get(allowed_kinds, Policy)),
    ?assertEqual(600, maps:get(created_at_skew_seconds, Policy)),
    ?assertEqual(4096, maps:get(1, maps:get(max_event_bytes, Policy))),
    ?assertEqual(131072, maps:get(30023, maps:get(max_event_bytes, Policy))),
    ?assertEqual(
        [<<"d">>, <<"title">>, <<"published_at">>], maps:get(30023, maps:get(required_tags, Policy))
    ),
    ?assertEqual(#{max_requests => 12, window_seconds => 60}, maps:get(rate_limit, Policy)),

    application:unset_env(damage, nsecbunker).
