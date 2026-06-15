-module(damage_nsecbunker_phase1_tests).

-include_lib("eunit/include/eunit.hrl").

policy_from_config_converts_methods_test() ->
    Config = #{
        bunker_pubkey_hex => <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>,
        contract_sha => <<"signedoff">>,
        authorized_clients => [<<"client">>],
        allowed_methods => [connect, ping, get_public_key, sign_event],
        limits => #{
            created_at_skew_seconds => 60, max_kind_1_bytes => 100, max_kind_30023_bytes => 1000
        },
        kind_30023 => #{require_tags => [<<"d">>], reject_html => true}
    },
    Policy = damage_nsecbunker:policy(Config),
    ?assert(lists:member(<<"sign_event">>, maps:get(allowed_methods, Policy))),
    ?assertEqual([<<"client">>], maps:get(authorized_clients, Policy)).

plain_ping_fails_closed_when_backend_missing_test() ->
    %% This is a shape test for the plain BDD hook. Full gen_server startup depends on damage_sup integration.
    Config = #{
        enabled => true,
        bunker_pubkey_hex => <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>,
        authorized_clients => [<<"client">>],
        allowed_methods => [ping],
        allowed_kinds => [1, 30023],
        crypto_backend_cmd => "/definitely/not/installed"
    },
    Policy = damage_nsecbunker:policy(Config),
    Vault = damage_nsecbunker_vault:init(Config, Policy),
    VaultState = damage_nsecbunker_vault:guard_state(Vault),
    Request = #{
        requester_pubkey => <<"client">>,
        request_id => <<"ping-1">>,
        method => <<"ping">>,
        created_at => erlang:system_time(second),
        params => []
    },
    ?assertEqual(
        {error, vault_sealed},
        damage_nsecbunker_vault_guard:assert_ready(VaultState, maps:get(bunker_pubkey_hex, Policy))
    ).
