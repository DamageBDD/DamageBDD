-module(damage_aws_secret_provider_tests).

-include_lib("eunit/include/eunit.hrl").

credential_provider_104_contract_test() ->
    ?assertEqual(
        aws_credentials_ec2,
        damage_aws_secret_provider:credential_provider(
            #{credential_provider => aws_credentials_ec2}
        )
    ).

nonempty_nested_aws_config_is_valid_test() ->
    ?assertEqual(
        ok,
        damage_nsecbunker_config:validate_production(#{
            mode => production,
            crypto_backend_cmd => "/opt/damage/bin/damage-nsecbunker-crypto-c",
            vault_path => "/var/lib/damage/nsecbunker/node.vault",
            secret_provider => aws_secrets_manager,
            aws_secret_bootstrap => #{
                enabled => true,
                provider => aws_secrets_manager,
                credential_source => ec2_instance_profile,
                require_imdsv2 => true,
                region => "ap-southeast-2",
                secret_id => "/damage/prod/nsecbunker/vault-passphrase",
                version_stage => "AWSCURRENT",
                expected_account_id => "123456789012",
                expected_role_name => "damage-node-prod"
            }
        })
    ).

successful_instance_profile_flow_test() ->
    Config = config(),
    Deps = base_dependencies(),
    {ok, <<"vault-passphrase">>, Metadata} =
        damage_aws_secret_provider:fetch_vault_passphrase(Config, Deps),
    ?assertEqual(aws_credentials_ec2, maps:get(credential_provider, Metadata)),
    ?assertEqual(imdsv2, maps:get(imds_protocol, Metadata)),
    ?assertEqual(<<"123456789012">>, maps:get(account_id, Metadata)),
    ?assertEqual(<<"damage-node-prod">>, maps:get(role_name, Metadata)),
    ?assertEqual(<<"version-1">>, maps:get(version_id, Metadata)),
    ?assertEqual(false, maps:is_key(access_key_id, Metadata)),
    ?assertEqual(false, maps:is_key(secret_access_key, Metadata)),
    ?assertEqual(false, maps:is_key(token, Metadata)).

wrong_provider_is_rejected_test() ->
    Deps = maps:put(
        get_credentials,
        fun() -> (credential_map())#{credential_provider => aws_credentials_env} end,
        base_dependencies()
    ),
    ?assertMatch(
        {error, {wrong_credential_provider, aws_credentials_env}},
        damage_aws_secret_provider:fetch_vault_passphrase(config(), Deps)
    ).

static_environment_credentials_fail_before_secret_call_test() ->
    Self = self(),
    GetEnv = fun
        ("AWS_ACCESS_KEY_ID") -> "forbidden";
        (_) -> false
    end,
    GetSecret = fun(_Client, _Input) ->
        Self ! secrets_manager_called,
        {error, should_not_be_called}
    end,
    Deps = maps:merge(
        base_dependencies(),
        #{os_getenv => GetEnv, get_secret => GetSecret}
    ),
    ?assertMatch(
        {error, {forbidden_aws_credential_source, ["AWS_ACCESS_KEY_ID"]}},
        damage_aws_secret_provider:fetch_vault_passphrase(config(), Deps)
    ),
    receive
        secrets_manager_called -> ?assert(false)
    after 0 ->
        ok
    end.

config() ->
    #{
        enabled => true,
        provider => aws_secrets_manager,
        credential_source => ec2_instance_profile,
        require_imdsv2 => true,
        region => <<"ap-southeast-2">>,
        secret_id => <<"/damage/prod/nsecbunker/vault-passphrase">>,
        version_stage => <<"AWSCURRENT">>,
        expected_account_id => <<"123456789012">>,
        expected_role_name => <<"damage-node-prod">>
    }.

credential_map() ->
    #{
        credential_provider => aws_credentials_ec2,
        access_key_id => <<"temporary-access-key">>,
        secret_access_key => <<"temporary-secret-key">>,
        token => <<"temporary-session-token">>
    }.

base_dependencies() ->
    #{
        ensure_credentials_loaded => fun() -> ok end,
        ensure_credentials_started => fun() -> {ok, [aws_credentials]} end,
        app_env => fun
            (aws_credentials, credential_providers) -> [aws_credentials_ec2];
            (aws_credentials, fail_if_unavailable) -> true
        end,
        os_getenv => fun(_) -> false end,
        imdsv2_validate => fun(<<"damage-node-prod">>) ->
            {ok, #{protocol => imdsv2, role_name => <<"damage-node-prod">>}}
        end,
        get_credentials => fun credential_map/0,
        make_client => fun(_Access, _Secret, _Token, _Region) -> fake_client end,
        sts_identity => fun(fake_client) ->
            {ok,
                #{
                    <<"Account">> => <<"123456789012">>,
                    <<"Arn">> =>
                        <<"arn:aws:sts::123456789012:assumed-role/damage-node-prod/i-0123456789abcdef0">>
                },
                #{}}
        end,
        get_secret => fun(fake_client, Input) ->
            ?assertEqual(
                <<"/damage/prod/nsecbunker/vault-passphrase">>,
                maps:get(<<"SecretId">>, Input)
            ),
            ?assertEqual(<<"AWSCURRENT">>, maps:get(<<"VersionStage">>, Input)),
            {ok,
                #{
                    <<"SecretString">> => <<"vault-passphrase">>,
                    <<"VersionId">> => <<"version-1">>,
                    <<"VersionStages">> => [<<"AWSCURRENT">>]
                },
                #{}}
        end
    }.
