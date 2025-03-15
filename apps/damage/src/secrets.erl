-module(secrets).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-export([
    init_db/0,
    store_secret/2,
    retrieve_secret/1,
    encrypt_secret/2,
    decrypt_secret/2,
    encrypt_store/2,
    retrieve_decrypt/1,
    import/0,
    test/0
]).

-define(DETS_FILE, "damage.dets").
-define(DETS_ARGS, [{auto_save, 5000}]).
%% Initialize dets database
init_db() ->
    ok.

%%% --- AES-GCM Encryption & Decryption ---
% https://medium.com/@brucifi/how-to-encrypt-with-aes-256-gcm-with-erlang-2a2aec13598d
%% Implement HKDF for AES-256 Key Derivation
hkdf(Salt, InputKeyMaterial, Info, Length) ->
    %% Extract step
    PRK = crypto:mac(hmac, sha256, Salt, InputKeyMaterial),
    %% Expand step
    T1 = crypto:mac(hmac, sha256, PRK, <<Info/binary, 1>>),
    <<DerivedKey:Length/binary, _/binary>> = T1,
    ?LOG_DEBUG("Derived key ~p", [DerivedKey]),
    DerivedKey.

%% Derive AES-256 Key from Private Key
derive_aes_key(PrivateKey) ->
    Salt = <<"Aeternity_Secret_Storage">>,
    %% Ensure 32-byte AES key
    hkdf(Salt, PrivateKey, <<"AES-KEY">>, 32).

%% Encrypt a secret using AES-256-GCM
encrypt_secret(Secret, PrivateKey) ->
    AESKey = derive_aes_key(PrivateKey),
    %% Ensure IV is exactly 16 bytes
    IV = crypto:strong_rand_bytes(16),

    %% Verify AES Key and IV sizes
    true = (byte_size(AESKey) == 32),
    true = (byte_size(IV) == 16),

    %% Encrypt using AES-256-GCM (Pass empty AAD `<<>>` and tag length of 16)
    {CipherText, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, AESKey, IV, Secret, <<>>, true),

    {IV, CipherText, Tag}.

%% Decrypt a secret using AES-256-GCM
decrypt_secret({IV, CipherText, Tag}, PrivateKey) ->
    AESKey = derive_aes_key(PrivateKey),

    %% Verify AES Key and IV sizes before decryption
    true = (byte_size(AESKey) == 32),
    true = (byte_size(IV) == 16),
    AAD = <<>>,

    %% Decrypt using AES-256-GCM (NO Tag argument in decryption mode)
    %crypto:crypto_one_time_aead(aes_256_gcm, AESKey, IV, CipherText, <<>>, 16, true).
    ?LOG_DEBUG("decrypt ~p", [CipherText]),

    binary_to_list(
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            AESKey,
            IV,
            CipherText,
            AAD,
            Tag,
            false
        )
    ).

%% Store encrypted secret in SQLite
store_secret(Name, {IV, CipherText, Tag}) ->
    {ok, ?DETS_FILE} = dets:open_file(?DETS_FILE, ?DETS_ARGS),
    dets:insert(?DETS_FILE, {Name, {IV, CipherText, Tag}}).

%% Retrieve encrypted secret from SQLite
retrieve_secret(Name) ->
    dets:open_file(?DETS_FILE, ?DETS_ARGS),
    dets:lookup(?DETS_FILE, Name).
encrypt_store({Name, Secret}) ->
    encrypt_store(Name, Secret).
encrypt_store(Name, Secret) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = damage_ae:node_keypair(),
    store_secret(Name, encrypt_secret(Secret, PrivateKey)).
retrieve_decrypt(Name) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = damage_ae:node_keypair(),
    case retrieve_secret(Name) of
        [{Name, {IV, CipherText, Tag}}] ->
            {ok, decrypt_secret({IV, CipherText, Tag}, PrivateKey)};
        [] ->
            error
    end.

import() ->
    case file:consult("damage.plain") of
        {ok, Terms} ->
            ?LOG_DEBUG("Got damage.plain ~p", [Terms]),
            lists:map(fun encrypt_store/1, Terms);
        {error, enoent} ->
            ?LOG_ERROR("no damage.plain found ", []);
        Error ->
            ?LOG_ERROR("no damage.plain found ~p", [Error])
    end.

test() ->
    #{public_key := AeAccount, private_key := PrivateKey} = damage_ae:node_keypair(),
    ?LOG_DEBUG("public_key ~p, private_key ~p", [AeAccount, PrivateKey]),
    Secret = "Secret something something",
    {IV, CipherText, Tag} =
        encrypt_secret(Secret, PrivateKey),
    Secret = decrypt_secret({IV, CipherText, Tag}, PrivateKey),
    StoredSecret = "store secre",
    encrypt_store(test, StoredSecret),
    StoredSecret = retrieve_decrypt(test).
