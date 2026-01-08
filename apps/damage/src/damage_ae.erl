-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

-define(BASE_GAS, 15000).
-define(GAS_PER_BYTE, 20).
% Time-to-live in seconds
-define(CACHE_TTL_SECONDS, 30).

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
    transfer_damage/2,
    transfer_damage/3,
    transfer_hits/2,
    transfer_hits/3,
    confirm_spend_all/0,
    start_batch_spend_timer/0,
    get_reports/1,
    get_reports/2,
    get_domain_token/2,
    add_domain_token/3,
    revoke_domain_token/2,
    with_ae_node/1,
    with_ae_mdw_node/1,
    get_ae_mdw_ws_node/0,
    node_ae_balance/0,
    node_damage_balance/0,
    account_keypair/1,
    ae_to_aetto/1,
    delete_account/1,
    revoke_token/2,
    get_block_height_since/2,
    restart_wallet_proc/1,
    get_wallet_proc/1,
    get_events/3,
    is_custodial/1,
    set_private_key/2,
    get_ae_balance/1,
    deploy_damage_nft/0,
    contract_path/1
]).
-export([
    contract_call/4,
    contract_call/5,
    contract_call/6,
    contract_call_dry/5,
    contract_deploy/3,
    contract_deploy/2,
    contract_balance/1,
    contract_deploy_for/3,
    contract_call_payfor_user/5,
    payfor_tx/1,
    contract_call_prepare_tx/5,
    deploy_account_registry/1,
    deploy_node_registry/0,
    make_transaction_signature_base58/2,
    make_transaction_signature/2,
    attach_signature_base58/2,
    post_signed_or_payfor/1,
    min_fee/0,
    wait_tx/1
]).
-export([
    balance/1,
    invalidate_cache/1,
    spend/2,
    mint_nft_report/1,
    confirm_spend/2
]).
-export([
    test_get_block_height_since/0,
    test_find_block/0,
    test_verify_message/0,
    test_contract_deploy/0,
    test_contract_call/0,
    test_paying_for_tx/0,
    test_contract_deploy_for/0
]).
-import(damage_utils, [float_to_full_integer/1]).

start_link() -> gen_server:start_link(?MODULE, [], []).
start_link(AeAccount, PrivateKey) -> gen_server:start_link(?MODULE, [AeAccount, PrivateKey], []).

ae_to_aetto(Ae) -> Ae * 1000000000000000.

%Ae * 100000000000000000.
init([]) ->
    process_flag(trap_exit, true),
    ConfirmSpendTimer = erlang:send_after(10000, self(), confirm_spend_all),
    {ok, WS, _Path} = get_ae_mdw_ws_node(),
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
%% Encode FATE calldata for off-chain contract call using the compiled AACI
-spec encode_call_data(term(), term(), list()) -> {ok, binary()} | {error, term()}.
encode_call_data(Contract, Fun, Args) ->
    try
        {ok, AACI} = vanillae:prepare_contract(contract_path(Contract)),
        %% aeb_aaci / aeb_fate_abi are part of ae SDK; adjust if your project uses a wrapper
        {ok, Calldata} = aeb_fate_abi:encode_call_data(AACI, Fun, Args),
        {ok, Calldata}
    catch
        C:R:S ->
            {error, {calldata_encode_failed, {C, R, S}}}
    end.

handle_call(
    {channel_contract_call, CtId, Contract, Fun, Args, Gas, Amount, Meta},
    _From,
    #{
        public_key := _AeAccount,
        private_key := _PrivateKey,
        initiator := Initiator,
        responder := Responder,
        round := Round,
        state_hash := StateHash
    } = State
) ->
    GasPrice = min_gas_price(),
    case encode_call_data(Contract, Fun, Args) of
        {ok, Calldata} ->
            %% Build the off-chain update payload
            Update = #{
                type => contract_call,
                %% <<"ct_...">>
                ct_id => CtId,
                "fun" => Fun,
                %% calldata (FATE)
                args_cd => Calldata,
                gas => Gas,
                gas_price => GasPrice,
                %% aetto to send
                amount => Amount,
                %% initiator pays by default
                from => Initiator,
                %% responder executes
                to => Responder,
                meta => Meta,
                round => Round + 1
            },

            %% TODO: wire to the real channel FSM: send 'update', await 'update_ack'
            Round1 = Round + 1,
            Root1 = crypto:hash(sha256, term_to_binary({Update, Round1, StateHash})),

            Ch1 = #{
                round => Round1,
                state_hash => Root1,
                last_payload => Update,
                pending_updates => []
            },

            Receipt = #{
                kind => contract_call,
                ct_id => CtId,
                "fun" => Fun,
                round => Round1,
                state_hash => Root1,
                gas => Gas,
                gas_price => GasPrice,
                amount => Amount,
                meta => Meta
            },
            {reply, {ok, Receipt}, maps:merge(Ch1, State)};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(
    {contract_call_payfor_user, Contract, ContractSource, Func, Args},
    _From,
    #{public_key := AeAccount, private_key := PrivateKey} = State
) ->
    ?LOG_INFO("calling contract_call_payfor_user ~p", [PrivateKey]),
    KeyPair = #{public_key => AeAccount, private_key => PrivateKey},
    Result = do_contract_call_payfor_user(
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
    with_ae_mdw_node(fun(ConnPid, PathPrefix) ->
        Path =
            PathPrefix ++ "v3/accounts/" ++ AeAccount ++ "activities?type=aex141",
        StreamRef = gun:get(ConnPid, Path),
        Balance =
            case read_stream(ConnPid, StreamRef) of
                #{amount := null} -> 0;
                #{amount := Balance0} -> Balance0
            end,
        {reply, Balance, Cache}
    end);
handle_call(
    {get_last_test_status, AeAccount, FeatureHash, _Hours},
    _From,
    Cache
) ->
    with_ae_mdw_node(fun(ConnPid, PathPrefix) ->
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
        end
    end);
handle_call({events, ContractId, Limit}, _From, Cache) ->
    with_ae_mdw_node(fun(ConnPid, PathPrefix) ->
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
        {reply, Events, Cache}
    end);
handle_call({reports, AeAccount}, _From, Cache) ->
    with_ae_mdw_node(fun(ConnPid, PathPrefix) ->
        %TODO use events
        Path =
            PathPrefix ++
                "v3/accounts/" ++
                binary_to_list(AeAccount) ++
                "/activities?" ++
                "direction=backward" ++
                "&type=aex9" ++
                "&limit=10",
        %?DAMAGE_TOKEN_CONTRACT ++
        ?LOG_DEBUG("Path ~p", [Path]),
        StreamRef = gun:get(ConnPid, Path),
        catch gun:close(ConnPid),
        {reply, read_stream(ConnPid, StreamRef), Cache}
    end);
handle_call({balance, AeAccount}, _From, Cache) when is_binary(AeAccount) ->
    Now = erlang:monotonic_time(second),
    case maps:get({balance, AeAccount}, Cache, none) of
        {Balance, Expiry} when is_integer(Balance), Now < Expiry ->
            {reply, Balance, Cache};
        _ ->
            %case contract_balance(AeAccount) of
            case middleware_balance(AeAccount) of
                ContractBalance when is_integer(ContractBalance) ->
                    ExpiryTime = Now + ?CACHE_TTL_SECONDS,
                    NewCache = maps:put({balance, AeAccount}, {ContractBalance, ExpiryTime}, Cache),
                    {reply, ContractBalance, NewCache};
                Err ->
                    ?LOG_DEBUG("Balance fetch failed ~p", [Err]),
                    {reply, error, Cache}
            end
    end;
handle_call({confirm_spend_all}, _From, Cache) ->
    ?LOG_DEBUG("handle_call confirm_spend_all/0 : ~p", [Cache]),
    {reply, ok, Cache};
handle_call(
    {is_custodial, AeAccount},
    _From,
    #{public_key := AeAccount, private_key := PrivateKey} = Cache
) when is_binary(PrivateKey) ->
    {reply, true, Cache};
handle_call(
    {is_custodial, AeAccount},
    _From,
    #{public_key := AeAccount} = Cache
) ->
    {reply, false, Cache};
handle_call(
    {set_private_key, AeAccount, PrivateKey},
    _From,
    #{public_key := AeAccount} = State
) ->
    {reply, false, maps:put(private_key, PrivateKey, State)};
handle_call({transaction, Data}, _From, State) ->
    ?LOG_DEBUG("handle_call transaction/1 : ~p", [Data]),
    {reply, ok, State};
handle_call(
    {
        confirm_spend,
        #{
            public_key := AeAccount,
            feature_hash := FeatureHash,
            dry_run := true
        } = Context
    },
    _From,
    #{public_key := AeAccount} = Cache
) ->
    ?LOG_DEBUG("confirm spend on dryrun ~p ~p", [AeAccount, FeatureHash]),
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case maps:get(spent_balance, AccountCache, {0, 0}) of
        {_, Amount} when Amount > 0 ->
            NewCache =
                maps:put(
                    AeAccount,
                    maps:put(spent_balance, {Amount, 0}, AccountCache),
                    Cache
                ),
            {reply, maps:put(cost, Amount, Context),
                maps:put(cost, Amount, maps:put({balance, AeAccount}, none, NewCache))};
        {_, Amount} ->
            ?LOG_DEBUG("Amount 0: ~p", [Amount]),
            {reply, Context, Cache}
    end;
handle_call(
    {
        confirm_spend,
        #{
            public_key := AeAccount,
            feature_hash := FeatureHash,
            report_hash := ReportHash,
            node_public_key := NodePublicKey,
            private_key := PrivateKey
        } = _RunRecord
    },
    _From,
    #{public_key := AeAccount} = Cache
) ->
    KeyPair = #{public_key => AeAccount, private_key => PrivateKey},
    SpendRecord = #{"report_hash" => binary_to_list(ReportHash)},
    AccountCache = maps:get(AeAccount, Cache, #{}),
    case maps:get(spent_balance, AccountCache, {0, 0}) of
        {_, Amount} when Amount > 0 ->
            ?LOG_INFO("confirm spend ~p ~p ~p", [Amount, AeAccount, SpendRecord]),
            case
                do_contract_call_payfor_user(
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
                    {reply, Amount, maps:put({balance, AeAccount}, none, NewCache)};
                #{status := <<"fail">>} ->
                    ?LOG_DEBUG("confirm spend failed ~p", [Cache]),
                    {reply, Amount, Cache}
            end;
        {_, Amount} ->
            ?LOG_DEBUG("Amount 0: ~p", [Amount]),
            {reply, Amount, Cache}
    end.
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
            transfer_damage(
                AeAccount, binary_to_integer(AmountDamage)
            );
        Err ->
            ?LOG_INFO("damage_ae ignores label: ~p", [Err])
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
    get_wallet_proc(AeAccount, none);
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
    DamageAEPid = get_wallet_proc(admin),
    gen_server:call(DamageAEPid, {balance, AeAccount}, ?AE_TIMEOUT).

get_reports(AeAccount) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {reports, AeAccount}, ?AE_TIMEOUT).
get_reports(AeAccount, Query) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {reports, AeAccount, Query}, ?AE_TIMEOUT).

get_events(#{public_key := PubKey}, ContractId, Limit) ->
    DamageAEPid = get_wallet_proc(PubKey),
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

confirm_spend(Config, #{public_key := AeAccount} = Context) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    ?LOG_INFO("confirm_spend ~p", [proplists:get_value(dry_run, Config, none)]),
    case proplists:get_value(dry_run, Config, none) of
        true ->
            gen_server:call(
                DamageAEPid, {confirm_spend, maps:put(dry_run, true, Context)}, ?AE_TIMEOUT
            );
        _ ->
            gen_server:call(DamageAEPid, {confirm_spend, Context}, ?AE_TIMEOUT)
    end.

delete_account(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {delete_account, AeAccount}, ?AE_TIMEOUT).
is_custodial(AeAccount) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {is_custodial, AeAccount}, ?AE_TIMEOUT).

set_private_key(AeAccount, PrivateKey) ->
    % temporary storage to commit after feature execution
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(DamageAEPid, {set_private_key, AeAccount, PrivateKey}, ?AE_TIMEOUT).

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
with_ae_node(Fun) ->
    {ok, ConnPid, PathPrefix} = get_ae_node(),
    try
        Fun(ConnPid, PathPrefix)
    after
        catch gun:close(ConnPid)
    end.

get_ae_balance(AeAccount) when is_binary(AeAccount) ->
    get_ae_balance(binary_to_list(AeAccount));
get_ae_balance(AeAccount) ->
    with_ae_node(fun(ConnPid, PathPrefix) ->
        Path = PathPrefix ++ "v3/accounts/" ++ AeAccount,
        StreamRef = gun:get(ConnPid, Path),
        read_stream(ConnPid, StreamRef)
    end).

transfer_damage(AeAccount, Damage) when is_integer(Damage) ->
    transfer_hits(AeAccount, trunc(Damage * math:pow(10, ?DAMAGE_DECIMALS))).
transfer_hits(AeAccount, Hits) when is_integer(Hits) ->
    % transfer damage tokens from admin account to to account
    ContractCall =
        contract_call(
            secrets:node_keypair(),
            ?DAMAGE_TOKEN_CONTRACT,
            "contracts/token.aes",
            "transfer",
            [AeAccount, Hits]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [ContractCall]),
    ContractCall.

transfer_damage(FromAccount, ToAeAccount, Damage) when is_integer(Damage) ->
    transfer_hits(FromAccount, ToAeAccount, trunc(Damage * math:pow(10, ?DAMAGE_DECIMALS))).
transfer_hits(FromAccount, ToAeAccount, Hits) when is_integer(Hits) ->
    Result =
        contract_call(
            account_keypair(FromAccount),
            ?DAMAGE_TOKEN_CONTRACT,
            "contracts/token.aes",
            "transfer",
            [ToAeAccount, Hits]
        ),
    ?LOG_DEBUG("Tokens transfered ~p", [Result]),
    Result.

%% Generic base function
-spec calculate_gas(non_neg_integer(), binary()) -> non_neg_integer().
calculate_gas(BaseMultiplier, TxBin) ->
    Base = BaseMultiplier * ?BASE_GAS,
    SizeFee = byte_size(TxBin) * ?GAS_PER_BYTE,
    Base + SizeFee.

%% Contract create (FATE) gas
-spec gas_for_contract_create_fate(binary()) -> non_neg_integer().
gas_for_contract_create_fate(TxBin) ->
    calculate_gas(5, TxBin).
%% Contract call (FATE) gas
-spec gas_for_contract_call_fate(binary()) -> non_neg_integer().
gas_for_contract_call_fate(TxBin) ->
    calculate_gas(24, TxBin).
contract_path(Contract0) ->
    PrivDir = code:priv_dir(damage),
    %% Strip "contracts/" prefix if present
    Contract1 =
        case string:prefix(Contract0, "contracts/") of
            nomatch -> Contract0;
            Name -> Name
        end,
    %% Ensure it ends with ".aes"
    Contract2 =
        case filename:extension(Contract1) of
            ".aes" -> Contract1;
            _ -> Contract1 ++ ".aes"
        end,
    filename:join([PrivDir, "contracts", Contract2]).

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
    BaseGas = 46000,
    GasPerByte = 20,
    SizeDiff = byte_size(PayingForTxBin) - byte_size(InnerTxBin),
    BaseGas + (SizeDiff * GasPerByte).
min_gas_price() ->
    1000000000.
min_fee() ->
    %TODO some fine tuning
    vanillae:min_fee() * 2.
min_gas() ->
    %TODO some fine tuning
    vanillae:min_gas() * 2.
contract_call_prepare_tx(
    #{public_key := AeAccount}, ContractId, ContractSource, Func, Args
) ->
    {ok, AeAccountNonce} = vanillae:next_nonce(AeAccount),
    Fee = min_fee(),
    Gas = min_gas(),
    Amount = 0,
    GasPrice = min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(contract_path(ContractSource)),
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, AeAccountNonce, Gas, GasPrice, Fee, Amount, AACI, ContractId, Func, Args
    ),
    ContractCall.
payfor_tx(
    SignedTX
) ->
    #{public_key := NodeAeAccount, private_key := NodePrivateKey} = secrets:node_keypair(),
    {ok, NodeNonce} = vanillae:next_nonce(NodeAeAccount),
    Fee = min_fee(),
    %Gas = vanillae:min_gas(),
    %Amount = 0,
    GasPrice = min_gas_price(),

    {transaction, InnerTxBin} = aeser_api_encoder:decode(SignedTX),
    ?LOG_DEBUG("payfor_tx ~p", [InnerTxBin]),
    %{ok,_} = vanillae:dry_run(InnerTxBin),

    {ok, NodeNonce} = vanillae:next_nonce(NodeAeAccount),
    {ok, PayingForTx} = paying_for(list_to_binary(NodeAeAccount), NodeNonce, Fee, InnerTxBin),
    {transaction, PayingForTxBin} = aeser_api_encoder:decode(PayingForTx),

    CorrectGas = calculate_paying_for_gas(PayingForTxBin, InnerTxBin),
    CorrectFee = CorrectGas * GasPrice,
    % Regenerate the paying_for tx with correct gas/fee

    {ok, PayingForTxFinal} = paying_for(
        list_to_binary(NodeAeAccount), NodeNonce, CorrectFee, InnerTxBin
    ),
    PayingSignature = make_transaction_signature_base58(NodePrivateKey, PayingForTxFinal),
    PayingSignedTX = attach_signature_base58(PayingForTxFinal, PayingSignature),

    case vanillae:post_tx(PayingSignedTX) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_tx(ContractCallTxHash);
        Error ->
            Error
    end.

do_contract_call_payfor_user(
    #{public_key := AeAccount, private_key := PrivateKey}, ContractId, ContractSource, Func, Args
) when is_binary(PrivateKey) ->
    #{public_key := NodeAeAccount, private_key := NodePrivateKey} = secrets:node_keypair(),
    {ok, AeAccountNonce} = vanillae:next_nonce(AeAccount),
    Fee = min_fee(),
    Gas = min_gas(),
    Amount = 0,
    GasPrice = min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(contract_path(ContractSource)),
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, AeAccountNonce, Gas, GasPrice, Fee, Amount, AACI, ContractId, Func, Args
    ),

    Signature = make_transaction_signature_base58(PrivateKey, {inner, ContractCall}),
    SignedTX = attach_signature_base58(ContractCall, Signature),
    {transaction, InnerTxBin} = aeser_api_encoder:decode(SignedTX),

    {ok, NodeNonce} = vanillae:next_nonce(NodeAeAccount),
    {ok, PayingForTx} = paying_for(list_to_binary(NodeAeAccount), NodeNonce, Fee, InnerTxBin),
    {transaction, PayingForTxBin} = aeser_api_encoder:decode(PayingForTx),

    CorrectGas = calculate_paying_for_gas(PayingForTxBin, InnerTxBin),
    CorrectFee = CorrectGas * GasPrice,
    % Regenerate the paying_for tx with correct gas/fee
    {ok, ContractCall0} = vanillae:contract_call(
        AeAccount, AeAccountNonce, CorrectGas, GasPrice, Fee, Amount, AACI, ContractId, Func, Args
    ),

    Signature0 = make_transaction_signature_base58(PrivateKey, {inner, ContractCall0}),
    SignedTX0 = attach_signature_base58(ContractCall0, Signature0),
    {transaction, InnerTxBin0} = aeser_api_encoder:decode(SignedTX0),

    {ok, PayingForTxFinal} = paying_for(
        list_to_binary(NodeAeAccount), NodeNonce, CorrectFee, InnerTxBin0
    ),
    PayingSignature = make_transaction_signature_base58(NodePrivateKey, PayingForTxFinal),
    PayingSignedTX = attach_signature_base58(PayingForTxFinal, PayingSignature),

    case vanillae:post_tx(PayingSignedTX) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_tx(ContractCallTxHash);
        Error ->
            Error
    end.
contract_call_payfor_user(
    AeAccount, Contract, ContractSource, Func, Args
) when is_binary(AeAccount) ->
    DamageAEPid = get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {contract_call_payfor_user, Contract, ContractSource, Func, Args},
        ?AE_TIMEOUT
    ).

contract_call(
    ContractAddress,
    Contract,
    Func,
    Args
) ->
    case secrets:node_keypair() of
        #{public_key := _AeAccount, private_key := _PrivateKey} = Keypair ->
            contract_call(Keypair, ContractAddress, Contract, Func, Args);
        Error ->
            Error
    end.
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
    GasPrice = min_gas_price(),

    {ok, AACI} = vanillae:prepare_contract(contract_path(Contract)),

    %% First build raw tx with dummy values to estimate gas
    DummyGas = min_gas(),
    DummyFee = min_fee(),

    {ok, ContractCall0} = vanillae:contract_call(
        AeAccount, Nonce, DummyGas, GasPrice, DummyFee, Amount, AACI, ContractAddress, Func, Args
    ),
    Signature0 = make_transaction_signature_base58(PrivateKey, ContractCall0),
    SignedTx0 = attach_signature_base58(ContractCall0, Signature0),
    {transaction, TxBin} = aeser_api_encoder:decode(SignedTx0),

    %% Calculate correct gas + fee
    Gas = gas_for_contract_call_fate(TxBin),
    Fee = Gas * GasPrice,

    %% Rebuild final tx with correct gas and fee
    {ok, ContractCall} = vanillae:contract_call(
        AeAccount, Nonce, Gas, GasPrice, Fee, Amount, AACI, ContractAddress, Func, Args
    ),
    Signature = make_transaction_signature_base58(PrivateKey, ContractCall),
    SignedTX = attach_signature_base58(ContractCall, Signature),

    case vanillae:post_tx(SignedTX) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_tx(ContractCallTxHash);
        Error ->
            Error
    end.

contract_call_dry(
    #{public_key := AeAccount, private_key := _PrivateKey},
    ContractAddress,
    Contract,
    Func,
    Args
) ->
    ?LOG_DEBUG("Contract call ~p:~p ~p", [Contract, Func, Args]),
    {ok, Nonce} = vanillae:next_nonce(AeAccount),
    Fee = min_fee(),
    Gas = min_gas(),
    GasPrice = min_gas_price(),
    {ok, AACI} = vanillae:prepare_contract(contract_path(Contract)),
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

contract_deploy(Contract, Args) ->
    Keypair = secrets:node_keypair(),
    contract_deploy(Keypair, Contract, Args).
contract_deploy(#{public_key := AeAccount, private_key := PrivateKey}, Contract, Args) ->
    {ok, AeAccountNonce} = vanillae:next_nonce(AeAccount),
    Amount = 0,
    GasPrice = min_gas_price(),
    %% First build raw tx with dummy values to estimate gas
    DummyGas = min_gas(),
    DummyFee = vanillae:min_fee(),

    {ok, ContractData} = vanillae:contract_create(
        AeAccount,
        AeAccountNonce,
        Amount,
        DummyGas,
        GasPrice,
        DummyFee,
        Contract,
        Args
    ),
    ?LOG_INFO("Contract create ~p:~p ~p", [Contract, ContractData, Args]),

    SignedContract = sign_transaction_base58(PrivateKey, ContractData),
    {transaction, TxBin} = aeser_api_encoder:decode(SignedContract),
    CorrectGas = gas_for_contract_create_fate(TxBin),
    CorrectFee = CorrectGas * GasPrice,
    ?LOG_INFO("Correct gas ~p and Fee ~p", [CorrectGas, CorrectFee]),
    {ok, ContractData0} = vanillae:contract_create(
        AeAccount,
        AeAccountNonce,
        Amount,
        CorrectGas,
        GasPrice,
        CorrectFee,
        Contract,
        Args
    ),
    SignedContract0 = sign_transaction_base58(PrivateKey, ContractData0),

    case vanillae:post_tx(SignedContract0) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_tx(ContractCallTxHash);
        Error ->
            Error
    end.
%{ok, #{
%    "results" :=
%        [Result | _],
%    "tx_events" := []
%}} =
%    vanillae:dry_run(ContractData0),
%tx_info_convert_dry_run_result(Result).
contract_deploy_for(
    #{public_key := AeAccount, private_key := PrivateKey},
    Contract,
    Args
) ->
    {ok, AeAccountNonce} = vanillae:next_nonce(AeAccount),
    DummyGas = min_gas(),
    DummyFee = min_fee(),
    Amount = 0,
    GasPrice = min_gas_price() * 2,
    %% Node keypair (payer)
    #{public_key := NodeAeAccount, private_key := NodePrivateKey} = secrets:node_keypair(),

    %% 1. Create unsigned contract creation tx
    {ok, ContractData} = vanillae:contract_create(
        AeAccount, AeAccountNonce, Amount, DummyGas, GasPrice, DummyFee, Contract, Args
    ),

    %% 2. Sign with user's private key
    SignedContract = sign_transaction_base58(PrivateKey, {inner, ContractData}),
    {transaction, InnerTxBin} = aeser_api_encoder:decode(SignedContract),

    {ok, NodeNonce} = vanillae:next_nonce(NodeAeAccount),
    {ok, PayingForTx} = paying_for(list_to_binary(NodeAeAccount), NodeNonce, DummyFee, InnerTxBin),
    {transaction, PayingForTxBin} = aeser_api_encoder:decode(PayingForTx),
    %?LOG_INFO("Paying for tx ~p ~p ~p", [NodeAeAccount, NodeNonce, PayingForTx]),

    CorrectGas = calculate_paying_for_gas(PayingForTxBin, InnerTxBin),
    CorrectFee = CorrectGas * GasPrice,

    ?LOG_INFO("Correct gas ~p and Fee ~p", [CorrectGas, CorrectFee]),

    {ok, ContractData0} = vanillae:contract_create(
        AeAccount, AeAccountNonce, Amount, CorrectGas, GasPrice, CorrectFee, Contract, Args
    ),
    SignedContract0 = sign_transaction_base58(PrivateKey, {inner, ContractData0}),
    {transaction, InnerTxBin0} = aeser_api_encoder:decode(SignedContract0),

    {ok, PayingForTxFinal} = paying_for(
        list_to_binary(NodeAeAccount), NodeNonce, CorrectFee, InnerTxBin0
    ),
    PayingSignature = make_transaction_signature_base58(NodePrivateKey, PayingForTxFinal),
    PayingSignedTX = attach_signature_base58(PayingForTxFinal, PayingSignature),

    ?LOG_INFO("Paying for ~p", [PayingSignedTX]),
    case vanillae:post_tx(PayingSignedTX) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_tx(ContractCallTxHash);
        Error ->
            Error
    end.

with_ae_mdw_node(Fun) ->
    {ok, ConnPid, PathPrefix} = get_ae_mdw_node(),
    try
        Fun(ConnPid, PathPrefix)
    after
        catch gun:close(ConnPid)
    end.

middleware_balance(Account) when is_binary(Account) ->
    middleware_balance(binary_to_list(Account));
middleware_balance(Account) ->
    with_ae_mdw_node(fun(ConnPid, PathPrefix) ->
        Path = PathPrefix ++ "v3/aex9/" ++ ?DAMAGE_TOKEN_CONTRACT ++ "/balances/" ++ Account,
        StreamRef = gun:get(ConnPid, Path),
        #{amount := Amount} = read_stream(ConnPid, StreamRef),
        Amount
    end).
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
        "return_value" := ReturnValue
    } = contract_call(
        KeyPair,
        ?DAMAGE_TOKEN_CONTRACT,
        "contracts/token.aes",
        "balance",
        [Account]
    ),
    case ReturnValue of
        {variant, [0, 1], 1, {Balance}} ->
            Balance;
        {variant, [0, 1], 0, {}} ->
            0
    end.

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

sign_transaction(Priv, {inner, TX}) ->
    Sig = make_transaction_signature(Priv, {inner, TX}),
    SignedTXTemplate = [{signatures, [binary]}, {transaction, binary}],
    Fields = [{signatures, [Sig]}, {transaction, TX}],
    aeser_chain_objects:serialize(signed_tx, 1, SignedTXTemplate, Fields);
sign_transaction(Priv, TX) ->
    Sig = make_transaction_signature(Priv, TX),
    SignedTXTemplate = [{signatures, [binary]}, {transaction, binary}],
    Fields = [{signatures, [Sig]}, {transaction, TX}],
    aeser_chain_objects:serialize(signed_tx, 1, SignedTXTemplate, Fields).
sign_transaction_base58(Priv, {inner, EncodedTX}) ->
    {transaction, TX} = aeser_api_encoder:decode(EncodedTX),
    SignedTX = sign_transaction(Priv, {inner, TX}),
    aeser_api_encoder:encode(transaction, SignedTX);
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

node_ae_balance() ->
    case secrets:node_keypair() of
        #{public_key := AeAccount, private_key := _PrivateKey} ->
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
            Balance / math:pow(10, ?AE_DECIMALS);
        {error, Error} ->
            {error, Error}
    end.

node_damage_balance() ->
    #{public_key := AeAccount, private_key := _PrivateKey} = secrets:node_keypair(),
    Balance = balance(list_to_binary(AeAccount)),
    Balance / math:pow(10, ?DAMAGE_DECIMALS).

%% Post the already-signed tx, with optional paying_for wrapper
%-spec post_signed_or_payfor(binary(), boolean()) -> {ok, map()} | {error, term()}.
%post_signed_or_payfor(SignedTx, true) ->
%    %% Node pays the fee; inner must be signed by initiator.
%
%    %% your existing helper that wraps+posts
%    payfor_tx(SignedTx);
%post_signed_or_payfor(SignedTx, false) ->
%    vanillae:post_tx(SignedTx).

%% Post already-signed tx, or wrap in paying_for if you prefer node-paid fees
post_signed_or_payfor(SignedTx) ->
    %% Option A: direct post (tx must be signed by initiator)
    %% vanillae:post_tx(SignedTx).

    %% Option B: node pays fee, inner must be signed by initiator:

    %% your existing helper; returns {ok, #{ "tx_hash" := ...}} or {error, ...}
    payfor_tx(SignedTx).
deploy_account_registry(AccountKeypair) ->
    #{"contract_id" := ContractId} = contract_deploy_for(
        AccountKeypair, "contracts/AccountRegistry.aes", []
    ),
    ContractId.
deploy_node_registry() ->
    AccountKeypair = secrets:node_keypair(),
    #{"contract_id" := ContractId} = contract_deploy_for(
        AccountKeypair, "contracts/AccountRegistry.aes", []
    ),
    ContractId.

deploy_damage_nft() ->
    AccountKeypair = secrets:node_keypair(),
    #{"contract_id" := ContractId} = contract_deploy_for(
        AccountKeypair, "contracts/AccountRegistry.aes", []
    ),
    ContractId.

mint_nft_report(_TestTx) ->
    ok.

test_contract_deploy() ->
    KeyPair = secrets:node_keypair(),
    #{"contract_id" := ContractId} = contract_deploy(KeyPair, "contracts/test.aes", []),
    ContractId.
test_contract_deploy_for() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {PubKey, _Password, PrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    #{"contract_id" := ContractId} = contract_deploy_for(
        #{public_key => PubKey, private_key => PrivateKey},
        "contracts/test.aes",
        []
    ),
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
    with_ae_mdw_node(fun(ConnPid, _PathPrefix) ->
        case find_block_at_timestamp(ADayAgo * 1000, ConnPid) of
            {ok, Block, Mblocks} ->
                ?LOG_INFO("Found block ~p ~p", [Block, Mblocks]);
            Error ->
                ?LOG_ERROR("block not found ~p", [Error])
        end
    end).
test_get_block_height_since() ->
    with_ae_mdw_node(fun(ConnPid, _PathPrefix) ->
        Result = get_block_height_since(36, ConnPid),
        ?LOG_INFO("block height ~p", [Result]),
        Result
    end).

test_verify_message() ->
    #{public_key := PubKey, private_key := PrivateKey} = secret:node_keypair(),

    Data = <<"test">>,
    SigHex = sign_transaction_base58(PrivateKey, Data),
    _SigResult = vanillae:verify_signature(SigHex, Data, PubKey).
