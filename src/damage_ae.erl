-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

-define(DEFAULT_HTTP_TIMEOUT, 60000).

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
    maybe_create_wallet/2,
    maybe_fund_wallet/2,
    maybe_fund_wallet/1,
    transfer_damage_tokens/2,
    get_account_context/1,
    get_webhooks/1,
    add_webhook/3,
    delete_webhook/2,
    add_context/4,
    deploy_account_contract/0,
    confirm_spend_all/0,
    start_batch_spend_timer/0,
    get_reports/1,
    get_domain_token/2,
    add_domain_token/3,
    revoke_domain_token/2,
    contract_call_admin_account/2,
    get_ae_mdw_node/0,
    get_ae_mdw_ws_node/0
  ]
).
-export([sign_tx/2]).
-export([contract_call/5, contract_call/6, contract_deploy/3]).
-export([test_contract_call/0, test_sign_vw/0, test_create_wallet/0]).
-export([balance/1, invalidate_cache/1, spend/2, confirm_spend/1]).
-export([get_schedules/1]).
-export([set_meta/1]).
-export([get_meta/1]).
-export([delete_account/1]).
-export([revoke_token/2]).
-export([resolve_npub/1]).
-export([get_block_height_since/2]).
-export([test_find_block/0]).
-export([get_wallet_proc/1]).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  process_flag(trap_exit, true),
  ConfirmSpendTimer = erlang:send_after(10000, self(), confirm_spend_all),
  {ok, WS, _Path} = get_ae_mdw_node(),
  {ok, #{heartbeat_timer => ConfirmSpendTimer, websocket => WS}}.


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


get_ae_mdw_ws_node() ->
  {ok, AENodes} = application:get_env(damage, ae_mdw_ws_nodes),
  find_active_node(AENodes).


get_block_height_since(SinceHours, ConnPid) ->
  find_block_at_timestamp(
    date_util:datetime_to_epoch(
      calendar:now_to_datetime(erlang:timestamp())
      -
      hours_to_seconds(SinceHours)
    ),
    ConnPid
  ).

hours_to_seconds(Hours) -> 3600 * Hours.

handle_call(
  {get_last_test_status, AeAccount, _FeatureHash, Hours},
  _From,
  Cache
) ->
  case get_ae_mdw_node() of
    {ok, ConnPid, PathPrefix} ->
      Path =
        PathPrefix
        ++
        "v3/accounts/"
        ++
        AeAccount
        ++
        "/activities?direction=backward&type=transactions&height="
        ++
        get_block_height_since(Hours, ConnPid),
      StreamRef = gun:get(ConnPid, Path),
      Balance =
        case read_stream(ConnPid, StreamRef) of
          #{amount := null} -> 0;
          #{amount := Balance0} -> Balance0
        end,
      {reply, Balance, Cache};

    Err ->
      ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
      {reply, {error, not_found}, Cache}
  end;

handle_call({reports, AeAccount}, _From, Cache) ->
  {ok, DamageToken} = application:get_env(damage, token_contract),
  case get_ae_mdw_node() of
    {ok, ConnPid, PathPrefix} ->
      Path =
        PathPrefix
        ++
        "v3/transactions/?direction=backward&type=contract_call&contract="
        ++
        DamageToken
        ++
        "&account="
        ++
        AeAccount
        ++
        "&limit=10",
      StreamRef = gun:get(ConnPid, Path),
      Balance =
        case read_stream(ConnPid, StreamRef) of
          #{amount := null} -> 0;
          #{amount := Balance0} -> Balance0
        end,
      {reply, Balance, Cache};

    Err ->
      ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
      {reply, {error, not_found}, Cache}
  end;

handle_call({balance, AeAccount}, _From, Cache) ->
  {ok, DamageToken} = application:get_env(damage, token_contract),
  case get_ae_mdw_node() of
    {ok, ConnPid, PathPrefix} ->
      Path =
        PathPrefix ++ "v3/aex9/" ++ DamageToken ++ "/balances/" ++ AeAccount,
      StreamRef = gun:get(ConnPid, Path),
      Balance =
        case read_stream(ConnPid, StreamRef) of
          #{amount := null} -> 0;

          #{error := Error} ->
            ?LOG_ERROR("Error getting balance ~p", [Error]),
            0;

          #{amount := Balance0} -> Balance0
        end,
      {reply, Balance, Cache};

    Err ->
      ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
      {reply, {error, not_found}, Cache}
  end;

handle_call({get_schedules, Email}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  case catch maps:get(schedules, AccountCache, undefined) of
    undefined ->
      #{decodedResult := Results} =
        contract_call_user_account(Email, "get_schedules", []),
      Schedules =
        maps:from_list(
          [
            {
              damage_utils:decrypt(base64:decode(FeatureHashEncrypted)),
              damage_utils:decrypt(base64:decode(CronEncrypted))
            }
            || [FeatureHashEncrypted, CronEncrypted] <- Results
          ]
        ),
      {
        reply,
        Schedules,
        maps:put(Email, maps:put(schedules, Schedules, AccountCache), Cache)
      };

    Schedules when is_map(Schedules) -> {reply, Schedules, Cache}
  end;

handle_call({get_context, Email}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  case catch maps:get(context, AccountCache, undefined) of
    undefined ->
      #{decodedResult := Results} =
        contract_call_user_account(Email, "get_context", []),
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
        maps:put(Email, maps:put(context, ClientContext, AccountCache), Cache)
      };

    Context when is_map(Context) -> {reply, Context, Cache}
  end;

handle_call({set_context, Email, AccountContext}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  NewAccountContext =
    maps:merge(maps:get(context, AccountCache, #{}), AccountContext),
  Results =
    contract_call_user_account(Email, "set_context", [NewAccountContext]),
  ?LOG_DEBUG("set_context caching ~p, ~p", [NewAccountContext, Results]),
  {
    reply,
    NewAccountContext,
    maps:put(Email, maps:put(context, NewAccountContext, AccountCache), Cache)
  };

handle_call({add_context, Email, Key, Value, Visibility}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  ContextCache = maps:get(context, AccountCache, #{}),
  KeyEncrypted = base64:encode(damage_utils:encrypt(Key)),
  ValueEncrypted = base64:encode(damage_utils:encrypt(Value)),
  Results =
    damage_ae:contract_call_user_account(
      Email,
      "add_context",
      [KeyEncrypted, ValueEncrypted, Visibility]
    ),
  ?LOG_DEBUG("AddContext ~p", [Results]),
  {
    reply,
    Results,
    maps:put(
      Email,
      maps:put(context, maps:put(Key, Value, ContextCache), AccountCache),
      Cache
    )
  };

handle_call({delete_context, Email, Key}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  ContextCache = maps:get(context, AccountCache, #{}),
  ContextKeyEnc = base64:encode(damage_utils:encrypt(Key)),
  Results =
    damage_ae:contract_call_user_account(
      Email,
      "delete_context",
      [ContextKeyEnc]
    ),
  ?LOG_DEBUG("wWebhooks ~p", [Results]),
  {
    reply,
    Results,
    maps:put(
      Email,
      maps:put(context, maps:delete(Key, ContextCache), AccountCache),
      Cache
    )
  };

handle_call({get_webhooks, Email}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  case catch maps:get(webhooks, AccountCache, undefined) of
    undefined ->
      #{decodedResult := Results} =
        contract_call_user_account(Email, "get_webhooks", []),
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
        maps:put(Email, maps:put(webhooks, WebHooks, AccountCache), Cache)
      };

    Context when is_map(Context) -> {reply, Context, Cache}
  end;

handle_call({add_webhook, Email, WebhookName, WebhookUrl}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  WebHookCache = maps:get(webhooks, AccountCache, #{}),
  WebhookUrlEncrypted = base64:encode(damage_utils:encrypt(WebhookUrl)),
  WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
  Results =
    contract_call_user_account(
      Email,
      "add_webhook",
      [WebhookNameEncrypted, WebhookUrlEncrypted]
    ),
  ?LOG_DEBUG("wWebhooks ~p", [Results]),
  {
    reply,
    Results,
    maps:put(
      Email,
      maps:put(
        webhooks,
        maps:put(WebhookName, WebhookUrl, WebHookCache),
        AccountCache
      ),
      Cache
    )
  };

handle_call({delete_webhook, Email, WebhookName}, _From, Cache) ->
  WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
  Results =
    contract_call_user_account(Email, "delete_webhook", [WebhookNameEncrypted]),
  ?LOG_DEBUG("Webhooks ~p", [Results]),
  {reply, Results, Cache};

handle_call({get_auth_token, Email, TokenKey}, _From, Cache) ->
  case contract_call_user_account(Email, "get_auth_token", [TokenKey]) of
    #{decodedResult := EncryptedConfirmToken} ->
      {reply, damage_utils:decrypt(base64:decode(EncryptedConfirmToken)), Cache};

    Error ->
      ?LOG_ERROR("invalid confirm token ~p ~p", [TokenKey, Error]),
      {reply, invalid, Cache}
  end;

handle_call({confirm_spend_all}, _From, Cache) ->
  ?LOG_DEBUG("handle_call confirm_spend_all/0 : ~p", [Cache]),
  {reply, ok, Cache};

handle_call({transaction, Data}, _From, State) ->
  ?LOG_DEBUG("handle_call transaction/1 : ~p", [Data]),
  {reply, ok, State};

handle_call({delete_account, Email}, _From, Cache) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  #{decodedResult := []} =
    contract_call(
      Email,
      AccountContract,
      "contracts/account.aes",
      "delete_account",
      []
    ),
  ?LOG_DEBUG("deleting account data ~p", [Email]),
  {reply, #{}, maps:delete(Email, Cache)};

handle_call({set_meta, #{email := Email} = AccountMeta}, _From, Cache) ->
  AccountCache = maps:get(Email, Cache, #{}),
  NewAccountMeta = maps:merge(maps:get(meta, AccountCache, #{}), AccountMeta),
  {ok, AccountContract} = application:get_env(damage, account_contract),
  NewAccountMetaEncrypted =
    base64:encode(damage_utils:encrypt(jsx:encode(NewAccountMeta))),
  #{decodedResult := []} =
    contract_call(
      Email,
      AccountContract,
      "contracts/account.aes",
      "set_meta",
      [NewAccountMetaEncrypted]
    ),
  ?LOG_DEBUG("set_meta caching ~p", [NewAccountMeta]),
  {
    reply,
    NewAccountMeta,
    maps:put(Email, maps:put(meta, NewAccountMeta, AccountCache), Cache)
  };

handle_call({revoke_access_token, TokenKey}, _From, Cache) ->
  #{decodedResult := []} =
    contract_call_admin_account("revoke_auth_token", [TokenKey]),
  TokenCache = maps:get(tokens, Cache, #{}),
  {reply, ok, maps:put(tokens, maps:remove(TokenKey, TokenCache), Cache)};

handle_call({set_access_token, TokenKey, Token}, _From, Cache) ->
  #{decodedResult := []} =
    contract_call_admin_account("add_auth_token", [TokenKey, Token]),
  TokenCache = maps:get(tokens, Cache, #{}),
  {reply, ok, maps:put(tokens, maps:put(TokenKey, Token, TokenCache), Cache)};

handle_call({get_access_token, AccessToken}, _From, Cache) ->
  TokenCache = maps:get(tokens, Cache, #{}),
  case catch maps:get(AccessToken, TokenCache, undefined) of
    undefined ->
      case contract_call_admin_account("get_auth_token", [AccessToken]) of
        #{decodedResult := <<"notfound">>} -> {reply, notfound, Cache};

        #{decodedResult := EncryptedMetaJson} ->
          ?LOG_DEBUG("Cache miss get_access_token ~p", [EncryptedMetaJson]),
          Token =
            jsx:decode(
              damage_utils:decrypt(base64:decode(EncryptedMetaJson)),
              [{labels, binary}]
            ),
          {
            reply,
            Token,
            maps:put(tokens, maps:put(AccessToken, Token, TokenCache), Cache)
          }
      end;

    Token when is_map(Token) ->
      ?LOG_DEBUG("Cache hit get_access_token ~p", [Token]),
      {reply, Token, Cache}
  end;

handle_call({get_meta, EmailOrUsername}, _From, Cache) ->
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  case catch maps:get(meta, AccountCache, undefined) of
    undefined ->
      case contract_call_user_account(EmailOrUsername, "get_meta", []) of
        #{status := <<"fail">>} -> {reply, notfound, Cache};
        <<"notfound">> -> {reply, notfound, Cache};

        #{
          result := #{callerId := AeAccount},
          decodedResult := EncryptedMetaJson
        } ->
          Meta =
            maps:put(
              ae_account,
              AeAccount,
              jsx:decode(
                damage_utils:decrypt(base64:decode(EncryptedMetaJson)),
                [{labels, atom}]
              )
            ),
          ?LOG_DEBUG("no Cache hit get Meta ~p", [Meta]),
          {
            reply,
            Meta,
            maps:put(EmailOrUsername, maps:put(meta, Meta, AccountCache), Cache)
          }
      end;

    Meta when is_map(Meta) ->
      ?LOG_DEBUG("Cache hit get Meta ~p", [Meta]),
      {reply, Meta, Cache}
  end;

handle_call({resolve_npub, NPub}, _From, Cache) ->
  case catch maps:get(NPub, Cache, undefined) of
    undefined ->
      case catch contract_call_admin_account("resolve_npub", [NPub]) of
        #{decodedResult := EncryptedMetaJson} ->
          AeAccount = damage_utils:decrypt(base64:decode(EncryptedMetaJson)),
          ?LOG_DEBUG("cache miss npub ~p ~p", [NPub, AeAccount]),
          {reply, AeAccount, maps:put(NPub, AeAccount, Cache)};

        Error ->
          ?LOG_DEBUG("Error  ~p", [Error]),
          {reply, error, Cache}
      end;

    Meta when is_map(Meta) ->
      ?LOG_DEBUG("Cache hit get Meta ~p", [Meta]),
      {reply, Meta, Cache};

    Error ->
      ?LOG_DEBUG("Error  ~p", [Error]),
      {reply, error, Cache}
  end.


filter_map(Map, Keys) when is_map(Map), is_list(Keys) ->
  maps:filter(fun (Key, _) -> lists:member(Key, Keys) end, Map).

handle_cast(
  {
    confirm_spend,
    #{
      username := EmailOrUsername,
      feature_hash := _FeatureHash,
      report_hash := _ReportHash,
      token_contract := DamageTokenContract,
      node_public_key := NodePublicKey
    } = RunRecord
  },
  Cache
) ->
  SpendRecord =
    filter_map(
      RunRecord,
      [
        feature_hash,
        report_hash,
        run_id,
        schedule_id,
        start_time,
        end_time,
        result_status,
        execution_time
      ]
    ),
  ?LOG_DEBUG("confirm spend ~p", [RunRecord]),
  AccountCache = maps:get(EmailOrUsername, Cache, #{}),
  case maps:get(spent_balance, AccountCache, {0, 0}) of
    {_, Amount} when Amount > 0 ->
      case
      contract_call(
        EmailOrUsername,
        binary_to_list(DamageTokenContract),
        "contracts/token.aes",
        "spend",
        [NodePublicKey, Amount, SpendRecord]
      ) of
        #{
          decodedEvents
          :=
          [
            #{
              args := [_UserAeAccount, _NodeAeAccount, _Amount],
              name := <<"Transfer">>,
              contract := #{name := <<"DamageToken">>, address := _TokenAddress}
            }
          ]
        } ->
          NewCache =
            maps:put(
              EmailOrUsername,
              maps:put(spent_balance, {Amount, 0}, AccountCache),
              Cache
            ),
          ?LOG_DEBUG("confirm spend cached ~p", [NewCache]),
          {noreply, NewCache};

        #{status := <<"fail">>} ->
          ?LOG_DEBUG("confirm spend failed ~p", [Cache]),
          {noreply, Cache}
      end;

    {_, Amount} ->
      ?LOG_DEBUG("Amount 0: ~p", [Amount]),
      {noreply, Cache}
  end;

handle_cast({spend, Email, Amount}, Cache) when is_list(Email) ->
  handle_cast({spend, list_to_binary(Email), Amount}, Cache);

handle_cast({spend, Email, Amount}, Cache) when is_binary(Email) ->
  AccountCache = maps:get(Email, Cache, #{}),
  {Balance, Spend} = maps:get(spent_balance, AccountCache, {0, 0}),
  NewCache = maps:put(spent_balance, {Balance, Spend + Amount}, AccountCache),
  {noreply, maps:put(Email, NewCache, Cache)};

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
  ?LOG_INFO("aecli cmd : ~p", [string:join(Cmd, " ")]),
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
      end;

    {error, [{exit_status, _ExitStatus}, {stderr, Err}]} ->
      ?LOG_ERROR("Stderr ~p  ", [Err]),
      #{status => <<"fail">>}
  end.


contract_call_user_account(Email, Func, Args) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  contract_call(Email, AccountContract, "contracts/account.aes", Func, Args).


contract_call_admin_account(Func, Args) ->
  AdminPassword = os:getenv("DAMAGE_AE_WALLET_PASSWORD"),
  {ok, AdminWallet} = application:get_env(damage, ae_wallet),
  {ok, AccountContract} = application:get_env(damage, account_contract),
  contract_call(
    AdminWallet,
    AdminPassword,
    AccountContract,
    "contracts/account.aes",
    Func,
    Args
  ).


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
    [
      "/home/steven/.npm-packages/bin/aecli",
      "contract",
      "call",
      "--contractSource",
      Contract,
      "--contractAddress",
      ContractAddress,
      Func,
      binary_to_list(jsx:encode(Args)),
      WalletPath,
      "--password",
      WalletPassword,
      "--json"
    ],
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
    [
      "/home/steven/.npm-packages/bin/aecli",
      "contract",
      "deploy",
      WalletPath,
      "--contractSource",
      Contract,
      binary_to_list(jsx:encode(Args)),
      "--password",
      WalletPassword,
      "--json"
    ],
  exec_aecli(Cmd).


get_wallet_proc(Username) ->
  case gproc:lookup_local_name({?MODULE, Username}) of
    undefined ->
      case supervisor:start_child(
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
      ) of
        {ok, AePid} ->
          gproc:reg_other({n, l, {?MODULE, Username}}, AePid),
          AePid;

        {error, {already_started, AePid}} ->
          gproc:reg_other({n, l, {?MODULE, Username}}, AePid),
          AePid
      end;

    Pid -> Pid
  end.


balance(AeAccount) when is_binary(AeAccount) ->
  balance(binary_to_list(AeAccount));

balance(AeAccount) ->
  ?LOG_DEBUG("Check balance ~p", [AeAccount]),
  DamageAEPid = get_wallet_proc(AeAccount),
  gen_server:call(DamageAEPid, {balance, AeAccount}, ?AE_TIMEOUT).


get_reports(AeAccount) ->
  ?LOG_DEBUG("Check balance ~p", [AeAccount]),
  DamageAEPid = get_wallet_proc(AeAccount),
  gen_server:call(DamageAEPid, {reports, AeAccount}, ?AE_TIMEOUT).


spend(Email, Amount) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(Email),
  gen_server:cast(DamageAEPid, {spend, Email, Amount}).


confirm_spend_all() ->
  DamageAEPid = get_wallet_proc(ae),
  gen_server:cast(DamageAEPid, {confirm_spend_all}).


start_batch_spend_timer() ->
  ?LOG_INFO("Starting batch spend timer."),
  erlcron:cron(
    <<"batch_spend_timer">>,
    {{daily, {every, {3600, sec}}}, {damage_ae, confirm_spend_all, []}}
  ).


confirm_spend(#{username := Username} = Context) ->
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


delete_webhook(EmailOrUsername, WebhookName) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(
    DamageAEPid,
    {delete_webhook, EmailOrUsername, WebhookName},
    ?AE_TIMEOUT
  ).


get_schedules(EmailOrUsername) ->
  DamageAEPid = get_wallet_proc(EmailOrUsername),
  gen_server:call(DamageAEPid, {get_schedules, EmailOrUsername}, ?AE_TIMEOUT).


set_meta(#{email := Email} = Meta) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(Email),
  gen_server:call(DamageAEPid, {set_meta, Meta}, ?AE_TIMEOUT).


get_meta(Email) ->
  case filelib:is_regular(get_wallet_path(Email)) of
    true ->
      % temporary storage to commit after feature execution
      DamageAEPid = get_wallet_proc(Email),
      gen_server:call(DamageAEPid, {get_meta, Email}, ?AE_TIMEOUT);

    _ -> notfound
  end.


delete_account(Email) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(Email),
  gen_server:call(DamageAEPid, {delete_account, Email}, ?AE_TIMEOUT).


invalidate_cache(Username) ->
  DamageAEPid = get_wallet_proc(Username),
  gen_server:cast(DamageAEPid, {invalidate_cache, Username}).


revoke_token(Email, Token) ->
  DamageAEPid = get_wallet_proc(Email),
  gen_server:cast(DamageAEPid, {revoke_access_token, Token}).


get_domain_token(Email, Domain) ->
  DamageAEPid = get_wallet_proc(Email),
  gen_server:cast(DamageAEPid, {get_domain_token, Domain}).


add_domain_token(Email, Domain, DomainContext) ->
  DamageAEPid = get_wallet_proc(Email),
  gen_server:cast(DamageAEPid, {add_domain_token, Domain, DomainContext}).


revoke_domain_token(Email, Domain) ->
  DamageAEPid = get_wallet_proc(Email),
  gen_server:cast(DamageAEPid, {add_domain_token, Domain}).


resolve_npub(Npub) ->
  % temporary storage to commit after feature execution
  DamageAEPid = get_wallet_proc(admin),
  gen_server:call(DamageAEPid, {resolve_npub, Npub}, ?AE_TIMEOUT).


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
      ?LOG_DEBUG("read_stream Status ~p Response: ~p", [Status, Body]),
      jsx:decode(Body, [{labels, atom}, return_maps]);

    Default ->
      ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
      Default
  end.


get_wallet_password(EmailOrUsername) ->
  AEPassword = os:getenv("DAMAGE_AE_WALLET_PASSWORD"),
  binary_to_list(damage_utils:idhash_keys([EmailOrUsername, AEPassword])).


get_wallet_path(Email) ->
  WalletName = binary_to_list(damage_utils:idhash_keys([Email])),
  filename:join(["wallets", "damagebdd_user_wallet_" ++ WalletName]).


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
          [
            "/home/steven/.npm-packages/bin/aecli",
            "account",
            "create",
            "--password",
            get_wallet_password(EmailOrUsername),
            "--json",
            WalletPath
          ],
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


transfer_damage_tokens(AeAccount, Amount) ->
  {ok, AdminWalletPath} = application:get_env(damage, ae_wallet),
  AdminPassword = os:getenv("DAMAGE_AE_WALLET_PASSWORD"),
  {ok, TokenContract} = application:get_env(damage, token_contract),
  ContractCall =
    contract_call(
      AdminWalletPath,
      AdminPassword,
      TokenContract,
      "contracts/token.aes",
      "transfer",
      [AeAccount, Amount]
    ),
  ?LOG_DEBUG("Tokens transfered ~p", [ContractCall]),
  ContractCall.


fund_wallet(AeAccount, EmailOrUsername, Amount) when is_binary(AeAccount) ->
  fund_wallet(binary_to_list(AeAccount), EmailOrUsername, Amount);

fund_wallet(AeAccount, EmailOrUsername, Amount) ->
  {ok, AdminWalletPath} = application:get_env(damage, ae_wallet),
  AdminPassword = os:getenv("DAMAGE_AE_WALLET_PASSWORD"),
  Cmd =
    [
      "/home/steven/.npm-packages/bin/aecli",
      "spend",
      "--password",
      AdminPassword,
      "--json",
      AdminWalletPath,
      AeAccount,
      integer_to_list(Amount)
    ],
  Result = exec_aecli(Cmd),
  ?LOG_INFO("Funded wallet with pub key ~p ~p", [EmailOrUsername, Result]),
  maps:put(public_key, AeAccount, Result).


maybe_fund_wallet(EmailOrUsername) ->
  maybe_fund_wallet(EmailOrUsername, ?AE_USER_WALLET_MINIMUM_BALANCE).

maybe_fund_wallet(EmailOrUsername, Amount) ->
  UserWalletPath = get_wallet_path(EmailOrUsername),
  {ok, Wallet} = file:read_file(UserWalletPath),
  #{public_key := UserAccount} =
    jsx:decode(Wallet, [{labels, atom}, return_maps]),
  AeResult =
    case get_ae_balance(UserAccount) of
      #{balance := AeBalance} when AeBalance < ?AE_USER_WALLET_MINIMUM_BALANCE ->
        {funded, fund_wallet(UserAccount, EmailOrUsername, Amount)};

      #{reason := <<"Account not found">>} ->
        {funded, fund_wallet(UserAccount, EmailOrUsername, Amount)};

      Result ->
        ?LOG_INFO(
          "Wallet above minimum balance ~p ~p",
          [EmailOrUsername, Result]
        ),
        {notfunded, #{public_key => UserAccount}}
    end,
  DamageTokenResult =
    case balance(UserAccount) of
      Balance when Balance < ?DAMAGE_USER_WALLET_MINIMUM_BALANCE ->
        {funded, transfer_damage_tokens(UserAccount, Amount)};

      #{reason := <<"Account not found">>} ->
        {funded, fund_wallet(UserAccount, EmailOrUsername, Amount)};

      Result0 ->
        ?LOG_INFO(
          "Wallet above minimum balance ~p ~p",
          [EmailOrUsername, Result0]
        ),
        {notfunded, #{public_key => UserAccount}}
    end,
  {AeResult, DamageTokenResult}.


maybe_create_wallet(Email, Password) ->
  create_wallet(Email),
  Funded = maybe_fund_wallet(Email),
  set_meta(#{email => Email, password => Password}),
  Funded.


deploy_account_contract() ->
  {ok, AdminWallet} = application:get_env(damage, ae_wallet),
  AdminPassword = os:getenv("DAMAGE_AE_WALLET_PASSWORD"),
  #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
    contract_deploy(AdminWallet, AdminPassword, "contracts/account.aes", []),
  application:set_env(damage, account_contract, binary_to_list(ContractAddress)),
  ?LOG_INFO("Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]),
  ContractAddress.

%% Main function to find the block height at or near the given timestamp.
%% It initializes an empty cache (map) and passes it along the recursive calls.

find_block_at_timestamp(Timestamp, ConnPid) ->
  {ok, TopBlockHeight} = get_latest_block_height(ConnPid),
  ?LOG_INFO("High ~p", [TopBlockHeight]),
  % Initialize an empty cache
  Cache = #{},
  binary_search_block(Timestamp, 100000, TopBlockHeight, ConnPid, Cache).

%% Perform a binary search to find the closest block at or before the given timestamp.

binary_search_block(TargetTimestamp, Low, High, ConnPid, Cache) when Low =< High ->
  Mid = (Low + High) div 2,
  ?LOG_INFO("Mid ~p", [Mid]),
  case get_block_timestamp_with_cache(Mid, ConnPid, Cache) of
    {ok, {BlockTimestamp, NewCache}} ->
      case BlockTimestamp of
        _ when BlockTimestamp =:= TargetTimestamp ->
          % Exact match
          {ok, Mid};

        notfound ->
          binary_search_block(TargetTimestamp, Mid + 1, High, ConnPid, NewCache);

        _ when BlockTimestamp < TargetTimestamp ->
          binary_search_block(TargetTimestamp, Mid + 1, High, ConnPid, NewCache);

        _ when BlockTimestamp > TargetTimestamp ->
          binary_search_block(TargetTimestamp, Low, Mid - 1, ConnPid, NewCache)
      end;

    {error, _Error} ->
      binary_search_block(TargetTimestamp, Mid + 1, High, ConnPid, Cache)
  end;

binary_search_block(_, Low, _, _, Cache) ->
  ?LOG_INFO("Low ~p", [Low]),
  {ok, maps:get(lastblock, Cache, no_block_found), Cache}.

%% Get the latest block height from the Aeternity API.

get_latest_block_height(ConnPid) ->
  StreamRef = gun:get(ConnPid, "/v3/status"),
  #{node_height := NodeHeight} = read_stream(ConnPid, StreamRef),
  {ok, NodeHeight}.

%% Caching mechanism using a map: check the cache first, if not found, fetch from API and update the cache.

get_block_timestamp_with_cache(Height, ConnPid, Cache) ->
  case maps:get(Height, Cache, undefined) of
    Timestamp when Timestamp =/= undefined ->
      % Return cached timestamp
      {ok, {Timestamp, Cache}};

    undefined ->
      % Fetch from API if not cached
      HeightBin = integer_to_binary(Height),
      HeightBinLen = size(HeightBin),
      case get_block_timestamp(Height, ConnPid) of
        {ok, BlockTimestamp} ->
          % Update the cache
          NewCache = maps:put(Height, BlockTimestamp, Cache),
          {ok, {BlockTimestamp, maps:put(lastblock, Height, NewCache)}};

        {error, #{error := <<"not found:", HeightBin:HeightBinLen/binary>>}} ->
          NewCache = maps:put(Height, notfound, Cache),
          {notfound, {Height, NewCache}};

        Error -> {error, {Error, Cache}}
      end
  end.

%% Get the block's timestamp at a specific height (without caching).

get_block_timestamp(Height, ConnPid) ->
  StreamRef = gun:get(ConnPid, "/v3/key-blocks/" ++ integer_to_list(Height)),
  case read_stream(ConnPid, StreamRef) of
    #{time := KeyBlockTime} ->
      ?LOG_INFO("Block timestamp ~p", [KeyBlockTime]),
      {ok, KeyBlockTime};

    Error -> Error
  end.


test_find_block() ->
  case get_ae_mdw_node() of
    {ok, ConnPid, _PathPrefix} ->
      find_block_at_timestamp(1726119531337, ConnPid);

    Error -> ?LOG_ERROR("Failed to find block timestamp ~p", [Error])
  end.


test_create_wallet() ->
  #{public_key := WalletAddress} =
    maybe_create_wallet("steven@gmail.com", "testpass"),
  ?LOG_INFO("Wallet created ~p ", [WalletAddress]).


test_contract_call() ->
  {ok, AeAccount} = application:get_env(damage, ae_account),
  JobId = <<"sdds">>,
  %{ok, Nonce} = vanillae:next_nonce(AeAccount),
  #{nonce := Nonce} = get_ae_balance(AeAccount),
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
