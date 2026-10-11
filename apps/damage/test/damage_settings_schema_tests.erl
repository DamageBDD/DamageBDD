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
