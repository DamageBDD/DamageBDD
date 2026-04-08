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
%%% What you need to adapt:
%%% - The 3 backend_* functions at the bottom.
%%% - Wire them to your actual liboqs / ex_oqs / NIF module.
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
    decrypt/2,
    decrypt/3,
    encrypt_b64/2,
    encrypt_b64/3,
    decrypt_b64/2,
    decrypt_b64/3,
    is_pqc_envelope/1
]).

-define(DEFAULT_KEM, ml_kem_768).
-define(AES_KEY_BYTES, 32).
-define(AES_GCM_IV_BYTES, 12).
-define(AES_GCM_TAG_BYTES, 16).
-define(INFO_KEY, <<"damagebdd:secrets_pqc:aes-key:v1">>).
-define(INFO_AAD, <<"damagebdd:secrets_pqc:aad:v1">>).

%% ------------------------------------------------------------------
%% Public API
%% ------------------------------------------------------------------

generate_keypair() ->
    generate_keypair(?DEFAULT_KEM).

generate_keypair(Kem) ->
    backend_keypair(Kem).

encrypt(Plaintext, PQPublicKey) ->
    encrypt(?DEFAULT_KEM, Plaintext, PQPublicKey).

encrypt(Kem, Plaintext, PQPublicKey) when is_list(Plaintext) ->
    encrypt(Kem, unicode:characters_to_binary(Plaintext), PQPublicKey);
encrypt(Kem, Plaintext, PQPublicKey) when is_binary(Plaintext), is_binary(PQPublicKey) ->
    #{ciphertext := KemCiphertext, shared_secret := SharedSecret} =
        backend_encapsulate(Kem, PQPublicKey),

    DataKey = kdf(SharedSecret, ?INFO_KEY, ?AES_KEY_BYTES),
    IV = crypto:strong_rand_bytes(?AES_GCM_IV_BYTES),
    AAD = aad(Kem, KemCiphertext),

    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            DataKey,
            IV,
            Plaintext,
            AAD,
            true
        ),

    #{
        v => 1,
        alg => pqc_hybrid_aes_256_gcm,
        kem => Kem,
        kem_ct => KemCiphertext,
        iv => IV,
        tag => Tag,
        ct => Ciphertext
    }.

decrypt(Envelope, PQPrivateKey) ->
    decrypt(?DEFAULT_KEM, Envelope, PQPrivateKey).

decrypt(_KemDefault, Envelope, PQPrivateKey) when is_map(Envelope), is_binary(PQPrivateKey) ->
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
            SharedSecret = backend_decapsulate(Kem, KemCiphertext, PQPrivateKey),
            DataKey = kdf(SharedSecret, ?INFO_KEY, ?AES_KEY_BYTES),
            AAD = aad(Kem, KemCiphertext),
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
    encrypt_b64(?DEFAULT_KEM, Plaintext, PQPublicKey).

encrypt_b64(Kem, Plaintext, PQPublicKey) ->
    base64:encode(term_to_binary(encrypt(Kem, Plaintext, PQPublicKey))).

decrypt_b64(Base64Envelope, PQPrivateKey) ->
    decrypt_b64(?DEFAULT_KEM, Base64Envelope, PQPrivateKey).

decrypt_b64(KemDefault, Base64Envelope, PQPrivateKey) when is_binary(Base64Envelope) ->
    decrypt(KemDefault, binary_to_term(base64:decode(Base64Envelope)), PQPrivateKey).

is_pqc_envelope(#{
    v := 1,
    alg := pqc_hybrid_aes_256_gcm,
    kem := _,
    kem_ct := _,
    iv := _,
    tag := _,
    ct := _
}) ->
    true;
is_pqc_envelope(_) ->
    false.

%% ------------------------------------------------------------------
%% Internal helpers
%% ------------------------------------------------------------------

aad(Kem, KemCiphertext) ->
    KemBin = to_binary(atom_to_list(Kem)),
    <<?INFO_AAD/binary, 0, KemBin/binary, 0, KemCiphertext/binary>>.

kdf(SharedSecret, Info, Length) when is_binary(SharedSecret), is_integer(Length), Length > 0 ->
    %% HKDF-SHA256
    Salt = <<"damagebdd:secrets_pqc:hkdf-salt:v1">>,
    PRK = crypto:mac(hmac, sha256, Salt, SharedSecret),
    T1 = crypto:mac(hmac, sha256, PRK, <<Info/binary, 1>>),
    <<Derived:Length/binary, _/binary>> = T1,
    Derived.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% ------------------------------------------------------------------
%% Backend adapter
%% ------------------------------------------------------------------
%%
%% Replace ONLY these 3 functions to match your PQC binding.
%%
%% Example expected semantics:
%%   backend_keypair(ml_kem_768) ->
%%       #{public_key => Pub, private_key => Priv}.
%%
%%   backend_encapsulate(ml_kem_768, Pub) ->
%%       #{ciphertext => KemCt, shared_secret => Ss}.
%%
%%   backend_decapsulate(ml_kem_768, KemCt, Priv) ->
%%       Ss.
%%
%% Keeping the adapter tiny makes the module easy to drop in.

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
