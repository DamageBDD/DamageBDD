-module(damage_tax_access_tests).
-include_lib("eunit/include/eunit.hrl").

admin_separation_test() ->
    Node = <<"ak_22222222222222222222222222222222222222222222222222222">>,
    Tax = <<"ak_33333333333333333333333333333333333333333333333333333">>,
    Other = <<"ak_44444444444444444444444444444444444444444444444444444">>,
    OldNode = application:get_env(damage, node_admins),
    OldTax = application:get_env(damage, tax_admins),
    try
        ok = application:set_env(damage, node_admins, [Node]),
        ok = application:set_env(damage, tax_admins, [Tax]),
        ?assert(damage_auth:is_node_admin_account(Node)),
        ?assert(not damage_auth:is_node_admin_account(Tax)),
        ?assert(damage_auth:is_tax_admin_account(Node)),
        ?assert(damage_auth:is_tax_admin_account(Tax)),
        ?assert(not damage_auth:is_tax_admin_account(Other)),
        TState = damage_auth:auth_success_state(#{}, Tax, #{}),
        ?assertEqual(false, maps:get(node_admin, TState)),
        ?assertEqual(true, maps:get(tax_admin, TState)),
        ?assert(damage_tax_access:allowed(TState)),
        ?assert(damage_tax_access:allowed(damage_auth:auth_success_state(#{}, Node, #{}))),
        ?assertNot(damage_tax_access:allowed(damage_auth:auth_success_state(#{}, Other, #{}))),
        ?assertNot(damage_tax_access:allowed(TState#{tax_admin => false})),
        ?assertNot(damage_tax_access:allowed(TState#{public_key => Other})),
        ?assertNot(damage_tax_access:allowed(TState#{auth_mode => wallet})),
        ?assertNot(damage_tax_access:allowed(TState#{auth_type => l402})),
        ?assertNot(damage_tax_access:allowed(TState#{authenticated => false})),
        %% Allowlist changes must revoke access immediately, without trusting
        %% the node_admin/tax_admin flags cached in an older session.
        ok = application:set_env(damage, tax_admins, []),
        ?assertNot(damage_tax_access:allowed(TState))
    after
        restore(node_admins, OldNode),
        restore(tax_admins, OldTax)
    end.

scoped_tax_settings_only_test() ->
    ?assertEqual(8, length(damage_tax_settings:keys())),
    ?assert(damage_tax_settings:authorized_changes(#{})),
    ?assert(damage_tax_settings:authorized_changes(#{<<"tax_enabled">> => false})),
    ?assert(damage_tax_settings:authorized_changes(#{<<"tax_jurisdiction">> => <<"US">>})),
    ?assertNot(
        damage_tax_settings:authorized_changes(
            #{<<"node_admins">> => [<<"intruder">>]}
        )
    ),
    ?assertNot(
        damage_tax_settings:authorized_changes(
            #{<<"tax_admins">> => [<<"intruder">>]}
        )
    ),
    ?assertNot(
        damage_tax_settings:authorized_changes(
            #{<<"cln_enabled">> => false}
        )
    ),
    ?assertNot(
        damage_tax_settings:authorized_changes(
            #{<<"tax_enabled">> => false, <<"nwc_ledger_mode">> => <<"server_signed">>}
        )
    ),
    ?assert(damage_tax_settings:authorized_resets([<<"tax_enabled">>])),
    ?assertNot(damage_tax_settings:authorized_resets([<<"tax_enabled">>, <<"tax_enabled">>])),
    ?assertNot(damage_tax_settings:authorized_resets([<<"tax_admins">>])).

projection_hides_non_tax_and_operator_metadata_test() ->
    Fields = [
        #{name => <<"tax_enabled">>, value => false},
        #{name => <<"tax_cln_owner">>, value => null},
        #{name => <<"node_admins">>, value => [<<"private">>]},
        #{name => <<"cln_enabled">>, value => true}
    ],
    Result = damage_tax_settings:project(#{
        fields => Fields,
        version => <<"v1">>,
        discovered => [#{name => <<"tax_admins">>}],
        config_file => <<"/secret/path">>,
        last_error => <<"sensitive">>,
        pending_restart => [<<"damage.tax_enabled">>, <<"damage.cln_enabled">>]
    }),
    ?assertEqual(
        [
            #{name => <<"tax_enabled">>, value => false},
            #{name => <<"tax_cln_owner">>, value => null}
        ],
        maps:get(fields, Result)
    ),
    ?assertEqual([<<"damage.tax_enabled">>], maps:get(pending_restart, Result)),
    ?assertEqual(true, maps:get(restart_required, Result)),
    ?assertNot(maps:is_key(config_file, Result)),
    ?assertNot(maps:is_key(discovered, Result)),
    ?assertNot(maps:is_key(last_error, Result)).

restore(Key, undefined) -> application:unset_env(damage, Key);
restore(Key, {ok, Old}) -> application:set_env(damage, Key, Old).
