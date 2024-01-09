-module(damage_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

-behaviour(gen_server).

-export([start_link/1]).
-export(
  [
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).
-export([sign_tx/2]).
-export([aecli/4, aecli/6]).
-export([test_contract_call/1]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  process_flag(trap_exit, true),
  {ok, undefined}.


handle_call({transaction, Data}, _From, State) ->
  logger:debug("handle_call transaction/1 : ~p", [Data]),
  {reply, ok, State}.


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
  ?debugFmt("Cmd : ~p", [Cmd]),
  Result = exec:run(Cmd, [stdout, stderr, sync]),
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
  ?debugFmt("Cmd : ~p", [Cmd]),
  Result0 = exec:run(Cmd, [stdout, stderr, sync]),
  {ok, [{stdout, Result}]} = Result0,
  jsx:decode(binary:list_to_bin(Result), [{labels, atom}]).


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


% Tokenization
% all nodes get same payout once consensus is acheived
% if there is no consensus then esclation and re-election of participating nodes through some mechanism
