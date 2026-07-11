%%--------------------------------------------------------------------
%% damage_nsecbunker_ops
%%
%% Operational nsecbunker helpers implemented in Erlang so Phase 4
%% deployment/key-ceremony work can run from the Damage release without
%% shell/python ceremony scripts.
%%
%% This module still calls the process-isolated C crypto backend via
%% open_port({spawn_executable, Cmd}, ...). That is intentional: the C
%% backend remains the custody/crypto boundary. The module does not invoke
%% /bin/sh and does not require Python/curl/sha256sum for ceremony, artifact
%% hashing or release checks. DamageBDD feature submission is intentionally
%% kept outside the production release environment.
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
    Passphrase = opt_env(
        Opts, passphrase, "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase4a-bdd-dev-passphrase"
    ),
    Reset = truthy(opt_env(Opts, reset, "RESET_DEV_VAULT", "1")),
    ok = ensure_parent(Vault),
    ok = ensure_dir(ReportDir),
    case Reset of
        true ->
            _ = file:delete(Vault),
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
    _ = file:change_mode(Vault, 8#600),
    Created = iso8601_now(),
    Report = #{}#{
        <<"phase">> => <<"4A">>
    }#{
        <<"purpose">> => <<"dev_damagebdd_key_rehearsal">>
    }#{
        <<"status">> => <<"generated">>
    }#{
        <<"created_at_utc">> => Created
    }#{
        <<"backend">> => bin(Backend)
    }#{
        <<"vault_path">> => bin(Vault)
    }#{
        <<"pubkey_hex">> => Pubkey
    }#{
        <<"npub">> => Npub
    }#{
        <<"secret_exported">> => false
    }#{
        <<"scope">> => <<"DEV/DISPOSABLE ONLY - not LodgeiT production custody">>
    },
    ok = assert_no_secret_material(Report),
    ok = write_json(JsonReport, Report),
    ok = write_file(MdReport, phase4a_markdown(Report)),
    {ok, Report#{<<"json_report">> => bin(JsonReport), <<"markdown_report">> => bin(MdReport)}}.

phase4b_create_production_damagebdd_node_key() ->
    phase4b_create_production_damagebdd_node_key(#{}).

phase4b_create_production_damagebdd_node_key(Opts0) ->
    Opts = opts(Opts0),
    case require_phase4b_approval(Opts) of
        ok -> phase4b_create_production_damagebdd_node_key_0(Opts);
        {error, _} = Error -> Error
    end.

phase4b_create_production_damagebdd_node_key_0(Opts) ->
    Root = root(Opts),
    Backend = crypto_backend_path(Opts),
    Vault = opt_env_config(
        Opts,
        prod_vault_path,
        "DAMAGE_NSECBUNKER_PROD_VAULT",
        [phase4b_prod_vault_path, production_vault_path, prod_vault_path],
        "/var/lib/damage/nsecbunker/damagebdd_node_production.vault"
    ),
    ReportDir = report_dir(Opts#{root => Root}),
    JsonReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json"),
    MdReport = filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md"),
    Passphrase = opt_env(Opts, passphrase, "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", undefined),
    case Passphrase of
        undefined ->
            {error, production_vault_passphrase_required};
        [] ->
            {error, production_vault_passphrase_required};
        <<>> ->
            {error, production_vault_passphrase_required};
        _ ->
            phase4b_create_production_damagebdd_node_key_1(
                Opts, Backend, Vault, ReportDir, JsonReport, MdReport, Passphrase
            )
    end.

phase4b_create_production_damagebdd_node_key_1(
    Opts, Backend, Vault, _ReportDir, JsonReport, MdReport, Passphrase
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
                    #{<<"op">> => <<"generate_identity">>, <<"vault_path">> => bin(Vault)}, Opts#{
                        backend => Backend, env => Env
                    }
                )
        end,
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
    ok = file_mode_private(Vault),
    VaultMode = file_mode_octal(Vault),
    BackendSha = lower_hex_sha256_file(Backend),
    Created = iso8601_now(),
    Status =
        case VaultExistsBefore of
            true -> <<"existing_vault_public_identity_exported">>;
            false -> <<"generated">>
        end,
    Report = #{}#{
        <<"phase">> => <<"4B">>
    }#{
        <<"purpose">> => <<"production_damagebdd_node_key">>
    }#{
        <<"status">> => Status
    }#{
        <<"created_at_utc">> => Created
    }#{
        <<"backend">> => bin(Backend)
    }#{
        <<"backend_sha256">> => BackendSha
    }#{
        <<"vault_path">> => bin(Vault)
    }#{
        <<"vault_exists_before">> => VaultExistsBefore
    }#{
        <<"vault_mode_octal">> => bin(VaultMode)
    }#{
        <<"pubkey_hex">> => Pubkey
    }#{
        <<"npub">> => Npub
    }#{
        <<"secret_exported">> => false
    }#{
        <<"scope">> =>
            <<"PRODUCTION DamageBDD node nsecbunker identity - not LodgeiT publisher identity">>
    },
    ok = assert_no_secret_material(Report),
    ok = write_json(JsonReport, Report),
    ok = write_file(MdReport, phase4b_markdown(Report)),
    _ = file:change_mode(JsonReport, 8#644),
    _ = file:change_mode(MdReport, 8#644),
    {ok, Report#{<<"json_report">> => bin(JsonReport), <<"markdown_report">> => bin(MdReport)}}.

phase4a_ceremony_available() ->
    executable_file(crypto_backend_path()).

phase4b_ceremony_available() ->
    executable_file(crypto_backend_path()).

%%====================================================================
%% Backend operations
%%====================================================================

backend_call(Payload) ->
    backend_call(Payload, #{}).

backend_call(Payload, Opts0) ->
    Opts = opts(Opts0),
    Backend = crypto_backend_path(Opts),
    case executable_file(Backend) of
        true -> backend_call_executable(Backend, Payload, Opts);
        false -> error({crypto_backend_not_executable, Backend})
    end.

backend_call_executable(Backend, Payload, Opts) ->
    Timeout = opt(crypto_timeout_ms, Opts, config_get(crypto_timeout_ms, 45000)),
    Env = opt(env, Opts, []),
    PortOpts0 = [binary, use_stdio, exit_status, stderr_to_stdout],
    PortOpts =
        case Env of
            [] -> PortOpts0;
            _ -> PortOpts0 ++ [{env, Env}]
        end,
    try open_port({spawn_executable, Backend}, PortOpts) of
        Port ->
            Json = jsx:encode(Payload),
            true = port_command(Port, <<Json/binary, "\n">>),
            case collect_port(Port, Timeout, <<>>) of
                {ok, Bin} -> decode_backend(Bin);
                {error, Reason} -> error(Reason)
            end
    catch
        Class:Reason -> error({crypto_backend_open_failed, Class, Reason})
    end.

collect_port(Port, Timeout, Acc) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, Timeout, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {crypto_backend_exit, Status, Acc}}
    after Timeout ->
        safe_port_close(Port),
        {error, crypto_backend_timeout}
    end.

safe_port_close(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        _:_ -> ok
    end.

decode_backend(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        #{<<"ok">> := true, <<"result">> := Result} when is_map(Result) -> Result;
        #{<<"ok">> := true, <<"result">> := Result} -> #{<<"value">> => Result};
        #{<<"ok">> := false, <<"error">> := Error} -> error({crypto_backend_not_ok, Error});
        Other -> error({crypto_backend_bad_envelope, Other})
    catch
        Class:Reason -> error({crypto_backend_invalid_json, Class, Reason, Bin})
    end.

smoke_phase2b_crypto_c_backend() ->
    smoke_phase2b_crypto_c_backend(#{}).

smoke_phase2b_crypto_c_backend(Opts0) ->
    Opts = opts(Opts0),
    Vault = opt_env(
        Opts, vault_path, "DAMAGE_NSECBUNKER_TEST_VAULT", "/tmp/damage-nsecbunker-phase2b-c.vault"
    ),
    Passphrase = opt_env(
        Opts, passphrase, "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase2b-c-local-test-passphrase"
    ),
    _ = file:delete(Vault),
    Env = backend_env(Opts, Passphrase) ++ [{"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"}],
    O = Opts#{env => Env},
    Health = backend_call(#{<<"op">> => <<"health">>}, O),
    Gen = backend_call(#{<<"op">> => <<"generate_identity">>, <<"vault_path">> => bin(Vault)}, O),
    Pub = backend_call(#{<<"op">> => <<"get_public_key">>, <<"vault_path">> => bin(Vault)}, O),
    Pubkey = require_pubkey(
        first_present([field(<<"pubkey_hex">>, Pub), field(<<"pubkey_hex">>, Gen)])
    ),
    Npub = backend_call(#{<<"op">> => <<"npub">>, <<"pubkey_hex">> => Pubkey}, O),
    Sign = backend_call(
        #{}#{
            <<"op">> => <<"sign_event">>
        }#{
            <<"vault_path">> => bin(Vault)
        }#{
            <<"event">> => #{}#{
                <<"pubkey">> => Pubkey
            }#{
                <<"created_at">> => 1778000000
            }#{
                <<"kind">> => 1
            }#{
                <<"tags">> => []
            }#{
                <<"content">> => <<"phase2b c backend smoke">>
            }
        },
        O
    ),
    Event = field(<<"event">>, Sign),
    ok = require_signed_event(Event),
    Enc = backend_call(
        #{
            <<"op">> => <<"nip44_encrypt">>,
            <<"plaintext">> => <<"{\"id\":\"phase2b\",\"result\":\"pong\"}">>
        },
        O
    ),
    Ct = require_binary(field(<<"ciphertext">>, Enc), ciphertext),
    Dec = backend_call(#{<<"op">> => <<"nip44_decrypt">>, <<"ciphertext">> => Ct}, O),
    #{
        health => Health,
        generated => Gen,
        public => Pub,
        npub => Npub,
        signed_event => Event,
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
    Passphrase = opt_env(
        Opts, passphrase, "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase2c-smoke-passphrase"
    ),
    _ = file:delete(Vault),
    Base = Opts#{env => backend_env(Opts, Passphrase)},
    assert_fields(health, backend_call(#{<<"op">> => <<"health">>}, Base), #{
        <<"phase">> => <<"2c">>, <<"nip44">> => <<"v2">>
    }),
    assert_fields(
        bip340_sign,
        backend_call(
            #{}#{
                <<"op">> => <<"schnorr_sign_vector">>
            }#{
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000003">>
            }#{
                <<"message_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000000">>
            }#{
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
            #{}#{
                <<"op">> => <<"schnorr_verify">>
            }#{
                <<"pubkey_hex">> =>
                    <<"F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9">>
            }#{
                <<"message_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000000">>
            }#{
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
            #{}#{
                <<"op">> => <<"event_id">>
            }#{
                <<"pubkey_hex">> =>
                    <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>
            }#{
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
            #{}#{
                <<"op">> => <<"nip44_encrypt_vector">>
            }#{
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000001">>
            }#{
                <<"peer_pubkey_hex">> =>
                    <<"c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5">>
            }#{
                <<"nonce_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000001">>
            }#{
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
            #{}#{
                <<"op">> => <<"nip44_decrypt_vector">>
            }#{
                <<"secret_key_hex">> =>
                    <<"0000000000000000000000000000000000000000000000000000000000000002">>
            }#{
                <<"peer_pubkey_hex">> =>
                    <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>
            }#{
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
        Result -> error({Label, expected_failure, Result})
    catch
        error:{crypto_backend_not_ok, ExpectedError} ->
            ok;
        error:{crypto_backend_not_ok, Other} ->
            error({Label, unexpected_backend_error, Other, ExpectedError})
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
    ok = file:change_mode(Dest, 8#755),
    {ok, Dest}.

check_release_artifacts() ->
    check_release_artifacts(root()).

check_release_artifacts(ReleaseRoot0) ->
    ReleaseRoot = str(ReleaseRoot0),
    RequiredFiles = [
        "bin/damage-nsecbunker-crypto-c"
    ],
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
        _ -> #{}
    catch
        _:_ ->
            case application:get_env(damage, nsecbunker) of
                {ok, Raw} -> canonical_config(Raw);
                undefined -> #{}
            end
    end.

canonical_config(Map) when is_map(Map) ->
    Map;
canonical_config(List) when is_list(List) ->
    maps:from_list([{canon_key(K), V} || {K, V} <- List]);
canonical_config(_) ->
    #{}.

canon_key(K) when is_atom(K) -> K;
canon_key(K) when is_binary(K) ->
    try
        binary_to_existing_atom(K, utf8)
    catch
        _:_ -> K
    end;
canon_key(K) when is_list(K) ->
    try
        list_to_existing_atom(K)
    catch
        _:_ -> K
    end;
canon_key(K) ->
    K.

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
    Base ++ Extra.

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
        "# Phase 4A dev DamageBDD key rehearsal\n\n",
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
        "Scope:\n\n```text\nDEV / DISPOSABLE ONLY\nNot the real LodgeiT publisher identity.\nDo not reuse for Phase 4B.\n```\n\n",
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
        "# Phase 4B production DamageBDD node key ceremony\n\n",
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
        "Scope:\n\n```text\nPRODUCTION DamageBDD node nsecbunker identity.\nNot the LodgeiT publisher identity.\n```\n\n",
        "Secret handling:\n\n```text\nnsec exported: no\nprivate key printed: no\nsecret-shaped fields in report: no\nproduction vault overwritten: no\n```\n"
    ]).

write_json(Path, Map) ->
    Json = iolist_to_binary(jsx:encode(Map)),
    write_file(Path, <<Json/binary, "\n">>).

write_file(Path0, Data) ->
    Path = str(Path0),
    ok = ensure_parent(Path),
    file:write_file(Path, Data).

ensure_parent(Path0) ->
    Path = str(Path0),
    filelib:ensure_dir(filename:join(filename:dirname(Path), ".keep")).

ensure_dir(Dir0) ->
    Dir = str(Dir0),
    filelib:ensure_dir(filename:join(Dir, ".keep")).

file_mode_private(Path) ->
    case filelib:is_regular(Path) of
        true -> ok;
        false -> error({vault_missing, Path})
    end,
    _ = file:change_mode(Path, 8#600),
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
        <<"sk">>
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
