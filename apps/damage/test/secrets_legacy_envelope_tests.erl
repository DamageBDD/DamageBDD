%% Regression coverage for the public legacy encrypted-envelope boundary.
%% No node wallet, storage configuration, mocks, or external services are used.
-module(secrets_legacy_envelope_tests).
-include_lib("eunit/include/eunit.hrl").

legacy_envelope_test_() ->
    {setup, fun start_crypto/0, fun(_) -> ok end, [
        fun valid_binary_and_charlist_inputs_roundtrip/0,
        fun empty_plaintext_roundtrips/0,
        fun malformed_base64_returns_error/0,
        fun malformed_etf_returns_error/0,
        fun unsupported_envelope_shapes_return_error/0,
        fun invalid_iv_and_tag_sizes_return_error/0,
        fun tampered_envelope_returns_error/0,
        fun wrong_key_returns_error/0,
        fun key_derivation_exception_returns_error/0,
        fun unknown_etf_atom_is_not_created/0
    ]}.

start_crypto() ->
    {ok, _} = application:ensure_all_started(crypto),
    ok.

valid_binary_and_charlist_inputs_roundtrip() ->
    KeyPair = encryption_fixture(),
    PlainText = <<"Disposable legacy-envelope regression fixture">>,
    Encoded = secrets:encrypt(KeyPair, PlainText),
    ?assert(is_binary(Encoded)),
    ?assertEqual(PlainText, secrets:decrypt(KeyPair, Encoded)),
    ?assertEqual(PlainText, secrets:decrypt(KeyPair, binary_to_list(Encoded))).

empty_plaintext_roundtrips() ->
    KeyPair = encryption_fixture(),
    ?assertEqual(<<>>, secrets:decrypt(KeyPair, secrets:encrypt(KeyPair, <<>>))).

malformed_base64_returns_error() ->
    KeyPair = encryption_fixture(),
    lists:foreach(
        fun(Input) -> ?assertEqual(error, secrets:decrypt(KeyPair, Input)) end,
        [<<"A">>, <<"!!!!">>, undefined, 42, #{}, [256]]
    ).

malformed_etf_returns_error() ->
    KeyPair = encryption_fixture(),
    %% Valid base64 can contain invalid Erlang External Term Format bytes.
    %% The old try-of layout let binary_to_term/2 exceptions escape.
    lists:foreach(
        fun(Bytes) ->
            ?assertEqual(error, secrets:decrypt(KeyPair, base64:encode(Bytes)))
        end,
        [<<>>, <<"bad-etf">>, <<131>>, <<131, 104, 3>>]
    ).

unsupported_envelope_shapes_return_error() ->
    KeyPair = encryption_fixture(),
    IV = <<0:128>>,
    CipherText = <<"fixture">>,
    Tag = <<0:128>>,
    lists:foreach(
        fun(Term) -> ?assertEqual(error, secrets:decrypt(KeyPair, encode_term(Term))) end,
        [undefined, #{}, [], {IV, CipherText}, {IV, CipherText, Tag, extra},
         {bound_v1, IV, CipherText, Tag}, {IV, [1, 2, 3], Tag}]
    ).

invalid_iv_and_tag_sizes_return_error() ->
    KeyPair = encryption_fixture(),
    IV = <<0:128>>,
    CipherText = <<"fixture">>,
    Tag = <<0:128>>,
    lists:foreach(
        fun(Term) -> ?assertEqual(error, secrets:decrypt(KeyPair, encode_term(Term))) end,
        [{<<0:120>>, CipherText, Tag}, {<<0:136>>, CipherText, Tag},
         {not_binary, CipherText, Tag}, {IV, CipherText, <<0:120>>},
         {IV, CipherText, <<0:136>>}, {IV, CipherText, not_binary}]
    ).

tampered_envelope_returns_error() ->
    KeyPair = encryption_fixture(),
    Encoded = secrets:encrypt(KeyPair, <<"nonempty disposable plaintext">>),
    {IV, CipherText, Tag} = binary_to_term(base64:decode(Encoded), [safe]),
    lists:foreach(
        fun(Term) -> ?assertEqual(error, secrets:decrypt(KeyPair, encode_term(Term))) end,
        [{flip_byte(IV), CipherText, Tag},
         {IV, flip_byte(CipherText), Tag},
         {IV, CipherText, flip_byte(Tag)}]
    ).

wrong_key_returns_error() ->
    KeyPair = encryption_fixture(),
    Encoded = secrets:encrypt(KeyPair, <<"disposable plaintext">>),
    WrongKey = KeyPair#{private_key := flip_byte(maps:get(private_key, KeyPair))},
    ?assertEqual(error, secrets:decrypt(WrongKey, Encoded)).

key_derivation_exception_returns_error() ->
    KeyPair = encryption_fixture(),
    Encoded = secrets:encrypt(KeyPair, <<"disposable plaintext">>),
    %% This reaches key derivation after a syntactically valid envelope.
    %% Crypto exceptions must be caught just like base64 and ETF errors.
    BadKey = KeyPair#{private_key := invalid_private_key},
    ?assertEqual(error, secrets:decrypt(BadKey, Encoded)).

unknown_etf_atom_is_not_created() ->
    KeyPair = encryption_fixture(),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(16)),
    AtomName = <<"damage_legacy_envelope_untrusted_", Suffix/binary>>,
    ?assertError(badarg, binary_to_existing_atom(AtomName, utf8)),
    %% VERSION_MAGIC + SMALL_ATOM_UTF8_EXT. Do not create the atom locally.
    Bytes = <<131, 119, (byte_size(AtomName)), AtomName/binary>>,
    ?assertEqual(error, secrets:decrypt(KeyPair, base64:encode(Bytes))),
    ?assertError(badarg, binary_to_existing_atom(AtomName, utf8)).

encryption_fixture() ->
    %% Opaque disposable AES key material, NOT a valid signing wallet.
    %% The legacy encryption boundary derives its AES key from these bytes;
    %% signing-key validation remains covered by damage_ae_wallet_tests.
    #{public_key => <<"disposable-encryption-fixture">>,
      private_key => crypto:strong_rand_bytes(64)}.

encode_term(Term) ->
    base64:encode(term_to_binary(Term)).

flip_byte(<<First, Rest/binary>>) ->
    <<(First bxor 1), Rest/binary>>.
