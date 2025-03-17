-module(secrets).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-export(
    [
        init/1,
        start_link/0,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).
-export([
    init_db/0,
    store_secret/2,
    retrieve_secret/1,
    encrypt_secret/2,
    decrypt_secret/2,
    encrypt_store/2,
    retrieve_decrypt/1,
    import/0,
    node_keypair/0,
    test/0,
    migrate/0
]).
-export([encrypt/2, decrypt/2, change_password/3]).
-export([encrypt/3, decrypt/3]).

-define(ASKPASS_TIMEOUT, 60000).
-define(DETS_FILE, "damage.dets").
-define(DETS_ARGS, [{auto_save, 5000}]).
%% Initialize dets database
init_db() ->
    ok.

-define(ITERATIONS, 100000).
-define(SALT_SIZE, 16).
-define(KEY_SIZE, 32).
-define(IV_SIZE, 12).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    gproc:reg_other({n, l, {?MODULE, secrets}}, self()),
    {ok, #{}}.
handle_call({encrypt, Key, Prompt, Data}, _From, State) ->
    Password =
        case maps:get(Key, State, undefined) of
            undefined ->
                case erm:ask_password(Prompt) of
                    undefined ->
                        undefined;
                    Password0 ->
                        list_to_binary(Password0)
                end;
            Pass ->
                Pass
        end,
    EncData = secrets:encrypt(Password, term_to_binary(Data)),
    {reply, term_to_binary(EncData), maps:put(Key, Password, State)};
handle_call({decrypt, Key, Prompt, EncData}, _From, State) ->
    Password =
        case maps:get(Key, State, undefined) of
            undefined ->
                list_to_binary(erm:ask_password(Prompt));
            Pass ->
                Pass
        end,
    Data = secrets:decrypt(Password, binary_to_term(EncData)),
    {reply, binary_to_term(Data), maps:put(Key, Password, State)};
handle_call(Request, From, State) ->
    ?LOG_ERROR(
        "got unknown on gun websocket Call ~p, From ~p, State ~p",
        [Request, From, State]
    ),
    {reply, err, State}.
handle_cast(Msg, State) ->
    ?LOG_DEBUG("got unknown on gun websocket cast ~p,  State ~p", [Msg, State]),
    {noreply, State}.
handle_info(Info, State) ->
    ?LOG_DEBUG("got unknown on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_ERROR("Terminating secrets ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

make_keypair() ->
    #{public := Pub, secret := Priv} = enacl:sign_keypair(),
    PubBin = aeser_api_encoder:encode(account_pubkey, Pub),
    PubStr = unicode:characters_to_list(PubBin),
    #{public_key => PubStr, private_key => Priv}.
node_keypair() ->
    Path = application:get_env(damage, keystore, "damage.key"),
    case file:read_file(Path) of
        {error, enoent} ->
            ?LOG_INFO("damage.key not found ... creating.", []),
            Data = make_keypair(),
            EncData = secrets:encrypt(
                node_passphrase,
                "Damage Node Password (used to encrypt keys stored on disk)",
                Data
            ),
            ok = file:write_file(Path, EncData),
            Data;
        {ok, EncData} ->
            Data = secrets:decrypt(
                node_passphrase,
                "Damage Node Password (used to decrypt keys stored on disk)",
                EncData
            ),
            #{public_key := _Pub, private_key := _Priv} = Data
    end.
%% Generates a random salt
random_bytes(N) -> crypto:strong_rand_bytes(N).

%% Derives a key from a password and salt using PBKDF2
derive_key(Password, Salt) ->
    hkdf(Salt, Password, <<"AES-KEY">>, 32).

encrypt(Key, Password, PlainText) ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, {encrypt, Key, Password, PlainText}, ?ASKPASS_TIMEOUT).

%% Encrypts data with a password
encrypt(Password, PlainText) ->
    Salt = random_bytes(?SALT_SIZE),
    IV = random_bytes(?IV_SIZE),
    Key = derive_key(Password, Salt),
    {CipherText, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, PlainText, <<>>, true),
    {Salt, IV, Tag, CipherText}.

decrypt(Key, Password, CipherText) ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, {decrypt, Key, Password, CipherText}, ?ASKPASS_TIMEOUT).
%% Decrypts data with a password
decrypt(Password, {Salt, IV, Tag, CipherText}) ->
    Key = derive_key(Password, Salt),
    AAD = <<>>,
    crypto:crypto_one_time_aead(
        aes_256_gcm,
        Key,
        IV,
        CipherText,
        AAD,
        Tag,
        false
    ).

%% Changes the password by decrypting and re-encrypting with a new password
change_password(OldPassword, NewPassword, EncryptedData) ->
    PlainText = decrypt(OldPassword, EncryptedData),
    encrypt(NewPassword, PlainText).

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
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    store_secret(Name, encrypt_secret(Secret, PrivateKey)).
retrieve_decrypt(Name) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
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
    #{public_key := AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    ?LOG_DEBUG("public_key ~p, private_key ~p", [AeAccount, PrivateKey]),
    Secret = "Secret something something",
    {IV, CipherText, Tag} =
        encrypt_secret(Secret, PrivateKey),
    Secret = decrypt_secret({IV, CipherText, Tag}, PrivateKey),
    StoredSecret = "store secre",
    encrypt_store(test, StoredSecret),
    StoredSecret = retrieve_decrypt(test).
migrate() ->
    {ok, Data} = file:read_file("damage.prod.key"),
    #{public_key := _Pub, private_key := _Priv} = binary_to_term(Data),
    EncData = secrets:encrypt(
        node_passphrase,
        "Damage Node Password (used to encrypt keys stored on disk)",
        binary_to_term(Data)
    ),
    ok = file:write_file("damage.key", EncData).
