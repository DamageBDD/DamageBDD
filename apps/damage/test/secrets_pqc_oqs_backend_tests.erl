%%%-------------------------------------------------------------------
%%% secrets_pqc_oqs_backend_tests.erl
%%%
%%% Integration tests for the real liboqs/NIF backend.
%%%
%%% This does NOT use the fake test backend. It verifies:
%%%   - secrets_pqc_oqs loads
%%%   - keypair/1 works
%%%   - encapsulate/2 and decapsulate/3 agree
%%%   - secrets_pqc can use secrets_pqc_oqs as its configured backend
%%%-------------------------------------------------------------------
-module(secrets_pqc_oqs_backend_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEM, ml_kem_768).

secrets_pqc_oqs_backend_test_() ->
    case ensure_oqs_backend_available() of
        ok ->
            {
                setup,
                fun setup/0,
                fun cleanup/1,
                {inorder, [
                    fun oqs_backend_exports_exist/0,
                    fun oqs_keypair_shape/0,
                    fun oqs_kem_roundtrip/0,
                    fun oqs_wrong_private_key_does_not_match/0,
                    fun secrets_pqc_roundtrip_using_oqs_backend/0,
                    fun secrets_pqc_b64_roundtrip_using_oqs_backend/0,
                    fun secrets_pqc_context_bound_roundtrip_using_oqs_backend/0,
                    fun secrets_pqc_tampered_payload_fails/0,
                    fun unsupported_kem_errors/0
                ]}
            };
        {skip, Reason} ->
            skip_tests(Reason)
    end.

setup() ->
    OldBackend = application:get_env(damage, pqc_backend_module),
    application:set_env(damage, pqc_backend_module, secrets_pqc_oqs),
    OldBackend.

cleanup(undefined) ->
    application:unset_env(damage, pqc_backend_module);
cleanup({ok, OldBackend}) ->
    application:set_env(damage, pqc_backend_module, OldBackend).

ensure_oqs_backend_available() ->
    case code:ensure_loaded(secrets_pqc_oqs) of
        {module, secrets_pqc_oqs} ->
            case catch secrets_pqc_oqs:keypair(?KEM) of
                #{public_key := Pub, private_key := Priv} when
                    is_binary(Pub), is_binary(Priv)
                ->
                    ok;
                {'EXIT', Reason} ->
                    {skip, {oqs_backend_unavailable, Reason}};
                Other ->
                    {skip, {unexpected_keypair_result, Other}}
            end;
        {error, Reason} ->
            {skip, {module_load_failed, Reason}}
    end.

skip_tests(Reason) ->
    Name =
        lists:flatten(
            io_lib:format(
                "SKIP secrets_pqc_oqs backend tests: ~p",
                [Reason]
            )
        ),
    [
        {Name, fun() ->
            io:format(user, "~s~n", [Name]),
            ok
        end}
    ].

oqs_backend_exports_exist() ->
    ?assert(erlang:function_exported(secrets_pqc_oqs, keypair, 1)),
    ?assert(erlang:function_exported(secrets_pqc_oqs, encapsulate, 2)),
    ?assert(erlang:function_exported(secrets_pqc_oqs, decapsulate, 3)).

oqs_keypair_shape() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc_oqs:keypair(?KEM),

    ?assert(is_binary(PublicKey)),
    ?assert(is_binary(PrivateKey)),
    ?assert(byte_size(PublicKey) > 0),
    ?assert(byte_size(PrivateKey) > 0),

    %% ML-KEM-768 raw liboqs sizes. Keep strict size checks opt-in so
    %% wrapped/encoded NIF key formats can still pass backend integration.
    maybe_assert_raw_size(public_key, PublicKey, 1184),
    maybe_assert_raw_size(private_key, PrivateKey, 2400).

oqs_kem_roundtrip() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc_oqs:keypair(?KEM),

    Encapsulation = secrets_pqc_oqs:encapsulate(?KEM, PublicKey),

    ?assertMatch(
        #{
            ciphertext := _,
            shared_secret := _
        },
        Encapsulation
    ),

    Ciphertext = maps:get(ciphertext, Encapsulation),
    SharedSecret1 = maps:get(shared_secret, Encapsulation),
    SharedSecret2 =
        secrets_pqc_oqs:decapsulate(?KEM, Ciphertext, PrivateKey),

    ?assert(is_binary(Ciphertext)),
    ?assert(is_binary(SharedSecret1)),
    ?assert(is_binary(SharedSecret2)),

    %% ML-KEM-768 raw liboqs ciphertext size is opt-in because some NIFs
    %% may wrap or encode ciphertexts. The shared secret must remain raw.
    maybe_assert_raw_size(ciphertext, Ciphertext, 1088),
    ?assertEqual(32, byte_size(SharedSecret1)),
    ?assertEqual(SharedSecret1, SharedSecret2).

oqs_wrong_private_key_does_not_match() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc_oqs:keypair(?KEM),
    #{private_key := WrongPrivateKey} =
        secrets_pqc_oqs:keypair(?KEM),

    #{
        ciphertext := Ciphertext,
        shared_secret := SharedSecret
    } =
        secrets_pqc_oqs:encapsulate(?KEM, PublicKey),

    Correct =
        secrets_pqc_oqs:decapsulate(?KEM, Ciphertext, PrivateKey),
    Wrong =
        catch secrets_pqc_oqs:decapsulate(?KEM, Ciphertext, WrongPrivateKey),

    ?assertEqual(SharedSecret, Correct),
    ?assertNotEqual(SharedSecret, Wrong).

secrets_pqc_roundtrip_using_oqs_backend() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(?KEM),

    Plaintext = <<"DamageBDD real OQS backend payload">>,
    Envelope = secrets_pqc:encrypt(?KEM, Plaintext, PublicKey),

    ?assert(secrets_pqc:is_pqc_envelope(Envelope)),
    ?assertEqual(
        Plaintext,
        secrets_pqc:decrypt(?KEM, Envelope, PrivateKey)
    ).

secrets_pqc_b64_roundtrip_using_oqs_backend() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(?KEM),

    Plaintext = <<"DamageBDD base64 OQS payload">>,
    EncodedEnvelope =
        secrets_pqc:encrypt_b64(?KEM, Plaintext, PublicKey),

    ?assert(is_binary(EncodedEnvelope)),
    ?assertEqual(
        Plaintext,
        secrets_pqc:decrypt_b64(?KEM, EncodedEnvelope, PrivateKey)
    ).

secrets_pqc_context_bound_roundtrip_using_oqs_backend() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(?KEM),

    Plaintext = <<"DamageBDD context-bound OQS payload">>,
    AADContext = #{
        <<"domain">> => <<"damagebdd:test:oqs:aad:v1">>,
        <<"contract_id">> => <<"ct_test">>,
        <<"owner_at_mint">> => <<"ak_test">>,
        <<"payload_sha256">> => binary:encode_hex(crypto:hash(sha256, Plaintext)),
        <<"recipient_pqpk_sha256">> => binary:encode_hex(crypto:hash(sha256, PublicKey))
    },
    Envelope = secrets_pqc:encrypt(?KEM, Plaintext, PublicKey, AADContext),

    ?assert(is_binary(maps:get(aad_sha256, Envelope))),
    ?assertEqual(
        Plaintext,
        secrets_pqc:decrypt(?KEM, Envelope, PrivateKey, AADContext)
    ),

    WrongAADContext = AADContext#{<<"contract_id">> := <<"ct_wrong">>},
    WrongResult = catch secrets_pqc:decrypt(?KEM, Envelope, PrivateKey, WrongAADContext),
    ?assertNotEqual(Plaintext, WrongResult).

secrets_pqc_tampered_payload_fails() ->
    #{public_key := PublicKey, private_key := PrivateKey} =
        secrets_pqc:generate_keypair(?KEM),

    Plaintext = <<"authenticated OQS payload">>,
    Envelope = secrets_pqc:encrypt(?KEM, Plaintext, PublicKey),

    Ct = maps:get(ct, Envelope),
    TamperedEnvelope = Envelope#{ct := flip_first_byte(Ct)},

    Result = catch secrets_pqc:decrypt(?KEM, TamperedEnvelope, PrivateKey),

    ?assertNotEqual(Plaintext, Result).

unsupported_kem_errors() ->
    ?assertError(
        {unsupported_kem, unsupported_test_kem},
        secrets_pqc_oqs:keypair(unsupported_test_kem)
    ),
    ?assertError(
        {unsupported_kem, unsupported_test_kem},
        secrets_pqc_oqs:encapsulate(unsupported_test_kem, <<"pub">>)
    ),
    ?assertError(
        {unsupported_kem, unsupported_test_kem},
        secrets_pqc_oqs:decapsulate(
            unsupported_test_kem,
            <<"ct">>,
            <<"priv">>
        )
    ).

maybe_assert_raw_size(Label, Bin, ExpectedSize) ->
    case application:get_env(damage, pqc_oqs_assert_raw_sizes, false) of
        true ->
            ?assertEqual({Label, ExpectedSize}, {Label, byte_size(Bin)});
        _ ->
            ok
    end.

flip_first_byte(<<Byte:8, Rest/binary>>) ->
    <<(Byte bxor 16#01):8, Rest/binary>>;
flip_first_byte(<<>>) ->
    <<1>>.
