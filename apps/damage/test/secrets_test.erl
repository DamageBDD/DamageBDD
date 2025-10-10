-module(secrets_test).
-include_lib("eunit/include/eunit.hrl").

%% Setup before running tests
setup() ->
    application:ensure_all_started(sqlite3),
    ae_secrets_sqlite:init_db().

%% Cleanup after tests
teardown() ->
    file:delete("secrets.db").

%% Test case for encryption, storage, retrieval, and decryption
encryption_storage_test_() ->
    {setup,
        %% Setup before test
        fun setup/0,
        %% Cleanup after test
        fun teardown/0, [
            {"Generate keypair, encrypt secret, store, retrieve, and decrypt", fun() ->
                %% Generate keypair
                {PrivateKey, PublicKey} = ae_secrets_sqlite:generate_keypair(),

                %% Define secret
                Secret = <<"My secret message">>,

                %% Encrypt secret
                {EncryptedKey, IV, CipherText} = ae_secrets_sqlite:encrypt_secret(
                    Secret, PublicKey
                ),

                %% Store encrypted secret
                ok = ae_secrets_sqlite:store_secret(<<"secret1">>, EncryptedKey, IV, CipherText),

                %% Retrieve stored secret
                {ok, RetrievedEncryptedSecret} = ae_secrets_sqlite:retrieve_secret(<<"secret1">>),

                %% Decrypt retrieved secret
                DecryptedSecret = ae_secrets_sqlite:decrypt_secret(
                    RetrievedEncryptedSecret, PrivateKey
                ),

                %% Ensure decrypted secret matches original
                ?assertEqual(Secret, DecryptedSecret)
            end}
        ]}.
