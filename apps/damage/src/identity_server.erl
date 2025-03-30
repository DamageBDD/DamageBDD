-module(identity_server).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    register_email/2,
    register_npub/1,
    register_lightning/1,
    set_email_password/2,
    get_account_by_email/1,
    get_account_by_npub/1,
    get_account_by_lightning/1,
    get_access_token/1,
    verify_access_token/1,
    test/0
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

register_email(Email, Password) ->
    #{public_key := PubKey, private_key := PrivateKey} = secrets:make_keypair(),
    case
        gen_server:call(
            ?MODULE, {register_email, Email, PubKey, Password, PrivateKey}
        )
    of
        #{"return_type" := "ok", "return_value" := true} ->
            {ok, <<"Email confirmed and password set.">>};
        #{"return_type" := _, "return_value" := Other} ->
            {error, Other}
    end.
set_email_password(Email, Password) ->
    case gen_server:call(?MODULE, {set_email_password, Email, Password}) of
        #{"return_type" := "ok", "return_value" := true} ->
            {ok, <<"Password set.">>};
        #{"return_type" := _, "return_value" := Other} ->
            {error, Other}
    end.

register_npub(Npub) ->
    gen_server:call(?MODULE, {register_npub, Npub}).

register_lightning(AuthKey) ->
    gen_server:call(?MODULE, {register_lightning, AuthKey}).

get_account_by_email(Email) ->
    gen_server:call(?MODULE, {get_account_by_email, Email}).

get_account_by_npub(Npub) ->
    gen_server:call(?MODULE, {get_account_by_npub, Npub}).

get_account_by_lightning(AuthKey) ->
    gen_server:call(?MODULE, {get_account_by_lightning, AuthKey}).

get_access_token(AeAccount) ->
    AeAccount.
verify_access_token(Token) ->
    Token.
%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    {ok, #{}}.

handle_call({register_email, Email, PublicKey, Password, PrivateKey}, _From, State) ->
    EmailHashed = binary_to_list(secrets:salted_hash(Email)),
    PasswordEncrypted = binary_to_list(secrets:encrypt(Password)),
    PrivateKeyEncrypted = binary_to_list(secrets:encrypt(PrivateKey)),
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?EMAIL_REGISTRY_CONTRACT,
        "contracts/email_registry.aes",
        "register_email",
        [?KEYSTORE_CONTRACT, EmailHashed, PublicKey, PasswordEncrypted, PrivateKeyEncrypted]
    ),
    {reply, Response, State};
handle_call({get_account_by_email, Email}, _From, State) ->
    EmailHashed = binary_to_list(secrets:salted_hash(Email)),
    KeyPair = secrets:node_keypair(),
    case maps:get(Email, State, notfound) of
        notfound ->
            case
                damage_ae:contract_call(
                    KeyPair,
                    ?EMAIL_REGISTRY_CONTRACT,
                    "contracts/email_registry.aes",
                    "get_account",
                    [?KEYSTORE_CONTRACT, EmailHashed]
                )
            of
                #{"return_value" := #{email := _Email, meta := Meta}} ->
                    Response = #{email => Email, meta => binary_to_term(secrets:decrypt(Meta))},
                    {reply, Response, State};
                #{
                    "return_type" := "ok",
                    "return_value" :=
                        {variant, [0, 1], 1,
                            {{tuple, {
                                {address, AddressData}, PasswordEncrypted, PrivateKeyEncrypted
                            }}}}
                } ->
                    Password = secrets:decrypt(PasswordEncrypted),
                    PrivateKey = secrets:decrypt(PrivateKeyEncrypted),
                    Address = aeser_api_encoder:encode(account_pubkey, AddressData),
                    Acccount = {Address, Password, PrivateKey},

                    {reply, Acccount, maps:put(Email, Acccount, State)};
                #{
                    "return_type" := "revert",
                    "return_value" := <<"Email not registered.">>
                } ->
                    ?LOG_DEBUG("Email not registered", []),
                    {reply, notfound, State};
                Other ->
                    ?LOG_DEBUG("Unexpected response ~p", [Other]),
                    {reply, notfound, State}
            end;
        Cached ->
            {reply, Cached, State}
    end;
handle_call({set_email_password, Email, Password}, _From, State) ->
    PasswordEncrypted = binary_to_list(secrets:encrypt(Password)),
    EmailHashed = binary_to_list(secrets:salted_hash(Email)),
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?EMAIL_REGISTRY_CONTRACT,
        "contracts/email_registry.aes",
        "set_meta",
        [?KEYSTORE_CONTRACT, EmailHashed, PasswordEncrypted]
    ),
    {reply, Response, State};
handle_call({register_npub, Npub, PublicKey}, _From, State) ->
    NpubHashed = binary_to_list(secrets:salted_hash(Npub)),
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?NPUB_REGISTRY_CONTRACT,
        "contracts/nostr_registry.aes",
        "register_npub",
        [?KEYSTORE_CONTRACT, NpubHashed, PublicKey]
    ),
    {reply, Response, State};
handle_call({register_lightning, AuthKey, PublicKey}, _From, State) ->
    AuthKeyHashed = binary_to_list(secrets:salted_hash(AuthKey)),
    KeyPair = secrets:node_keypair(),
    Response = damage_ae:contract_call(
        KeyPair,
        ?NPUB_REGISTRY_CONTRACT,
        "contracts/lightning_registry.aes",
        "register_lightning",
        [?KEYSTORE_CONTRACT, AuthKeyHashed, PublicKey]
    ),
    {reply, Response, State};
handle_call({get_account_by_npub, Npub}, _From, State) ->
    NpubHashed = binary_to_list(secrets:salted_hash(Npub)),
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_call(
            KeyPair,
            ?NPUB_REGISTRY_CONTRACT,
            "contracts/npub_registry.aes",
            "get_account",
            [?KEYSTORE_CONTRACT, NpubHashed]
        ),
    {reply, Response, State};
handle_call({get_account_by_lightning, AuthKey}, _From, State) ->
    AuthKeyHashed = binary_to_list(secrets:salted_hash(AuthKey)),
    KeyPair = secrets:node_keypair(),
    Response =
        damage_ae:contract_call(
            KeyPair,
            ?LIGHTNING_REGISTRY_CONTRACT,
            "contracts/lightning_registry.aes",
            "get_account",
            [?KEYSTORE_CONTRACT, AuthKeyHashed]
        ),
    {reply, Response, State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

%%% =========================
%%% HELPER FUNCTIONS
%%% =========================

test() ->
    Res = register_email("test@gmail.com", "testpass"),
    ?LOG_INFO("register result ~p", [Res]),
    Res0 = get_account_by_email("test@gmail.com"),
    ?LOG_INFO("lookup result ~p", [Res0]).
