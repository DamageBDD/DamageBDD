-module(damage_nsecbunker_phase2c_vector_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

phase2c_crypto_vectors_test_() ->
    {timeout, 120, fun run/0}.

run() ->
    Cmd = crypto_cmd(),
    ?assert(executable_file(Cmd)),
    Health = call(Cmd, #{op => <<"health">>}, []),
    ?assertEqual(true, ok_field(Health)),
    ?assertEqual(<<"2c">>, result_field(Health, <<"phase">>)),

    BIP340 = call(Cmd, #{
        op => <<"schnorr_sign_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000003">>,
        message_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>,
        aux_rand_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>
    }, []),
    ?assertEqual(true, ok_field(BIP340)),
    ?assertEqual(<<"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9">>, result_field(BIP340, <<"pubkey_hex">>)),
    ?assertEqual(<<"e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0">>, result_field(BIP340, <<"signature_hex">>)),

    Verify = call(Cmd, #{
        op => <<"schnorr_verify">>,
        pubkey_hex => <<"F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9">>,
        message_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>,
        signature_hex => <<"E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0">>
    }, []),
    ?assertEqual(true, ok_field(Verify)),
    ?assertEqual(true, result_field(Verify, <<"valid">>)),

    Npub = call(Cmd, #{
        op => <<"npub">>,
        pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>
    }, []),
    ?assertEqual(true, ok_field(Npub)),
    ?assertEqual(<<"npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d">>, result_field(Npub, <<"npub">>)),

    EventId = call(Cmd, #{
        op => <<"event_id">>,
        pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
        event => #{created_at => 0, kind => 1, tags => [], content => <<"hello">>}
    }, []),
    ?assertEqual(true, ok_field(EventId)),
    ?assertEqual(<<"5a25a8422478717a983475e3ab77edeb1b72775dde3d2e2dffb054aa98c5cc45">>, result_field(EventId, <<"id">>)),

    NIP44 = call(Cmd, #{
        op => <<"nip44_encrypt_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000001">>,
        peer_pubkey_hex => <<"c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5">>,
        nonce_hex => <<"0000000000000000000000000000000000000000000000000000000000000001">>,
        plaintext => <<"a">>
    }, []),
    ?assertEqual(true, ok_field(NIP44)),
    ?assertEqual(<<"c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d">>, result_field(NIP44, <<"conversation_key">>)),
    ?assertEqual(<<"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb">>, result_field(NIP44, <<"payload">>)),

    NIP44D = call(Cmd, #{
        op => <<"nip44_decrypt_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000002">>,
        peer_pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
        payload => <<"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb">>
    }, []),
    ?assertEqual(true, ok_field(NIP44D)),
    ?assertEqual(<<"a">>, result_field(NIP44D, <<"plaintext">>)),

    Vault = <<"/tmp/damage-nsecbunker-phase2c-eunit.vault">>,
    _ = file:delete(binary_to_list(Vault)),
    Env = [{"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase2c-eunit-passphrase"}],
    Gen = call(Cmd, #{op => <<"generate_identity">>, vault_path => Vault}, Env),
    ?assertEqual(true, ok_field(Gen)),
    Pub = result_field(Gen, <<"pubkey_hex">>),
    ?assertMatch({match, _}, re:run(Pub, <<"^[0-9a-f]{64}$">>)),

    Client = <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
    Enc = call(Cmd, #{op => <<"nip44_encrypt">>, vault_path => Vault, client_pubkey => Client, plaintext => <<"phase2c real nip44">>}, Env),
    ?assertEqual(true, ok_field(Enc)),
    Ciphertext = result_field(Enc, <<"ciphertext">>),
    ?assertNotEqual(<<"plain:">>, binary:part(Ciphertext, 0, min(6, byte_size(Ciphertext)))),
    Dec = call(Cmd, #{op => <<"nip44_decrypt">>, vault_path => Vault, client_pubkey => Client, ciphertext => Ciphertext}, Env),
    ?assertEqual(<<"phase2c real nip44">>, result_field(Dec, <<"plaintext">>)),

    Bad = call(Cmd, #{op => <<"get_public_key">>, vault_path => Vault}, [{"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "wrong-passphrase"}]),
    ?assertEqual(false, ok_field(Bad)),
    ?assertEqual(<<"vault_decrypt_failed">>, maps:get(<<"error">>, Bad)),

    PlainBlocked = call(Cmd, #{op => <<"plain_mode_status">>}, [
        {"DAMAGE_NSECBUNKER_TEST_MODE", "1"},
        {"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"},
        {"DAMAGE_NSECBUNKER_PRODUCTION", "1"}
    ]),
    ?assertEqual(false, result_field(PlainBlocked, <<"plain_allowed">>)),
    ok.

crypto_cmd() ->
    case os:getenv("DAMAGE_NSECBUNKER_CRYPTO_CMD") of
        false -> "priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c";
        Cmd -> Cmd
    end.

call(Cmd, Req, Env) ->
    Port = open_port({spawn_executable, Cmd}, [binary, use_stdio, exit_status, stderr_to_stdout, {env, Env}]),
    Json = jsx:encode(Req),
    true = port_command(Port, <<Json/binary, "\n">>),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, _Status}} -> jsx:decode(Acc, [return_maps])
    after 15000 ->
        _ = erlang:port_close(Port),
        error({crypto_backend_timeout, Acc})
    end.

ok_field(Map) -> maps:get(<<"ok">>, Map, maps:get(ok, Map, false)).

result_field(Map, Field) ->
    Result = maps:get(<<"result">>, Map, maps:get(result, Map, #{})),
    maps:get(Field, Result).

executable_file(Cmd) when is_list(Cmd) ->
    case file:read_file_info(Cmd) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            (Mode band 8#111) =/= 0;
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Cmd) of
                {ok, LinkTarget} -> executable_file(filename:absname(LinkTarget, filename:dirname(Cmd)));
                {error, _} -> false
            end;
        _ ->
            false
    end.
