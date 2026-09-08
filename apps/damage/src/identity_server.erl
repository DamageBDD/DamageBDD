-module(identity_server).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get_account/1,
    clear_cache/0,
    clear_cache/1,
    reload_account/1,
    register_email/2,
    register_npub/1,
    register_lightning/1,
    set_email_password/2,
    get_account_by_email/1,
    get_account_by_npub/1,
    get_account_by_lightning/1,
    get_access_token/1,
    verify_access_token/1,
    deploy_contracts/0,
    test/0,
    test_email_contract/0
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(EMAIL_REGISTRY_CONTRACT,
    % staging "ct_9arW6cnYKGoioHceaJ3v9rBWXpVXYP6VjKD19JEa5FosFGPBo"
    "ct_BJi1Lg4JmpPZqY5Pt1JB4PoRiTNphMvkuxTzCk2kNLimKMHvB"
).
-define(NPUB_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).

-define(LIGHTNING_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).
%%% =========================
%%% PUBLIC API
%%% =========================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_account(AeAccount) ->
    gen_server:call(
        ?MODULE,
        {get_account, normalize_identity_key(AeAccount)},
        ?AE_TIMEOUT
    ).

clear_cache() ->
    gen_server:call(?MODULE, clear_cache, ?AE_TIMEOUT).

clear_cache(Key) ->
    gen_server:call(
        ?MODULE,
        {clear_cache, normalize_identity_key(Key)},
        ?AE_TIMEOUT
    ).

reload_account(AeAccount) ->
    gen_server:call(
        ?MODULE,
        {reload_account, normalize_identity_key(AeAccount)},
        ?AE_TIMEOUT
    ).

register_email(Email, Password) ->
    #{public_key := PubKey, private_key := PrivateKey} = secrets:make_keypair(),
    case
        gen_server:call(
            ?MODULE, {register_email, Email, PubKey, Password, PrivateKey}, ?AE_TIMEOUT
        )
    of
        #{"return_type" := "ok", "return_value" := {}} ->
            {ok, <<"Email confirmed and password set.">>, PubKey, PrivateKey};
        #{"return_type" := "ok", "return_value" := true} ->
            {ok, <<"Email confirmed and password set.">>, PubKey, PrivateKey};
        #{"return_type" := _, "return_value" := Other} ->
            {error, Other}
    end.
set_email_password(Email, Password) ->
    case gen_server:call(?MODULE, {set_email_password, Email, Password}) of
        #{"return_type" := "ok", "return_value" := {}} ->
            {ok, <<"Password set.">>};
        #{"return_type" := _, "return_value" := Other} ->
            {error, Other};
        {error, Reason} ->
            {error, Reason}
    end.

register_npub(Npub) ->
    gen_server:call(?MODULE, {register_npub, Npub}, ?AE_TIMEOUT).

register_lightning(AuthKey) ->
    gen_server:call(?MODULE, {register_lightning, AuthKey}, ?AE_TIMEOUT).

get_account_by_email(Email) ->
    gen_server:call(?MODULE, {get_account_by_email, Email}, ?AE_TIMEOUT).

get_account_by_npub(Npub) ->
    gen_server:call(?MODULE, {get_account_by_npub, Npub}, ?AE_TIMEOUT).

get_account_by_lightning(AuthKey) ->
    gen_server:call(?MODULE, {get_account_by_lightning, AuthKey}, ?AE_TIMEOUT).

get_access_token(AeAccount) ->
    AeAccount.
verify_access_token(Token) ->
    Token.
get_email_registry_contract() ->
    application:get_env(damage, email_registry_ct, ?EMAIL_REGISTRY_CONTRACT).
get_npub_registry_contract() ->
    application:get_env(damage, npub_registry_ct, ?NPUB_REGISTRY_CONTRACT).
get_lightning_registry_contract() ->
    application:get_env(damage, npub_registry_ct, ?LIGHTNING_REGISTRY_CONTRACT).
%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    Table = ets:new(identity_cache, [named_table, set, private]),
    {ok, #{ets_table => Table}}.

handle_call(clear_cache, _From, #{ets_table := Table} = State) ->
    true = ets:delete_all_objects(Table),
    {reply, ok, State};
handle_call({clear_cache, Key}, _From, #{ets_table := Table} = State) ->
    ok = evict_identity_cache(Table, Key),
    {reply, ok, State};
handle_call({reload_account, PublicKey}, _From, #{ets_table := Table} = State) ->
    ok = evict_identity_cache(Table, PublicKey),
    case load_account_from_contract(PublicKey) of
        {ok, Account} ->
            true = ets:insert(Table, {PublicKey, Account}),
            {reply, Account, State};
        notfound ->
            {reply, notfound, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({get_account, PublicKey}, _From, #{ets_table := Table} = State) ->
    case ets:lookup(Table, PublicKey) of
        [{PublicKey, Account}] ->
            {reply, Account, State};
        [] ->
            case load_account_from_contract(PublicKey) of
                {ok, Account} ->
                    true = ets:insert(Table, {PublicKey, Account}),

                    {reply, Account, State};
                notfound ->
                    {reply, notfound, State};
                {error, Reason} ->
                    ?LOG_WARNING(
                        "Identity account load failed account=~p reason=~p",
                        [PublicKey, Reason]
                    ),
                    %% Preserve the historical get_account/1 return contract.
                    {reply, notfound, State}
            end
    end;
handle_call({register_email, Email, PublicKey, Password, PrivateKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        get_email_registry_contract(),
        damage_ae:contract_path(damage, "contracts/email_registry.aes"),
        % TODO update contract
        ?AE_INITIAL_AETTOS + 1,
        "register_email",
        [
            ?DAMAGE_TOKEN_CONTRACT,
            binary_to_list(secrets:salted_hash(Email)),
            PublicKey,
            binary_to_list(
                secrets:encrypt_bound(
                    {identity, normalize_identity_key(PublicKey), password},
                    secrets:salted_hash(Password)
                )
            ),
            binary_to_list(
                secrets:encrypt_bound(
                    {identity, normalize_identity_key(PublicKey), private_key},
                    PrivateKey
                )
            ),
            ?DAMAGE_INITIAL_HITS,
            ?AE_INITIAL_AETTOS
        ]
    ),
    {reply, Response, State};
handle_call({get_account_by_email, Email}, _From, #{ets_table := Table} = State) ->
    case ets:lookup(Table, Email) of
        [{Email, Account}] ->
            ?LOG_DEBUG("Identity cache hit key=~p", [normalize_identity_key(Email)]),
            {reply, Account, State};
        [] ->
            KeyPair = secrets:node_keypair(),
            case
                damage_ae:contract_query(
                    KeyPair,
                    get_email_registry_contract(),
                    damage_ae:contract_path(damage, "contracts/email_registry.aes"),
                    "get_account",
                    [
                        binary_to_list(secrets:salted_hash(Email))
                    ]
                )
            of
                #{"return_value" := #{email := _Email, meta := Meta}} ->
                    Response = #{email => Email, meta => safe_decrypted_term(Meta)},
                    {reply, Response, State};
                #{
                    "return_type" := "ok",
                    "return_value" :=
                        {
                            {address, AddressData}, PrivateKeyEncrypted, PasswordEncrypted
                        }
                } ->
                    Address = aeser_api_encoder:encode(account_pubkey, AddressData),
                    Password = decrypt_identity_field(Address, password, PasswordEncrypted),
                    PrivateKey = decrypt_identity_field(Address, private_key, PrivateKeyEncrypted),
                    Account = {Address, Password, PrivateKey},
                    CanonicalAccount = #{
                        public_key => Address,
                        password => Password,
                        private_key => PrivateKey
                    },
                    true = ets:insert(Table, {Email, Account}),
                    true = ets:insert(Table, {Address, CanonicalAccount}),

                    {reply, Account, State};
                #{
                    "return_type" := "revert",
                    "return_value" := <<"Email not registered.">>
                } ->
                    ?LOG_DEBUG("Email not registered", []),
                    {reply, notfound, State};
                Other ->
                    ?LOG_DEBUG("Unexpected response ~p", [Other]),
                    {reply, notfound, State}
            end
    end;
handle_call({set_email_password, Email, Password}, _From, #{ets_table := Table} = State) ->
    KeyPair = secrets:node_keypair(),
    Response =
        case identity_public_key_by_email(KeyPair, Email) of
            {ok, PublicKey} ->
                damage_ae:contract_call(
                    KeyPair,
                    get_email_registry_contract(),
                    damage_ae:contract_path(damage, "contracts/email_registry.aes"),
                    "set_password",
                    [
                        binary_to_list(secrets:salted_hash(Email)),
                        binary_to_list(
                            secrets:encrypt_bound(
                                {identity, PublicKey, password},
                                Password
                            )
                        )
                    ]
                );
            {error, Reason} ->
                {error, {identity_lookup_failed, Reason}}
        end,

    ets:delete(Table, Email),
    {reply, Response, State};
handle_call({register_npub, Npub, PublicKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        get_npub_registry_contract(),
        damage_ae:contract_path(damage, "contracts/nostr_registry.aes"),
        "register_npub",
        [
            get_email_registry_contract(),
            binary_to_list(secrets:salted_hash(Npub)),
            PublicKey
        ]
    ),
    {reply, Response, State};
handle_call({register_lightning, AuthKey, PublicKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        get_npub_registry_contract(),
        damage_ae:contract_path(damage, "contracts/lightning_registry.aes"),
        "register_lightning",
        [
            get_email_registry_contract(),
            binary_to_list(secrets:salted_hash(AuthKey)),
            PublicKey
        ]
    ),
    {reply, Response, State};
handle_call({get_account_by_npub, Npub}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_query(
            KeyPair,
            get_npub_registry_contract(),
            damage_ae:contract_path(damage, "contracts/npub_registry.aes"),
            "get_account",
            [
                get_email_registry_contract(),
                binary_to_list(secrets:salted_hash(Npub))
            ]
        ),
    {reply, Response, State};
handle_call({get_account_by_lightning, AuthKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_query(
            KeyPair,
            get_lightning_registry_contract(),
            damage_ae:contract_path(damage, "contracts/lightning_registry.aes"),
            "get_account",
            [
                get_email_registry_contract(),
                binary_to_list(secrets:salted_hash(AuthKey))
            ]
        ),
    {reply, Response, State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

%%% =========================
%%% HELPER FUNCTIONS
%%% =========================
load_account_from_contract(PublicKey) ->
    try
        damage_ae:contract_query(
            get_email_registry_contract(),
            damage_ae:contract_path(damage, "contracts/email_registry.aes"),
            "get_email",
            [PublicKey]
        )
    of
        #{
            "return_type" := "ok",
            "return_value" :=
                {{address, AddressData}, PrivateKeyEncrypted, PasswordEncrypted}
        } ->
            Address = aeser_api_encoder:encode(account_pubkey, AddressData),
            case normalize_identity_key(Address) =:= PublicKey of
                true ->
                    {ok, #{
                        public_key => PublicKey,
                        password => decrypt_identity_field(
                            PublicKey, password, PasswordEncrypted
                        ),
                        private_key => decrypt_identity_field(
                            PublicKey, private_key, PrivateKeyEncrypted
                        )
                    }};
                false ->
                    {error, {identity_account_mismatch, PublicKey, Address}}
            end;
        #{"return_type" := "revert"} ->
            notfound;
        Other ->
            {error, {unexpected_identity_contract_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {identity_contract_read_failed, Class, Reason, Stacktrace}}
    end.

decrypt_identity_field(PublicKey0, Field, CipherText) ->
    PublicKey = normalize_identity_key(PublicKey0),
    case secrets:decrypt_bound({identity, PublicKey, Field}, CipherText) of
        error ->
            %% Legacy compatibility for accounts created before bound envelopes.
            %% New registrations and password changes always write bound data.
            ?LOG_WARNING(
                "Using legacy unbound identity ciphertext account=~p field=~p; migrate this account",
                [PublicKey, Field]
            ),
            secrets:decrypt(CipherText);
        Value ->
            Value
    end.

identity_public_key_by_email(KeyPair, Email) ->
    case damage_ae:contract_query(
        KeyPair,
        get_email_registry_contract(),
        damage_ae:contract_path(damage, "contracts/email_registry.aes"),
        "get_account",
        [binary_to_list(secrets:salted_hash(Email))]
    ) of
        #{
            "return_type" := "ok",
            "return_value" := {{address, AddressData}, _PrivateKeyEncrypted, _PasswordEncrypted}
        } ->
            {ok, normalize_identity_key(aeser_api_encoder:encode(account_pubkey, AddressData))};
        #{"return_type" := "revert", "return_value" := Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_identity_contract_result, Other}}
    end.

safe_decrypted_term(CipherText) ->
    case secrets:decrypt(CipherText) of
        Plain when is_binary(Plain) ->
            try binary_to_term(Plain, [safe]) of
                Term -> Term
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

evict_identity_cache(Table, IdentityKey) ->
    true = ets:delete(Table, IdentityKey),
    lists:foreach(
        fun({CacheKey, CachedValue}) ->
            case cached_identity_account(CachedValue) of
                IdentityKey ->
                    true = ets:delete(Table, CacheKey);
                _ ->
                    ok
            end
        end,
        ets:tab2list(Table)
    ),
    ok.

cached_identity_account(#{public_key := Account}) ->
    normalize_identity_key(Account);
cached_identity_account({Account, _Password, _PrivateKey}) ->
    normalize_identity_key(Account);
cached_identity_account(_) ->
    undefined.

normalize_identity_key(Value) when is_binary(Value) -> Value;
normalize_identity_key(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_identity_key(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_identity_key(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).

deploy_contracts() ->
    #{
        "contract_id" :=
            EmailContractId,
        "return_type" := "ok"
    } = damage_ae:contract_deploy(
        damage_ae:contract_path(damage, "contracts/email_registry.aes"), []
    ),
    ?LOG_INFO("email_registry contract id ~p", [EmailContractId]),
    #{
        "contract_id" :=
            NostrContractId,
        "return_type" := "ok"
    } = damage_ae:contract_deploy(
        damage_ae:contract_path(damage, "contracts/nostr_registry.aes"), []
    ),
    ?LOG_INFO("nostr_registry contract id ~p", [NostrContractId]),
    #{
        "contract_id" :=
            LightningContractId,
        "return_type" := "ok"
    } = damage_ae:contract_deploy(
        damage_ae:contract_path(damage, "contracts/lightning_registry.aes"), []
    ),
    ?LOG_INFO("lightning_registry contract id ~p", [LightningContractId]).

test() ->
    Email = <<"test@gmail.com">>,
    Password = <<"testpass">>,
    Res = register_email(Email, Password),
    ?LOG_INFO("register result ~p", [Res]),
    {_PubKey, Password, _PrivateKey} = Res0 = get_account_by_email(Email),
    ?LOG_INFO("lookup result account=~p", [cached_identity_account(Res0)]).

test_email_contract() ->
    #{public_key := PublicKey, private_key := PrivateKey} = secrets:make_keypair(),
    ?LOG_DEBUG("New key pair created public_key=~p", [PublicKey]),
    Email = <<"steven@damagebdd.com">>,
    Password = <<"testpassword">>,
    #{
        "caller_id" := _Caller,
        "caller_nonce" := _Nonce,
        "contract_id" :=
            ContractId,
        "gas_price" := _,
        "gas_used" := _,
        "height" := _,
        "log" := [],
        "return_type" := "ok",
        "return_value" := none
    } = damage_ae:contract_deploy(
        damage_ae:contract_path(damage, "contracts/email_registry.aes"), []
    ),
    KeyPair = secrets:node_keypair(),
    ?LOG_DEBUG("contract account ~p", [ContractId]),
    Args = [
        ?DAMAGE_TOKEN_CONTRACT,
        binary_to_list(secrets:salted_hash(Email)),
        PublicKey,
        binary_to_list(secrets:encrypt_bound({identity, PublicKey, password}, Password)),
        binary_to_list(secrets:encrypt_bound({identity, PublicKey, private_key}, PrivateKey)),
        100000000,
        1000
    ],
    ?LOG_DEBUG("contract call prepared for account=~p", [PublicKey]),
    damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(damage, "contracts/email_registry.aes"),
        10000,
        "register_email",
        Args
    ).
