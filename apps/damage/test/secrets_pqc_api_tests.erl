%%%-------------------------------------------------------------------
%%% secrets_pqc_api_tests.erl
%%%
%%% EUnit compatibility tests for secrets_pqc.
%%%
%%% This tests the intended secrets-compatible crypto surface:
%%%   encrypt/2, encrypt/3, decrypt/2, decrypt/3
%%%
%%% It also verifies the PQC-specific keypair/envelope/base64 helpers.
%%% The test module doubles as a fake PQC backend, so the tests do not
%%% need the liboqs NIF to be loaded.
%%%-------------------------------------------------------------------
-module(secrets_pqc_api_tests).

-include_lib("eunit/include/eunit.hrl").

%% Fake backend callbacks used by secrets_pqc through:
%% application env damage:pqc_backend_module.
-export([keypair/1, encapsulate/2, decapsulate/3]).

-define(DEFAULT_KEM, ml_kem_768).

%% Keep this list as the explicit compatibility contract with secrets.erl.
%% Do not include secrets:encrypt/1 or secrets:decrypt/1 unless secrets_pqc
%% intentionally grows node-keypair based defaults.
compat_exports() ->
    [
        {encrypt, 2},
        {encrypt, 3},
        {decrypt, 2},
        {decrypt, 3}
    ].

pqc_exports() ->
    [
        {generate_keypair, 0},
        {generate_keypair, 1},
        {encrypt_b64, 2},
        {encrypt_b64, 3},
        {decrypt_b64, 2},
        {decrypt_b64, 3},
        {is_pqc_envelope, 1}
    ].

secrets_pqc_api_test_() ->
    {
        setup,
        fun setup/0,
        fun cleanup/1,
        [
            fun compatible_exports_exist/0,
            fun pqc_specific_exports_exist/0,
            fun keypair_shape_matches_secrets_keypair_shape/0,
            fun encrypt_decrypt_binary_roundtrip/0,
            fun encrypt_decrypt_list_roundtrip/0,
            fun explicit_kem_roundtrip/0,
            fun b64_roundtrip/0,
            fun envelope_shape_and_authentication/0,
            fun ciphertexts_are_randomized/0,
            fun unsupported_kem_errors/0
        ]
    }.

setup() ->
    {module, secrets_pqc} = code:ensure_loaded(secrets_pqc),
    {module, secrets} = code:ensure_loaded(secrets),
    OldBackend = application:get_env(damage, pqc_backend_module),
    application:set_env(damage, pqc_backend_module, ?MODULE),
    OldBackend.

cleanup(undefined) ->
    application:unset_env(damage, pqc_backend_module);
cleanup({ok, OldBackend}) ->
    application:set_env(damage, pqc_backend_module, OldBackend).

compatible_exports_exist() ->
    Missing = missing_exports(secrets_pqc, compat_exports()),
    ?assertEqual([], Missing),

    %% Verify the compat list itself still exists on secrets.erl.
    MissingOnSecrets = missing_exports(secrets, compat_exports()),
    ?assertEqual([], MissingOnSecrets).

pqc_specific_exports_exist() ->
    Missing = missing_exports(secrets_pqc, pqc_exports()),
    ?assertEqual([], Missing).

keypair_shape_matches_secrets_keypair_shape() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),
    ?assert(is_binary(PublicKey)),
    ?assert(is_binary(PrivateKey)),
    ?assert(byte_size(PublicKey) > 0),
    ?assert(byte_size(PrivateKey) > 0).

encrypt_decrypt_binary_roundtrip() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),

    Plaintext = <<"DamageBDD PQC secret">>,
    Envelope = secrets_pqc:encrypt(Plaintext, PublicKey),

    ?assert(secrets_pqc:is_pqc_envelope(Envelope)),
    ?assertEqual(Plaintext, secrets_pqc:decrypt(Envelope, PrivateKey)).

encrypt_decrypt_list_roundtrip() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),

    Envelope = secrets_pqc:encrypt("DamageBDD list secret", PublicKey),

    ?assertEqual(
        <<"DamageBDD list secret">>,
        secrets_pqc:decrypt(Envelope, PrivateKey)
    ).

explicit_kem_roundtrip() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(?DEFAULT_KEM),

    Plaintext = <<"explicit ML-KEM-768 payload">>,
    Envelope = secrets_pqc:encrypt(?DEFAULT_KEM, Plaintext, PublicKey),

    ?assertEqual(
        Plaintext,
        secrets_pqc:decrypt(?DEFAULT_KEM, Envelope, PrivateKey)
    ).

b64_roundtrip() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),

    Plaintext = <<"base64 sealed payload">>,
    EncodedEnvelope = secrets_pqc:encrypt_b64(Plaintext, PublicKey),

    ?assert(is_binary(EncodedEnvelope)),
    ?assertEqual(
        Plaintext,
        secrets_pqc:decrypt_b64(EncodedEnvelope, PrivateKey)
    ).

ciphertexts_are_randomized() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),

    Plaintext = <<"same plaintext">>,
    Envelope1 = secrets_pqc:encrypt(Plaintext, PublicKey),
    Envelope2 = secrets_pqc:encrypt(Plaintext, PublicKey),

    ?assertEqual(Plaintext, secrets_pqc:decrypt(Envelope1, PrivateKey)),
    ?assertEqual(Plaintext, secrets_pqc:decrypt(Envelope2, PrivateKey)),

    ?assertNotEqual(maps:get(kem_ct, Envelope1), maps:get(kem_ct, Envelope2)),
    ?assertNotEqual(maps:get(iv, Envelope1), maps:get(iv, Envelope2)),
    ?assertNotEqual(maps:get(ct, Envelope1), maps:get(ct, Envelope2)).

unsupported_kem_errors() ->
    ?assertError(
        {unsupported_kem, unsupported_test_kem},
        secrets_pqc:generate_keypair(unsupported_test_kem)
    ).

missing_exports(Module, Exports) ->
    [
        {Function, Arity}
     || {Function, Arity} <- Exports,
        not erlang:function_exported(Module, Function, Arity)
    ].

%% ------------------------------------------------------------------
%% Fake PQC backend
%% ------------------------------------------------------------------

keypair(?DEFAULT_KEM) ->
    Seed = crypto:strong_rand_bytes(32),
    PublicKey =
        crypto:hash(
            sha256,
            <<"damagebdd:pqc-test:pub:", Seed/binary>>
        ),
    PrivateKey = term_to_binary({?MODULE, ?DEFAULT_KEM, PublicKey, Seed}),
    #{public_key => PublicKey, private_key => PrivateKey};
keypair(Kem) ->
    error({unsupported_kem, Kem}).

encapsulate(?DEFAULT_KEM, PublicKey) when is_binary(PublicKey) ->
    KemCiphertext = crypto:strong_rand_bytes(32),
    #{
        ciphertext => KemCiphertext,
        shared_secret => shared_secret(?DEFAULT_KEM, PublicKey, KemCiphertext)
    };
encapsulate(Kem, _PublicKey) ->
    error({unsupported_kem, Kem}).

decapsulate(?DEFAULT_KEM, KemCiphertext, PrivateKey) when
    is_binary(KemCiphertext), is_binary(PrivateKey)
->
    case catch binary_to_term(PrivateKey) of
        {?MODULE, ?DEFAULT_KEM, PublicKey, _Seed} when is_binary(PublicKey) ->
            shared_secret(?DEFAULT_KEM, PublicKey, KemCiphertext);
        _ ->
            error({bad_test_private_key, PrivateKey})
    end;
decapsulate(Kem, _KemCiphertext, _PrivateKey) ->
    error({unsupported_kem, Kem}).

shared_secret(Kem, PublicKey, KemCiphertext) ->
    KemBin = atom_to_binary(Kem, utf8),
    crypto:hash(
        sha256,
        <<
            "damagebdd:pqc-test:ss:",
            KemBin/binary,
            0,
            PublicKey/binary,
            0,
            KemCiphertext/binary
        >>
    ).

flip_first_byte(<<Byte:8, Rest/binary>>) ->
    <<(Byte bxor 16#01):8, Rest/binary>>;
flip_first_byte(<<>>) ->
    <<1>>.
envelope_shape_and_authentication() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(),
    #{private_key := WrongPrivateKey} =
        secrets_pqc:generate_keypair(),

    Plaintext = <<"authenticated payload">>,
    Envelope = secrets_pqc:encrypt(Plaintext, PublicKey),

    ?assertMatch(
        #{
            v := 1,
            alg := pqc_hybrid_aes_256_gcm,
            kem := ?DEFAULT_KEM,
            kem_ct := _,
            iv := _,
            tag := _,
            ct := _
        },
        Envelope
    ),

    KemCt = maps:get(kem_ct, Envelope),
    IV = maps:get(iv, Envelope),
    Tag = maps:get(tag, Envelope),
    Ct = maps:get(ct, Envelope),

    ?assert(is_binary(KemCt)),
    ?assert(is_binary(IV)),
    ?assertEqual(12, byte_size(IV)),
    ?assert(is_binary(Tag)),
    ?assertEqual(16, byte_size(Tag)),
    ?assert(is_binary(Ct)),

    ?assertEqual(Plaintext, secrets_pqc:decrypt(Envelope, PrivateKey)),

    %% Wrong PQC private key must not decrypt.
    WrongResult = catch secrets_pqc:decrypt(Envelope, WrongPrivateKey),
    ?assertNotEqual(Plaintext, WrongResult),

    %% Tampered ciphertext must not decrypt.
    TamperedEnvelope = Envelope#{ct := flip_first_byte(Ct)},
    TamperedResult = catch secrets_pqc:decrypt(TamperedEnvelope, PrivateKey),
    ?assertNotEqual(Plaintext, TamperedResult),

    ?assertEqual(
        false,
        secrets_pqc:is_pqc_envelope(#{ct => <<"not-enough">>})
    ).
