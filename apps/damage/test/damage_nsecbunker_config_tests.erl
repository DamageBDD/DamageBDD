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

disabled_aws_config_is_not_requested_test() ->
    ?assertEqual(
        false,
        damage_nsecbunker_config:aws_requested(#{
            enabled => false,
            secret_provider => aws_secrets_manager
        })
    ).

enabled_aws_config_is_requested_test() ->
    ?assertEqual(
        true,
        damage_nsecbunker_config:aws_requested(#{
            enabled => true,
            secret_provider => aws_secrets_manager
        })
    ).

enabled_defaults_to_false_test() ->
    ?assertEqual(
        false,
        damage_nsecbunker_config:enabled(#{})
    ).

default_provider_is_local_test() ->
    ?assertEqual(
        local,
        damage_nsecbunker_config:secret_provider(#{})
    ).

explicit_local_overrides_stale_aws_block_test() ->
    Config = #{
        secret_provider => local,
        aws_secret_bootstrap => #{enabled => true}
    },
    ?assertEqual(
        local,
        damage_nsecbunker_config:secret_provider(Config)
    ),
    ?assertEqual(
        false,
        damage_nsecbunker_config:managed_secret_owner(Config)
    ).

stale_aws_block_does_not_activate_aws_test() ->
    Config = #{
        aws_secret_bootstrap => #{enabled => true}
    },
    ?assertEqual(
        local,
        damage_nsecbunker_config:secret_provider(Config)
    ).

local_production_config_needs_no_aws_configuration_test() ->
    ?assertEqual(
        ok,
        damage_nsecbunker_config:validate_production(
            (production_config())#{
                secret_provider => local
            }
        )
    ).

omitted_provider_preserves_local_compatibility_test() ->
    Config = production_config(),
    ?assertEqual(
        local,
        damage_nsecbunker_config:secret_provider(Config)
    ),
    ?assertEqual(
        ok,
        damage_nsecbunker_config:validate_production(Config)
    ).

complete_aws_production_config_is_valid_test() ->
    Config = (production_config())#{
        secret_provider => aws_secrets_manager,
        aws_secret => aws_config()
    },
    ?assertEqual(
        ok,
        damage_nsecbunker_config:validate_production(Config)
    ),
    ?assertEqual(
        true,
        damage_nsecbunker_config:managed_secret_owner(Config)
    ).

aws_provider_requires_production_mode_test() ->
    Config = #{
        secret_provider => aws_secrets_manager,
        aws_secret => aws_config()
    },
    ?assertEqual(
        {error, invalid_aws_secret_provider_configuration},
        damage_nsecbunker_config:validate_production(Config)
    ).

aws_configuration_must_be_complete_test() ->
    Config = (production_config())#{
        secret_provider => aws_secrets_manager,
        aws_secret => maps:remove(secret_id, aws_config())
    },
    ?assertMatch(
        {error, {missing_aws_secret_configuration, _}},
        damage_nsecbunker_config:validate_production(Config)
    ).

unknown_provider_is_rejected_test() ->
    Config = (production_config())#{
        secret_provider => some_cloud
    },
    ?assertEqual(
        {
            error,
            {
                unsupported_nsecbunker_secret_provider,
                some_cloud
            }
        },
        damage_nsecbunker_config:validate_production(Config)
    ).

same_provider_reload_is_allowed_test() ->
    ?assertEqual(
        ok,
        damage_nsecbunker_config:provider_change(
            #{secret_provider => local},
            #{secret_provider => local}
        )
    ).

provider_change_requires_restart_test() ->
    ?assertMatch(
        {
            error,
            {
                secret_provider_change_requires_restart,
                #{
                    from := local,
                    to := aws_secrets_manager
                }
            }
        },
        damage_nsecbunker_config:provider_change(
            #{secret_provider => local},
            #{secret_provider => aws_secrets_manager}
        )
    ).

local_supervisor_omits_managed_owner_test() ->
    with_nsecbunker_config(
        (production_config())#{
            secret_provider => local
        },
        fun() ->
            {ok, {{one_for_one, 5, 10}, Children}} =
                damage_nsecbunker_sup:init([]),
            ?assertEqual(
                false,
                lists:member(
                    damage_nsecbunker_secret_owner,
                    child_ids(Children)
                )
            )
        end
    ).

aws_supervisor_includes_managed_owner_test() ->
    with_nsecbunker_config(
        (production_config())#{
            secret_provider => aws_secrets_manager,
            aws_secret => aws_config()
        },
        fun() ->
            {ok, {{rest_for_one, 5, 10}, Children}} =
                damage_nsecbunker_sup:init([]),
            ?assertEqual(
                true,
                lists:member(
                    damage_nsecbunker_secret_owner,
                    child_ids(Children)
                )
            )
        end
    ).

child_ids(Children) ->
    [maps:get(id, Child) || Child <- Children].

with_nsecbunker_config(Config, Fun) ->
    Previous = application:get_env(damage, nsecbunker),
    ok = application:set_env(damage, nsecbunker, Config),
    try
        Fun()
    after
        restore_nsecbunker_config(Previous)
    end.

restore_nsecbunker_config(undefined) ->
    application:unset_env(damage, nsecbunker);
restore_nsecbunker_config({ok, Value}) ->
    application:set_env(damage, nsecbunker, Value).

production_config() ->
    #{
        enabled => true,
        mode => production,
        crypto_backend_cmd =>
            "/opt/damage/bin/damage-nsecbunker-crypto-c",
        vault_path =>
            "/var/lib/damage/nsecbunker/node.vault"
    }.

aws_config() ->
    #{
        region => "ap-southeast-2",
        secret_id =>
            "/damage/prod/nsecbunker/vault-passphrase",
        expected_account_id => "123456789012",
        expected_role_name => "damage-node-prod"
    }.
