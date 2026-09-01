%%--------------------------------------------------------------------
%% damage_nsecbunker_ops
%%
%% Operational nsecbunker helpers implemented in Erlang so Phase 4
%% deployment/key-ceremony work can run from the Damage release without
%% shell/python ceremony scripts.
%%
%% Managed-provider ceremonies delegate through the supervised secure owner.
%% The default local provider retains the existing one-shot ceremony/backend
%% behavior. The module does not invoke /bin/sh and does not require
%% Python/curl/sha256sum for ceremony, artifact hashing or checks.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_ops).

-include_lib("kernel/include/file.hrl").

-export([
    %% Phase 4 ceremonies
    phase4a_create_dev_key/0,
    phase4a_create_dev_key/1,
    phase4b_create_production_damagebdd_node_key/0,
    phase4b_create_production_damagebdd_node_key/1,
    phase4a_ceremony_available/0,
    phase4b_ceremony_available/0,

    %% Backend contract / smoke helpers
    backend_call/1,
    backend_call/2,
    smoke_phase2b_crypto_c_backend/0,
    smoke_phase2b_crypto_c_backend/1,
    smoke_phase2c_crypto_vectors/0,
    smoke_phase2c_crypto_vectors/1,

    %% Interactive operator / REPL helpers
    help/0,
    status/0,
    services/0,
    aws_probe/0,
    quiesce_aws/0,
    disable/0,
    use_local/0,
    use_aws/4,
    restart/0,
    %% Release/deployment helpers
    install_crypto_backend/0,
    install_crypto_backend/2,
    check_release_artifacts/0,
    check_release_artifacts/1,
    hash_phase4a_artifacts/0,
    hash_phase4b_artifacts/0,
    hash_artifacts/2,

    %% Utility exposed for BDD steps/tests
    crypto_backend_path/0,
    crypto_backend_path/1,
    root/0,
    root/1,
    report_dir/1,
    lower_hex_sha256_file/1,
    contains_secret_material/1
]).

-define(APPROVAL, "I_UNDERSTAND_THIS_CREATES_A_PRODUCTION_DAMAGEBDD_NODE_KEY").
-define(DEFAULT_BACKEND, "/opt/damage/bin/damage-nsecbunker-crypto-c").
-define(LOCAL_BACKEND, "priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c").

%%====================================================================
%% Phase 4 ceremonies
%%====================================================================

phase4a_create_dev_key() ->
    phase4a_create_dev_key(#{}).

phase4a_create_dev_key(Opts0) ->
    with_file_access_errors(fun() -> phase4a_create_dev_key_unsafe(Opts0) end).

phase4a_create_dev_key_unsafe(Opts0) ->
    Opts = opts(Opts0),
    Root = root(Opts),
    Backend = crypto_backend_path(Opts),
    Vault = opt_env_config(
        Opts,
        dev_vault_path,
        "DAMAGE_NSECBUNKER_DEV_VAULT",
        [phase4a_dev_vault_path, dev_vault_path],
        filename:join([Root, ".damage-nsecbunker", "phase4a_dev_damagebdd_bdd.vault"])
    ),
    ReportDir = report_dir(Opts),
    JsonReport = filename:join(ReportDir, "PHASE4A_DEV_DAMAGEBDD_KEY.json"),
    MdReport = filename:join(ReportDir, "PHASE4A_DEV_DAMAGEBDD_KEY.md"),
    Passphrase = vault_passphrase(Opts, "phase4a-bdd-dev-passphrase"),
    Reset = truthy(opt_env(Opts, reset, "RESET_DEV_VAULT", "1")),
    ok = ensure_parent(Vault),
    ok = ensure_dir(ReportDir),
    case Reset of
        true ->
            ok = delete_if_exists(Vault),
            ok;
        false ->
            ok
    end,
    Env = backend_env(Opts, Passphrase),
    Gen = backend_call(
        #{<<"op">> => <<"generate_identity">>, <<"vault_path">> => bin(Vault)}, Opts#{
            backend => Backend, env => Env
        }
    ),
    Pub = backend_call(#{<<"op">> => <<"get_public_key">>, <<"vault_path">> => bin(Vault)}, Opts#{
        backend => Backend, env => Env
    }),
    Pubkey = require_pubkey(
        first_present([field(<<"pubkey_hex">>, Pub), field(<<"pubkey_hex">>, Gen)])
    ),
    Npub = require_npub(
        first_present([
            field(<<"npub">>, Gen), npub_for(Pubkey, Opts#{backend => Backend, env => Env})
        ])
    ),
    ok = change_mode(Vault, 8#600),
    Created = iso8601_now(),
    Report = #{
        <<"phase">> => <<"4A">>,
        <<"purpose">> => <<"dev_damagebdd_key_rehearsal">>,
        <<"status">> => <<"generated">>,
        <<"created_at_utc">> => Created,
        <<"backend">> => bin(Backend),
        <<"vault_path">> => bin(Vault),
        <<"pubkey_hex">> => Pubkey,
        <<"npub">> => Npub,
        <<"secret_exported">> => false,
        <<"scope">> => <<"DEV/DISPOSABLE ONLY - not production custody">>
    },
    ok = assert_no_secret_material(Report),
    ok = write_json(JsonReport, Report),
    ok = write_file(MdReport, phase4a_markdown(Report)),
    {ok, Report#{<<"json_report">> => bin(JsonReport), <<"markdown_report">> => bin(MdReport)}}.

phase4b_create_production_damagebdd_node_key() ->
    phase4b_create_production_damagebdd_node_key(#{}).

phase4b_create_production_damagebdd_node_key(Opts0) ->
    with_file_access_errors(fun() ->
        Opts = opts(Opts0),
        case require_phase4b_approval(Opts) of
            ok -> phase4b_create_production_damagebdd_node_key_0(Opts);
            {error, _} = Error -> Error
        end
    end).

phase4b_create_production_damagebdd_node_key_0(Opts) ->
    Config = config(),
    case production_phase4b_preflight(Opts, Config) of
        {ok, aws_secrets_manager} ->
            phase4b_create_production_damagebdd_node_key_secure(Opts, Config);
        {ok, local} ->
            phase4b_create_production_damagebdd_node_key_local(Opts, Config);
        {error, _} = Error ->
            Error
    end.

phase4b_create_production_damagebdd_node_key_secure(Opts, Config) ->
    Root = root(Opts),
    Vault = str(maps:get(vault_path, Config)),
    Backend = str(maps:get(crypto_backend_cmd, Config)),
    ReportDir = report_dir(Opts#{root => Root}),
    JsonReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json"),
    MdReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md"),
    ok = ensure_parent(JsonReport),
    case damage_nsecbunker:generate_identity() of
        {ok, Generated} ->
            case damage_nsecbunker:export_identity() of
                {ok, Exported} ->
                    phase4b_write_secure_report(
                        Backend, Vault, JsonReport, MdReport, Generated, Exported
                    );
                {error, Reason} ->
                    {error, {production_identity_export_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {production_identity_generation_failed, Reason}}
    end.

phase4b_write_secure_report(Backend, Vault, JsonReport, MdReport, Generated, Exported) ->
    Pubkey = require_pubkey(
        first_present([
            field(<<"pubkey_hex">>, Exported), field(<<"pubkey_hex">>, Generated)
        ])
    ),
    Npub = require_npub(
        first_present([
            field(<<"npub">>, Exported), field(<<"npub">>, Generated)
        ])
    ),
    OwnerStatus = damage_nsecbunker_secret_owner:status(),
    Provenance = maps:get(secret_provenance, OwnerStatus, #{}),
    VaultMetadata = maps:get(vault, OwnerStatus, #{}),
    VaultCreated = first_present(
        [
            maps:get(vault_created, VaultMetadata, undefined),
            maps:get(<<"vault_created">>, VaultMetadata, false)
        ],
        false
    ),
    ok = file_mode_private(Vault),
    VaultMode = file_mode_octal(Vault),
    Report = #{
        <<"phase">> => <<"4B">>,
        <<"purpose">> => <<"production_damagebdd_node_key">>,
        <<"status">> =>
            case VaultCreated of
                true -> <<"generated">>;
                false -> <<"existing_vault_public_identity_exported">>
            end,
        <<"created_at_utc">> => iso8601_now(),
        <<"backend">> => bin(Backend),
        <<"backend_sha256">> => lower_hex_sha256_file(Backend),
        <<"backend_protocol">> => bin(maps:get(backend_protocol, Provenance, framed_stdio_v2)),
        <<"secret_provider">> => <<"aws_secrets_manager">>,
        <<"vault_path">> => bin(Vault),
        <<"vault_created">> => VaultCreated,
        <<"vault_mode_octal">> => bin(VaultMode),
        <<"pubkey_hex">> => Pubkey,
        <<"npub">> => Npub,
        <<"credential_provider">> => bin(maps:get(credential_provider, Provenance, undefined)),
        <<"imds_protocol">> => bin(maps:get(imds_protocol, Provenance, undefined)),
        <<"aws_account_id">> => maps:get(account_id, Provenance, <<>>),
        <<"aws_role_name">> => maps:get(role_name, Provenance, <<>>),
        <<"secret_id_sha256">> => maps:get(secret_id_sha256, Provenance, <<>>),
        <<"secret_version_id">> => bin(maps:get(version_id, Provenance, <<>>)),
        <<"secret_version_stages">> => maps:get(version_stages, Provenance, []),
        <<"secret_exported">> => false,
        <<"scope">> => <<"PRODUCTION Damage node nsecbunker identity">>
    },
    write_phase4b_report(JsonReport, MdReport, Report).

%% Compatibility path for non-managed infrastructure. It intentionally keeps
%% the previous Damage secret-store and one-shot C backend behavior. It is
%% selected only by explicit/default local configuration; an AWS-selected node
%% never reaches this code after an AWS failure.
phase4b_create_production_damagebdd_node_key_local(Opts, Config) ->
    Root = root(Opts),
    Backend = crypto_backend_path(Opts),
    Vault = opt_env_config(
        Opts,
        prod_vault_path,
        "DAMAGE_NSECBUNKER_PROD_VAULT",
        [phase4b_prod_vault_path, production_vault_path, prod_vault_path],
        str(
            maps:get(
                vault_path,
                Config,
                "/var/lib/damage/nsecbunker/damagebdd_node_production.vault"
            )
        )
    ),
    ReportDir = report_dir(Opts#{root => Root}),
    JsonReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json"),
    MdReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md"),
    Passphrase = vault_passphrase(Opts, undefined),
    case Passphrase of
        undefined ->
            {error, production_vault_passphrase_required};
        [] ->
            {error, production_vault_passphrase_required};
        <<>> ->
            {error, production_vault_passphrase_required};
        _ ->
            phase4b_create_production_damagebdd_node_key_local_1(
                Opts, Backend, Vault, JsonReport, MdReport, Passphrase
            )
    end.

phase4b_create_production_damagebdd_node_key_local_1(
    Opts, Backend, Vault, JsonReport, MdReport, Passphrase
) ->
    ok = ensure_parent(Vault),
    ok = ensure_parent(JsonReport),
    VaultExistsBefore = filelib:is_regular(Vault),
    Env = backend_env(Opts, Passphrase),
    Gen =
        case VaultExistsBefore of
            true ->
                #{};
            false ->
                backend_call(
                    #{
                        <<"op">> => <<"generate_identity">>,
                        <<"vault_path">> => bin(Vault)
                    },
                    Opts#{backend => Backend, env => Env}
                )
        end,
    Pub = backend_call(
        #{<<"op">> => <<"get_public_key">>, <<"vault_path">> => bin(Vault)},
        Opts#{backend => Backend, env => Env}
    ),
    Pubkey = require_pubkey(
        first_present([
            field(<<"pubkey_hex">>, Pub), field(<<"pubkey_hex">>, Gen)
        ])
    ),
    Npub = require_npub(
        first_present([
            field(<<"npub">>, Gen),
            npub_for(Pubkey, Opts#{backend => Backend, env => Env})
        ])
    ),
    ok = file_mode_private(Vault),
    VaultMode = file_mode_octal(Vault),
    Report = #{
        <<"phase">> => <<"4B">>,
        <<"purpose">> => <<"production_damagebdd_node_key">>,
        <<"status">> =>
            case VaultExistsBefore of
                true -> <<"existing_vault_public_identity_exported">>;
                false -> <<"generated">>
            end,
        <<"created_at_utc">> => iso8601_now(),
        <<"backend">> => bin(Backend),
        <<"backend_sha256">> => lower_hex_sha256_file(Backend),
        <<"backend_protocol">> => <<"one_shot_json_v1">>,
        <<"secret_provider">> => <<"local">>,
        <<"vault_path">> => bin(Vault),
        <<"vault_exists_before">> => VaultExistsBefore,
        <<"vault_mode_octal">> => bin(VaultMode),
        <<"pubkey_hex">> => Pubkey,
        <<"npub">> => Npub,
        <<"secret_exported">> => false,
        <<"scope">> => <<"PRODUCTION Damage node nsecbunker identity">>
    },
    write_phase4b_report(JsonReport, MdReport, Report).

write_phase4b_report(JsonReport, MdReport, Report) ->
    ok = assert_no_secret_material(Report),
    ok = write_json(JsonReport, Report),
    ok = write_file(MdReport, phase4b_markdown(Report)),
    ok = change_mode(JsonReport, 8#644),
    ok = change_mode(MdReport, 8#644),
    {ok, Report#{
        <<"json_report">> => bin(JsonReport),
        <<"markdown_report">> => bin(MdReport)
    }}.

production_phase4b_preflight(Opts, Config) ->
    case damage_nsecbunker_config:production(Config) of
        false ->
            {error, production_mode_required};
        true ->
            case damage_nsecbunker_config:secret_provider(Config) of
                local ->
                    {ok, local};
                aws_secrets_manager ->
                    managed_phase4b_preflight(Opts, Config);
                Other ->
                    {error, {unsupported_nsecbunker_secret_provider, Other}}
            end
    end.

managed_phase4b_preflight(Opts, Config) ->
    ForbiddenOptions = [
        Key
     || Key <- [
            passphrase,
            env,
            backend,
            prod_vault_path,
            production_vault_path
        ],
        maps:is_key(Key, Opts)
    ],
    case
        {
            damage_nsecbunker_config:secure_aws(Config),
            damage_nsecbunker_secret_owner:ready(),
            ForbiddenOptions
        }
    of
        {true, true, []} -> {ok, aws_secrets_manager};
        {false, _, _} -> {error, invalid_aws_secret_provider_configuration};
        {_, false, _} -> {error, secure_vault_owner_not_ready};
        {_, _, [_ | _]} -> {error, {production_custody_override_forbidden, ForbiddenOptions}}
    end.

phase4a_ceremony_available() ->
    executable_file(crypto_backend_path()).

phase4b_ceremony_available() ->
    Config = config(),
    case
        {
            damage_nsecbunker_config:production(Config),
            damage_nsecbunker_config:secret_provider(Config)
        }
    of
        {true, aws_secrets_manager} ->
            damage_nsecbunker_config:secure_aws(Config) andalso
                damage_nsecbunker_secret_owner:ready();
        {true, local} ->
            executable_file(crypto_backend_path());
        _ ->
            false
    end.

%%====================================================================
%% Backend operations
%%====================================================================

backend_call(Payload) ->
    backend_call(Payload, #{}).

backend_call(Payload, Opts0) ->
    case damage_nsecbunker_config:secret_provider(config()) of
        aws_secrets_manager ->
            error(managed_provider_direct_backend_call_forbidden);
        local ->
            Opts = opts(Opts0),
            Timeout = opt(
                crypto_timeout_ms,
                Opts,
                config_get(crypto_timeout_ms, 45000)
            ),
            Config = legacy_backend_config(Opts),
            unwrap_legacy_backend(
                damage_nsecbunker_legacy_backend:call(
                    Config,
                    Payload,
                    Timeout
                )
            );
        Other ->
            error({unsupported_nsecbunker_secret_provider, Other})
    end.

legacy_backend_config(Opts) ->
    Base = config(),
    Backend = crypto_backend_path(Opts),
    Env = opt(env, Opts, []),
    Config0 = maps:merge(
        Base,
        maps:with(
            [
                vault_passphrase,
                vault_path,
                crypto_timeout_ms
            ],
            Opts
        )
    ),
    Config1 = Config0#{
        crypto_backend_cmd => Backend,
        backend_env => strip_backend_secret_env(Env)
    },
    case explicit_passphrase(Opts, Env) of
        undefined ->
            Config1;
        Passphrase ->
            Config1#{
                resolved_vault_passphrase => Passphrase
            }
    end.

explicit_passphrase(Opts, Env) ->
    case opt(passphrase, Opts, undefined) of
        undefined ->
            env_value(
                "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
                Env
            );
        Passphrase ->
            Passphrase
    end.

env_value(_Name, []) ->
    undefined;
env_value(Name, [{Name0, Value} | Rest]) ->
    case env_name(Name0) =:= Name of
        true ->
            Value;
        false ->
            env_value(Name, Rest)
    end;
env_value(Name, [_Other | Rest]) ->
    env_value(Name, Rest).

strip_backend_secret_env(Env) ->
    [
        {Name, Value}
     || {Name, Value} <- Env,
        not lists:member(
            env_name(Name),
            [
                "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
                "DAMAGE_NSECBUNKER_VAULT_PATH"
            ]
        )
    ].

unwrap_legacy_backend({ok, Result}) when is_map(Result) ->
    Result;
unwrap_legacy_backend({ok, Result}) ->
    #{<<"value">> => Result};
unwrap_legacy_backend({error, {crypto_backend_rejected, Reason}}) ->
    error({crypto_backend_not_ok, Reason});
unwrap_legacy_backend({error, Reason}) ->
    error(Reason).

smoke_phase2b_crypto_c_backend() ->
    smoke_phase2b_crypto_c_backend(#{}).

smoke_phase2b_crypto_c_backend(Opts0) ->
    Opts = opts(Opts0),
    Vault = opt_env(
        Opts,
        vault_path,
        "DAMAGE_NSECBUNKER_TEST_VAULT",
        "/tmp/damage-nsecbunker-phase2b-c.vault"
    ),
    Passphrase = vault_passphrase(Opts, "phase2b-c-local-test-passphrase"),
    _ = file:delete(Vault),
    Env = backend_env(Opts, Passphrase) ++ [{"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"}],
    O = Opts#{env => Env},

    Health = backend_call(#{<<"op">> => <<"health">>}, O),

    Gen = backend_call(
        #{
            <<"op">> => <<"generate_identity">>,
            <<"vault_path">> => bin(Vault)
        },
        O
    ),

    Pub = backend_call(
        #{
            <<"op">> => <<"get_public_key">>,
            <<"vault_path">> => bin(Vault)
        },
        O
    ),

    Pubkey = require_pubkey(
        first_present([field(<<"pubkey_hex">>, Pub), field(<<"pubkey_hex">>, Gen)])
    ),

    Npub = backend_call(
        #{
            <<"op">> => <<"npub">>,
            <<"pubkey_hex">> => Pubkey
        },
        O
    ),

    Sign = backend_call(
        #{
            <<"op">> => <<"sign_event">>,
            <<"vault_path">> => bin(Vault),
            <<"event">> => #{
                <<"pubkey">> => Pubkey,
                <<"created_at">> => 1778000000,
                <<"kind">> => 1,
                <<"tags">> => [],
                <<"content">> => <<"phase2b c backend smoke">>
            }
        },
        O
    ),

    Event = field(<<"event">>, Sign),
    ok = require_signed_event(Event),

    ClientPubkey0 = opt_env(
        Opts,
        client_pubkey,
        "DAMAGE_NSECBUNKER_TEST_CLIENT_PUBKEY",
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    ),
    ClientPubkey = bin(ClientPubkey0),

    Plaintext0 = opt_env(
        Opts,
        plaintext,
        "DAMAGE_NSECBUNKER_TEST_PLAINTEXT",
        "{\"id\":\"phase2b\",\"result\":\"pong\"}"
    ),
    Plaintext = bin(Plaintext0),

    Enc = backend_call(
        #{
            <<"op">> => <<"nip44_encrypt">>,
            <<"vault_path">> => bin(Vault),
            <<"client_pubkey">> => ClientPubkey,
            <<"plaintext">> => Plaintext
        },
        O
    ),

    Ct = require_binary(field(<<"ciphertext">>, Enc), ciphertext),

    Dec = backend_call(
        #{
            <<"op">> => <<"nip44_decrypt">>,
            <<"vault_path">> => bin(Vault),
            <<"client_pubkey">> => ClientPubkey,
            <<"ciphertext">> => Ct
        },
        O
    ),

    PlainRoundtrip = field(<<"plaintext">>, Dec),
    case PlainRoundtrip =:= Plaintext of
        true ->
            ok;
        false ->
            error(
                {phase2b_plaintext_roundtrip_failed, #{
                    expected => Plaintext,
                    got => PlainRoundtrip,
                    decrypted => Dec
                }}
            )
    end,

    #{
        health => Health,
        generated => Gen,
        public => Pub,
        npub => Npub,
        signed_event => Event,
        encrypted => Enc,
        decrypted => Dec
    }.

smoke_phase2c_crypto_vectors() ->
    smoke_phase2c_crypto_vectors(#{}).

smoke_phase2c_crypto_vectors(Opts0) ->
    Opts = opts(Opts0),
    Vault = opt_env(
        Opts,
        vault_path,
        "DAMAGE_NSECBUNKER_TEST_VAULT",
        "/tmp/damage-nsecbunker-phase2c-smoke.vault"
    ),
    Passphrase = vault_passphrase(Opts, "phase2c-smoke-passphrase"),
    _ = file:delete(Vault),
    Base = Opts#{env => backend_env(Opts, Passphrase)},
    assert_fields(health, backend_call(#{<<"op">> => <<"health">>}, Base), #{
        <<"phase">> => <<"2c">>, <<"nip44">> => <<"v2">>
    }),
    assert_fields(
        bip340_sign,
        backend_call(
            #{
                <<"op">> => <<"schnorr_sign_vector">>,
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000003">>,
                <<"message_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000000">>,
                <<"aux_rand_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000000">>
            },
            Base
        ),
        #{
            <<"pubkey_hex">> =>
                <<"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9">>,
            <<"signature_hex">> =>
                <<"e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0">>
        }
    ),
    assert_fields(
        bip340_verify,
        backend_call(
            #{
                <<"op">> => <<"schnorr_verify">>,
                <<"pubkey_hex">> =>
                    <<"F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9">>,
                <<"message_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000000">>,
                <<"signature_hex">> =>
                    <<"E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0">>
            },
            Base
        ),
        #{<<"valid">> => true}
    ),
    assert_fields(
        npub_vector,
        backend_call(
            #{
                <<"op">> => <<"npub">>,
                <<"pubkey_hex">> =>
                    <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>
            },
            Base
        ),
        #{<<"npub">> => <<"npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d">>}
    ),
    assert_fields(
        event_id_vector,
        backend_call(
            #{
                <<"op">> => <<"event_id">>,
                <<"pubkey_hex">> =>
                    <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
                <<"event">> => #{
                    <<"created_at">> => 0,
                    <<"kind">> => 1,
                    <<"tags">> => [],
                    <<"content">> => <<"hello">>
                }
            },
            Base
        ),
        #{<<"id">> => <<"5a25a8422478717a983475e3ab77edeb1b72775dde3d2e2dffb054aa98c5cc45">>}
    ),
    assert_fields(
        nip44_encrypt_vector,
        backend_call(
            #{
                <<"op">> => <<"nip44_encrypt_vector">>,
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000001">>,
                <<"peer_pubkey_hex">> =>
                    <<"c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5">>,
                <<"nonce_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000001">>,
                <<"plaintext">> => <<"a">>
            },
            Base
        ),
        #{
            <<"conversation_key">> =>
                <<"c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d">>,
            <<"payload">> =>
                <<"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb">>
        }
    ),
    assert_fields(
        nip44_decrypt_vector,
        backend_call(
            #{
                <<"op">> => <<"nip44_decrypt_vector">>,
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000002">>,
                <<"peer_pubkey_hex">> =>
                    <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
                <<"payload">> =>
                    <<"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb">>
            },
            Base
        ),
        #{
            <<"conversation_key">> =>
                <<"c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d">>,
            <<"plaintext">> => <<"a">>
        }
    ),
    Gen = backend_call(
        #{<<"op">> => <<"generate_identity">>, <<"vault_path">> => bin(Vault)}, Base
    ),
    Pubkey = require_pubkey(field(<<"pubkey_hex">>, Gen)),
    Client = <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
    Enc = backend_call(
        #{
            <<"op">> => <<"nip44_encrypt">>,
            <<"vault_path">> => bin(Vault),
            <<"client_pubkey">> => Client,
            <<"plaintext">> => <<"phase2c real nip44">>
        },
        Base
    ),
    Ct = require_binary(field(<<"ciphertext">>, Enc), ciphertext),
    assert_fields(
        real_nip44_roundtrip,
        backend_call(
            #{
                <<"op">> => <<"nip44_decrypt">>,
                <<"vault_path">> => bin(Vault),
                <<"client_pubkey">> => Client,
                <<"ciphertext">> => Ct
            },
            Base
        ),
        #{<<"plaintext">> => <<"phase2c real nip44">>, <<"nip44">> => <<"v2">>}
    ),
    ok = assert_backend_fails(
        wrong_passphrase,
        #{<<"op">> => <<"get_public_key">>, <<"vault_path">> => bin(Vault)},
        Opts#{env => backend_env(Opts, "wrong-passphrase")},
        <<"vault_decrypt_failed">>
    ),
    assert_fields(
        production_blocks_plain,
        backend_call(#{<<"op">> => <<"plain_mode_status">>}, Opts#{
            env => [
                {"DAMAGE_NSECBUNKER_TEST_MODE", "1"},
                {"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"},
                {"DAMAGE_NSECBUNKER_PRODUCTION", "1"}
            ]
        }),
        #{<<"plain_allowed">> => false, <<"production">> => true}
    ),
    #{status => pass, vault => bin(Vault), pubkey_hex => Pubkey}.

assert_backend_fails(Label, Payload, Opts, ExpectedError) ->
    try backend_call(Payload, Opts) of
        Result ->
            error({Label, expected_failure, Result})
    catch
        error:{crypto_backend_not_ok, ExpectedError} ->
            ok;
        error:{crypto_backend_not_ok, Other} ->
            error({Label, unexpected_backend_error, Other, ExpectedError});
        error:{crypto_backend_exit, _Status, Bin} ->
            assert_backend_error_bin(Label, Bin, ExpectedError);
        error:{crypto_backend_open_failed, error, {crypto_backend_exit, _Status, Bin}} ->
            assert_backend_error_bin(Label, Bin, ExpectedError);
        error:Other ->
            error({Label, unexpected_failure_shape, Other, ExpectedError})
    end.

assert_backend_error_bin(Label, Bin, ExpectedError) ->
    case backend_error_from_bin(Bin) of
        ExpectedError ->
            ok;
        Other ->
            error({Label, unexpected_backend_error, Other, ExpectedError, Bin})
    end.

backend_error_from_bin(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        #{<<"ok">> := false, <<"error">> := Error} -> Error;
        Other -> {bad_backend_error_envelope, Other}
    catch
        Class:Reason -> {invalid_backend_error_json, Class, Reason, Bin}
    end.

assert_fields(Label, Map, Expected) ->
    maps:fold(
        fun(K, V, ok) ->
            Got = field(K, Map),
            case Got =:= V of
                true -> ok;
                false -> error({Label, field_mismatch, K, expected, V, got, Got, full, Map})
            end
        end,
        ok,
        Expected
    ).

%%====================================================================
%% Interactive operator / REPL helpers
%%====================================================================

help() ->
    [
        {status, "show consolidated nsecbunker and AWS state"},
        {services, "show OTP process and AWS application state"},
        {aws_probe, "perform one IMDSv2 role probe without starting aws_credentials"},
        {quiesce_aws, "stop stray aws_credentials when AWS custody is not selected"},
        {disable, "runtime-only disable nsecbunker and restart its subtree"},
        {use_local, "runtime-only select local custody and restart its subtree"},
        {use_aws, "use_aws(Region, SecretId, AccountId, RoleName); requires pinned bunker pubkey"},
        {restart, "restart the nsecbunker subtree under damage_sup"}
    ].

status() ->
    Config = config(),
    #{
        enabled =>
            damage_nsecbunker_config:enabled(Config),

        provider =>
            damage_nsecbunker_config:secret_provider(
                Config
            ),

        config_validation =>
            damage_nsecbunker_config:validate_production(
                Config
            ),

        services =>
            services(),

        aws =>
            damage_aws_runtime:status(),

        bunker =>
            safe_bunker_status(),

        owner =>
            safe_owner_status()
    }.

services() ->
    #{
        damage_sup =>
            process_status(damage_sup),

        nsecbunker_sup =>
            process_status(damage_nsecbunker_sup),

        nsecbunker =>
            process_status(damage_nsecbunker),

        secret_owner =>
            process_status(
                damage_nsecbunker_secret_owner
            ),

        aws =>
            application_status(aws),

        aws_credentials =>
            application_status(aws_credentials)
    }.

%% One-shot probe only. This must not start aws_credentials.
aws_probe() ->
    damage_aws_runtime:probe().

%% Field-recovery helper. damage_aws_runtime refuses this while AWS custody
%% is selected, so this cannot silently downgrade a managed node.
quiesce_aws() ->
    damage_aws_runtime:quiesce().

%% Runtime-only configuration commands. These deliberately do not rewrite
%% sys.config. Persist an approved configuration through normal deployment.

disable() ->
    Config0 = config(),
    Config = Config0#{
        enabled => false
    },

    apply_runtime_config(
        Config0,
        Config,
        #{enabled => false},
        true
    ).

use_local() ->
    Config0 = config(),
    Config = Config0#{
        enabled => true,
        secret_provider => local
    },

    case
        damage_nsecbunker_config:validate_production(
            Config
        )
    of
        ok ->
            apply_runtime_config(
                Config0,
                Config,
                #{provider => local},
                true
            );
        {error, _} = Error ->
            Error
    end.

use_aws(
    Region,
    SecretId,
    AccountId,
    RoleName
) ->
    Config0 = config(),
    case configured_bunker_pubkey(Config0) of
        {ok, BunkerPubkey} ->
            Config = Config0#{
                enabled => true,
                mode => production,
                secret_provider => aws_secrets_manager,
                vault_mode => open_existing,
                bunker_pubkey_hex => BunkerPubkey,
                aws_secret => #{
                    region => Region,
                    secret_id => SecretId,
                    expected_account_id => AccountId,
                    expected_role_name => RoleName
                }
            },
            case damage_nsecbunker_config:validate_production(Config) of
                ok ->
                    apply_runtime_config(
                        Config0,
                        Config,
                        #{
                            provider => aws_secrets_manager,
                            vault_mode => open_existing,
                            bunker_pubkey_hex => BunkerPubkey
                        },
                        false
                    );
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, bunker_pubkey_required_for_aws_runtime_switch}
    end.

apply_runtime_config(Config0, Config, Result0, QuiesceAws) ->
    ok = application:set_env(
        damage,
        nsecbunker,
        Config
    ),
    case restart() of
        {ok, _} = RestartResult ->
            finish_runtime_config_change(
                Result0,
                RestartResult,
                QuiesceAws
            );
        {error, _} = RestartError ->
            %% Restore the previous runtime configuration and make a
            %% best-effort attempt to restore the previous subtree.
            ok = application:set_env(
                damage,
                nsecbunker,
                Config0
            ),
            RollbackRestart = restart(),
            {error,
                {
                    nsecbunker_runtime_config_restart_failed,
                    #{
                        reason => RestartError,
                        rollback_restart => RollbackRestart
                    }
                }}
    end.

finish_runtime_config_change(Result0, RestartResult, false) ->
    {ok, Result0#{
        runtime_only => true,
        restart => RestartResult
    }};
finish_runtime_config_change(Result0, RestartResult, true) ->
    case damage_aws_runtime:quiesce() of
        ok ->
            {ok, Result0#{
                runtime_only => true,
                restart => RestartResult
            }};
        {error, _} = Error ->
            %% The requested provider change is live, but credential cleanup
            %% did not complete. Do not hide this from the operator.
            {error,
                {
                    aws_runtime_quiesce_failed,
                    #{
                        reason => Error,
                        runtime_config_applied => true,
                        restart => RestartResult
                    }
                }}
    end.

configured_bunker_pubkey(Config) ->
    case maps:get(bunker_pubkey_hex, Config, undefined) of
        Value when is_binary(Value) ->
            validate_bunker_pubkey(Value);
        Value when is_list(Value) ->
            validate_bunker_pubkey(
                unicode:characters_to_binary(Value)
            );
        _ ->
            error
    end.

validate_bunker_pubkey(<<Value:64/binary>>) ->
    case lists:all(fun is_hex_char/1, binary_to_list(Value)) of
        true -> {ok, Value};
        false -> error
    end;
validate_bunker_pubkey(_) ->
    error.

is_hex_char(C) when C >= $0, C =< $9 -> true;
is_hex_char(C) when C >= $a, C =< $f -> true;
is_hex_char(C) when C >= $A, C =< $F -> true;
is_hex_char(_) -> false.

%% Restart only the nsecbunker subtree so operator changes do not require
%% restarting the entire Damage node.
restart() ->
    case whereis(damage_sup) of
        undefined ->
            {error, damage_sup_not_running};
        _Pid ->
            restart_nsecbunker_child()
    end.

restart_nsecbunker_child() ->
    case
        supervisor:terminate_child(
            damage_sup,
            damage_nsecbunker_sup
        )
    of
        ok ->
            normalize_restart_result(
                supervisor:restart_child(
                    damage_sup,
                    damage_nsecbunker_sup
                )
            );
        {error, not_found} ->
            {error, nsecbunker_supervisor_not_child_of_damage_sup};
        {error, Reason} ->
            {error, {
                nsecbunker_terminate_failed,
                Reason
            }}
    end.

normalize_restart_result({ok, Pid}) when
    is_pid(Pid)
->
    {ok, Pid};
normalize_restart_result({ok, Pid, Info}) when
    is_pid(Pid)
->
    {ok, #{pid => Pid, info => Info}};
normalize_restart_result({error, Reason}) ->
    {error, {
        nsecbunker_restart_failed,
        Reason
    }}.

safe_bunker_status() ->
    case whereis(damage_nsecbunker) of
        undefined ->
            #{
                running => false
            };
        _Pid ->
            try damage_nsecbunker:status() of
                Value ->
                    Value
            catch
                _:_ ->
                    #{
                        running => true,
                        status => unavailable
                    }
            end
    end.

safe_owner_status() ->
    case
        whereis(
            damage_nsecbunker_secret_owner
        )
    of
        undefined ->
            #{
                running => false,
                ready => false
            };
        _Pid ->
            damage_nsecbunker_secret_owner:status()
    end.

process_status(Name) ->
    case whereis(Name) of
        undefined ->
            #{
                running => false
            };
        Pid ->
            #{
                running => true,
                pid => Pid
            }
    end.

application_status(App) ->
    case
        lists:keyfind(
            App,
            1,
            application:which_applications()
        )
    of
        false ->
            #{
                running => false
            };
        {App, Description, Version} ->
            #{
                running => true,
                description => Description,
                version => Version
            }
    end.
%%====================================================================
%% Release / hashing helpers
%%====================================================================

install_crypto_backend() ->
    install_crypto_backend(filename:join(root(), ?LOCAL_BACKEND), ?DEFAULT_BACKEND).

install_crypto_backend(Source0, Dest0) ->
    Source = str(Source0),
    Dest = str(Dest0),
    case executable_file(Source) of
        true -> ok;
        false -> error({source_backend_not_executable, Source})
    end,
    ok = ensure_parent(Dest),
    case file:copy(Source, Dest) of
        {ok, _Bytes} -> ok;
        {error, Reason} -> error({backend_install_copy_failed, Source, Dest, Reason})
    end,
    ok = change_mode(Dest, 8#755),
    {ok, Dest}.

check_release_artifacts() ->
    check_release_artifacts(root()).

check_release_artifacts(ReleaseRoot0) ->
    ReleaseRoot = str(ReleaseRoot0),
    RequiredFiles = ["bin/damage-nsecbunker-crypto-c"],
    RequiredDirs = ["doc/nsecbunker"],
    MissingFiles = [P || P <- RequiredFiles, not filelib:is_regular(filename:join(ReleaseRoot, P))],
    MissingDirs = [P || P <- RequiredDirs, not filelib:is_dir(filename:join(ReleaseRoot, P))],
    ExecutableOk = executable_file(filename:join(ReleaseRoot, "bin/damage-nsecbunker-crypto-c")),
    case {MissingFiles, MissingDirs, ExecutableOk} of
        {[], [], true} ->
            {ok, #{release_root => bin(ReleaseRoot), checked => RequiredFiles ++ RequiredDirs}};
        _ ->
            {error, #{
                missing_files => MissingFiles,
                missing_dirs => MissingDirs,
                backend_executable => ExecutableOk
            }}
    end.

hash_phase4a_artifacts() ->
    hash_artifacts("MANIFEST.phase4a.steps.sha256", [
        "apps/damage/src/damage_nsecbunker_ops.erl",
        "apps/damage/src/steps_nsecbunker_phase4a.erl",
        "features/nsecbunker/phase4a_dev_key_rehearsal.feature"
    ]).

hash_phase4b_artifacts() ->
    hash_artifacts("MANIFEST.phase4b.prod_key.sha256", [
        "apps/damage/src/damage_nsecbunker_ops.erl",
        "apps/damage/src/steps_nsecbunker_phase4b.erl",
        "features/nsecbunker/phase4b_damagebdd_node_production_key.feature",
        "config/sys.config.nsecbunker.fragment.config",
        "doc/nsecbunker/PHASE4B_DAMAGEBDD_PRODUCTION_KEY_CEREMONY.md"
    ]).

hash_artifacts(Manifest0, Files0) ->
    Root = root(),
    Manifest = abs_path(Manifest0, Root),
    Files = [abs_path(F, Root) || F <- Files0],
    Lines = [hash_line(F, Root) || F <- Files],
    ok = write_file(Manifest, iolist_to_binary(Lines)),
    {ok, #{manifest => bin(Manifest), count => length(Lines), lines => [bin(L) || L <- Lines]}}.

hash_line(File, Root) ->
    Hash = lower_hex_sha256_file(File),
    Rel = rel_path(File, Root),
    [Hash, <<"  ">>, bin(Rel), <<"\n">>].

lower_hex_sha256_file(Path0) ->
    Path = str(Path0),
    case file:read_file(Path) of
        {ok, Bin} -> lower_hex(crypto:hash(sha256, Bin));
        {error, Reason} -> error({sha256_file_failed, Path, Reason})
    end.

%%====================================================================
%% Config/path helpers
%%====================================================================

crypto_backend_path() ->
    crypto_backend_path(#{}).

crypto_backend_path(Opts0) ->
    Opts = opts(Opts0),
    Root = root(Opts),
    case opt(backend, Opts, undefined) of
        undefined ->
            case os:getenv("DAMAGE_NSECBUNKER_CRYPTO_CMD") of
                false ->
                    case config_first([crypto_backend_cmd, crypto_port_cmd], undefined) of
                        undefined ->
                            case executable_file(?DEFAULT_BACKEND) of
                                true -> ?DEFAULT_BACKEND;
                                false -> filename:join(Root, ?LOCAL_BACKEND)
                            end;
                        Cmd ->
                            str(Cmd)
                    end;
                Cmd ->
                    Cmd
            end;
        Backend ->
            str(Backend)
    end.

root() -> root(#{}).

root(Opts0) ->
    Opts = opts(Opts0),
    case opt(root, Opts, undefined) of
        undefined ->
            case os:getenv("DAMAGE_ROOT") of
                false ->
                    case file:get_cwd() of
                        {ok, Cwd} -> Cwd;
                        _ -> "."
                    end;
                Root ->
                    Root
            end;
        Root ->
            str(Root)
    end.

report_dir(Opts0) ->
    Opts = opts(Opts0),
    Root = root(Opts),
    opt_env_config(
        Opts,
        report_dir,
        "DAMAGE_NSECBUNKER_REPORT_DIR",
        [report_dir],
        filename:join([Root, "doc", "nsecbunker", "reports"])
    ).

config() ->
    try damage_nsecbunker:config() of
        C when is_map(C) -> C;
        _ -> damage_nsecbunker_config:load()
    catch
        _:_ -> damage_nsecbunker_config:load()
    end.

config_get(Key, Default) ->
    maps:get(Key, config(), Default).

config_first(Keys, Default) ->
    first_present([config_get(K, undefined) || K <- Keys], Default).

opt_env_config(Opts, OptKey, EnvName, ConfigKeys, Default) ->
    case opt(OptKey, Opts, undefined) of
        undefined ->
            case os:getenv(EnvName) of
                false -> str(config_first(ConfigKeys, Default));
                Val -> Val
            end;
        Val ->
            str(Val)
    end.

opt_env(Opts, OptKey, EnvName, Default) ->
    case opt(OptKey, Opts, undefined) of
        undefined ->
            case os:getenv(EnvName) of
                false -> Default;
                Val -> Val
            end;
        Val ->
            Val
    end.

vault_passphrase(Opts, Default) ->
    case damage_nsecbunker_config:secret_provider(config()) of
        aws_secrets_manager ->
            error(managed_provider_local_passphrase_forbidden);
        local ->
            case opt(passphrase, Opts, undefined) of
                undefined ->
                    case
                        damage_nsecbunker_local_secret_provider:fetch(#{
                            vault_passphrase =>
                                vault_passphrase_secret_name(Opts)
                        })
                    of
                        {ok, Passphrase} -> Passphrase;
                        {error, _Reason} -> Default
                    end;
                Passphrase ->
                    Passphrase
            end;
        Other ->
            error({unsupported_nsecbunker_secret_provider, Other})
    end.

vault_passphrase_secret_name(Opts) ->
    %% Strict API boundary: the secret name is the atom stored in config/opts.
    %% No env fallback and no name candidate conversion. If the configured atom
    %% does not exactly match the encrypted secret name, retrieval fails.
    first_present(
        [
            opt(vault_passphrase, Opts, undefined),
            config_get(vault_passphrase, undefined)
        ],
        nsecbunker_vault_passphrase
    ).

opts(Map) when is_map(Map) -> Map;
opts(List) when is_list(List) -> maps:from_list(List);
opts(undefined) -> #{}.

opt(Key, Opts, Default) ->
    maps:get(Key, Opts, Default).

backend_env(Opts, Passphrase) ->
    Extra = opt(env, Opts, []),
    Base =
        case Passphrase of
            undefined -> [];
            false -> [];
            <<>> -> [];
            [] -> [];
            _ -> [{"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", str(Passphrase)}]
        end,
    %% Extra env is allowed for non-secret flags/path, but the resolved
    %% passphrase is authoritative and is written last into the env map.
    dedupe_env(Extra ++ passthrough_env() ++ Base).

passthrough_env() ->
    passthrough_env([
        "DAMAGE_NSECBUNKER_PRODUCTION",
        "DAMAGE_NSECBUNKER_TEST_MODE",
        "DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44"
    ]).

passthrough_env(Names) ->
    lists:foldl(
        fun(Name, Acc) ->
            case os:getenv(Name) of
                false -> Acc;
                Value -> [{Name, Value} | Acc]
            end
        end,
        [],
        Names
    ).

dedupe_env(Env) ->
    lists:reverse(
        maps:fold(
            fun(Name, Value, Acc) -> [{env_name(Name), Value} | Acc] end,
            [],
            maps:from_list([{env_name(Name), Value} || {Name, Value} <- Env])
        )
    ).

env_name(Name) when is_binary(Name) -> binary_to_list(Name);
env_name(Name) when is_atom(Name) -> atom_to_list(Name);
env_name(Name) when is_list(Name) -> Name.

require_phase4b_approval(Opts) ->
    Approved = opt(approved, Opts, false),
    Env = os:getenv("DAMAGE_NSECBUNKER_PRODUCTION_CEREMONY_APPROVED"),
    case Approved =:= true orelse Env =:= ?APPROVAL of
        true -> ok;
        false -> {error, production_key_ceremony_approval_missing}
    end.

%%====================================================================
%% Report helpers
%%====================================================================

phase4a_markdown(Report) ->
    Pubkey = field(<<"pubkey_hex">>, Report),
    Npub = field(<<"npub">>, Report),
    Created = field(<<"created_at_utc">>, Report),
    Backend = field(<<"backend">>, Report),
    Vault = field(<<"vault_path">>, Report),
    iolist_to_binary([
        "# Phase 4A dev nsecbunker key rehearsal\n\n",
        "Status: generated\n\n",
        "Created UTC: ",
        Created,
        "\n\n",
        "Backend: `",
        Backend,
        "`\n",
        "Vault path: `",
        Vault,
        "`\n\n",
        "Public identity:\n\n```text\n",
        "pubkey_hex: ",
        Pubkey,
        "\n",
        "npub: ",
        Npub,
        "\n",
        "```\n\n",
        "Scope:\n\n```text\nDEV / DISPOSABLE ONLY\nNot a production identity.\nDo not reuse for production ceremonies.\n```\n\n",
        "Secret handling:\n\n```text\nnsec exported: no\nprivate key printed: no\nsecret-shaped fields in report: no\n```\n"
    ]).

phase4b_markdown(Report) ->
    Pubkey = field(<<"pubkey_hex">>, Report),
    Npub = field(<<"npub">>, Report),
    Status = field(<<"status">>, Report),
    Created = field(<<"created_at_utc">>, Report),
    Backend = field(<<"backend">>, Report),
    BackendSha = field(<<"backend_sha256">>, Report),
    Vault = field(<<"vault_path">>, Report),
    VaultMode = field(<<"vault_mode_octal">>, Report),
    iolist_to_binary([
        "# Phase 4B production Damage node key ceremony\n\n",
        "Status: ",
        Status,
        "\n\n",
        "Created UTC: ",
        Created,
        "\n\n",
        "Backend: `",
        Backend,
        "`\n",
        "Backend sha256: `",
        BackendSha,
        "`\n",
        "Vault path: `",
        Vault,
        "`\n",
        "Vault mode: `",
        VaultMode,
        "`\n\n",
        "Public identity:\n\n```text\n",
        "pubkey_hex: ",
        Pubkey,
        "\n",
        "npub: ",
        Npub,
        "\n",
        "```\n\n",
        "Scope:\n\n```text\nPRODUCTION Damage node nsecbunker identity.\n```\n\n",
        "Secret handling:\n\n```text\nnsec exported: no\nprivate key printed: no\nsecret-shaped fields in report: no\nproduction vault overwritten: no\n```\n"
    ]).

write_json(Path, Map) ->
    Json = iolist_to_binary(jsx:encode(Map)),
    write_file(Path, <<Json/binary, "\n">>).

write_file(Path0, Data) ->
    Path = str(Path0),
    ok = ensure_parent(Path),
    expect_file_ok(write_file, Path, file:write_file(Path, Data)).

ensure_parent(Path0) ->
    Path = str(Path0),
    Parent = filename:dirname(Path),
    expect_file_ok(ensure_parent, Parent, filelib:ensure_dir(filename:join(Parent, ".keep"))).

ensure_dir(Dir0) ->
    Dir = str(Dir0),
    expect_file_ok(ensure_dir, Dir, filelib:ensure_dir(filename:join(Dir, ".keep"))).

delete_if_exists(Path0) ->
    Path = str(Path0),
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> file_access_error(delete_file, Path, Reason)
    end.

change_mode(Path0, Mode) ->
    Path = str(Path0),
    expect_file_ok(change_mode, Path, file:change_mode(Path, Mode)).

expect_file_ok(_Operation, _Path, ok) ->
    ok;
expect_file_ok(Operation, Path, {error, Reason}) ->
    file_access_error(Operation, Path, Reason).

with_file_access_errors(Fun) ->
    try Fun() of
        Result -> Result
    catch
        error:{nsecbunker_file_access_error, ErrorMap} ->
            {error, ErrorMap};
        error:{badmatch, {error, Reason}} ->
            {error, #{
                reason => file_access_failed,
                operation => unknown_file_operation,
                os_reason => Reason,
                hint => file_access_hint(unknown_file_operation, undefined, Reason)
            }}
    end.

file_access_error(Operation, Path, Reason) ->
    error(
        {nsecbunker_file_access_error, #{
            reason => file_access_failed,
            operation => Operation,
            path => bin(Path),
            os_reason => Reason,
            hint => file_access_hint(Operation, Path, Reason)
        }}
    ).

file_access_hint(_Operation, Path, enoent) ->
    iolist_to_binary([
        <<"Missing directory or file for path: ">>,
        bin(first_present([Path], "<unknown>")),
        <<". Create the parent directory and ensure the Damage runtime user can access it.">>
    ]);
file_access_hint(_Operation, Path, eacces) ->
    iolist_to_binary([
        <<"Permission denied for path: ">>,
        bin(first_present([Path], "<unknown>")),
        <<". Fix ownership/mode for the Damage runtime user, for example /var/lib/damage/nsecbunker should be private and report_dir writable.">>
    ]);
file_access_hint(_Operation, Path, Reason) ->
    iolist_to_binary([
        <<"File operation failed for path: ">>,
        bin(first_present([Path], "<unknown>")),
        <<" with reason ">>,
        bin(Reason),
        <<".">>
    ]).

file_mode_private(Path) ->
    case filelib:is_regular(Path) of
        true -> ok;
        false -> error({vault_missing, Path})
    end,
    ok = change_mode(Path, 8#600),
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} ->
            case (Mode band 8#077) =:= 0 of
                true -> ok;
                false -> error({vault_permissions_too_open, Path, file_mode_octal(Mode)})
            end;
        {error, Reason} ->
            error({vault_stat_failed, Path, Reason})
    end.

file_mode_octal(Path) when is_list(Path); is_binary(Path) ->
    case file:read_file_info(str(Path)) of
        {ok, #file_info{mode = Mode}} -> file_mode_octal(Mode);
        {error, Reason} -> error({file_mode_failed, Path, Reason})
    end;
file_mode_octal(Mode) when is_integer(Mode) ->
    lists:flatten(io_lib:format("0~.8B", [Mode band 8#777])).

%%====================================================================
%% Validation / utility
%%====================================================================

npub_for(Pubkey, Opts) ->
    case backend_call(#{<<"op">> => <<"npub">>, <<"pubkey_hex">> => Pubkey}, Opts) of
        Map -> field(<<"npub">>, Map)
    end.

require_pubkey(Value) ->
    Bin = require_binary(Value, pubkey_hex),
    case re:run(Bin, <<"^[0-9a-f]{64}$">>, [{capture, none}]) of
        match -> Bin;
        nomatch -> error({invalid_pubkey_hex, Bin})
    end.

require_npub(Value) ->
    Bin = require_binary(Value, npub),
    case Bin of
        <<"npub1", _/binary>> -> Bin;
        _ -> error({invalid_npub, Bin})
    end.

require_binary(undefined, Name) -> error({missing_required_field, Name});
require_binary(B, _Name) when is_binary(B) -> B;
require_binary(L, _Name) when is_list(L) -> unicode:characters_to_binary(L);
require_binary(Other, Name) -> error({invalid_binary_field, Name, Other}).

require_signed_event(Event) when is_map(Event) ->
    Id = require_binary(field(<<"id">>, Event), event_id),
    Sig = require_binary(field(<<"sig">>, Event), event_sig),
    case
        {
            re:run(Id, <<"^[0-9a-f]{64}$">>, [{capture, none}]),
            re:run(Sig, <<"^[0-9a-f]{128}$">>, [{capture, none}])
        }
    of
        {match, match} -> ok;
        _ -> error({invalid_signed_event_shape, Event})
    end;
require_signed_event(Other) ->
    error({invalid_signed_event, Other}).

field(Key, Map) when is_map(Map), is_binary(Key) ->
    case maps:get(Key, Map, undefined) of
        undefined ->
            try
                maps:get(binary_to_existing_atom(Key, utf8), Map, undefined)
            catch
                _:_ -> undefined
            end;
        Value ->
            Value
    end;
field(Key, Map) when is_map(Map), is_atom(Key) ->
    case maps:get(Key, Map, undefined) of
        undefined -> maps:get(atom_to_binary(Key, utf8), Map, undefined);
        Value -> Value
    end.

first_present(List) -> first_present(List, undefined).
first_present([], Default) -> Default;
first_present([undefined | Rest], Default) -> first_present(Rest, Default);
first_present([false | Rest], Default) -> first_present(Rest, Default);
first_present([<<>> | Rest], Default) -> first_present(Rest, Default);
first_present([[] | Rest], Default) -> first_present(Rest, Default);
first_present([Value | _], _Default) -> Value.

contains_secret_material(Term) ->
    secret_leak(Term) =/= false orelse secret_value(term_to_binary_safe(Term)).

assert_no_secret_material(Term) ->
    case secret_leak(Term) of
        false ->
            case secret_value(term_to_binary_safe(Term)) of
                false -> ok;
                true -> error({secret_value_leaked, <<"[REDACTED]">>})
            end;
        Leak ->
            error({secret_key_leaked, Leak})
    end.

secret_leak(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            case Acc of
                false ->
                    case secret_key(K) of
                        true -> {secret_key, K};
                        false -> secret_leak(V)
                    end;
                _ ->
                    Acc
            end
        end,
        false,
        Map
    );
secret_leak(List) when is_list(List) ->
    lists:foldl(
        fun(V, Acc) ->
            case Acc of
                false -> secret_leak(V);
                _ -> Acc
            end
        end,
        false,
        List
    );
secret_leak(_) ->
    false.

secret_key(K) ->
    Lower = lower(bin(K)),
    lists:member(Lower, [
        <<"nsec">>,
        <<"private_key">>,
        <<"private_key_hex">>,
        <<"privkey">>,
        <<"privkey_hex">>,
        <<"secret_key">>,
        <<"secret_key_hex">>,
        <<"mnemonic">>,
        <<"seed">>,
        <<"seed_hex">>,
        <<"sk">>,
        <<"passphrase">>,
        <<"vault_passphrase">>,
        <<"secret_value">>,
        <<"aws_access_key_id">>,
        <<"aws_secret_access_key">>,
        <<"aws_session_token">>
    ]).

secret_value(Bin0) ->
    Bin = bin(Bin0),
    case re:run(Bin, <<"nsec1[02-9ac-hj-np-z]+">>, [caseless, {capture, none}]) of
        match ->
            true;
        nomatch ->
            case re:run(Bin, <<"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----">>, [{capture, none}]) of
                match -> true;
                nomatch -> false
            end
    end.

term_to_binary_safe(B) when is_binary(B) -> B;
term_to_binary_safe(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).

executable_file(Path0) ->
    Path = str(Path0),
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            (Mode band 8#111) =/= 0;
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} -> executable_file(filename:absname(Target, filename:dirname(Path)));
                {error, _} -> false
            end;
        _ ->
            false
    end.

truthy(true) -> true;
truthy(1) -> true;
truthy(<<"1">>) -> true;
truthy(<<"true">>) -> true;
truthy(<<"yes">>) -> true;
truthy("1") -> true;
truthy("true") -> true;
truthy("yes") -> true;
truthy(_) -> false.

abs_path(Path0, Root) ->
    Path = str(Path0),
    case filename:pathtype(Path) of
        absolute -> filename:absname(Path);
        _ -> filename:absname(filename:join(Root, Path))
    end.

rel_path(Path0, Root0) ->
    Path = filename:absname(str(Path0)),
    Root = filename:absname(str(Root0)),
    Prefix = Root ++ "/",
    case lists:prefix(Prefix, Path) of
        true -> lists:nthtail(length(Prefix), Path);
        false -> Path
    end.

iso8601_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])
    ).

lower_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [X]) || <<X>> <= Bin]).

lower(Bin) when is_binary(Bin) ->
    <<<<(lower_char(C))>> || <<C>> <= Bin>>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

str(B) when is_binary(B) -> binary_to_list(B);
str(A) when is_atom(A) -> atom_to_list(A);
str(L) when is_list(L) -> L;
str(I) when is_integer(I) -> integer_to_list(I);
str(Other) -> lists:flatten(io_lib:format("~p", [Other])).

bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
