-module(damage_nsecbunker_config_tests).

-include_lib("eunit/include/eunit.hrl").

standard_sys_config_proplist_policy_test() ->
    Config = [
        {enabled, true},
        {relay_client_enabled, false},
        {mode, phase4a_dev_rehearsal},
        {crypto_backend_cmd, "/opt/damage/bin/damage-nsecbunker-crypto-c"},
        {vault_path, "/var/lib/damage/nsecbunker/dev_damagebdd.vault"},
        {audit_log, "/var/log/damage/nsecbunker_audit.log"},
        {bunker_pubkey_hex, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {contract_sha, "feature-sha"},
        {authorized_clients, [
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ]},
        {allowed_methods, [connect, ping, get_public_key, sign_event]},
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
        {reject_active_content, true},
        {bunker_publishes, false},
        {signing_timeout_ms, 10000},
        {genesis, [
            {enabled, false},
            {allowed_content_sha256, []}
        ]}
    ],
    Policy = damage_nsecbunker:policy(Config),
    ?assertEqual(
        <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>,
        maps:get(bunker_pubkey_hex, Policy)
    ),
    ?assertEqual(
        [<<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>],
        maps:get(authorized_clients, Policy)
    ),
    ?assertEqual(
        [<<"connect">>, <<"ping">>, <<"get_public_key">>, <<"sign_event">>],
        maps:get(allowed_methods, Policy)
    ),
    ?assertEqual([1, 30023], maps:get(allowed_kinds, Policy)),
    ?assertEqual(600, maps:get(created_at_skew_seconds, Policy)),
    ?assertEqual(#{1 => 4096, 30023 => 131072}, maps:get(max_event_bytes, Policy)),
    ?assertEqual(
        #{30023 => [<<"d">>, <<"title">>, <<"published_at">>]},
        maps:get(required_tags, Policy)
    ),
    ?assertEqual(#{max_requests => 12, window_seconds => 60}, maps:get(rate_limit, Policy)).

explicit_required_tags_proplist_test() ->
    Config = [
        {bunker_pubkey_hex, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {required_tags, [{30023, ["d", "title"]}]},
        {max_event_bytes, [{1, "4096"}, {30023, "131072"}]}
    ],
    Policy = damage_nsecbunker:policy(Config),
    ?assertEqual(#{30023 => [<<"d">>, <<"title">>]}, maps:get(required_tags, Policy)),
    ?assertEqual(#{1 => 4096, 30023 => 131072}, maps:get(max_event_bytes, Policy)).
