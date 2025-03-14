-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(AECLI_EXEC, "/home/steven/.npm-packages/bin/aecli").
-define(TAG_CONTRACT_CALL_TX, 43).
-define(TAG_SIGNED_TX, 11).
-define(OBJECT_VERSION, 1).
-define(HASH_BYTES, 32).

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
        transfer_damage_tokens/3,
        get_account_context/1,
        get_webhooks/1,
        add_webhook/3,
        delete_webhook/2,
        add_context/4,
        confirm_spend_all/0,
        start_batch_spend_timer/0,
        get_reports/1,
        get_domain_token/2,
        add_domain_token/3,
        revoke_domain_token/2,
        contract_call_admin_account/2,
        get_ae_mdw_node/0,
        get_ae_mdw_ws_node/0,
        node_keypair/0,
        account_keypair/1,
        deploy_account_contract/0,
        deploy_keystore_contract/0,
        deploy_identity_contract/0,
        deploy_knowledge_nft_contract/0
    ]
).
-export([contract_call/5, contract_deploy/3]).
-export([test_contract_call/0, test_create_wallet/0, test_contract_deploy/0]).
-export([balance/1, invalidate_cache/1, spend/2, confirm_spend/1]).
-export([get_schedules/1]).
-export([delete_account/1]).
-export([revoke_token/2]).
-export([get_block_height_since/2]).
-export([test_get_block_height_since/0]).
-export([test_find_block/0]).
-export([test_verify_message/0]).
-export([test_get_user_keypair/0]).
-export([get_wallet_proc/1]).
-export([ae_to_aetto/1]).

start_link() -> gen_server:start_link(?MODULE, [], []).

ae_to_aetto(Ae) -> Ae * 1000000000000000.

%Ae * 100000000000000000.
init([]) ->
    process_flag(trap_exit, true),
    ConfirmSpendTimer = erlang:send_after(10000, self(), confirm_spend_all),
    {ok, WS, _Path} = get_ae_mdw_node(),
    {ok, #{heartbeat_timer => ConfirmSpendTimer, websocket => WS}}.

find_active_node([{Host, Port, PathPrefix} | Rest]) ->
    case gun:open(Host, Port, #{tls_opts => [{verify, verify_none}]}) of
        {ok, ConnPid} ->
            {ok, ConnPid, PathPrefix};
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
    SinceSeconds =
        date_util:datetime_to_epoch(calendar:now_to_datetime(erlang:timestamp())) -
            hours_to_seconds(SinceHours),
    ?LOG_DEBUG("Since seconds ~p", [SinceSeconds]),
    {ok, Result, _MicroBlocks} = find_block_at_timestamp(SinceSeconds, ConnPid),
    Result.

hours_to_seconds(Hours) -> 3600 * Hours.

%% Function to extract the "feature_hash" and other arguments into a map

extract_arguments(Arguments) ->
    %% Iterate through each argument to build the result map
    lists:foldl(fun process_argument/2, #{}, Arguments).

%% Helper function to process each argument

process_argument(#{type := <<"map">>, value := MapValues}, Acc) ->
    %% Iterate through the key-value pairs in the "map" argument and add to the accumulator
    lists:foldl(fun process_map_entry/2, Acc, MapValues);
process_argument(#{type := Type, value := Value}, Acc) ->
    %% Handle other argument types (e.g., "address", "int")
    %% We can label each by its type in the resulting map for clarity
    maps:put(Type, Value, Acc).

process_field(<<"execution_time">>, Value) -> string:to_float(Value);
process_field(<<"start_time">>, Value) -> string:to_float(Value);
process_field(<<"end_time">>, Value) -> string:to_float(Value);
process_field(_, Value) -> Value.

%% Helper function to process each key-value pair inside the "map" argument

process_map_entry(
    #{
        key := #{type := <<"string">>, value := Key},
        val := #{type := <<"string">>, value := Val}
    },
    Acc
) ->
    %% Add the key-value pair to the accumulator map
    maps:put(Key, process_field(Key, Val), Acc).

%% Function to find the latest record with the given feature_hash

find_latest_record_with_feature_hash(Records, FeatureHash) ->
    ?LOG_DEBUG("call records ~p", [Records]),
    %% Filter records with the given feature_hash
    MatchingRecords =
        [
            Record
         || Record <- Records,
            Record =/= #{},
            maps:get(<<"feature_hash">>, Record) =:= FeatureHash
        ],
    %% Check if there are matching records
    case MatchingRecords of
        [] ->
            %% Return error if no matching records
            {error, not_found};
        _ ->
            %% Find the record with the latest end_time
            damage_utils:max_by(MatchingRecords, fun compare_records/2)
    end.

%% Helper function to compare two records based on their end_time

compare_records(Record1, Record2) ->
    EndTime1 = maps:get(<<"end_time">>, Record1),
    EndTime2 = maps:get(<<"end_time">>, Record2),
    if
        EndTime1 >= EndTime2 -> true;
        EndTime1 < EndTime2 -> false
    end.

extract_feature_hash(Data) ->
    %% Navigate through the parsed JSON to find the "feature_hash"
    Payload = maps:get(payload, Data),
    Tx = maps:get(tx, Payload),
    Arguments = maps:get(arguments, Tx),
    %% Find the map in the "arguments" that contains the key "feature_hash"
    extract_arguments(Arguments).

handle_call({get_published, AeAccount}, _From, Cache) ->
    case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            Path =
                PathPrefix ++ "v3/accounts/" ++ AeAccount ++ "activities?type=aex141",
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
handle_call(
    {get_last_test_status, AeAccount, FeatureHash, _Hours},
    _From,
    Cache
) ->
    case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            %BlockHeight = get_block_height_since(Hours, ConnPid),
            %?LOG_DEBUG("BlockHeight ~p", [BlockHeight]),
            Path =
                PathPrefix ++
                    "v3/accounts/" ++
                    binary_to_list(AeAccount) ++
                    "/activities?owned_only=true&direction=backward&type=transactions&limit=100",
            %++
            %integer_to_list(BlockHeight),
            ?LOG_DEBUG("Path ~p", [Path]),
            StreamRef = gun:get(ConnPid, Path),
            case read_stream(ConnPid, StreamRef) of
                #{data := null} ->
                    {reply, undefined, Cache};
                #{data := Results} ->
                    TxData = [extract_feature_hash(Result) || Result <- Results],
                    case find_latest_record_with_feature_hash(TxData, FeatureHash) of
                        #{
                            <<"result_status">> :=
                                <<?RESULT_STATUS_PREFIX_SUCCESS, _Timestamp/binary>>
                        } ->
                            {reply, "success", Cache};
                        #{
                            <<"result_status">> :=
                                <<?RESULT_STATUS_PREFIX_FAIL, _Timestamp/binary>>
                        } ->
                            {reply, "failed", Cache};
                        {error, not_found} ->
                            {reply, "not_found", Cache};
                        #{<<"result_status">> := <<Result:1/binary, _Timestamp/binary>>} ->
                            {reply, Result, Cache}
                    end
            end;
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}, Cache}
    end;
handle_call({reports, AeAccount}, _From, Cache) ->
    {ok, DamageToken} = application:get_env(damage, token_contract),
    case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            Path =
                PathPrefix ++
                    "v3/transactions/?direction=backward&type=contract_call&contract=" ++
                    DamageToken ++
                    "&account=" ++
                    AeAccount ++
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
                case catch read_stream(ConnPid, StreamRef) of
                    #{amount := null} ->
                        0;
                    {error, Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{error := Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{amount := Balance0} ->
                        Balance0
                end,
            {reply, Balance, Cache};
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}, Cache}
    end;
handle_call({get_schedules, AeAccount}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case catch maps:get(schedules, AccountCache, undefined) of
        undefined ->
            #{decodedResult := Results} =
                contract_call_user_account(AeAccount, "get_schedules", []),
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
                maps:put(AeAccount, maps:put(schedules, Schedules, AccountCache), Cache)
            };
        Schedules when is_map(Schedules) -> {reply, Schedules, Cache}
    end;
handle_call({get_context, AeAccount}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case catch maps:get(context, AccountCache, undefined) of
        undefined ->
            #{decodedResult := Results} =
                contract_call_user_account(AeAccount, "get_context", []),
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
                    AeAccount,
                    maps:put(context, ClientContext, AccountCache),
                    Cache
                )
            };
        Context when is_map(Context) -> {reply, Context, Cache}
    end;
handle_call({set_context, AeAccount, AccountContext}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    NewAccountContext =
        maps:merge(maps:get(context, AccountCache, #{}), AccountContext),
    Results =
        contract_call_user_account(AeAccount, "set_context", [NewAccountContext]),
    ?LOG_DEBUG("set_context caching ~p, ~p", [NewAccountContext, Results]),
    {
        reply,
        NewAccountContext,
        maps:put(
            AeAccount,
            maps:put(context, NewAccountContext, AccountCache),
            Cache
        )
    };
handle_call({add_context, AeAccount, Key, Value, Visibility}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    ContextCache = maps:get(context, AccountCache, #{}),
    KeyEncrypted = base64:encode(damage_utils:encrypt(Key)),
    ValueEncrypted = base64:encode(damage_utils:encrypt(Value)),
    Results =
        contract_call_user_account(
            AeAccount,
            "add_context",
            [KeyEncrypted, ValueEncrypted, Visibility]
        ),
    ?LOG_DEBUG("AddContext ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(context, maps:put(Key, Value, ContextCache), AccountCache),
            Cache
        )
    };
handle_call({delete_context, AeAccount, Key}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    ContextCache = maps:get(context, AccountCache, #{}),
    ContextKeyEnc = base64:encode(damage_utils:encrypt(Key)),
    Results =
        contract_call_user_account(
            AeAccount,
            "delete_context",
            [ContextKeyEnc]
        ),
    ?LOG_DEBUG("wWebhooks ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(context, maps:delete(Key, ContextCache), AccountCache),
            Cache
        )
    };
handle_call({get_webhooks, AeAccount}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case catch maps:get(webhooks, AccountCache, undefined) of
        undefined ->
            #{decodedResult := Results} =
                contract_call_user_account(AeAccount, "get_webhooks", []),
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
                maps:put(AeAccount, maps:put(webhooks, WebHooks, AccountCache), Cache)
            };
        Context when is_map(Context) -> {reply, Context, Cache}
    end;
handle_call({add_webhook, AeAccount, WebhookName, WebhookUrl}, _From, Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    WebHookCache = maps:get(webhooks, AccountCache, #{}),
    WebhookUrlEncrypted = base64:encode(damage_utils:encrypt(WebhookUrl)),
    WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
    Results =
        contract_call_user_account(
            AeAccount,
            "add_webhook",
            [WebhookNameEncrypted, WebhookUrlEncrypted]
        ),
    ?LOG_DEBUG("wWebhooks ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(
                webhooks,
                maps:put(WebhookName, WebhookUrl, WebHookCache),
                AccountCache
            ),
            Cache
        )
    };
handle_call({delete_webhook, AeAccount, WebhookName}, _From, Cache) ->
    WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
    Results =
        contract_call_user_account(
            AeAccount,
            "delete_webhook",
            [WebhookNameEncrypted]
        ),
    ?LOG_DEBUG("Webhooks ~p", [Results]),
    {reply, Results, Cache};
handle_call({get_auth_token, AeAccount, TokenKey}, _From, Cache) ->
    case contract_call_user_account(AeAccount, "get_auth_token", [TokenKey]) of
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
handle_call({delete_account, AeAccount}, _From, Cache) ->
    {ok, AccountContract} = application:get_env(damage, account_contract),
    #{decodedResult := []} =
        contract_call(
            AeAccount,
            AccountContract,
            "contracts/account.aes",
            "delete_account",
            []
        ),
    ?LOG_DEBUG("deleting account data ~p", [AeAccount]),
    {reply, #{}, maps:delete(AeAccount, Cache)};
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
                #{decodedResult := <<"notfound">>} ->
                    {reply, notfound, Cache};
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
    end.

filter_map(Map, Keys) when is_map(Map), is_list(Keys) ->
    maps:filter(fun(Key, _) -> lists:member(Key, Keys) end, Map).

handle_cast(
    {
        confirm_spend,
        #{
            username := AeAccount,
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
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case maps:get(spent_balance, AccountCache, {0, 0}) of
        {_, Amount} when Amount > 0 ->
            case
                contract_call(
                    AeAccount,
                    binary_to_list(DamageTokenContract),
                    "contracts/token.aes",
                    "spend",
                    [NodePublicKey, Amount, SpendRecord]
                )
            of
                #{
                    decodedEvents :=
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
                            AeAccount,
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
handle_cast({spend, AeAccount, Amount}, Cache) when is_list(AeAccount) ->
    handle_cast({spend, list_to_binary(AeAccount), Amount}, Cache);
handle_cast({spend, AeAccount, Amount}, Cache) when is_binary(AeAccount) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    {Balance, Spend} = maps:get(spent_balance, AccountCache, {0, 0}),
    NewCache = maps:put(spent_balance, {Balance, Spend + Amount}, AccountCache),
    {noreply, maps:put(AeAccount, NewCache, Cache)};
handle_cast({invalidate_cache, _AeAccount}, _Cache) ->
    {noreply, #{}};
handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

-define(VALID_PRIVK(K), byte_size(K) =:= 64).

exec_aecli(Cmd) ->
    ?LOG_DEBUG("aecli cmd : ~p", [string:join(Cmd, " ")]),
    AeNodeUrl = get_ae_node_url(),
    case exec:run(Cmd, [stdout, stderr, sync, {env, [{"AECLI_NODE_URL", AeNodeUrl}]}]) of
        %?LOG_DEBUG("Result : ~p", [Result]),
        {ok, [{stdout, StdOutList}]} ->
            jsx:decode(damage_utils:binarystr_join(StdOutList), [{labels, atom}]);
        {ok, [{stdout, StdOutList}, {stderr, [Err | _]}]} ->
            ?LOG_ERROR("Stderr ~s", [Err]),
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

contract_call_user_account(AeAccount, Func, Args) ->
    {ok, AccountContract} = application:get_env(damage, account_contract),
    contract_call(AeAccount, AccountContract, "contracts/account.aes", Func, Args).

contract_call_admin_account(Func, Args) ->
    #{public_key := _AeAccount, private_key := _PrivateKey} = KeyPair = node_keypair(),
    {ok, AccountContract} = application:get_env(damage, account_contract),
    contract_call(
        KeyPair,
        AccountContract,
        "contracts/account.aes",
        Func,
        Args
    ).

contract_call(
    #{public_key := AeAccount, private_key := PrivateKey}, ContractAddress, Contract, Func, Args
) ->
    ?LOG_DEBUG("ae account ~p", [AeAccount]),
    {ok, AACI} = vanillae:prepare_contract(Contract),
    ?LOG_DEBUG("contract prepare_aaci success ~p", [size(AACI)]),
    {ok, ContractCall} = vanillae:contract_call(AeAccount, AACI, ContractAddress, Func, Args),
    ?LOG_DEBUG("contract call ~p", [ContractCall]),
    Signature = make_transaction_signature_base58(PrivateKey, ContractCall),
    SignedTX = attach_signature_base58(ContractCall, Signature),
    {ok, #{"tx_hash" := ContractCallTxHash}} = vanillae:post_tx(SignedTX),
    ?LOG_DEBUG("contract call success ~p", [ContractCallTxHash]),
    ok = wait_tx(ContractCallTxHash).

contract_deploy(#{public_key := AeAccount, private_key := PrivateKey}, Contract, Args) ->
    {ok, ContractData} =
        vanillae:contract_create(AeAccount, Contract, Args),
    SignedContract = sign_transaction_base58(PrivateKey, ContractData),
    %{ok, Nonce} = vanillae:next_nonce(AeAccount),
    %?LOG_DEBUG("tx_info ~p", [SignedContract]),
    %{ok, TxHashBinary} = eblake2:blake2b(?HASH_BYTES, <<SignedContract/binary, Nonce/integer>>),
    %TxHash = aeser_api_encoder:encode(tx_hash, TxHashBinary),
    vanillae:post_tx(SignedContract).

get_wallet_proc(<<"ak_", _/binary>> = AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        % mandatory
                        id => AeAccount,
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
                )
            of
                {ok, AePid} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid;
                {error, {already_started, AePid}} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid
            end;
        Pid ->
            Pid
    end;
get_wallet_proc(admin) ->
    {ok, AeAdmin} = application:get_env(damage, node_public_key),
    get_wallet_proc(list_to_binary(AeAdmin));
get_wallet_proc(Email) ->
    case identity_server:get_account_by_email(Email) of
        notfound -> {error, not_found};
        Aeaccount -> get_wallet_proc(Aeaccount)
    end.

balance(AeAccount) when is_binary(AeAccount) ->
    balance(binary_to_list(AeAccount));
balance(AeAccount) ->
    ?LOG_DEBUG("Check balance ~p", [AeAccount]),
    DamageAEPid = get_wallet_proc(admin),
    gen_server:call(DamageAEPid, {balance, AeAccount}, ?AE_TIMEOUT).

get_reports(AeAccount) ->
    ?LOG_DEBUG("Check balance ~p", [AeAccount]),
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {reports, AeAccount}, ?AE_TIMEOUT).

spend(AeAccount, Amount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {spend, AeAccount, Amount}).

confirm_spend_all() ->
    DamageAEPid = get_wallet_proc(ae),
    gen_server:cast(DamageAEPid, {confirm_spend_all}).

start_batch_spend_timer() ->
    ?LOG_INFO("Starting batch spend timer."),
    erlcron:cron(
        <<"batch_spend_timer">>,
        {{daily, {every, {3600, sec}}}, {damage_ae, confirm_spend_all, []}}
    ).

confirm_spend(#{ae_account := AeAccount} = Context) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {confirm_spend, Context}).

get_account_context(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {get_context, AeAccount}, ?AE_TIMEOUT).

add_context(AeAccount, Key, Value, Visibility) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {add_context, AeAccount, Key, Value, Visibility},
        ?AE_TIMEOUT
    ).

get_webhooks(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {get_webhooks, AeAccount}, ?AE_TIMEOUT).

add_webhook(AeAccount, WebhookName, WebhookUrl) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {add_webhook, AeAccount, WebhookName, WebhookUrl},
        ?AE_TIMEOUT
    ).

delete_webhook(AeAccount, WebhookName) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {delete_webhook, AeAccount, WebhookName},
        ?AE_TIMEOUT
    ).

get_schedules(AeAccount) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {get_schedules, AeAccount}, ?AE_TIMEOUT).

delete_account(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {delete_account, AeAccount}, ?AE_TIMEOUT).

invalidate_cache(Username) ->
    DamageAEPid = get_wallet_proc(Username),
    gen_server:cast(DamageAEPid, {invalidate_cache, Username}).

revoke_token(AeAccount, Token) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {revoke_access_token, Token}).

get_domain_token(AeAccount, Domain) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {get_domain_token, Domain}).

add_domain_token(AeAccount, Domain, DomainContext) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {add_domain_token, Domain, DomainContext}).

revoke_domain_token(AeAccount, Domain) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {add_domain_token, Domain}).

setup_vanillae_deps() ->
    true = code:add_path("_checkouts/vanillae/ebin"),
    true = code:add_path("_checkouts/vw/ebin"),
    Vanillae =
        "otpr-vanillae-" ++ lists:droplast(os:cmd("zx latest otpr-vanillae")),
    Deps = string:lexemes(os:cmd("zx list deps " ++ Vanillae), "\n"),
    ZX =
        "otpr-zx-" ++
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

get_wallet_password(Email) ->
    AEPassword = damage_utils:pass_get(ae_wallet_pass_path),
    binary_to_list(damage_utils:idhash_keys([Email, AEPassword])).

get_wallet_path(Email) ->
    WalletName = binary_to_list(damage_utils:idhash_keys([Email])),
    filename:join(["wallets", "damagebdd_user_wallet_" ++ WalletName]).

create_wallet(WalletName, Password) when is_binary(WalletName) ->
    create_wallet(binary_to_list(WalletName), Password);
create_wallet(Email, _Password) ->
    WalletPath = get_wallet_path(Email),
    ?LOG_DEBUG("Wallet path. ~p", [WalletPath]),
    Created =
        case filelib:is_regular(WalletPath) of
            true ->
                ?LOG_DEBUG("Wallet exists not overwriting. ~p", [WalletPath]),
                existing;
            _ ->
                Cmd =
                    [
                        ?AECLI_EXEC,
                        "account",
                        "create",
                        "--password",
                        get_wallet_password(Email),
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
    % transfer damage tokens from admin account to to account
    {ok, TokenContract} = application:get_env(damage, token_contract),
    ContractCall =
        contract_call(
            node_keypair(),
            TokenContract,
            "contracts/token.aes",
            "transfer",
            [AeAccount, Amount]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [ContractCall]),
    ContractCall.
get_user_keypair(PublicKey) ->
    {ok, KeystoreContract} = application:get_env(damage, keystore_contract),
    Result =
        contract_call(
            node_keypair(),
            KeystoreContract,
            "contracts/keystore.aes",
            "get_keypair",
            [PublicKey]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [Result]),
    Result.

transfer_damage_tokens(FromAccount, ToAeAccount, Amount) ->
    {ok, TokenContract} = application:get_env(damage, token_contract),
    Result =
        contract_call(
            get_user_keypair(FromAccount),
            TokenContract,
            "contracts/token.aes",
            "transfer",
            [ToAeAccount, Amount]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [Result]),
    Result.

fund_wallet(AeAccount, AeAccount, Amount) when is_binary(AeAccount) ->
    fund_wallet(binary_to_list(AeAccount), AeAccount, Amount);
fund_wallet(AeAccount, AeAccount, Amount) ->
    {ok, AdminWalletPath} = application:get_env(damage, ae_wallet),
    AdminPassword = damage_utils:pass_get(ae_wallet_pass_path),
    Cmd =
        [
            ?AECLI_EXEC,
            "spend",
            "--password",
            AdminPassword,
            "--json",
            AdminWalletPath,
            AeAccount,
            integer_to_list(Amount)
        ],
    Result = exec_aecli(Cmd),
    ?LOG_INFO("Funded wallet with pub key ~p ~p", [AeAccount, Result]),
    maps:put(public_key, AeAccount, Result).

maybe_fund_wallet(AeAccount) ->
    maybe_fund_wallet(AeAccount, ?AE_USER_WALLET_MINIMUM_BALANCE).

maybe_fund_wallet(AeAccount, Amount) ->
    UserWalletPath = get_wallet_path(AeAccount),
    {ok, Wallet} = file:read_file(UserWalletPath),
    #{public_key := UserAccount} =
        jsx:decode(Wallet, [{labels, atom}, return_maps]),
    AeResult =
        case get_ae_balance(UserAccount) of
            #{balance := AeBalance} when AeBalance < ?AE_USER_WALLET_MINIMUM_BALANCE ->
                {funded, fund_wallet(UserAccount, AeAccount, Amount)};
            #{reason := <<"Account not found">>} ->
                {funded, fund_wallet(UserAccount, AeAccount, Amount)};
            Result ->
                ?LOG_INFO("Wallet above minimum balance ~p ~p", [AeAccount, Result]),
                {notfunded, #{public_key => UserAccount}}
        end,
    DamageTokenResult =
        case balance(UserAccount) of
            Balance when Balance < ?DAMAGE_USER_WALLET_MINIMUM_BALANCE ->
                {funded, transfer_damage_tokens(UserAccount, Amount)};
            #{reason := <<"Account not found">>} ->
                {funded, fund_wallet(UserAccount, AeAccount, Amount)};
            Result0 ->
                ?LOG_INFO("Wallet above minimum balance ~p ~p", [AeAccount, Result0]),
                {notfunded, #{public_key => UserAccount}}
        end,
    {AeResult, DamageTokenResult}.

maybe_create_wallet(Email, Password) ->
    {_, #{publicKey := AeAccount}} = create_wallet(Email, Password),
    #{publicKey := AeAccount} = Funded = maybe_fund_wallet(AeAccount),
    identity_server:register_email(Email, AeAccount),
    Funded.

%% Main function to find the block height at or near the given timestamp.
%% It initializes an empty cache (map) and passes it along the recursive calls.

find_block_at_timestamp(Timestamp, ConnPid) ->
    {ok, TopBlockHeight} = get_latest_block_height(ConnPid),
    ?LOG_INFO("High ~p", [TopBlockHeight]),
    % Initialize an empty cache
    Cache = #{},
    binary_search_block(Timestamp, 1015354, TopBlockHeight, ConnPid, Cache).

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
    #{top_block_height := NodeHeight} = read_stream(ConnPid, StreamRef),
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
                Error ->
                    {error, {Error, Cache}}
            end
    end.

%% Get the block's timestamp at a specific height (without caching).

get_block_timestamp(Height, ConnPid) ->
    StreamRef = gun:get(ConnPid, "/v3/key-blocks/" ++ integer_to_list(Height)),
    case read_stream(ConnPid, StreamRef) of
        #{time := KeyBlockTime} ->
            ?LOG_INFO("Block timestamp ~p", [KeyBlockTime]),
            {ok, KeyBlockTime};
        Error ->
            Error
    end.

attach_signature(TX, Sig) ->
    SignedTXTemplate = [{signatures, [binary]}, {transaction, binary}],
    Fields = [{signatures, [Sig]}, {transaction, TX}],
    aeser_chain_objects:serialize(signed_tx, 1, SignedTXTemplate, Fields).

attach_signature_base58(EncodedTX, EncodedSig) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    {signature, Sig} = aeser_api_encoder:decode(EncodedSig),
    SignedTX = attach_signature(TX, Sig),
    aeser_api_encoder:encode(transaction, SignedTX).
% returns the signature by itself
make_transaction_signature_base58(Priv, EncodedTX) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    Sig = make_transaction_signature(Priv, TX),
    aeser_api_encoder:encode(signature, Sig).
make_transaction_signature(Priv, TX) ->
    Id = list_to_binary(vanillae:network_id()),
    Blob = <<Id/binary, TX/binary>>,
    enacl:sign_detached(Blob, Priv).
sign_transaction(Priv, TX) ->
    Sig = make_transaction_signature(Priv, TX),
    SignedTXTemplate = [{signatures, [binary]}, {transaction, binary}],
    Fields = [{signatures, [Sig]}, {transaction, TX}],
    aeser_chain_objects:serialize(signed_tx, 1, SignedTXTemplate, Fields).
sign_transaction_base58(Priv, EncodedTX) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    SignedTX = sign_transaction(Priv, TX),
    aeser_api_encoder:encode(transaction, SignedTX).

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
            ok = file:write_file(Path, term_to_binary(Data)),
            Data;
        {ok, Data} ->
            #{public_key := _Pub, private_key := _Priv} = binary_to_term(Data)
    end.
account_keypair(AeAccount) ->
    {ok, KeyStoreContract} = application:get_env(damage, keystore_contract),
    #{public_key := _AeAccount, private_key := _PrivateKey} = KeyPair = damage_ae:node_keypair(),
    damage_ae:contract_call(
        KeyPair,
        KeyStoreContract,
        "contracts/keystore.aes",
        "get_keypair",
        [AeAccount]
    ).

tx_info_convert_result(ResultDef, Result) ->
    ?LOG_DEBUG("Got value ~p", [Result]),
    case Result of
        #{
            "call_info" := #{
                "caller_id" := _CallerId,
                "caller_nonce" := _CallerNonce,
                "contract_id" := _ContractId,
                "gas_price" := _GasPrice,
                "gas_used" := _GasUsed,
                "height" := _Height,
                "log" := _log,
                "return_type" := _ReturnType,
                "return_value" := Encoded
            }
        } ->
            Res = vanillae:decode_bytearray(ResultDef, Encoded),
            Res;
        {error, Reason} ->
            {error, Reason}
    end.

poll_tx(Fun, Args, Interval, Timeout) ->
    poll_tx(Fun, Args, Interval, Timeout, erlang:monotonic_time(millisecond)).

poll_tx(Fun, Args, Interval, Timeout, StartTime) ->
    case apply(Fun, Args) of
        {ok, Result} ->
            tx_info_convert_result(map, Result);
        Result ->
            ?LOG_DEBUG("error value ~p", [Result]),
            Elapsed = erlang:monotonic_time(millisecond) - StartTime,
            if
                Elapsed >= Timeout ->
                    exit({timeout_error, {polling_failed, Result, Fun, Args}});
                true ->
                    timer:sleep(Interval),
                    poll_tx(Fun, Args, Interval, Timeout, StartTime)
            end
    end.

wait_tx(ConId) ->
    poll_tx(fun vanillae:tx_info/1, [ConId], 1000, 15000).

test_get_user_keypair() ->
    AeAccount = <<"">>,
    get_user_keypair(AeAccount).

test_contract_call() ->
    {ok, AccountContract} = application:get_env(damage, account_contract),
    #{public_key := _AeAccount, private_key := _PrivateKey} = KeyPair = node_keypair(),
    ?LOG_DEBUG("contract account ~p", [AccountContract]),
    contract_call(KeyPair, AccountContract, "contracts/account.aes", "get_schedules", []).

test_contract_deploy() ->
    KeyPair = #{public_key := _AeAccount, private_key := _PrivateKey} = node_keypair(),

    %KeyPair = get_user_keypair(AeAccount),
    contract_deploy(KeyPair, "contracts/account.aes", []).
%{ok, Response} =
%SignedContractCall = svt:sign_contract(ContractCall, PrivateKey),

test_find_block() ->
    {Today, _Now} = calendar:local_time(),
    Yesterday = date_util:subtract(Today, {days, 1}),
    ADayAgo = date_util:date_to_epoch(Yesterday),
    case get_ae_mdw_node() of
        {ok, ConnPid, _PathPrefix} ->
            case find_block_at_timestamp(ADayAgo * 1000, ConnPid) of
                {ok, Block, Mblocks} ->
                    ?LOG_INFO("Found block ~p ~p", [Block, Mblocks]);
                Error ->
                    ?LOG_ERROR("block not found ~p", [Error])
            end;
        Error ->
            ?LOG_ERROR("Failed to find block timestamp ~p", [Error])
    end.

test_create_wallet() ->
    #{public_key := WalletAddress} =
        maybe_create_wallet("steven@gmail.com", "testpass"),
    ?LOG_INFO("Wallet created ~p ", [WalletAddress]).

test_get_block_height_since() ->
    case get_ae_mdw_node() of
        {ok, ConnPid, _PathPrefix} ->
            Result = get_block_height_since(36, ConnPid),
            ?LOG_INFO("block height ~p", [Result]),
            Result;
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err])
    end.

test_verify_message() ->
    AdminPassword = damage_utils:pass_get(ae_wallet_pass_path),
    {ok, AdminWalletPath} = application:get_env(damage, ae_wallet),
    Cmd =
        [
            ?AECLI_EXEC,
            "account",
            "sign-message",
            "--password",
            AdminPassword,
            "--json",
            AdminWalletPath,
            "test"
        ],
    #{data := Data, signature := _Sig, address := PubKey, signatureHex := SigHex} =
        Result = exec_aecli(Cmd),
    ?LOG_INFO("Result ~p", [Result]),
    _SigResult = vanillae:verify_signature(SigHex, Data, PubKey).

deploy_account_contract() ->
    #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
        contract_deploy(node_keypair(), "contracts/account.aes", []),
    application:set_env(damage, account_contract, binary_to_list(ContractAddress)),
    ?LOG_INFO("Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]),
    ContractAddress.

deploy_keystore_contract() ->
    #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
        contract_deploy(node_keypair(), "contracts/keystore.aes", []),
    application:set_env(damage, account_contract, binary_to_list(ContractAddress)),
    ?LOG_INFO("Keystore Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]),
    ContractAddress.
deploy_identity_contract() ->
    #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
        contract_deploy(node_keypair(), "contracts/identity.aes", []),
    application:set_env(damage, keystore_contract, binary_to_list(ContractAddress)),
    ?LOG_INFO("Identity Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]),
    ContractAddress.
deploy_knowledge_nft_contract() ->
    #{address := ContractAddress, result := #{gasUsed := GasUsed}} =
        contract_deploy(node_keypair(), "contracts/knowledge_nft.aes", []),
    application:set_env(damage, knowledge_nft_contract, binary_to_list(ContractAddress)),
    ?LOG_INFO("Knowledge NFT Contract deployed ~p gasused ~p", [ContractAddress, GasUsed]),
    ContractAddress.
