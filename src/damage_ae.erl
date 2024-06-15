-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("reporting/formatter.hrl").

-behaviour(gen_server).

-export(
  [
    init/1,
    start_link/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    setup_vanillae_deps/0,
    get_wallet_path/1,
    maybe_create_wallet/1,
    maybe_fund_wallet/2,
    maybe_fund_wallet/1,
    get_account_context/1,
    get_webhooks/1,
    add_webhook/3,
    add_context/4,
    deploy_account_contract/0
  ]
).
-export([sign_tx/2]).
-export([contract_call/5, contract_call/6, contract_deploy/3]).
-export([test_contract_call/1, test_sign_vw/0, test_create_wallet/0]).
-export([balance/1, invalidate_cache/1, spend/2, confirm_spend/1]).

-define(AE_USER_WALLET_MINIMUM_BALANCE, 1000100000000000).
-define(AE_TIMEOUT, 36000).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  process_flag(trap_exit, true),
  gproc:reg_other({n, l, {?MODULE, ae}}, self()),
  {ok, #{}}.


find_active_node([{Host, Port, PathPrefix} | Rest]) ->
  case gun:open(Host, Port, #{tls_opts => [{verify, verify_none}]}) of
    {ok, ConnPid} -> {ok, ConnPid, PathPrefix};

    Err ->
      ?LOG_DEBUG(
        "Connecing to host ~p port ~p failed with error ~p trying ~p",
        [Host, Port, Err, Rest]
      ),
      find_active_node(Rest)
  end.


get_ae_node_url() ->
  {ok, NodeUrl} = application:get_env(damage, ae_cli_node_url),
  NodeUrl.


get_ae_node() ->
  {ok, AENodes} = application:get_env(damage, ae_nodes),
  find_active_node(AENodes).


get_ae_mdw_node() ->
  {ok, AENodes} = application:get_env(damage, ae_mdw_nodes),
  find_active_node(AENodes).


handle_call({balance, AeAccount}, _From, Cache) ->
  AccountCache = maps:get(AeAccount, Cache, #{}),
  {ok, DamageToken} = application:get_env(damage, token_contract),
  case catch maps:get(balance, AccountCache, undefined) of
    undefined ->
      case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
          Path =
            PathPrefix
            ++
            "v3/aex9/"
            ++
            DamageToken
            ++
            "/balances/"
            ++
            AeAccount,
          StreamRef = gun:get(ConnPid, Path),
          #{amount := Balance} = read_stream(ConnPid, StreamRef),
          {reply, {ok, Balance}, Cache};

        Err ->
          ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
          {reply, {error, not_found}, Cache}
      end;

    {Balance, _} -> {reply, {ok, Balance}, Cache}
  end;

handle_call({get_context, EmailOrUsername}, _From, Cache) ->
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  case catch maps:get(context, AccountCache, undefined) of
    undefined ->
      {ok, AccountContract} = application:get_env(damage, account_contract),
      #{decodedResult := Results} =
        damage_ae:contract_call(
          EmailOrUsername,
          AccountContract,
          "contracts/account.aes",
          "get_context",
          []
        ),
      ClientContext =
        maps:from_list(
          [
            {
              damage_utils:decrypt(base64:decode(KeyEncrypted)),
              damage_utils:decrypt(base64:decode(ValueEncrypted))
            }
            || [KeyEncrypted, ValueEncrypted] <- Results
          ]
        ),
      ?LOG_DEBUG("context caching ~p", [ClientContext]),
      {
        reply,
        ClientContext,
        maps:put(
          EmailOrUsername,
          maps:put(context, ClientContext, AccountCache),
          Cache
        )
      };

    Context when is_map(Context) -> {reply, Context, Cache}
  end;

handle_call({set_context, EmailOrUsername, AccountContext}, _From, Cache) ->
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  NewAccountContext =
    maps:merge(maps:get(context, AccountCache, #{}), AccountContext),
  {ok, AccountContract} = application:get_env(damage, account_contract),
  #{decodedResult := []} =
    damage_ae:contract_call(
      EmailOrUsername,
      AccountContract,
      "contracts/account.aes",
      "set_context",
      [NewAccountContext]
    ),
  ?LOG_DEBUG("set_context caching ~p", [NewAccountContext]),
  {
    reply,
    NewAccountContext,
    maps:put(
      EmailOrUsername,
      maps:put(context, NewAccountContext, AccountCache),
      Cache
    )
  };

handle_call({get_webhooks, EmailOrUsername}, _From, Cache) ->
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  case catch maps:get(webhooks, AccountCache, undefined) of
    undefined ->
      {ok, AccountContract} = application:get_env(damage, account_contract),
      #{decodedResult := Results} =
        damage_ae:contract_call(
          EmailOrUsername,
          AccountContract,
          "contracts/account.aes",
          "get_webhooks",
          []
        ),
      WebHooks =
        maps:from_list(
          [
            {
              damage_utils:decrypt(base64:decode(Key)),
              damage_utils:decrypt(base64:decode(Hook))
            }
            || [Key, Hook] <- Results
          ]
        ),
      ?LOG_DEBUG("Cache get Webhooks ~p", [WebHooks]),
      {
        reply,
        WebHooks,
        maps:put(
          EmailOrUsername,
          maps:put(webhooks, WebHooks, AccountCache),
          Cache
        )
      };

    Context when is_map(Context) -> {reply, Context, Cache}
  end;

handle_call({add_context, Username, Key, Value, Visibility}, _From, Cache) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  KeyEncrypted = base64:encode(damage_utils:encrypt(Key)),
  ValueEncrypted = base64:encode(damage_utils:encrypt(Value)),
  #{decodedResult := Results} =
    damage_ae:contract_call(
      Username,
      AccountContract,
      "contracts/account.aes",
      "add_context",
      [KeyEncrypted, ValueEncrypted, Visibility]
    ),
  ?LOG_DEBUG("AddContext ~p", [Results]),
  {reply, Results, Cache};

handle_call(
  {add_webhook, EmailOrUsername, WebhookName, WebhookUrl},
  _From,
  Cache
) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  WebhookUrlEncrypted = base64:encode(damage_utils:encrypt(WebhookUrl)),
  WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
  Results =
    damage_ae:contract_call(
      EmailOrUsername,
      AccountContract,
      "contracts/account.aes",
      "add_webhook",
      [WebhookNameEncrypted, WebhookUrlEncrypted]
    ),
  ?LOG_DEBUG("wWebhooks ~p", [Results]),
  {reply, Results, Cache};

handle_call({transaction, Data}, _From, State) ->
  ?LOG_DEBUG("handle_call transaction/1 : ~p", [Data]),
  {reply, ok, State}.


handle_cast(
  {
    confirm_spend,
    #{
      username := EmailOrUsername,
      account_contract := AccountContract,
      feature_hash := FeatureHash,
      report_hash := ReportHash,
      token_contract := DamageTokenContract,
      node_public_key := NodePublicKey
    }
  },
  Cache
)
when is_binary(EmailOrUsername) ->
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  case maps:get(balance, AccountCache, {0, 0}) of
    {_, Amount} when Amount > 0 ->
      ContractCall =
        damage_ae:contract_call(
          EmailOrUsername,
          AccountContract,
          "contracts/account.aes",
          "spend",
          [DamageTokenContract, NodePublicKey, Amount, FeatureHash, ReportHash]
        ),
      #{
        decodedResult
        :=
        #{balance := Balance, deployer := _Deployer} = _Balances
      } = ContractCall,
      NewCache =
        maps:put(
          EmailOrUsername,
          maps:put(balance, {Balance, 0}, AccountCache),
          Cache
        ),
      ?LOG_DEBUG("confirm spend ~p", [NewCache]),
      {noreply, NewCache};

    {_, Amount} ->
      ?LOG_DEBUG("Amount 0: ~p", [Amount]),
      {noreply, Cache}
  end;

handle_cast({spend, AeAccount, Amount}, Cache) when is_list(AeAccount) ->
  handle_cast({spend, list_to_binary(AeAccount), Amount}, Cache);

handle_cast({spend, AeAccount, Amount}, Cache) when is_binary(AeAccount) ->
  AccountCache = maps:get(AeAccount, Cache, #{}),
  {Balance, Spend} = maps:get(balance, AccountCache, {0, 0}),
  NewCache = maps:put(balance, {Balance, Spend + Amount}, AccountCache),
  {noreply, maps:put(AeAccount, NewCache, Cache)};

handle_cast({invalidate_cache, _EmailOrUsername}, _Cache) -> {noreply, #{}};
handle_cast(_Event, State) -> {noreply, State}.


handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

sign_tx(Tx, PrivKey) -> sign_tx(Tx, PrivKey, false).

-define(VALID_PRIVK(K), byte_size(K) =:= 64).

sign_tx(Tx, PrivKey, SignHash) -> sign_tx(Tx, PrivKey, SignHash, undefined).

sign_tx(Tx, PrivKey, SignHash, Pfx) ->
  %% set debug true to meet legacy expectations (?)
  sign_tx(Tx, PrivKey, SignHash, Pfx, [{debug, true}]).


sign_tx(Tx, PrivKey, SignHash, AdditionalPrefix, Cfg) when is_binary(PrivKey) ->
  sign_tx(Tx, [PrivKey], SignHash, AdditionalPrefix, Cfg);

sign_tx(Tx, PrivKeys, SignHash, AdditionalPrefix, _Cfg) when is_list(PrivKeys) ->
  Bin0 = aetx:serialize_to_binary(Tx),
  Bin1 =
    case SignHash of
      true -> aec_hash:hash(signed_tx, Bin0);
      false -> Bin0
    end,
  Bin =
    case AdditionalPrefix of
      undefined -> Bin1;
      _ -> <<"-", AdditionalPrefix/binary, Bin1/binary>>
    end,
  BinForNetwork = aec_governance:add_network_id(Bin),
  case lists:filter(fun (PrivKey) -> not (?VALID_PRIVK(PrivKey)) end, PrivKeys) of
    [_ | _] = BrokenKeys -> erlang:error({invalid_priv_key, BrokenKeys});
    [] -> pass
  end,
  Signatures =
    [enacl:sign_detached(BinForNetwork, PrivKey) || PrivKey <- PrivKeys],
  aetx_sign:new(Tx, Signatures).


exec_aecli(Cmd) ->
  AeNodeUrl = get_ae_node_url(),
  case
  exec:run(Cmd, [stdout, stderr, sync, {env, [{"AECLI_NODE_URL", AeNodeUrl}]}]) of
    %?LOG_DEBUG("Result : ~p", [Result]),
    {ok, [{stdout, StdOutList}]} ->
      jsx:decode(damage_utils:binarystr_join(StdOutList), [{labels, atom}]);

    {ok, [{stdout, StdOutList}, {stderr, Err}]} ->
      ?LOG_ERROR("Stderr ~p ~p", [StdOutList, Err]),
      jsx:decode(damage_utils:binarystr_join(StdOutList), [{labels, atom}]);

    {error, [{exit_status, _ExitStatus}, {stdout, StdOutList}, {stderr, Err}]} ->
      case jsx:decode(damage_utils:binarystr_join(StdOutList), [{labels, atom}]) of
        #{validation := [#{key := <<"InsufficientBalance">>}]} = Result ->
          ?LOG_INFO("Insufficient balance for account  ~p ", [Result]);

        Result ->
          ?LOG_ERROR("Stderr ~p ~p ", [Err, Result]),
          #{status => <<"fail">>}
      end
  end.


contract_call(EmailOrUsername, ContractAddress, Contract, Func, Args) ->
  contract_call(
    get_wallet_path(EmailOrUsername),
    get_wallet_password(EmailOrUsername),
    ContractAddress,
    Contract,
    Func,
    Args
  ).

contract_call(WalletPath, WalletPassword, ContractAddress, Contract, Func, Args) ->
  Cmd =
    mustache:render(
      "aecli contract call --contractSource {{contract_source}} --contractAddress {{contract_address}} {{contract_function}} '{{contract_args}}' {{wallet}} --password={{password}} --json",
      damage_utils:convert_context(
        #{
          wallet => WalletPath,
          password => WalletPassword,
          contract_source => Contract,
          contract_args => binary_to_list(jsx:encode(Args)),
          contract_address => ContractAddress,
          contract_function => Func
        }
      )
    ),
  ?LOG_DEBUG("Cmd : ~p", [Cmd]),
  exec_aecli(Cmd).


contract_deploy(EmailOrUsername, Contract, Args) ->
  contract_deploy(
    get_wallet_path(EmailOrUsername),
    get_wallet_password(EmailOrUsername),
    Contract,
    Args
  ).

contract_deploy(WalletPath, WalletPassword, Contract, Args) ->
  Cmd =
    mustache:render(
      "aecli contract deploy {{wallet}} --contractSource {{contract_source}} '{{contract_args}}' --password={{password}} --json ",
      damage_utils:convert_context(
        #{
          wallet => WalletPath,
          password => WalletPassword,
          contract_source => Contract,
          contract_args => binary_to_list(jsx:encode(Args))
        }
      )
    ),
  ?LOG_DEBUG("Cmd : ~p", [Cmd]),
  exec_aecli(Cmd).


get_wallet_proc(Username) ->
  case gproc:lookup_local_name({?MODULE, Username}) of
    undefined ->
      {ok, AePid} =
        supervisor:start_child(
          damage_sup,
          #{
            % mandatory
            id => Username,
            % mandatory
            start => {damage_ae, start_link, []},
            % optional
            restart => permanent,
            % optional
            shutdown => 60,
            % optional
            type => worker,
            modules => [damage_ae]
          }
        ),
      gproc:reg_other({n, l, {?MODULE, Username}}, AePid),
      AePid;

    Pid -> Pid
  end.


balance(Username) ->
  ?LOG_DEBUG("Check balance", []),
  DamageAEPid = get_wallet_proc(Username),
  gen_server:call(DamageAEPid, {balance, Username}, ?AE_TIMEOUT).


spend(Username, Amount) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(Username),
  gen_server:cast(DamageAEPid, {spend, Username, Amount}).


confirm_spend(#{username := Username} = Context) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(Username),
  gen_server:cast(DamageAEPid, {confirm_spend, Context}).


get_account_context(EmailOrUsername) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(DamageAEPid, {get_context, EmailOrUsername}, ?AE_TIMEOUT).


add_context(EmailOrUsername, Key, Value, Visibility) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(
    DamageAEPid,
    {add_context, EmailOrUsername, Key, Value, Visibility},
    ?AE_TIMEOUT
  ).


get_webhooks(EmailOrUsername) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(DamageAEPid, {get_webhooks, EmailOrUsername}, ?AE_TIMEOUT).


add_webhook(EmailOrUsername, WebhookName, WebhookUrl) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(
    DamageAEPid,
    {add_webhook, EmailOrUsername, WebhookName, WebhookUrl},
    ?AE_TIMEOUT
  ).


invalidate_cache(Username) ->
  DamageAEPid = get_wallet_proc(Username),
  gen_server:cast(DamageAEPid, {invalidate_cache, Username}).


setup_vanillae_deps() ->
  true = code:add_path("_checkouts/vanillae/ebin"),
  true = code:add_path("_checkouts/vw/ebin"),
  Vanillae =
    "otpr-vanillae-" ++ lists:droplast(os:cmd("zx latest otpr-vanillae")),
  Deps = string:lexemes(os:cmd("zx list deps " ++ Vanillae), "\n"),
  ZX =
    "otpr-zx-"
    ++
    lists:nth(2, string:lexemes(lists:droplast(os:cmd("zx --version")), " ")),
  Packages = [ZX, Vanillae | Deps],
  ZompLib = filename:join(os:getenv("HOME"), "zomp/lib"),
  ?LOG_DEBUG("Packages paths ~p", [Packages]),
  Converted =
    [string:join(string:lexemes(Package, "-"), "/") || Package <- Packages],
  PackagePaths =
    [filename:join([ZompLib, PackagePath, "ebin"]) || PackagePath <- Converted],
  ?LOG_DEBUG("Code paths ~p", [PackagePaths]),
  ok = code:add_paths(PackagePaths).


read_stream(ConnPid, StreamRef) ->
  case gun:await(ConnPid, StreamRef, 600000) of
    {response, nofin, Status, _Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      ?LOG_DEBUG(" Status ~p Response: ~p", [Status, Body]),
      jsx:decode(Body, [{labels, atom}, return_maps]);

    Default ->
      ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
      Default
  end.


get_wallet_password(EmailOrUsername) ->
  AEPassword = os:getenv("AE_PASSWORD"),
  damage_utils:idhash_keys([EmailOrUsername, AEPassword]).


get_wallet_path(EmailOrUsername) ->
  WalletName = binary_to_list(damage_utils:idhash_keys([EmailOrUsername])),
  filename:join(["wallets", "damage_user_wallet_" ++ WalletName]).


create_wallet(WalletName) when is_binary(WalletName) ->
  create_wallet(binary_to_list(WalletName));

create_wallet(EmailOrUsername) ->
  WalletPath = get_wallet_path(EmailOrUsername),
  ?LOG_DEBUG("Wallet path. ~p", [WalletPath]),
  Created =
    case filelib:is_regular(WalletPath) of
      true ->
        ?LOG_DEBUG("Wallet exists not overwriting. ~p", [WalletPath]),
        existing;

      _ ->
        Cmd =
          mustache:render(
            "aecli account create --password={{password}} --json  '{{wallet_path}}'",
            damage_utils:convert_context(
              #{
                password => get_wallet_password(EmailOrUsername),
                wallet_path => WalletPath
              }
            )
          ),
        ?LOG_DEBUG("Cmd : ~p", [Cmd]),
        Result = exec_aecli(Cmd),
        ?LOG_INFO("Generateed wallet with pub key ~p", [Result]),
        created
    end,
  {ok, Wallet} = file:read_file(WalletPath),
  {Created, jsx:decode(Wallet, [{labels, atom}, return_maps])}.


get_ae_balance(AeAccount) ->
  {ok, ConnPid, PathPrefix} = get_ae_node(),
  Path = PathPrefix ++ "v3/accounts/" ++ AeAccount,
  StreamRef = gun:get(ConnPid, Path),
  read_stream(ConnPid, StreamRef).


maybe_fund_wallet(EmailOrUsername) ->
  maybe_fund_wallet(EmailOrUsername, ?AE_USER_WALLET_MINIMUM_BALANCE).

maybe_fund_wallet(EmailOrUsername, Amount) ->
  UserWalletPath = get_wallet_path(EmailOrUsername),
  {ok, Wallet} = file:read_file(UserWalletPath),
  #{public_key := UserAccount} =
    jsx:decode(Wallet, [{labels, atom}, return_maps]),
  case get_ae_balance(UserAccount) of
    #{balance := Balance} when Balance < ?AE_USER_WALLET_MINIMUM_BALANCE ->
      {ok, AdminWalletPath} = application:get_env(damage, ae_wallet),
      AdminPassword = os:getenv("AE_PASSWORD"),
      Cmd =
        mustache:render(
          "aecli spend --password={{password}} --json '{{admin_wallet_path}}' {{user_account}} {{amount}}",
          damage_utils:convert_context(
            #{
              amount => Amount,
              user_account => UserAccount,
              password => AdminPassword,
              admin_wallet_path => AdminWalletPath
            }
          )
        ),
      ?LOG_DEBUG("Cmd : ~p", [Cmd]),
      Result = exec_aecli(Cmd),
      ?LOG_INFO("Funded wallet with pub key ~p ~p", [EmailOrUsername, Result]),
      {funded, Result};

    Result ->
      ?LOG_INFO("Wallet above minimum balance ~p ~p", [EmailOrUsername, Result]),
      {notfunded, #{public_key => UserAccount}}
  end.


maybe_create_wallet(#{email := Email}) ->
  create_wallet(Email),
  maybe_fund_wallet(Email).


deploy_account_contract() ->
  {ok, AdminWallet} = application:get_env(damage, ae_wallet),
  AdminPassword = os:getenv("AE_PASSWORD"),
  #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
    contract_deploy(AdminWallet, AdminPassword, "contracts/account.aes", []),
  application:set_env(damage, account_contract, binary_to_list(ContractAddress)),
  ?LOG_INFO("Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]).


test_create_wallet() ->
  #{wallet_address := WalletAddress} =
    Result = maybe_create_wallet(#{email => "stevenjose@gmail.com"}),
  ?LOG_INFO("Wallet created ~p ~p.", [WalletAddress, Result]).


test_contract_call(AeAccount) when is_binary(AeAccount) ->
  test_contract_call(binary_to_list(AeAccount));

test_contract_call(AeAccount) when is_list(AeAccount) ->
  JobId = <<"sdds">>,
  {ok, Nonce} = vanillae:next_nonce(AeAccount),
  ?LOG_DEBUG("nonce ~p", [Nonce]),
  %{contract_pubkey, ContractData} =
  ContractData =
    vanillae:contract_create(AeAccount, "contracts/account.aes", []),
  ?LOG_DEBUG("contract data ~p", [ContractData]),
  {ok, STx} = sign_tx(ContractData),
  ?LOG_DEBUG("contract create ~p", [STx]),
  {ok, AACI} = vanillae:prepare_contract("contracts/account.aes"),
  ContractCall =
    vanillae:contract_call(
      AeAccount,
      Nonce,
      % Amount
      0,
      % Gas
      0,
      % GasPrice
      0,
      % Fee
      0,
      AACI,
      STx,
      "update_schedule",
      [JobId]
    ),
  ?LOG_DEBUG("contract call ~p", [ContractCall]),
  {ok, STx} = sign_tx(ContractCall),
  case vanillae:post_tx(STx) of
    {ok, #{"tx_hash" := Hash}} ->
      ?LOG_DEBUG("contract call success ~p", [Hash]),
      Hash;

    {ok, WTF} ->
      logger:error("contract call Unexpected result ~p", [WTF]),
      {error, unexpected};

    {error, Reason} ->
      logger:error("contract call error ~p", [Reason]),
      {error, Reason}
  end.

%% Ref:
%%
%% https://github.com/aeternity/protocol/blob/fd179822fc70241e79cbef7636625cf344a08109/node/api/api_encoding.md
%% https://github.com/aeternity/protocol/blob/fd179822fc70241e79cbef7636625cf344a08109/serializations.md

test_sign_vw() ->
  #{public := PublicKey, secret := SecretKey} = ecu_eddsa:sign_keypair(),
  PublicKey0 = vd:encode_id(PublicKey),
  ?LOG_DEBUG("pubkey ~p", [PublicKey0]),
  {ok, Nonce} = vanillae:next_nonce(PublicKey0),
  ?LOG_DEBUG("nonce ~p", [Nonce]),
  %{contract_pubkey, ContractData} =
  ContractData =
    vanillae:contract_create(PublicKey, "contracts/account.aes", []),
  ?LOG_DEBUG("contract data ~p", [ContractData]),
  Signed = ecu_eddsa:sign(ContractData, SecretKey),
  Signed.


sign_tx(UTx) ->
  Password = list_to_binary(os:getenv("AE_SECRET_KEY")),
  sign_tx(UTx, Password).


%sign_tx(UTx, PrivateKey) ->
%  SignData = base64:encode(<<"ae_uat", UTx/binary>>),
%  Signature = enacl:sign_detached(SignData, base64:encode(PrivateKey)),
%  TagBytes = <<11 : 64>>,
%  VsnBytes = <<1 : 64>>,
%  {ok, vrlp:encode([TagBytes, VsnBytes, [Signature], UTx])}.
%update_schedules(ContractAddress, JobId, Cron)->
%  ContractCreated =
%    aecli(
%      contract,
%      call,
%      binary_to_list(ContractAddress),
%      "contracts/account.aes",
%      "update_schedules",
%      [BtcAddress, RefundAddress]
%    ),
%    ok.
%
%on_payment(Wallet) ->
%    take_fee(Wallet)
%    get_ae(Wallet)
% FROM jrx/b_lib.ts:tx_sign
%        let tx_bytes        : Uint8Array = (await vdk_aeser.unbaseNcheck(tx_str)).bytes;
%        // thank you ulf
%        // https://github.com/aeternity/protocol/tree/fd179822fc70241e79cbef7636625cf344a08109/consensus#transaction-signature
%        // we sign <<NetworkId, SerializedObject>>
%        // SerializedObject can either be the object or the hash of the object
%        // let's stick with hash for now
%        let network_id      : Uint8Array = vdk_binary.encode_utf8('ae_uat');
%        // let tx_hash_bytes   : Uint8Array = hash(tx_bytes);
%        let sign_data       : Uint8Array = vdk_binary.bytes_concat(network_id, tx_bytes);
%        // @ts-ignore yes nacl is stupid
%        let signature       : Uint8Array = nacl.sign.detached(sign_data, secret_key);
%        let signed_tx_bytes : Uint8Array = vdk_aeser.signed_tx([signature], tx_bytes);
%        let signed_tx_str   : string     = await vdk_aeser.baseNcheck('tx', signed_tx_bytes);
%/**
% * RLP-encode signed tx (signatures and tx are both the BINARY representations)
% *
% * See https://github.com/aeternity/protocol/blob/fd179822fc70241e79cbef7636625cf344a08109/serializations.md#signed-transaction
% */
%function
%signed_tx
%    (signatures : Array<Uint8Array>,
%     tx         : Uint8Array)
%    : Uint8Array
%{
%    // tag for signed tx
%    let tag_bytes = vdk_rlp.encode_uint(11);
%    // not sure what version number should be but guessing 1
%    let vsn_bytes = vdk_rlp.encode_uint(1);
%    // result is [tag, vsn, signatures, tx]
%    return vdk_rlp.encode([tag_bytes, vsn_bytes, signatures, tx]);
%}
