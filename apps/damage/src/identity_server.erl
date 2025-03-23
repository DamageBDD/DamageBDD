-module(identity_server).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    register_email/2,
    register_npub/1,
    register_lightning/1,
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
    Meta = secrets:make_keypair(),
    EmailHashed = binary_to_list(base64:encode(crypto:hash(sha256, Email))),
    MetaEncrypted = binary_to_list(
        secrets:encrypt(term_to_binary(maps:put(password, Password, Meta)))
    ),
    #{"return_type" := "ok", "return_value" := true} =
        Result = gen_server:call(?MODULE, {register_email, EmailHashed, MetaEncrypted}),
    {ok, Result}.
register_npub(Npub) ->
    NpubEncrypted = secrets:encrypt(Npub),
    gen_server:call(?MODULE, {register_npub, NpubEncrypted}).

register_lightning(AuthKey) ->
    AuthKeyEncrypted = secrets:encrypt(AuthKey),
    gen_server:call(?MODULE, {register_lightning, AuthKeyEncrypted}).

get_account_by_email(Email) ->
    EmailHashed = binary_to_list(base64:encode(crypto:hash(sha256, Email))),
    gen_server:call(?MODULE, {get_account_by_email, EmailHashed}).

get_account_by_npub(Npub) ->
    NpubEncrypted = secrets:encrypt(Npub),
    gen_server:call(?MODULE, {get_account_by_npub, NpubEncrypted}).

get_account_by_lightning(AuthKey) ->
    AuthKeyEncrypted = secrets:encrypt(AuthKey),
    gen_server:call(?MODULE, {get_account_by_lightning, AuthKeyEncrypted}).

get_access_token(AeAccount) ->
    AeAccount.
verify_access_token(Token) ->
    Token.
%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    {ok, #{}}.

handle_call({register_email, Email, Password}, _From, State) ->
    Response = call_contract("register_email", [Email, Password]),
    {reply, Response, State};
handle_call({register_npub, Npub}, _From, State) ->
    Response = call_contract("register_npub", [Npub]),
    {reply, Response, State};
handle_call({register_lightning, AuthKey}, _From, State) ->
    Response = call_contract("register_lightning", [AuthKey]),
    {reply, Response, State};
handle_call({get_account_by_email, Email}, _From, State) ->
    case
        call_contract(
            "get_account_by_email", [Email]
        )
    of
        #{"return_value" := #{email := _Email, meta := Meta}} ->
            Response = #{email => Email, meta => binary_to_term(secrets:decrypt(Meta))},
            {reply, Response, State};
        #{
            "return_type" := "ok",
            "return_value" := {variant, [0, 1], 1, {{tuple, {{address, Address}, Password}}}}
        } ->
            Password0 = secrets:decrypt(Password),
            {reply, {Address, Password0}, State};
        Other ->
            ?LOG_DEBUG("Unexpected response ~p", [Other]),
            {reply, notfound, State}
    end;
handle_call({get_account_by_npub, Npub}, _From, State) ->
    Response = call_contract("get_account_by_npub", [Npub]),
    {reply, Response, State};
handle_call({get_account_by_lightning, AuthKey}, _From, State) ->
    Response = call_contract("get_account_by_lightning", [AuthKey]),
    {reply, Response, State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

%%% =========================
%%% HELPER FUNCTIONS
%%% =========================

call_contract(Func, Args) ->
    {ok, IdentityContract} = application:get_env(damage, identity_contract),

    _Response = damage_ae:contract_call(
        secrets:node_keypair(), IdentityContract, "contracts/identity.aes", Func, Args
    ).

test() ->
    Res = register_email("test@gmail.com", "testpass"),
    ?LOG_INFO("register result ~p", [Res]),
    Res0 = get_account_by_email("test@gmail.com"),
    ?LOG_INFO("lookup result ~p", [Res0]).
