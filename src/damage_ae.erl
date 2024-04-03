-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
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
    code_change/3
  ]
).
-export([sign_tx/2]).
-export([aecli/4, aecli/6]).
-export([test_contract_call/1, test_token_contract/0]).
-export([balance/1, invalidate_cache/0, spend/2, confirm_spend/1]).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  process_flag(trap_exit, true),
  gproc:reg_other({n, l, {?MODULE, ae}}, self()),
  {ok, #{}}.


handle_call({balance, ContractAddress}, _From, Cache) ->
  case catch maps:get(ContractAddress, Cache, undefined) of
    undefined -> {reply, {error, not_found}, Cache};
    {Balance, _} -> {reply, {ok, Balance}, Cache}
  end;

handle_call({transaction, Data}, _From, State) ->
  logger:debug("handle_call transaction/1 : ~p", [Data]),
  {reply, ok, State}.


handle_cast({confirm_spend, ContractAddress}, Cache)
when is_list(ContractAddress) ->
  handle_cast({confirm_spend, list_to_binary(ContractAddress)}, Cache);

handle_cast({confirm_spend, ContractAddress}, Cache)
when is_binary(ContractAddress) ->
  {_, Spend} = maps:get(ContractAddress, Cache, {0, 0}),
  logger:debug("handle_cast confirm_spend ~p ~p", [ContractAddress, Spend]),
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "spend",
      [Spend]
    ),
  #{decodedResult := #{balance := Balance, deployer := _Deployer} = _Balances} =
    ContractCall,
  NewCache = maps:put(ContractAddress, {Balance, 0}, Cache),
  logger:debug("confirm spend ~p", [NewCache]),
  {noreply, NewCache};

handle_cast({spend, ContractAddress, Amount}, Cache)
when is_list(ContractAddress) ->
  handle_cast({spend, list_to_binary(ContractAddress), Amount}, Cache);

handle_cast({spend, ContractAddress, Amount}, Cache)
when is_binary(ContractAddress) ->
  logger:debug("handle_cast spend", []),
  {Balance, Spend} = maps:get(ContractAddress, Cache, {0, 0}),
  NewCache = maps:put(ContractAddress, {Balance, Spend + Amount}, Cache),
  {noreply, NewCache};

handle_cast({update_balance, ContractAddress, Balance}, Cache)
when is_binary(ContractAddress) ->
  logger:debug("upate balance", []),
  {_, Spend} = maps:get(ContractAddress, Cache, {0, 0}),
  NewCache = maps:put(ContractAddress, {Balance, Spend}, Cache),
  {noreply, NewCache};

handle_cast(invalidate_cache, _Cache) -> {noreply, #{}};
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


aecli(contract, call, ContractAddress, Contract, Func, Args) ->
  {ok, AeWallet} = application:get_env(damage, ae_wallet),
  Password = os:getenv("AE_PASSWORD"),
  Cmd =
    mustache:render(
      "aecli contract call --contractSource {{contract_source}} --contractAddress {{contract_address}} {{contract_function}} '{{contract_args}}' {{wallet}} --password={{password}} --json",
      [
        {wallet, AeWallet},
        {password, Password},
        {contract_source, Contract},
        {contract_args, binary_to_list(jsx:encode(Args))},
        {contract_address, ContractAddress},
        {contract_function, Func}
      ]
    ),
  logger:debug("Cmd : ~p", [Cmd]),
  Result = exec:run(Cmd, [stdout, stderr, sync]),
  logger:debug("Result : ~p", [Result]),
  {ok, [{stdout, [AeAccount0]}]} = Result,
  jsx:decode(AeAccount0, [{labels, atom}]).


aecli(contract, deploy, Contract, Args) ->
  {ok, AeWallet} = application:get_env(damage, ae_wallet),
  Password = os:getenv("AE_PASSWORD"),
  Cmd =
    mustache:render(
      "aecli contract deploy {{wallet}} --contractSource {{contract_source}} '{{contract_args}}' --password={{password}} --json ",
      [
        {wallet, AeWallet},
        {password, Password},
        {contract_source, Contract},
        {contract_args, binary_to_list(jsx:encode(Args))}
      ]
    ),
  logger:debug("Cmd : ~p", [Cmd]),
  case exec:run(Cmd, [stdout, stderr, sync]) of
    {error, [{exit_status, _}, {stderr, Stderr}]} ->
      logger:error("Error executing aecli ~p", [Stderr]);

    {ok, [{stdout, Result}]} ->
      jsx:decode(binary:list_to_bin(Result), [{labels, atom}])
  end.


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
balance(ContractAddress) ->
  DamageAEPid = gproc:lookup_local_name({?MODULE, ae}),
  case gen_server:call(DamageAEPid, {balance, ContractAddress}) of
    {ok, Balance} -> Balance;

    _ ->
      ContractCall =
        damage_ae:aecli(
          contract,
          call,
          binary_to_list(ContractAddress),
          "contracts/account.aes",
          "get_state",
          []
        ),
      #{
        decodedResult := #{balance := Balance, deployer := _Deployer} = _Results
      } = ContractCall,
      Mesg =
        io:format("Balance of account ~p is ~p.", [ContractAddress, Balance]),
      logger:debug(Mesg, []),
      gen_server:cast(
        DamageAEPid,
        {update_balance, ContractAddress, binary_to_integer(Balance)}
      ),
      Balance
  end.


spend(ContractAddress, Amount) ->
  % temporary storage to commit after feature execution
  DamageAEPid = gproc:lookup_local_name({?MODULE, ae}),
  gen_server:cast(DamageAEPid, {spend, ContractAddress, Amount}).


confirm_spend(ContractAddress) ->
  % temporary storage to commit after feature execution
  DamageAEPid = gproc:lookup_local_name({?MODULE, ae}),
  gen_server:cast(DamageAEPid, {confirm_spend, ContractAddress}).


invalidate_cache() ->
  DamageAEPid = gproc:lookup_local_name({?MODULE, ae}),
  gen_server:cast(DamageAEPid, invalidate_cache).


test_contract_call(AeAccount) ->
  JobId = <<"sdds">>,
  {ok, Nonce} = vanillae:next_nonce(AeAccount),
  {ok, ContractData} =
    vanillae:contract_create(AeAccount, "contracts/account.aes", []),
  {ok, sTx} = sign_tx(ContractData),
  ?debugFmt("contract create ~p", [sTx]),
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
      sTx,
      "update_schedule",
      [JobId]
    ),
  ?debugFmt("contract call ~p", [ContractCall]),
  {ok, sTx} = sign_tx(ContractCall),
  case vanillae:post_tx(sTx) of
    {ok, #{"tx_hash" := Hash}} ->
      ?debugFmt("contract call success ~p", [Hash]),
      Hash;

    {ok, WTF} ->
      logger:error("contract call Unexpected result ~p", [WTF]),
      {error, unexpected};

    {error, Reason} ->
      logger:error("contract call error ~p", [Reason]),
      {error, Reason}
  end.


test_token_contract() ->
  #{owner := _Owner0, address := ContractAddress0} =
    aecli(
      contract,
      deploy,
      "contracts/token.aes",
      [<<"TestToken">>, 1000, <<"dmg">>, 1000]
    ),
  #{owner := _Owner1, address := ContractAddress1} =
    aecli(
      contract,
      deploy,
      "contracts/token.aes",
      [<<"TestToken">>, 1000, <<"dmg">>, 1000]
    ),
  #{decodedResult := _DecodedResult1, result := Result1} =
    aecli(
      contract,
      call,
      binary_to_list(ContractAddress0),
      "contracts/token.aes",
      "burn",
      [10]
    ),
  logger:debug("called deployed token contract burn ~p", [Result1]),
  %#{decodedResult := _DecodedResult2, result := _Result2} =
  CallResult =
    aecli(
      contract,
      call,
      binary_to_list(ContractAddress0),
      "contracts/token.aes",
      "transfer",
      [ContractAddress1, 10]
    ),
  logger:debug("called deployed token contract burn ~p", [CallResult]),
  CallResult0 =
    aecli(
      contract,
      call,
      binary_to_list(ContractAddress0),
      "contracts/token.aes",
      "balance",
      [ContractAddress1]
    ),
  logger:debug("called deployed token contract burn ~p", [CallResult0]).
