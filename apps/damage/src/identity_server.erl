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
    verify_password/2,
    change_password/3,
    get_access_token/1,
    verify_access_token/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(AE_NODE, "https://mainnet.aeternity.io/v3").
% Replace with actual contract address
-define(CONTRACT, "ct_...").

%%% =========================
%%% PUBLIC API
%%% =========================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_email(Email, Password) ->
    gen_server:call(?MODULE, {register_email, Email, Password}).

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

verify_password(Email, Password) ->
    gen_server:call(?MODULE, {verify_password, Email, Password}).

change_password(Email, Password, NewPassword) ->
    gen_server:call(?MODULE, {verify_password, Email, Password, NewPassword}).

get_access_token(AeAccount) ->
    AeAccount.
verify_access_token(Token) ->
    Token.
%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    {ok, #{}}.

handle_call({register_email, Email}, _From, State) ->
    Response = call_contract("register_email", [Email]),
    {reply, Response, State};
handle_call({register_npub, Npub}, _From, State) ->
    Response = call_contract("register_npub", [Npub]),
    {reply, Response, State};
handle_call({register_lightning, AuthKey}, _From, State) ->
    Response = call_contract("register_lightning", [AuthKey]),
    {reply, Response, State};
handle_call({get_account_by_email, Email}, _From, State) ->
    Response = call_contract(
        "get_account_by_email", [Email]
    ),
    {reply, Response, State};
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
