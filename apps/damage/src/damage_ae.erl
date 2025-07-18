-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

-export([
    init/1,
    start_link/0,
    start_link/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    transfer_damage_tokens/2,
    transfer_damage_tokens/3,
    confirm_spend_all/0,
    start_batch_spend_timer/0,
    get_reports/1,
    get_domain_token/2,
    add_domain_token/3,
    revoke_domain_token/2,
    get_ae_mdw_node/0,
    get_ae_mdw_ws_node/0,
    node_balance/0,
    node_damage_balance/0,
    account_keypair/1,
    wait_tx/1,
    ae_to_aetto/1,
    delete_account/1,
    revoke_token/2,
    get_block_height_since/2,
    restart_wallet_proc/1,
    get_wallet_proc/1,
    get_wallet_proc/2,
    get_events/3
]).
-export([
    contract_call/5,
    contract_call/6,
    contract_call_dry/5,
    contract_deploy/3,
    contract_deploy/2,
    contract_balance/1,
    contract_call_payfor_user/5
]).
-export([
    balance/1,
    invalidate_cache/1,
    spend/2,
    confirm_spend/1
]).
-export([
    test_get_block_height_since/0,
    test_find_block/0,
    test_verify_message/0,
    test_contract_deploy/0,
    test_contract_call/0,
    test_paying_for_tx/0
]).

start_link() -> gen_server:start_link(?MODULE, [], []).
start_link(AeAccount, PrivateKey) -> gen_server:start_link(?MODULE, [AeAccount, PrivateKey], []).

ae_to_aetto(Ae) -> Ae * 1000000000000000.

%Ae * 100000000000000000.
init([]) ->
    process_flag(trap_exit, true),
    ConfirmSpendTimer = erlang:send_after(10000, self(), confirm_spend_all),
    {ok, WS, _Path} = get_ae_mdw_node(),
    cln:register_listener(invoice_paid),
    {ok, #{heartbeat_timer => ConfirmSpendTimer, websocket => WS}};
init([AeAccount, PrivateKey]) ->
    process_flag(trap_exit, true),
    {ok, #{public_key => AeAccount, private_key => PrivateKey}}.

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

handle_call(
    {contract_call_payfor_user, Contract, ContractSource, Func, Args},
    _From,
    #{public_key := AeAccount, private_key := PrivateKey} = State
) ->
    KeyPair = #{public_key => AeAccount, private_key => PrivateKey},
    Result = contract_call_payfor_user(
        KeyPair,
        Contract,
        ContractSource,
        Func,
        Args
    ),
    {reply, Result, State};
handle_call(
    {contract_call, Contract, ContractSource, Func, Args},
    _From,
    #{public_key := AeAccount, private_key := PrivateKey} = State
) ->
    KeyPair = #{public_key => AeAccount, private_key => PrivateKey},
    Result = contract_call(
        KeyPair,
        Contract,
        ContractSource,
        Func,
        Args
    ),
    {reply, Result, State};
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
handle_call({events, ContractId, Limit}, _From, Cache) ->
    case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            Path =
                PathPrefix ++
                    "v3/contracts/logs?direction=forward&contract_id=" ++
                    ContractId ++
                    "&limit=" ++ integer_to_list(Limit),
            StreamRef = gun:get(ConnPid, Path),

            Events =
                case read_stream(ConnPid, StreamRef) of
                    #{data := Data} ->
                        Data;
                    Other ->
                        ?LOG_ERROR("Invalid response from events endpoint ~p", [Other]),
                        []
                end,
            {reply, Events, Cache};
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}, Cache}
    end;
handle_call({reports, AeAccount}, _From, Cache) ->
    case get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            %TODO use events
            Path =
                PathPrefix ++
                    "v3/transactions/?direction=backward&type=contract_call&contract=" ++
                    ?DAMAGE_TOKEN_CONTRACT ++
                    "&account=" ++
                    AeAccount ++
                    "&limit=10",
            StreamRef = gun:get(ConnPid, Path),
            Reports =
                case read_stream(ConnPid, StreamRef) of
                    #{amount := null} -> 0;
                    #{amount := Reports0} -> Reports0
                end,
            {reply, Reports, Cache};
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}, Cache}
    end;
handle_call({balance, AeAccount}, _From, Cache) when is_binary(AeAccount) ->
    case maps:get({balance, AeAccount}, Cache, none) of
        Balance when is_integer(Balance) ->
            {reply, Balance, Cache};
        _ ->
            case contract_balance(AeAccount) of
                ContractBalance when is_integer(ContractBalance) ->
                    {reply, ContractBalance,
                        maps:put({balance, AeAccount}, ContractBalance, Cache)};
                Err ->
                    ?LOG_DEBUG("ContractBalance failed ~p", [Err]),
                    {reply, error, Cache}
            end
    end;
handle_call({confirm_spend_all}, _From, Cache) ->
    ?LOG_DEBUG("handle_call confirm_spend_all/0 : ~p", [Cache]),
    {reply, ok, Cache};
handle_call({transaction, Data}, _From, State) ->
    ?LOG_DEBUG("handle_call transaction/1 : ~p", [Data]),
    {reply, ok, State}.

-spec float_to_full_integer(float()) -> integer().
float_to_full_integer(F) when is_float(F) ->
    round(F).

handle_cast(
    {
        confirm_spend,
        #{
            public_key := AeAccount,
            feature_hash := FeatureHash,
            report_hash := ReportHash,
            node_public_key := NodePublicKey
        } = _RunRecord
    },
    #{public_key := AeAccount, private_key := PrivateKey} = Cache
) ->
    KeyPair = #{public_key => AeAccount, private_key => PrivateKey},
    SpendRecord = #{"report_hash" => binary_to_list(ReportHash)},
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case maps:get(spent_balance, AccountCache, {0, 0}) of
        {_, Amount} when Amount > 0 ->
            ?LOG_DEBUG("confirm spend ~p ~p ~p", [Amount, AeAccount, SpendRecord]),
            case
                contract_call_payfor_user(
                    KeyPair,
                    ?DAMAGE_TOKEN_CONTRACT,
                    "contracts/token.aes",
                    "spend",
                    [
                        binary_to_list(NodePublicKey),
                        integer_to_list(float_to_full_integer(Amount)),
                        FeatureHash,
                        ReportHash
                    ]
                )
            of
                #{
                    "caller_id" :=
                        _UserAeAccount,
                    "caller_nonce" := _Nonce,
                    "contract_id" :=
                        _ContractId,
                    "gas_price" := _,
                    "gas_used" := _GasUsed,
                    "height" := _Height,
                    "log" :=
                        _Log,
                    "return_type" := "ok",
                    "return_value" := {}
                } ->
                    NewCache =
                        maps:put(
                            AeAccount,
                            maps:put(spent_balance, {Amount, 0}, AccountCache),
                            Cache
                        ),
                    ?LOG_DEBUG("confirm spend cached ~p", [NewCache]),
                    {noreply, maps:put({balance, AeAccount}, none, NewCache)};
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

damage_for_invoice(#{label := Label, amount_msat := _AmountMsat}) ->
    case binary:split(Label, <<":">>, [global]) of
        [<<"damage">>, AeAccount, AmountDamage, _Timestamp] ->
            ?LOG_INFO("Transfering ~p damage to ~p", [AmountDamage, AeAccount]),
            transfer_damage_tokens(
                AeAccount, trunc(binary_to_integer(AmountDamage) * math:pow(10, ?DAMAGE_DECIMALS))
            );
        Err ->
            ?LOG_INFO("No metadata in label: ~p", [Err])
    end.
handle_info({cln_event, invoice_paid, Invoice}, State) ->
    try
        damage_for_invoice(Invoice)
    catch
        _:Reason ->
            ?LOG_WARNING("Failed to send damage for invoice: ~p", [Reason])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_wallet_proc(AeAccount) when is_list(AeAccount) ->
    get_wallet_proc(list_to_binary(AeAccount));
get_wallet_proc(<<"ak_", _/binary>> = AeAccount) ->
    #{public_key := AeAccount, password := _Password, private_key := PrivateKey} = identity_server:get_account(
        AeAccount
    ),
    get_wallet_proc(AeAccount, PrivateKey);
get_wallet_proc(admin) ->
    #{public_key := NodePublicKey, private_key := PrivateKey} = secrets:node_keypair(),
    get_wallet_proc(list_to_binary(NodePublicKey), PrivateKey).
get_wallet_proc(AeAccount, PrivateKey) when is_list(AeAccount) ->
    get_wallet_proc(list_to_binary(AeAccount), PrivateKey);
get_wallet_proc(<<"ak_", _/binary>> = AeAccount, PrivateKey) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        % mandatory
                        id => {?MODULE, AeAccount},
                        % mandatory
                        start => {damage_ae, start_link, [AeAccount, PrivateKey]},
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
    end.

restart_wallet_proc(AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            get_wallet_proc(AeAccount);
        Pid ->
            supervisor:terminate_child(damage_sup, Pid),
            get_wallet_proc(AeAccount)
    end.

balance(AeAccount) ->
    ?LOG_DEBUG("Check balance ~p", [AeAccount]),
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {balance, AeAccount}, ?AE_TIMEOUT).

get_reports(AeAccount) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {reports, AeAccount}, ?AE_TIMEOUT).

get_events(#{public_key := PubKey, private_key := PrivateKey}, ContractId, Limit) ->
    DamageAEPid = get_wallet_proc(PubKey, PrivateKey),
    gen_server:call(DamageAEPid, {events, ContractId, Limit}, ?AE_TIMEOUT);
get_events(AeAccount, ContractId, Limit) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {events, ContractId, Limit}, ?AE_TIMEOUT).

spend(AeAccount, Amount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {spend, AeAccount, Amount}).

confirm_spend_all() ->
    DamageAEPid = get_wallet_proc(admin),
    gen_server:cast(DamageAEPid, {confirm_spend_all}).

start_batch_spend_timer() ->
    ?LOG_INFO("Starting batch spend timer."),
    erlcron:cron(
        <<"batch_spend_timer">>,
        {{daily, {every, {3600, sec}}}, {damage_ae, confirm_spend_all, []}}
    ).

confirm_spend(#{public_key := AeAccount} = Context) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {confirm_spend, Context}).

delete_account(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {delete_account, AeAccount}, ?AE_TIMEOUT).

invalidate_cache(AeAccount) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:cast(DamageAEPid, {invalidate_cache, AeAccount}).

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

read_stream(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, 600000) of
        {response, nofin, _Status, _Headers0} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            jsx:decode(Body, [{labels, atom}, return_maps]);
        Default ->
            ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
            Default
    end.

get_ae_balance(AeAccount) when is_binary(AeAccount) ->
    get_ae_balance(binary_to_list(AeAccount));
get_ae_balance(AeAccount) ->
    {ok, ConnPid, PathPrefix} = get_ae_node(),
    Path = PathPrefix ++ "v3/accounts/" ++ AeAccount,
    StreamRef = gun:get(ConnPid, Path),
    read_stream(ConnPid, StreamRef).

transfer_damage_tokens(AeAccount, Amount) ->
    % transfer damage tokens from admin account to to account
    ContractCall =
        contract_call(
            secrets:node_keypair(),
            ?DAMAGE_TOKEN_CONTRACT,
            "contracts/token.aes",
            "transfer",
            [AeAccount, Amount]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [ContractCall]),
    ContractCall.

transfer_damage_tokens(FromAccount, ToAeAccount, Amount) ->
    Result =
        contract_call(
            account_keypair(FromAccount),
            ?DAMAGE_TOKEN_CONTRACT,
            "contracts/token.aes",
            "transfer",
            [ToAeAccount, Amount]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [Result]),
    Result.

%paying_for(PayerId, Tx) ->
%    {ok, Nonce} = vanillae:next_nonce(PayerId),
%    Fee = vanillae:min_fee(),
%    {account_pubkey, PayerID} = aeser_api_encoder:decode(list_to_binary(PayerId)),
%    paying_for(PayerID, Nonce, Fee, Tx).

%### PayingFor
%The `PayingFor` transaction is available from version 5, Iris release. By using
%it,  an account `P` can pay for the transaction (transaction fee + gas) of another
%account `A`.
%
%#### PayingFor transaction
%```
%[ <payer_id> :: id()
%, <nonce>    :: int()
%, <fee>      :: int()
%, <tx>       :: binary()
%]
%```

paying_for(PK, Nonce, Fee, Tx) ->
    CallVersion = 1,
    Type = paying_for_tx,
    {account_pubkey, PayerId} = aeser_api_encoder:decode(PK),
    Fields =
        [
            {payer_id, aeser_id:create(account, PayerId)},
            {nonce, Nonce},
            {fee, Fee},
            {tx, Tx}
        ],
    Template = [
        {payer_id, id},
        {nonce, int},
        {fee, int},
        {tx, binary}
    ],
    TXB = aeser_chain_objects:serialize(Type, CallVersion, Template, Fields),
    try
        TX = aeser_api_encoder:encode(transaction, TXB),
        {ok, TX}
    catch
        error:Reason -> {error, Reason}
    end.
-spec calculate_paying_for_gas(binary(), binary()) -> non_neg_integer().
calculate_paying_for_gas(PayingForTxBin, InnerTxBin) ->
    BaseGas = 25000,
    GasPerByte = 20,
    SizeDiff = byte_size(PayingForTxBin) - byte_size(InnerTxBin),
    BaseGas + (SizeDiff * GasPerByte).
contract_call_payfor_user(
    #{public_key := AeAccount, private_key := PrivateKey}, ContractId, ContractSource, Func, Args
) ->
    #{public_key := NodeAeAccount, private_key := NodePrivateKey} = secrets:node_keypair(),
    {ok, AeAccountNonce} = vanillae:next_nonce(AeAccount),
    Fee = vanillae:min_fee(),
    Gas = vanillae:min_gas(),
    Amount = 0,
    GasPrice = vanillae:min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(ContractSource),
    %?LOG_INFO("Contract call ~p ~p ~p:~p ~p", [
    %    AeAccount, AeAccountNonce, ContractSource, Func, Args
    %]),
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, AeAccountNonce, Gas, GasPrice, Fee, Amount, AACI, ContractId, Func, Args
    ),

    Signature = make_transaction_signature_base58(PrivateKey, {inner, ContractCall}),
    SignedTX = attach_signature_base58(ContractCall, Signature),
    %?LOG_INFO("Paying for tx signed ~p", [SignedTX]),
    {transaction, InnerTxBin} = aeser_api_encoder:decode(SignedTX),

    {ok, NodeNonce} = vanillae:next_nonce(NodeAeAccount),
    {ok, PayingForTx} = paying_for(list_to_binary(NodeAeAccount), NodeNonce, Fee, InnerTxBin),
    {transaction, PayingForTxBin} = aeser_api_encoder:decode(PayingForTx),
    %?LOG_INFO("Paying for tx ~p ~p ~p", [NodeAeAccount, NodeNonce, PayingForTx]),

    CorrectGas = calculate_paying_for_gas(PayingForTxBin, InnerTxBin) + 1000,
    CorrectFee = CorrectGas * GasPrice,

    ?LOG_INFO("Correct gas ~p and Fee ~p", [CorrectGas, CorrectFee]),

    % Regenerate the paying_for tx with correct gas/fee
    {ok, ContractCall0} = vanillae:contract_call(
        AeAccount, AeAccountNonce, CorrectGas, GasPrice, Fee, Amount, AACI, ContractId, Func, Args
    ),

    Signature0 = make_transaction_signature_base58(PrivateKey, {inner, ContractCall0}),
    SignedTX0 = attach_signature_base58(ContractCall0, Signature0),
    %?LOG_INFO("Paying for tx signed ~p", [SignedTX]),
    {transaction, InnerTxBin0} = aeser_api_encoder:decode(SignedTX0),

    {ok, PayingForTxFinal} = paying_for(
        list_to_binary(NodeAeAccount), NodeNonce, CorrectFee, InnerTxBin0
    ),
    PayingSignature = make_transaction_signature_base58(NodePrivateKey, PayingForTxFinal),
    PayingSignedTX = attach_signature_base58(PayingForTxFinal, PayingSignature),

    {ok, #{"tx_hash" := ContractCallTxHash}} = vanillae:post_tx(PayingSignedTX),
    wait_tx(ContractCallTxHash);
contract_call_payfor_user(AeAccount, Contract, ContractSource, Func, Args) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {contract_call_payfor_user, Contract, ContractSource, Func, Args},
        ?AE_TIMEOUT
    ).

contract_call(
    #{public_key := _AeAccount, private_key := _PrivateKey} = Keypair,
    ContractAddress,
    Contract,
    Func,
    Args
) ->
    contract_call(
        Keypair, ContractAddress, Contract, 0, Func, Args
    );
contract_call(AeAccount, Contract, ContractSource, Func, Args) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {contract_call, Contract, ContractSource, Func, Args},
        ?AE_TIMEOUT
    ).
contract_call(
    #{public_key := AeAccount, private_key := PrivateKey},
    ContractAddress,
    Contract,
    Amount,
    Func,
    Args
) ->
    ?LOG_DEBUG("Contract call ~p:~p ~p", [Contract, Func, Args]),
    {ok, Nonce} = vanillae:next_nonce(AeAccount),
    Fee = vanillae:min_fee(),
    Gas = vanillae:min_gas(),
    GasPrice = vanillae:min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(Contract),
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, Nonce, Gas, GasPrice, Fee, Amount, AACI, ContractAddress, Func, Args
    ),
    Signature = make_transaction_signature_base58(PrivateKey, ContractCall),
    SignedTX = attach_signature_base58(ContractCall, Signature),
    {ok, #{"tx_hash" := ContractCallTxHash}} = vanillae:post_tx(SignedTX),
    wait_tx(ContractCallTxHash).

contract_call_dry(
    #{public_key := AeAccount, private_key := PrivateKey},
    ContractAddress,
    Contract,
    Func,
    Args
) ->
    ?LOG_DEBUG("Contract call ~p:~p ~p", [Contract, Func, Args]),
    {ok, Nonce} = vanillae:next_nonce(AeAccount),
    Fee = vanillae:min_fee(),
    Gas = 100000,
    GasPrice = vanillae:min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(Contract),
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, Nonce, Gas, GasPrice, Fee, 0, AACI, ContractAddress, Func, Args
    ),
    {ok, #{
        "results" :=
            [Result | _],
        "tx_events" := []
    }} =
        vanillae:dry_run(ContractCall),
    tx_info_convert_dry_run_result(Result).

contract_balance(Account) ->
    #{public_key := NodeAccount, private_key := _PrivateKey} = KeyPair = secrets:node_keypair(),
    #{
        "caller_id" :=
            NodeAccount,
        "caller_nonce" := _,
        "contract_id" :=
            ?DAMAGE_TOKEN_CONTRACT,
        "gas_price" := _,
        "gas_used" := _,
        "height" := _,
        "log" := [],
        "return_type" := "ok",
        "return_value" := {variant, [0, 1], 1, {Balance}}
    } = contract_call(
        KeyPair,
        ?DAMAGE_TOKEN_CONTRACT,
        "contracts/token.aes",
        "balance",
        [Account]
    ),
    Balance.

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
make_transaction_signature_base58(Priv, {inner, EncodedTX}) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    Sig = make_transaction_signature(Priv, {inner, TX}),
    aeser_api_encoder:encode(signature, Sig);
make_transaction_signature_base58(Priv, EncodedTX) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    Sig = make_transaction_signature(Priv, TX),
    aeser_api_encoder:encode(signature, Sig).

make_transaction_signature(Priv, {inner, TX}) ->
    Id = list_to_binary(vanillae:network_id() ++ "-inner_tx"),
    Blob = <<Id/binary, TX/binary>>,
    %?LOG_INFO("sig id ~p ~p", [Id, Blob]),
    enacl:sign_detached(Blob, Priv);
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

account_keypair(AeAccount) ->
    #{
        "return_type" := "ok",
        "return_value" := KeyPair
    } =
        contract_call(
            secrets:node_keypair(),
            ?EMAIL_REGISTRY_CONTRACT,
            "contracts/email_registry.aes",
            "get_email",
            [AeAccount]
        ),
    KeyPair.
tx_info_convert_dry_run_result(Result) ->
    case Result of
        #{
            "call_obj" := #{
                "caller_id" := _CallerId,
                "caller_nonce" := _CallerNonce,
                "contract_id" := _ContractId,
                "gas_price" := _GasPrice,
                "gas_used" := _GasUsed,
                "height" := _Height,
                "log" := _log,
                "return_type" := _ReturnType,
                "return_value" := Encoded
            } = CallInfo
        } ->
            case vanillae:decode_bytearray_fate(Encoded) of
                {ok, {tuple, ReturnValue}} -> maps:put("return_value", ReturnValue, CallInfo);
                {ok, ReturnValue} -> maps:put("return_value", ReturnValue, CallInfo);
                ReturnValue -> maps:put("return_value", ReturnValue, CallInfo)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

tx_info_convert_result(Result) ->
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
            } = CallInfo
        } ->
            case vanillae:decode_bytearray_fate(Encoded) of
                {ok, {tuple, ReturnValue}} -> maps:put("return_value", ReturnValue, CallInfo);
                {ok, ReturnValue} -> maps:put("return_value", ReturnValue, CallInfo);
                ReturnValue -> maps:put("return_value", ReturnValue, CallInfo)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

poll_tx(Fun, Args, Interval, Timeout) ->
    poll_tx(Fun, Args, Interval, Timeout, erlang:monotonic_time(millisecond)).

poll_tx(Fun, Args, Interval, Timeout, StartTime) ->
    case apply(Fun, Args) of
        {ok, Result} ->
            %?LOG_DEBUG("result value ~p", [Result]),
            ?LOG_DEBUG("poll tx got value ~p", [Result]),
            tx_info_convert_result(Result);
        Result ->
            ?LOG_DEBUG("poll tx error value ~p args ~p", [Result, Args]),
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
    poll_tx(fun vanillae:tx_info/1, [ConId], 2000, 55000).

contract_deploy(Contract, Args) ->
    Keypair = secrets:node_keypair(),
    contract_deploy(Keypair, Contract, Args).
contract_deploy(#{public_key := AeAccount, private_key := PrivateKey}, Contract, Args) ->
    {ok, ContractData} =
        vanillae:contract_create(AeAccount, Contract, Args),
    SignedContract = sign_transaction_base58(PrivateKey, ContractData),
    {ok, #{"tx_hash" := ContractCallTxHash}} = vanillae:post_tx(SignedContract),
    wait_tx(ContractCallTxHash).

node_balance() ->
    #{public_key := AeAccount, private_key := _PrivateKey} = secrets:node_keypair(),
    #{
        id :=
            _,
        balance := Balance,
        nonce := _,
        kind := <<"basic">>,
        payable := true
    } =
        get_ae_balance(AeAccount),
    ?LOG_DEBUG("balance ~p", [Balance]),
    Balance / math:pow(10, ?AE_DECIMALS).

node_damage_balance() ->
    #{public_key := AeAccount, private_key := _PrivateKey} = secrets:node_keypair(),
    Balance = balance(AeAccount),
    Balance / math:pow(10, ?DAMAGE_DECIMALS).

test_contract_deploy() ->
    KeyPair = secrets:node_keypair(),
    #{"contract_id" := ContractId} = contract_deploy(KeyPair, "contracts/test.aes", []),
    ContractId.

test_contract_call() ->
    #{public_key := _AeAccount, private_key := _PrivateKey} = KeyPair = secrets:node_keypair(),
    ContractId = test_contract_deploy(),
    ?LOG_DEBUG("contract account ~p", [ContractId]),
    contract_call(KeyPair, ContractId, "contracts/test.aes", "f", [2]).
%contract_call_dry(KeyPair, ContractId, "contracts/test.aes", "f", [2]).

test_paying_for_tx() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {PubKey, _Password, PrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    #{public_key := NodePublicKey, private_key := _NodePrivateKey} =
        _KeyPair = secrets:node_keypair(),
    Amount = 1 * math:pow(10, ?DAMAGE_DECIMALS),
    %contract_call(
    %  KeyPair,
    %    ?DAMAGE_TOKEN_CONTRACT,
    %    "contracts/token.aes",
    %    "spend",
    %    [NodePublicKey, float_to_full_integer(Amount), "testfeaturehash", "testreporthash"]
    %).
    contract_call_payfor_user(
        #{public_key => PubKey, private_key => PrivateKey},
        ?DAMAGE_TOKEN_CONTRACT,
        "contracts/token.aes",
        %"balance",
        %[PubKey]
        "spend",
        [NodePublicKey, float_to_full_integer(Amount), "testfeaturehash", "testreporthash"]
    ).

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
    #{public_key := PubKey, private_key := PrivateKey} = secret:node_keypair(),

    Data = <<"test">>,
    SigHex = sign_transaction_base58(PrivateKey, Data),
    _SigResult = vanillae:verify_signature(SigHex, Data, PubKey).
