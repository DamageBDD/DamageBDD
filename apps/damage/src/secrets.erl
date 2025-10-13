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
    keypair/1,
    node_keypair/0,
    make_keypair/0,
    salted_hash/1,
    salted_hash/2,
    test/0,
    migrate/0,
    import_secret_key/2,
    list_secrets/0,
    interpolate_template/1
]).
-export([encrypt/1, encrypt/2, decrypt/1, decrypt/2, change_password/3]).
-export([encrypt/3, decrypt/3]).
-export([has_node_password/0, set_node_password/1]).

-define(ASKPASS_TIMEOUT, 60000).
-define(DETS_FILE, "/var/lib/damage/damage.dets").
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

clear_cache() ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, clear_cache, ?ASKPASS_TIMEOUT).
get_node_password() ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, get_node_password, ?ASKPASS_TIMEOUT).
get_node_password_cached(State) ->
    Prompt = "Damage Node Password (used to encrypt keys stored on disk)",
    case maps:get(node_password, State, undefined) of
        undefined ->
            case os:getenv("DAMAGE_SECRET_KEY") of
                false ->
                    case erm_askpass:ask_password(Prompt) of
                        undefined ->
                            error;
                        NodePassword ->
                            {NodePassword, maps:put(node_password, NodePassword, State)}
                    end;
                NodePassword ->
                    {NodePassword, State}
            end;
        NodePassword ->
            {NodePassword, State}
    end.
has_node_password() ->
    case os:getenv("DAMAGE_SECRET_KEY") of
        false ->
            Pid = gproc:lookup_local_name({?MODULE, secrets}),
            gen_server:call(Pid, has_node_password, ?ASKPASS_TIMEOUT);
        _ ->
            true
    end.
set_node_password(Pw0) when is_list(Pw0); is_binary(Pw0) ->
    case has_node_password() of
        true ->
            {error, already_set};
        false ->
            Pw =
                case Pw0 of
                    B when is_binary(B) -> unicode:characters_to_list(B);
                    L when is_list(L) -> L
                end,
            case length(Pw) >= 8 of
                false ->
                    {error, too_short};
                true ->
                    Pid = gproc:lookup_local_name({?MODULE, secrets}),
                    gen_server:call(Pid, {set_node_password, Pw}, ?ASKPASS_TIMEOUT)
            end
    end.
handle_call(has_node_password, _From, State) ->
    Has = maps:get(node_password, State, undefined) =/= undefined,
    {reply, Has, State};
handle_call({set_node_password, Pw}, _From, State0) ->
    case maps:get(node_password, State0, undefined) of
        undefined ->
            {reply, ok, maps:put(node_password, Pw, State0)};
        _Existing ->
            {reply, {error, already_set}, State0}
    end;
handle_call(clear_cache, _From, State) ->
    {reply, ok, maps:remove(node_password, State)};
handle_call(get_node_password, _From, State0) ->
    {NodePassword, State} = get_node_password_cached(State0),
    {reply, NodePassword, State};
handle_call({encrypt, Key, Data}, _From, State0) ->
    {NodePassword, State} = get_node_password_cached(State0),
    case maps:get(Key, State, undefined) of
        undefined ->
            EncData = secrets:encrypt(
                list_to_binary(NodePassword), term_to_binary(Data)
            ),
            {reply, {ok, term_to_binary(EncData)}, maps:put(Key, Data, State)};
        Password ->
            Password
    end;
handle_call({decrypt, Key, EncData}, _From, State0) ->
    {NodePassword, State} = get_node_password_cached(State0),
    case maps:get(Key, State, undefined) of
        undefined ->
            case secrets:decrypt(list_to_binary(NodePassword), binary_to_term(EncData)) of
                Data when is_binary(Data) ->
                    DecryptedData = binary_to_term(Data),
                    {reply, DecryptedData, maps:put(Key, DecryptedData, State)};
                _ ->
                    {reply, error, State}
            end;
        Pass ->
            Pass
    end;
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
keypair(Path) ->
    case file:read_file(Path) of
        {error, enoent} ->
            ?LOG_INFO(Path ++ " not found ... creating.", []),
            Data = make_keypair(),
            case get_node_password() of
                undefined ->
                    ?LOG_WARNING("Failed get password for encrypting keypair ~p", [Path]),
                    %clear_cache(),
                    %keypair(Path);
                    error;
                Password ->
                    EncData = secrets:encrypt(
                        Password,
                        term_to_binary(Data)
                    ),
                    ok = file:write_file(Path, term_to_binary(EncData)),
                    Data
            end;
        {ok, EncDataBin} ->
            case get_node_password() of
                undefined ->
                    ?LOG_WARNING("Failed get password for decrypting keypair ~p", [Path]),
                    clear_cache(),
                    keypair(Path);
                Password ->
                    case
                        secrets:decrypt(
                            Password,
                            binary_to_term(EncDataBin)
                        )
                    of
                        error ->
                            ?LOG_WARNING("Failed to unlock keypair ~p", [Path]),
                            clear_cache(),
                            keypair(Path);
                        Data ->
                            binary_to_term(Data)
                    end
            end
    end.
node_keypair() ->
    Path = application:get_env(damage, keystore, "/var/lib/damage/damage.key"),
    ?LOG_INFO("Damage key path ~p", [Path]),
    keypair(Path).
%% Generates a random salt
random_bytes(N) -> crypto:strong_rand_bytes(N).

%% Derives a key from a password and salt using PBKDF2
derive_key(Password, Salt) ->
    hkdf(Salt, Password, <<"AES-KEY">>, 32).

encrypt(PlainText) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    base64:encode(term_to_binary(encrypt_secret(PlainText, PrivateKey))).
encrypt(Key, Password, PlainText) ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, {encrypt, Key, Password, PlainText}, ?ASKPASS_TIMEOUT).

%% Encrypts data with a password
encrypt(Password, PlainText) when is_list(Password) ->
    encrypt(list_to_binary(Password), PlainText);
encrypt(Password, PlainText) ->
    Salt = random_bytes(?SALT_SIZE),
    IV = random_bytes(?IV_SIZE),
    Key = derive_key(Password, Salt),
    {CipherText, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, PlainText, <<>>, true),
    {Salt, IV, Tag, CipherText}.

decrypt(null) ->
    error;
decrypt(Base64EncodedCipherTuple) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    case base64:decode(Base64EncodedCipherTuple) of
        Term when is_binary(Term) ->
            decrypt_secret(binary_to_term(Term), PrivateKey);
        _ ->
            error
    end.

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
    case catch secrets:node_keypair() of
        #{public_key := _AeAccount, private_key := PrivateKey} ->
            case catch retrieve_secret(Name) of
                [{Name, {IV, CipherText, Tag}}] ->
                    {ok, decrypt_secret({IV, CipherText, Tag}, PrivateKey)};
                _ ->
                    error
            end;
        _ ->
            error
    end.

salted_hash(BinaryData) when is_binary(BinaryData) ->
    case secrets:node_keypair() of
        #{public_key := _AeAccount, private_key := PrivateKey} ->
            base64:encode(crypto:mac(hmac, sha256, PrivateKey, BinaryData));
        _ ->
            error
    end.
salted_hash(BinarySalt, BinaryData) when is_binary(BinaryData) and is_binary(BinarySalt) ->
    base64:encode(crypto:mac(hmac, sha256, BinarySalt, BinaryData)).

import() ->
    case file:consult("damage.plain") of
        {ok, Terms} ->
            lists:map(fun encrypt_store/1, Terms);
        {error, enoent} ->
            ?LOG_ERROR("no damage.plain found ", []);
        Error ->
            ?LOG_ERROR("no damage.plain found ~p", [Error])
    end.
import_secret_key(PublicKey, PrivateKeyHex) ->
    Path = "damage.key.imported",
    PrivateKey = binary:decode_hex(PrivateKeyHex),
    Keypair = #{private_key => PrivateKey, public_key => PublicKey},
    Prompt = "Damage Node Password (used to encrypt keys stored on disk)",
    case erm_askpass:ask_password(Prompt) of
        undefined ->
            ?LOG_WARNING("Failed to get node_password", []),
            error;
        Password ->
            EncData = secrets:encrypt(
                Password,
                term_to_binary(Keypair)
            ),
            ok = file:write_file(Path, term_to_binary(EncData)),
            Keypair
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
    Path = application:get_env(damage, keystore, "damage.key"),
    Keypair = binary_to_term(Data),
    Prompt = "Damage Node Password (used to encrypt keys stored on disk)",
    case erm_askpass:ask_password(Prompt) of
        undefined ->
            ?LOG_WARNING("Failed to get node_password", []),
            error;
        Password ->
            EncData = secrets:encrypt(
                Password,
                term_to_binary(Keypair)
            ),
            ok = file:write_file(Path, term_to_binary(EncData)),
            Keypair
    end.

list_secrets() ->
    case dets:open_file(?DETS_FILE, ?DETS_ARGS) of
        {ok, _} ->
            Keys = dets:foldl(fun({Key, _}, Acc) -> [Key | Acc] end, [], ?DETS_FILE),
            dets:close(?DETS_FILE),
            lists:reverse(Keys);
        {error, Reason} ->
            ?LOG_ERROR("Failed to open secrets DETS: ~p", [Reason]),
            []
    end.
interpolate_template(Template) when is_binary(Template) ->
    interpolate_template(binary_to_list(Template));
interpolate_template(Template) when is_list(Template) ->
    %% Match all {{key}} patterns
    Pattern = "\\{\\{([^}]+)\\}\\}",
    case re:run(Template, Pattern, [{capture, all_but_first, list}, global]) of
        {match, Matches} ->
            lists:flatten(
                lists:foldl(
                    fun([Key], Acc) ->
                        Replacement =
                            case retrieve_decrypt(list_to_atom(Key)) of
                                {ok, Value} when is_binary(Value) -> binary_to_list(Value);
                                {ok, Value} -> io_lib:format("~p", [Value]);
                                error -> "<<missing:" ++ Key ++ ">>"
                            end,
                        string:replace(Acc, "{{" ++ Key ++ "}}", Replacement, all)
                    end,
                    Template,
                    Matches
                )
            );
        nomatch ->
            Template
    end.
