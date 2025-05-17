-module(identity_server).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get_account/1,
    register_email/2,
    register_npub/1,
    register_lightning/1,
    set_email_password/2,
    get_account_by_email/1,
    get_account_by_npub/1,
    get_account_by_lightning/1,
    get_access_token/1,
    verify_access_token/1,
    test/0,
    test_email_contract/0
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%%% =========================
%%% PUBLIC API
%%% =========================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_account(AeAccount) ->
    gen_server:call(?MODULE, {get_account, AeAccount}, ?AE_TIMEOUT).
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
            {error, Other}
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
%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    Table = ets:new(identity_cache, [named_table, set, private]),
    {ok, #{ets_table => Table}}.

handle_call({get_account, PublicKey}, _From, #{ets_table := Table} = State) ->
    case ets:lookup(Table, PublicKey) of
        [{PublicKey, Account}] ->
            {reply, Account, State};
        [] ->
            KeyPair = secrets:node_keypair(),
            case
                damage_ae:contract_call(
                    KeyPair,
                    ?EMAIL_REGISTRY_CONTRACT,
                    "contracts/email_registry.aes",
                    "get_email",
                    [
                        PublicKey
                    ]
                )
            of
                #{
                    "return_type" := "ok",
                    "return_value" :=
                        {
                            {address, AddressData}, PrivateKeyEncrypted, PasswordEncrypted
                        }
                    %{variant, [0, 1], 1,
                    %    {{tuple, {
                    %        {address, AddressData}, PasswordEncrypted, PrivateKeyEncrypted
                    %    }}}}
                } ->
                    Password = secrets:decrypt(PasswordEncrypted),
                    PrivateKey = secrets:decrypt(PrivateKeyEncrypted),
                    Address = aeser_api_encoder:encode(account_pubkey, AddressData),
                    Account = #{
                        public_key => Address, password => Password, private_key => PrivateKey
                    },
                    ets:insert(Table, {PublicKey, Account}),

                    {reply, Account, State};
                Other ->
                    ?LOG_DEBUG("Unexpected response ~p", [Other]),
                    {reply, notfound, State}
            end
    end;
handle_call({register_email, Email, PublicKey, Password, PrivateKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?EMAIL_REGISTRY_CONTRACT,
        "contracts/email_registry.aes",
        ?AE_INITIAL_AETTOS,
        "register_email",
        [
            ?DAMAGE_TOKEN_CONTRACT,
            binary_to_list(secrets:salted_hash(Email)),
            PublicKey,
            binary_to_list(secrets:encrypt(Password)),
            binary_to_list(secrets:encrypt(PrivateKey)),
            ?DAMAGE_INITIAL_HITS,
            ?AE_INITIAL_AETTOS
        ]
    ),
    {reply, Response, State};
handle_call({get_account_by_email, Email}, _From, #{ets_table := Table} = State) ->
    case ets:lookup(Table, Email) of
        [{Email, Account}] ->
            ?LOG_DEBUG("Table look up ~p ~p", [Table, Account]),
            {reply, Account, State};
        [] ->
            KeyPair = secrets:node_keypair(),
            case
                damage_ae:contract_call(
                    KeyPair,
                    ?EMAIL_REGISTRY_CONTRACT,
                    "contracts/email_registry.aes",
                    "get_account",
                    [
                        binary_to_list(secrets:salted_hash(Email))
                    ]
                )
            of
                #{"return_value" := #{email := _Email, meta := Meta}} ->
                    Response = #{email => Email, meta => binary_to_term(secrets:decrypt(Meta))},
                    {reply, Response, State};
                #{
                    "return_type" := "ok",
                    "return_value" :=
                        {
                            {address, AddressData}, PrivateKeyEncrypted, PasswordEncrypted
                        }
                } ->
                    Password = secrets:decrypt(PasswordEncrypted),
                    PrivateKey = secrets:decrypt(PrivateKeyEncrypted),
                    Address = aeser_api_encoder:encode(account_pubkey, AddressData),
                    Account = {Address, Password, PrivateKey},
                    ets:insert(Table, {Email, Account}),

                    {reply, Account, maps:put(Email, Account, State)};
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
    Response = damage_ae:contract_call(
        KeyPair,
        ?EMAIL_REGISTRY_CONTRACT,
        "contracts/email_registry.aes",
        "set_password",
        [
            binary_to_list(secrets:salted_hash(Email)),
            binary_to_list(secrets:encrypt(Password))
        ]
    ),

    ets:delete(Table, Email),
    {reply, Response, State};
handle_call({register_npub, Npub, PublicKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?NPUB_REGISTRY_CONTRACT,
        "contracts/nostr_registry.aes",
        "register_npub",
        [
            ?EMAIL_REGISTRY_CONTRACT,
            binary_to_list(secrets:salted_hash(Npub)),
            PublicKey
        ]
    ),
    {reply, Response, State};
handle_call({register_lightning, AuthKey, PublicKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?NPUB_REGISTRY_CONTRACT,
        "contracts/lightning_registry.aes",
        "register_lightning",
        [
            ?EMAIL_REGISTRY_CONTRACT,
            binary_to_list(secrets:salted_hash(AuthKey)),
            PublicKey
        ]
    ),
    {reply, Response, State};
handle_call({get_account_by_npub, Npub}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_call(
            KeyPair,
            ?NPUB_REGISTRY_CONTRACT,
            "contracts/npub_registry.aes",
            "get_account",
            [
                ?EMAIL_REGISTRY_CONTRACT,
                binary_to_list(secrets:salted_hash(Npub))
            ]
        ),
    {reply, Response, State};
handle_call({get_account_by_lightning, AuthKey}, _From, State) ->
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_call(
            KeyPair,
            ?LIGHTNING_REGISTRY_CONTRACT,
            "contracts/lightning_registry.aes",
            "get_account",
            [
                ?EMAIL_REGISTRY_CONTRACT,
                binary_to_list(secrets:salted_hash(AuthKey))
            ]
        ),
    {reply, Response, State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

%%% =========================
%%% HELPER FUNCTIONS
%%% =========================

test() ->
    Email = <<"test@gmail.com">>,
    Password = <<"testpass">>,
    Res = register_email(Email, Password),
    ?LOG_INFO("register result ~p", [Res]),
    {_PubKey, Password, _PrivateKey} = Res0 = get_account_by_email(Email),
    ?LOG_INFO("lookup result ~p", [Res0]).

test_email_contract() ->
    #{public_key := PublicKey, private_key := PrivateKey} = secrets:make_keypair(),
    ?LOG_DEBUG("New key pair created ~p ~p", [PublicKey, PrivateKey]),
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
    } = damage_ae:contract_deploy("contracts/email_registry.aes", []),
    KeyPair = secrets:node_keypair(),
    ?LOG_DEBUG("contract account ~p", [ContractId]),
    Args = [
        ?DAMAGE_TOKEN_CONTRACT,
        binary_to_list(secrets:salted_hash(Email)),
        PublicKey,
        binary_to_list(secrets:encrypt(Password)),
        binary_to_list(secrets:encrypt(PrivateKey)),
        100000000,
        1000
    ],
    ?LOG_DEBUG("contaract call args ~p", [Args]),
    damage_ae:contract_call(
        KeyPair, ContractId, "contracts/email_registry.aes", 10000, "register_email", Args
    ).
