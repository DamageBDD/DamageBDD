%%%-------------------------------------------------------------------
%%% secrets_pqc.erl
%%%
%%% Minimal application-layer PQC envelope for secrets.
%%%
%%% Why this shape:
%%% - ML-KEM-768 is a KEM, not a bulk cipher, so we use it to wrap a
%%%   random AES-256-GCM content key, then encrypt the payload with AES-GCM.
%%% - This sits cleanly on top of your existing infra without replacing
%%%   node_keypair() or existing secrets:encrypt/decrypt paths.
%%%
%%% AAD/context binding:
%%% - All envelopes use AES-GCM AAD v2.
%%% - encrypt/4 and decrypt/4 bind an explicit public context into AES-GCM AAD.
%%% - encrypt/2 and decrypt/2 use the explicit no-context value: none.
%%% - encrypt/3 supports either:
%%%     encrypt(Kem, Plaintext, PQPublicKey)
%%%     encrypt(Plaintext, PQPublicKey, AADContext)
%%% - decrypt/3 supports either:
%%%     decrypt(KemDefault, Envelope, PQPrivateKey)
%%%     decrypt(Envelope, PQPrivateKey, AADContext)
%%%
%%% Expected backend contract:
%%%   backend_keypair(Kem) ->
%%%       #{public_key => binary(), private_key => binary()}.
%%%
%%%   backend_encapsulate(Kem, PublicKey) ->
%%%       #{ciphertext => binary(), shared_secret => binary()}.
%%%
%%%   backend_decapsulate(Kem, Ciphertext, PrivateKey) ->
%%%       SharedSecret :: binary().
%%%-------------------------------------------------------------------
-module(secrets_pqc).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([
    generate_keypair/0,
    generate_keypair/1,
    encrypt/2,
    encrypt/3,
    encrypt/4,
    decrypt/2,
    decrypt/3,
    decrypt/4,
    encrypt_b64/2,
    encrypt_b64/3,
    encrypt_b64/4,
    decrypt_b64/2,
    decrypt_b64/3,
    decrypt_b64/4,
    is_pqc_envelope/1
]).

-define(DEFAULT_KEM, ml_kem_768).
-define(AES_KEY_BYTES, 32).
-define(AES_GCM_IV_BYTES, 12).
-define(INFO_KEY, <<"damagebdd:secrets_pqc:aes-key:v1">>).
-define(INFO_AAD, <<"damagebdd:secrets_pqc:aad:v2">>).

%% ------------------------------------------------------------------
%% Public API
%% ------------------------------------------------------------------

generate_keypair() ->
    generate_keypair(?DEFAULT_KEM).

generate_keypair(Kem) ->
    backend_keypair(Kem).
encrypt(Plaintext, PQPublicKey) ->
    encrypt(?DEFAULT_KEM, Plaintext, PQPublicKey, none).

encrypt(Kem, Plaintext, PQPublicKey) when is_atom(Kem) ->
    encrypt(Kem, Plaintext, PQPublicKey, none);
encrypt(Plaintext, PQPublicKey, AADContext) when
    (is_binary(Plaintext) orelse is_list(Plaintext)),
    is_binary(PQPublicKey)
->
    encrypt(?DEFAULT_KEM, Plaintext, PQPublicKey, AADContext).
encrypt(Kem, Plaintext0, PQPublicKey, AADContext) when
    is_atom(Kem),
    is_binary(PQPublicKey),
    is_binary(Plaintext0) orelse is_list(Plaintext0)
->
    Plaintext =
        case Plaintext0 of
            B when is_binary(B) -> B;
            L when is_list(L) -> unicode:characters_to_binary(L)
        end,

    #{ciphertext := KemCiphertext, shared_secret := SharedSecret} =
        backend_encapsulate(Kem, PQPublicKey),

    DataKey = kdf(SharedSecret, ?INFO_KEY, ?AES_KEY_BYTES),
    IV = crypto:strong_rand_bytes(?AES_GCM_IV_BYTES),
    AAD = aad(Kem, KemCiphertext, AADContext),

    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            DataKey,
            IV,
            Plaintext,
            AAD,
            true
        ),

    Envelope0 = #{
        v => 1,
        alg => pqc_hybrid_aes_256_gcm,
        kem => Kem,
        kem_ct => KemCiphertext,
        iv => IV,
        tag => Tag,
        ct => Ciphertext
    },

    Envelope0#{aad_sha256 => aad_context_hash(AADContext)}.

decrypt(Envelope, PQPrivateKey) ->
    decrypt(?DEFAULT_KEM, Envelope, PQPrivateKey, none).

%% Default-KEM context-bound shape.
decrypt(Envelope, PQPrivateKey, AADContext) when is_map(Envelope), is_binary(PQPrivateKey) ->
    decrypt(?DEFAULT_KEM, Envelope, PQPrivateKey, AADContext);
%% Explicit-KEM shape. The KEM is still taken from the envelope.
decrypt(KemDefault, Envelope, PQPrivateKey) ->
    decrypt(KemDefault, Envelope, PQPrivateKey, none).

decrypt(_KemDefault, Envelope, PQPrivateKey, AADContext) when
    is_map(Envelope), is_binary(PQPrivateKey)
->
    case Envelope of
        #{
            v := 1,
            alg := pqc_hybrid_aes_256_gcm,
            kem := Kem,
            kem_ct := KemCiphertext,
            iv := IV,
            tag := Tag,
            ct := Ciphertext
        } ->
            assert_aad_hash(Envelope, AADContext),
            SharedSecret = backend_decapsulate(Kem, KemCiphertext, PQPrivateKey),
            DataKey = kdf(SharedSecret, ?INFO_KEY, ?AES_KEY_BYTES),
            AAD = aad(Kem, KemCiphertext, AADContext),
            crypto:crypto_one_time_aead(
                aes_256_gcm,
                DataKey,
                IV,
                Ciphertext,
                AAD,
                Tag,
                false
            );
        _ ->
            error({invalid_pqc_envelope, Envelope})
    end.

encrypt_b64(Plaintext, PQPublicKey) ->
    encrypt_b64(?DEFAULT_KEM, Plaintext, PQPublicKey, none).

encrypt_b64(Kem, Plaintext, PQPublicKey) when is_atom(Kem) ->
    encrypt_b64(Kem, Plaintext, PQPublicKey, none);
encrypt_b64(Plaintext, PQPublicKey, AADContext) when
    (is_binary(Plaintext) orelse is_list(Plaintext)), is_binary(PQPublicKey)
->
    encrypt_b64(?DEFAULT_KEM, Plaintext, PQPublicKey, AADContext).

encrypt_b64(Kem, Plaintext, PQPublicKey, AADContext) ->
    base64:encode(term_to_binary(encrypt(Kem, Plaintext, PQPublicKey, AADContext))).

decrypt_b64(Base64Envelope, PQPrivateKey) ->
    decrypt_b64(?DEFAULT_KEM, Base64Envelope, PQPrivateKey, none).

decrypt_b64(Base64Envelope, PQPrivateKey, AADContext) when
    is_binary(Base64Envelope), is_binary(PQPrivateKey)
->
    decrypt_b64(?DEFAULT_KEM, Base64Envelope, PQPrivateKey, AADContext);
decrypt_b64(KemDefault, Base64Envelope, PQPrivateKey) ->
    decrypt_b64(KemDefault, Base64Envelope, PQPrivateKey, none).

decrypt_b64(KemDefault, Base64Envelope, PQPrivateKey, AADContext) when is_binary(Base64Envelope) ->
    Envelope = binary_to_term(base64:decode(Base64Envelope), [safe]),
    decrypt(KemDefault, Envelope, PQPrivateKey, AADContext).

is_pqc_envelope(#{
    v := 1,
    alg := pqc_hybrid_aes_256_gcm,
    kem := _Kem,
    kem_ct := _KemCiphertext,
    iv := _IV,
    tag := _Tag,
    ct := _Ciphertext,
    aad_sha256 := _AADHash
}) ->
    true;
is_pqc_envelope(_) ->
    false.

%% ------------------------------------------------------------------
%% Internal helpers
%% ------------------------------------------------------------------

assert_aad_hash(Envelope, AADContext) ->
    Expected = maps:get(aad_sha256, Envelope),
    Actual = aad_context_hash(AADContext),
    case Expected of
        Actual ->
            ok;
        _ ->
            error({pqc_aad_context_mismatch, #{expected => Expected, actual => Actual}})
    end.

aad(Kem, KemCiphertext, AADContext) ->
    KemBin = to_binary(Kem),
    ContextHash = aad_context_hash(AADContext),
    <<?INFO_AAD/binary, 0, KemBin/binary, 0, KemCiphertext/binary, 0, ContextHash/binary>>.

aad_context_hash(AADContext) ->
    crypto:hash(sha256, aad_context_bin(AADContext)).

aad_context_bin(AADContext) ->
    term_to_binary(normalize_aad_context(AADContext)).

normalize_aad_context(undefined) ->
    none;
normalize_aad_context(none) ->
    none;
normalize_aad_context(B) when is_binary(B) -> B;
normalize_aad_context(B) when is_boolean(B) -> B;
normalize_aad_context(A) when is_atom(A) -> atom_to_binary(A, utf8);
normalize_aad_context(I) when is_integer(I) -> I;
normalize_aad_context(F) when is_float(F) -> F;
normalize_aad_context(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> [normalize_aad_context(X) || X <- L]
    end;
normalize_aad_context(M) when is_map(M) ->
    lists:sort(
        [
            {to_binary(K), normalize_aad_context(V)}
         || {K, V} <- maps:to_list(M)
        ]
    );
normalize_aad_context(T) when is_tuple(T) ->
    {tuple, [normalize_aad_context(X) || X <- tuple_to_list(T)]};
normalize_aad_context(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

kdf(SharedSecret, Info, Length) when is_binary(SharedSecret), is_integer(Length), Length > 0 ->
    %% HKDF-SHA256. Current key size is 32 bytes, so one expand block is enough.
    Salt = <<"damagebdd:secrets_pqc:hkdf-salt:v1">>,
    PRK = crypto:mac(hmac, sha256, Salt, SharedSecret),
    T1 = crypto:mac(hmac, sha256, PRK, <<Info/binary, 1>>),
    <<Derived:Length/binary, _/binary>> = T1,
    Derived.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% ------------------------------------------------------------------
%% Backend adapter
%% ------------------------------------------------------------------

backend_keypair(Kem) ->
    case application:get_env(damage, pqc_backend_module) of
        {ok, Mod} ->
            Mod:keypair(Kem);
        undefined ->
            error({missing_pqc_backend, {keypair, Kem}})
    end.

backend_encapsulate(Kem, PublicKey) ->
    case application:get_env(damage, pqc_backend_module) of
        {ok, Mod} ->
            Mod:encapsulate(Kem, PublicKey);
        undefined ->
            error({missing_pqc_backend, {encapsulate, Kem}})
    end.

backend_decapsulate(Kem, Ciphertext, PrivateKey) ->
    case application:get_env(damage, pqc_backend_module) of
        {ok, Mod} ->
            Mod:decapsulate(Kem, Ciphertext, PrivateKey);
        undefined ->
            error({missing_pqc_backend, {decapsulate, Kem}})
    end.
