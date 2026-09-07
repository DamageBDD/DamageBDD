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
    delete_secret/1,
    delete_secret/2,
    encrypt_secret/2,
    decrypt_secret/2,
    encrypt_store/2,
    encrypt_store/3,
    retrieve_decrypt/1,
    retrieve_decrypt/2,
    import/0,
    node_keypair/0,
    make_keypair/0,
    salted_hash/1,
    salted_hash/2,
    test/0,
    migrate/0,
    import_secret_key/2,
    list_secrets/0,
    get_node_password/0,
    interpolate_template/1
]).
-export([encrypt/1, encrypt/2, decrypt/1, decrypt/2, change_password/3]).
-export([encrypt/3, decrypt/3]).
-export([has_node_password/0, set_node_password/1, has_node_keypair/0]).
-import(damage_utils, [to_bin/1]).

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

    case ensure_boot_ready() of
        ok ->
            {ok, #{}};
        locked ->
            ?LOG_WARNING("Secrets started locked; unlock via /secrets/unlock", []),
            {ok, #{}};
        {error, Reason} ->
            ?LOG_ERROR("Secrets not initialized, refusing to boot: ~p", [Reason]),
            {stop, Reason}
    end.
ensure_boot_ready() ->
    case get_env_password() of
        {error, no_env_password} -> locked;
        {error, empty_env_password} -> locked;
        {ok, Pw} -> ensure_keypair_valid(Pw)
    end.
get_env_password() ->
    case os:getenv("DAMAGE_SECRET_KEY") of
        false ->
            {error, no_env_password};
        "" ->
            {error, empty_env_password};
        Pw when is_list(Pw) ->
            {ok, list_to_binary(Pw)};
        Pw when is_binary(Pw) ->
            {ok, Pw}
    end.

get_node_password() ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, get_node_password, ?ASKPASS_TIMEOUT).

get_node_password_cached(State) ->
    case maps:get(node_password, State, undefined) of
        undefined ->
            case get_env_password() of
                {ok, NodePassword} ->
                    {binary_to_list(NodePassword), State};
                {error, _} ->
                    {error, node_locked}
            end;
        NodePassword ->
            {NodePassword, State}
    end.
cache_node_password(undefined, State) ->
    maps:remove(node_password, State);
cache_node_password(Password, State) when is_binary(Password) ->
    cache_node_password(binary_to_list(Password), State);
cache_node_password(Password, State) ->
    maps:put(node_password, Password, State).

has_node_password() ->
    case get_env_password() of
        {ok, _} ->
            true;
        {error, _} ->
            Pid = gproc:lookup_local_name({?MODULE, secrets}),
            gen_server:call(Pid, has_node_password, ?ASKPASS_TIMEOUT)
    end.

set_node_password(Pw0) ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, {set_node_password, Pw0}, ?ASKPASS_TIMEOUT).

normalize_node_password(undefined) ->
    {error, password_required};
normalize_node_password(<<>>) ->
    {error, password_required};
normalize_node_password("") ->
    {error, password_required};
normalize_node_password(Pw) when is_binary(Pw) ->
    {ok, Pw};
normalize_node_password(Pw) when is_list(Pw) ->
    {ok, list_to_binary(Pw)};
normalize_node_password(_) ->
    {error, invalid_password}.

handle_call(has_node_password, _From, State) ->
    Has = maps:get(node_password, State, undefined) =/= undefined,
    {reply, Has, State};
handle_call({set_node_password, Pw0}, _From, State) ->
    case normalize_node_password(Pw0) of
        {error, _} = Error ->
            {reply, Error, State};
        {ok, Pw} ->
            case has_node_keypair() of
                false ->
                    {reply, ok, cache_node_password(Pw, State)};
                true ->
                    case ensure_keypair_valid(Pw) of
                        ok ->
                            {reply, ok, cache_node_password(Pw, State)};
                        {error, _} = Error ->
                            {reply, Error, State}
                    end
            end
    end;
handle_call(clear_cache, _From, State) ->
    {reply, ok, maps:remove(node_password, State)};
handle_call(get_node_password, _From, State0) ->
    case get_node_password_cached(State0) of
        {error, _} = Error ->
            {reply, Error, State0};
        {NodePassword, State} ->
            {reply, NodePassword, State}
    end;
handle_call({encrypt, _Key, Data}, _From, State0) ->
    %% Do not cache plaintext in the gen_server state.  The state also carries
    %% the node keypair/password after unlock, so keeping arbitrary plaintext
    %% here unnecessarily widens the blast radius of a process-state leak.
    case get_node_password_cached(State0) of
        {error, _} = Error ->
            {reply, Error, State0};
        {NodePassword, State} ->
            EncData = secrets:encrypt(list_to_binary(NodePassword), term_to_binary(Data)),
            {reply, {ok, term_to_binary(EncData)}, State}
    end;
handle_call({decrypt, _Key, EncData}, _From, State0) ->
    case get_node_password_cached(State0) of
        {error, _} = Error ->
            {reply, Error, State0};
        {NodePassword, State} ->
            Reply = decrypt_cached_payload(list_to_binary(NodePassword), EncData),
            {reply, Reply, State}
    end;
handle_call({encrypt, _Key, Password0, Data}, _From, State) ->
    %% Compatibility for encrypt/3.  The previous implementation sent this
    %% request shape but had no matching handle_call clause, causing plaintext
    %% to fall into the catch-all logger.
    case normalize_node_password(Password0) of
        {ok, Password} ->
            EncData = secrets:encrypt(Password, term_to_binary(Data)),
            {reply, {ok, term_to_binary(EncData)}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({decrypt, _Key, Password0, EncData}, _From, State) ->
    case normalize_node_password(Password0) of
        {ok, Password} ->
            {reply, decrypt_cached_payload(Password, EncData), State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(
    node_keypair,
    _From,
    #{public_key := AeAccount, private_key := PrivateKey} = State
) when is_binary(PrivateKey) ->
    {reply, #{public_key => to_bin(AeAccount), private_key => PrivateKey}, State};
handle_call(node_keypair, _From, State) ->
    Path = application:get_env(damage, keystore, "/var/lib/damage/damage.key"),
    case get_node_password_cached(State) of
        {error, Other} ->
            {reply, {error, Other}, State};
        {NodePassword, State} ->
            case keypair(Path, NodePassword) of
                #{public_key := AeAccount, private_key := PrivateKey} = KeyPair ->
                    {reply, #{public_key => AeAccount, private_key => PrivateKey},
                        maps:merge(KeyPair, State)};
                {error, _} = Error ->
                    {reply, Error, State}
            end
    end;
handle_call(Request, _From, State) ->
    %% Never log request payloads or State here: State may contain node_password
    %% and private_key, while malformed requests may themselves contain secrets.
    ?LOG_ERROR("secrets received unsupported call tag=~p", [request_tag(Request)]),
    {reply, {error, unsupported_call}, State}.
handle_cast(Msg, State) ->
    ?LOG_DEBUG("secrets received unsupported cast tag=~p", [request_tag(Msg)]),
    {noreply, State}.
handle_info(Info, State) ->
    ?LOG_DEBUG("secrets received unsupported info tag=~p", [request_tag(Info)]),
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_ERROR("Terminating secrets ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

request_tag(Term) when is_tuple(Term), tuple_size(Term) > 0 ->
    element(1, Term);
request_tag(Term) when is_atom(Term) ->
    Term;
request_tag(_Term) ->
    unknown.

decrypt_cached_payload(Password, EncData) ->
    try binary_to_term(EncData, [safe]) of
        CipherTuple ->
            case secrets:decrypt(Password, CipherTuple) of
                Data when is_binary(Data) ->
                    try binary_to_term(Data, [safe]) of
                        Decoded -> Decoded
                    catch
                        _:_ -> error
                    end;
                _ ->
                    error
            end
    catch
        _:_ -> error
    end.

make_keypair() ->
    #{public := Pub, secret := Priv} = enacl:sign_keypair(),
    PubBin = aeser_api_encoder:encode(account_pubkey, Pub),
    PubStr = unicode:characters_to_list(PubBin),
    #{public_key => PubStr, private_key => Priv}.
keypair(Path, NodePassword) ->
    case file:read_file(Path) of
        {error, enoent} ->
            ?LOG_INFO(Path ++ " not found ... creating.", []),
            Data = make_keypair(),
            EncData = secrets:encrypt(
                NodePassword,
                term_to_binary(Data)
            ),
            ok = file:write_file(Path, term_to_binary(EncData)),
            Data;
        {ok, EncDataBin} ->
            try
                secrets:decrypt(
                    NodePassword,
                    binary_to_term(EncDataBin)
                )
            of
                error ->
                    ?LOG_WARNING("Failed to unlock keypair ~p", [Path]),
                    {error, decrypt_keypair};
                Data when is_binary(Data) ->
                    try binary_to_term(Data) of
                        #{public_key := _, private_key := _} = KeyPair ->
                            KeyPair;
                        _ ->
                            {error, corrupt_keypair}
                    catch
                        _Class:_Reason:_Stack ->
                            {error, corrupt_keypair}
                    end;
                _ ->
                    {error, decrypt_keypair}
            catch
                Class:Reason:Stack ->
                    ?LOG_WARNING(
                        "Invalid keypair data ~p: ~p",
                        [Path, {Class, Reason, Stack}]
                    ),
                    {error, corrupt_keypair}
            end
    end.
node_keypair() ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, node_keypair, ?ASKPASS_TIMEOUT).
has_node_keypair() ->
    Path = application:get_env(damage, keystore, "/var/lib/damage/damage.key"),
    case file:read_file(Path) of
        {error, enoent} ->
            false;
        {ok, _EncDataBin} ->
            true
    end.
ensure_keypair_valid(NodePassword) ->
    Path = application:get_env(damage, keystore, "/var/lib/damage/damage.key"),
    case file:read_file(Path) of
        {ok, Enc} ->
            try secrets:decrypt(NodePassword, binary_to_term(Enc)) of
                error ->
                    {error, invalid_password};
                _ ->
                    ok
            catch
                _Class:_Reason:_Stack ->
                    {error, corrupt_keypair}
            end;
        _ ->
            {error, missing_keypair}
    end.
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

encrypt(#{public_key := _AeAccount, private_key := PrivateKey}, PlainText) ->
    base64:encode(term_to_binary(encrypt_secret(PlainText, PrivateKey)));
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
    decrypt(secrets:node_keypair(), Base64EncodedCipherTuple).

decrypt(Key, Password, CipherText) ->
    Pid = gproc:lookup_local_name({?MODULE, secrets}),
    gen_server:call(Pid, {decrypt, Key, Password, CipherText}, ?ASKPASS_TIMEOUT).
%% Decrypts data with a password
decrypt(#{public_key := _AeAccount, private_key := PrivateKey}, Base64EncodedCipherTuple) ->
    case base64:decode(Base64EncodedCipherTuple) of
        Term when is_binary(Term) ->
            decrypt_secret(binary_to_term(Term), PrivateKey);
        _ ->
            error
    end;
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
%% Store encrypted secret in dets.  Keep the storage primitive generic so
%% legacy v1 envelopes and scoped v2 envelopes can coexist during migration.
store_secret(Name, Encrypted) ->
    {ok, ?DETS_FILE} = dets:open_file(?DETS_FILE, ?DETS_ARGS),
    dets:insert(?DETS_FILE, {Name, Encrypted}).

%% Retrieve encrypted secret from dets
retrieve_secret(Name) ->
    dets:open_file(?DETS_FILE, ?DETS_ARGS),
    dets:lookup(?DETS_FILE, Name).

%% Delete encrypted secret from dets by key
delete_secret(Name) ->
    {ok, ?DETS_FILE} = dets:open_file(?DETS_FILE, ?DETS_ARGS),
    case dets:delete(?DETS_FILE, Name) of
        ok -> dets:sync(?DETS_FILE);
        {error, _} = Error -> Error
    end.

%% Scoped deletion.  BDD/account-facing code should use this form.
delete_secret(Scope, Name) ->
    delete_secret(scoped_storage_key(Scope, Name)).

encrypt_store({Name, Secret}) ->
    encrypt_store(Name, Secret).


%% Legacy node-global storage.  Retained for trusted node integrations only.
encrypt_store(Name, Secret) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    store_secret(Name, encrypt_secret(Secret, PrivateKey)).

%% Account/scope isolated storage.  New user-derived secrets must use this API.
encrypt_store(Scope, Name, Secret) ->
    #{public_key := _AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    StorageKey = scoped_storage_key(Scope, Name),
    AAD = scoped_secret_aad(StorageKey),
    store_secret(StorageKey, encrypt_scoped_secret(Secret, PrivateKey, AAD)).

retrieve_decrypt(Name) ->
    try secrets:node_keypair() of
        #{public_key := _AeAccount, private_key := PrivateKey} ->
            try retrieve_secret(Name) of
                [{Name, {IV, CipherText, Tag}}] ->
                    {ok, decrypt_secret({IV, CipherText, Tag}, PrivateKey)};
                _ ->
                    error
            catch
                _Class:_Reason:_Stack ->
                    error
            end;
        _ ->
            error
    catch
        _Class:_Reason:_Stack ->
            error
    end.

%% Scope + name are authenticated as AES-GCM AAD and also feed the derived key.
%% Moving a DETS record to a different account/name therefore fails decryption.
retrieve_decrypt(Scope, Name) ->
    try secrets:node_keypair() of
        #{public_key := _AeAccount, private_key := PrivateKey} ->
            StorageKey = scoped_storage_key(Scope, Name),
            AAD = scoped_secret_aad(StorageKey),
            case retrieve_secret(StorageKey) of
                [{StorageKey, {v2, IV, CipherText, Tag}}] ->
                    case decrypt_scoped_secret({v2, IV, CipherText, Tag}, PrivateKey, AAD) of
                        error -> error;
                        Value -> {ok, Value}
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    catch
        _Class:_Reason:_Stack ->
            error
    end.

scoped_storage_key(Scope0, Name0) ->
    {Kind, Owner, Id} = normalize_secret_scope(Scope0),
    Name = normalize_secret_name(Name0),
    {damage_secret, 2, Kind, Owner, Id, Name}.

normalize_secret_scope(node) ->
    {node, <<"node">>, <<"default">>};
normalize_secret_scope({account, Owner}) ->
    {account, to_bin(Owner), <<"default">>};
normalize_secret_scope({wallet, Owner, Id}) ->
    {wallet, to_bin(Owner), to_bin(Id)};
normalize_secret_scope({agent, Owner, Id}) ->
    {agent, to_bin(Owner), to_bin(Id)};
normalize_secret_scope(#{kind := Kind, owner := Owner} = Scope) when
    Kind =:= account; Kind =:= wallet; Kind =:= agent
->
    {Kind, to_bin(Owner), to_bin(maps:get(id, Scope, <<"default">>))};
normalize_secret_scope(Other) ->
    error({invalid_secret_scope, Other}).

normalize_secret_name(Name) when is_binary(Name) -> Name;
normalize_secret_name(Name) when is_list(Name) -> unicode:characters_to_binary(Name);
normalize_secret_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
normalize_secret_name(Name) -> to_bin(Name).

scoped_secret_aad(StorageKey) ->
    term_to_binary({damagebdd_secret_scope_v2, StorageKey}).

encrypt_scoped_secret(Secret, PrivateKey, AAD) ->
    AESKey = derive_scoped_aes_key(PrivateKey, AAD),
    IV = crypto:strong_rand_bytes(?IV_SIZE),
    PlainText = term_to_binary(Secret),
    {CipherText, Tag} =
        crypto:crypto_one_time_aead(aes_256_gcm, AESKey, IV, PlainText, AAD, true),
    {v2, IV, CipherText, Tag}.

decrypt_scoped_secret({v2, IV, CipherText, Tag}, PrivateKey, AAD) ->
    AESKey = derive_scoped_aes_key(PrivateKey, AAD),
    case crypto:crypto_one_time_aead(aes_256_gcm, AESKey, IV, CipherText, AAD, Tag, false) of
        error ->
            error;
        PlainText when is_binary(PlainText) ->
            try binary_to_term(PlainText, [safe]) of
                Secret -> Secret
            catch
                _:_ -> error
            end
    end.

derive_scoped_aes_key(PrivateKey, AAD) ->
    ScopeSalt = crypto:hash(sha256, AAD),
    hkdf(ScopeSalt, PrivateKey, <<"damagebdd:scoped-secret:v2">>, 32).

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
    try erm_askpass:ask_password(Prompt) of
        Password when is_binary(Password) ->
            EncData = secrets:encrypt(
                Password,
                term_to_binary(Keypair)
            ),
            ok = file:write_file(Path, term_to_binary(EncData)),
            Keypair
    catch
        _ExceptionClass:{ask_password_failed, Class, Reason}:_Stack ->
            ?LOG_WARNING("Failed to get node_password ~p, Reason ~p", [Class, Reason]),
            error;
        Class:Reason:Stack ->
            ?LOG_WARNING(
                "Failed to get node_password ~p, Reason ~p",
                [Class, {Reason, Stack}]
            ),
            error
    end.

test() ->
    #{public_key := AeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    ?LOG_DEBUG("secrets test using public_key ~p", [AeAccount]),
    Secret = "Secret something something",
    {IV, CipherText, Tag} =
        encrypt_secret(Secret, PrivateKey),
    Secret = binary_to_list(decrypt_secret({IV, CipherText, Tag}, PrivateKey)),
    StoredSecret = <<"store secre">>,
    encrypt_store(test, StoredSecret),
    {ok, StoredSecret} = retrieve_decrypt(test).

migrate() ->
    {ok, Data} = file:read_file("damage.prod.key"),
    Path = application:get_env(damage, keystore, "damage.key"),
    Keypair = binary_to_term(Data),
    Prompt = "Damage Node Password (used to encrypt keys stored on disk)",
    try erm_askpass:ask_password(Prompt) of
        Password when is_binary(Password) ->
            EncData = secrets:encrypt(
                Password,
                term_to_binary(Keypair)
            ),
            ok = file:write_file(Path, term_to_binary(EncData)),
            Keypair
    catch
        _ExceptionClass:{ask_password_failed, Class, Reason}:_Stack ->
            ?LOG_WARNING("Failed to get node_password ~p, Reason ~p", [Class, Reason]),
            error;
        Class:Reason:Stack ->
            ?LOG_WARNING(
                "Failed to get node_password ~p, Reason ~p",
                [Class, {Reason, Stack}]
            ),
            error
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
                            case retrieve_legacy_template_secret(Key) of
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

retrieve_legacy_template_secret(Key0) ->
    KeyBin = unicode:characters_to_binary(Key0),
    case retrieve_decrypt(KeyBin) of
        {ok, _} = Ok ->
            Ok;
        error ->
            %% Compatibility for old DETS rows keyed by existing atoms only.
            %% Never create atoms from template-controlled strings.
            try binary_to_existing_atom(KeyBin, utf8) of
                KeyAtom -> retrieve_decrypt(KeyAtom)
            catch
                _:_ -> error
            end
    end.
