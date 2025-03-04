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
    test/0
]).

%% Initialize SQLite database
init_db() ->
    {ok, Conn} = sqlite3:open("secrets.db"),
    sqlite3:exec(
        Conn,
        "CREATE TABLE IF NOT EXISTS secrets (id TEXT PRIMARY KEY, iv BLOB, cipher_text BLOB, tag BLOB)"
    ),
    sqlite3:close(Conn),
    ok.

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

    crypto:crypto_one_time_aead(
        aes_256_gcm,
        AESKey,
        IV,
        CipherText,
        AAD,
        Tag,
        false
    ).

%% Store encrypted secret in SQLite
store_secret(Name, {IV, CipherText, Tag}) ->
    {ok, Conn} = sqlite3:open("secrets.db"),
    Stmt = "INSERT OR REPLACE INTO secrets (id, iv, cipher_text, tag) VALUES (?1, ?2, ?3, ?4)",
    sqlite3:bind(Conn, Stmt, [Name, IV, CipherText, Tag]),
    sqlite3:step(Conn),
    sqlite3:close(Conn),
    ok.

%% Retrieve encrypted secret from SQLite
retrieve_secret(Name) ->
    {ok, Conn} = sqlite3:open("secrets.db"),
    Stmt = "SELECT iv, cipher_text, tag FROM secrets WHERE id = ?1",
    case sqlite3:fetch(Conn, Stmt, [Name]) of
        {ok, [[IV, CipherText, Tag]]} ->
            sqlite3:close(Conn),
            {ok, {IV, CipherText, Tag}};
        _ ->
            sqlite3:close(Conn),
            {error, not_found}
    end.

test() ->
    #{public_key := AeAccount, private_key := PrivateKey} = damage_ae:node_keypair(),
    ?LOG_DEBUG("public_key ~p, private_key ~p", [AeAccount, PrivateKey]),
    Secret = <<"Secret something something">>,
    {IV, CipherText, Tag} =
        encrypt_secret(Secret, PrivateKey),
    Secret = decrypt_secret({IV, CipherText, Tag}, PrivateKey).
