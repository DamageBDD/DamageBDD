-module(damage_settings_schema_tests).
-include_lib("eunit/include/eunit.hrl").

schema_contains_all_apps_test() ->
    ?assertEqual([damage, ecai, nosternity, erm, bop], damage_settings_schema:apps()),
    ?assertEqual({error, unknown_application},
                 damage_settings_schema:normalize_app(<<"unknown">>)).

blocks_sensitive_and_unknown_keys_test() ->
    ?assertMatch({error, {not_editable, <<"node_admins">>}},
                 damage_settings_schema:decode_changes(damage,
                   #{<<"node_admins">> => [<<"ak_attacker">>]})),
    ?assertMatch({error, {not_editable, <<"api_key_secret">>}},
                 damage_settings_schema:decode_changes(damage,
                   #{<<"api_key_secret">> => <<"SECRET">>})),
    ?assertMatch({error, {not_editable, <<"nostr_private_key_hex">>}},
                 damage_settings_schema:decode_changes(nosternity,
                   #{<<"nostr_private_key_hex">> => <<"SECRET">>})),
    ?assertMatch({error, {not_editable, <<"code_security_enabled">>}},
                 damage_settings_schema:decode_changes(ecai,
                   #{<<"code_security_enabled">> => false})).

preserves_expected_erlang_types_test() ->
    {ok, Damage} = damage_settings_schema:decode_changes(damage, #{
        <<"strict_no_catchall">> => true, <<"ae_fee_multiplier">> => 4,
        <<"proxy_exclude">> => [<<"localhost">>, <<".lan">>]
    }),
    ?assertEqual(true, proplists:get_value(strict_no_catchall, Damage)),
    ?assertEqual(4, proplists:get_value(ae_fee_multiplier, Damage)),
    ?assertEqual(["localhost", ".lan"], proplists:get_value(proxy_exclude, Damage)),
    {ok, ECAI} = damage_settings_schema:decode_changes(ecai,
        #{<<"code_ollama_model">> => <<"qwen2.5-coder">>}),
    ?assertEqual("qwen2.5-coder", proplists:get_value(code_ollama_model, ECAI)).

invalid_type_or_range_test() ->
    ?assertMatch({error, {invalid_value, <<"ae_fee_multiplier">>, _}},
      damage_settings_schema:decode_changes(damage,
        #{<<"ae_fee_multiplier">> => -1})),
    ?assertMatch({error, {invalid_value, <<"strict_no_catchall">>, _}},
      damage_settings_schema:decode_changes(damage,
        #{<<"strict_no_catchall">> => <<"true">>})),
    ?assertMatch({error, {invalid_value, <<"code_ollama_model">>, _}},
      damage_settings_schema:decode_changes(ecai,
        #{<<"code_ollama_model">> => <<>>})),
    ?assertMatch({error, {invalid_value, <<"proxy_exclude">>, _}},
      damage_settings_schema:decode_changes(damage,
        #{<<"proxy_exclude">> => [<<"ok">>, 123]})).

feature_grouping_and_new_apps_test() ->
    {ok, Fee} = damage_settings_schema:field(damage, <<"ae_fee_multiplier">>),
    ?assertEqual(<<"aeternity">>, maps:get(group, Fee)),
    {ok, Repair} = damage_settings_schema:field(ecai, <<"code_patch_max_attempts">>),
    ?assertEqual(<<"repair">>, maps:get(group, Repair)),
    {ok, Http} = damage_settings_schema:field(erm, <<"http_enabled">>),
    ?assertEqual(<<"runtime">>, maps:get(group, Http)),
    {ok, Port} = damage_settings_schema:field(bop, <<"port">>),
    ?assertEqual(<<"runtime">>, maps:get(group, Port)),
    ?assert(length(damage_settings_catalog:groups(nosternity)) > 1),
    ?assertMatch({error, {invalid_value, <<"http_num_acceptors">>, _}},
                 damage_settings_schema:decode_changes(nosternity,
                   #{<<"http_num_acceptors">> => 101})),
    ?assertMatch({error, {not_editable, <<"keystore">>}},
                 damage_settings_schema:decode_changes(bop,
                   #{<<"keystore">> => <<"do not publish">>})).

nosternity_cross_field_validation_test() ->
    ?assertEqual(ok, damage_settings_schema:validate_effective(#{nosternity => #{
        search_default_limit => 25, search_max_limit => 50}})),
    ?assertMatch({error, {invalid_setting_combination, nosternity, _, _}},
                 damage_settings_schema:validate_effective(#{nosternity => #{
                     search_default_limit => 200, search_max_limit => 50}})).

catalog_contains_no_mutable_credentials_test() ->
    ?assertEqual(<<"protected">>, damage_settings_catalog:restriction(bop, <<"keystore">>)),
    ?assertEqual(<<"protected">>, damage_settings_catalog:restriction(damage, <<"node_admins">>)),
    ?assertMatch({error, {not_editable, <<"node_admins">>}},
                 damage_settings_schema:decode_changes(damage,
                   #{<<"node_admins">> => [<<"ak_forbidden">>]})).

%% Managed ATO tax settings are public *configuration* but not public reports.
%% The tax owner must survive the Settings serializer as a binary, not a list.
tax_controls_are_allowlisted_and_grouped_test() ->
    Keys = [tax_enabled, tax_cln_owner, tax_data_dir, tax_backfill_on_start,
            tax_standard_utc_offset_minutes, tax_max_prices_per_backfill,
            tax_price_pause_ms],
    [begin
        {ok, F} = damage_settings_schema:field(damage, atom_to_binary(K, utf8)),
        ?assertEqual(<<"tax">>, maps:get(group, F))
     end || K <- Keys],
    ?assert(lists:any(fun(G) -> maps:get(id, G) =:= <<"tax">> end,
                      damage_settings_catalog:groups(damage))),
    {ok, OwnerField} = damage_settings_schema:field(damage, <<"tax_cln_owner">>),
    ?assertEqual(ae_account, maps:get(type, OwnerField)),
    ?assertEqual(restart, maps:get(apply, OwnerField)),
    {ok, Enabled} = damage_settings_schema:field(damage, <<"tax_enabled">>),
    ?assertEqual(false, maps:get(default, Enabled)),
    ?assertEqual(restart, maps:get(apply, Enabled)),
    {ok, Budget} = damage_settings_schema:field(damage, <<"tax_max_prices_per_backfill">>),
    ?assertEqual(hot, maps:get(apply, Budget)),
    ?assertEqual(200, maps:get(default, Budget)).

tax_settings_preserve_runtime_types_test() ->
    Owner = <<"ak_22222222222222222222222222222222222222222222222222222">>,
    {ok, Changes} = damage_settings_schema:decode_changes(damage, #{
        <<"tax_enabled">> => true,
        <<"tax_cln_owner">> => Owner,
        <<"tax_data_dir">> => <<"/var/lib/damage/tax">>,
        <<"tax_backfill_on_start">> => false,
        <<"tax_standard_utc_offset_minutes">> => 600,
        <<"tax_max_prices_per_backfill">> => 200,
        <<"tax_price_pause_ms">> => 250
    }),
    ?assertEqual(Owner, proplists:get_value(tax_cln_owner, Changes)),
    ?assert(is_binary(proplists:get_value(tax_cln_owner, Changes))),
    ?assertEqual("/var/lib/damage/tax", proplists:get_value(tax_data_dir, Changes)),
    ?assertEqual(ok, damage_settings_schema:validate_effective(
        #{damage => maps:from_list(Changes)})),
    ?assertEqual({ok, Owner}, damage_settings_schema:decode_existing(
        damage, tax_cln_owner, binary_to_list(Owner))).

tax_invalid_settings_rejected_test() ->
    Invalid = [
        {<<"tax_enabled">>, <<"true">>},
        {<<"tax_cln_owner">>, <<"invalid-owner">>},
        {<<"tax_cln_owner">>, <<"ak_11O0Iillegal">>},
        {<<"tax_data_dir">>, <<"relative/path">>},
        {<<"tax_data_dir">>, <<"/var/lib/damage/../tax">>},
        {<<"tax_data_dir">>, <<"/">>},
        {<<"tax_data_dir">>, <<"/tmp">>},
        {<<"tax_data_dir">>, <<"/usr/bin">>},
        {<<"tax_standard_utc_offset_minutes">>, -600},
        {<<"tax_max_prices_per_backfill">>, 501},
        {<<"tax_price_pause_ms">>, 5001}
    ],
    [ ?assertMatch({error, {invalid_value, _, _}},
          damage_settings_schema:decode_changes(damage, #{Key => Bad}))
      || {Key, Bad} <- Invalid ],
    ?assertMatch({error, {invalid_setting_combination, damage,
                           tax_enabled, tax_cln_owner}},
        damage_settings_schema:validate_effective(
            #{damage => #{tax_enabled => true}})),
    ?assertEqual(ok, damage_settings_schema:validate_effective(
        #{damage => #{tax_enabled => false}})),
    %% Provider API tokens remain operator-managed secrets: names-only.
    ?assertEqual(<<"protected">>, damage_settings_catalog:restriction(
        damage, <<"tax_cryptocompare_key">>)),
    ?assertMatch({error, {not_editable, <<"tax_cryptocompare_key">>}},
        damage_settings_schema:decode_changes(damage,
            #{<<"tax_cryptocompare_key">> => <<"secret">>})),
    ?assertMatch({error, {not_editable, <<"tax_coingecko_demo_key">>}},
        damage_settings_schema:decode_changes(damage,
            #{<<"tax_coingecko_demo_key">> => <<"secret">>})).
