-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([create/1, balance/1, check_spend/2, store_profile/1, refund/1]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([sign_tx/1]).
%-export([update_schedules/3]).
-export([test_contract_call/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

validate_refund_addr(forward, BtcAddress) ->
  case bitcoin:validateaddress(BtcAddress) of
    {ok, #{isvalid := true, address := BtcAddress}} -> {ok, BtcAddress};
    _Other -> {ok, false}
  end.


do_kyc_create(
  #{
    <<"full_name">> := FullName,
    <<"email">> := ToEmail,
    <<"refund_address">> := RefundAddress
  } = KycData
) ->
  KycDataJson = jsx:encode(KycData),
  case os:getenv("KYC_SECRET_KEY") of
    false ->
      logger:info("KYC_SECRET_KEY environment variable not set."),
      exit(normal);

    KycKey ->
      EncryptedKyc =
        damage_utils:encrypt(
          KycDataJson,
          base64:decode(list_to_binary(KycKey)),
          crypto:strong_rand_bytes(32)
        ),
      Ctxt = maps:merge(create(RefundAddress), KycData),
      damage_utils:send_email(
        {FullName, ToEmail},
        <<"DamageBDD SignUp">>,
        damage_utils:load_template("signup_email.mustache", Ctxt)
      ),
      {ok, _Obj} =
        damage_riak:put(
          <<"kyc">>,
          maps:get(ae_contract_address, Ctxt),
          EncryptedKyc
        ),
      KycData
  end.


do_action(<<"create_from_yaml">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" yaml data: ~p ", [Data]),
  {ok, [Data0]} = fast_yaml:decode(Data, [maps]),
  do_action(<<"create">>, Data0);

do_action(<<"create_from_json">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" json data: ~p ", [Data]),
  Data0 = jsx:decode(Data, [return_maps]),
  do_action(<<"create">>, Data0);

do_action(<<"create">>, #{<<"refund_address">> := RefundAddress} = Data) ->
  case validate_refund_addr(forward, RefundAddress) of
    {ok, RefundAddress} -> do_kyc_create(Data);

    Other ->
      ?debugFmt("refund_address data: ~p ", [Other]),
      <<"Invalid refund_address.">>
  end;

do_action(<<"balance">>, Req) ->
  #{account := Account} = cowboy_req:match_qs([account], Req),
  balance(Account);

do_action(<<"refund">>, Req) ->
  #{account := Account} = cowboy_req:match_qs([account], Req),
  refund(Account).


to_json(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Body = jsx:encode(Result),
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req, State}.


to_text(Req, State) -> to_json(Req, State).

to_html(Req, State) ->
  Body = damage_utils:load_template("create.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


from_html(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Resp = cowboy_req:set_resp_body(Result, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_json(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_json">>, Req),
  JsonResult = jsx:encode(Result),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_yaml(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_yaml">>, Req),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


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


%
%generate an erlang gen_server process that monitors a bitcoin address for transactions using the bitcoin core json rpc
create(RefundAddress) ->
  ?debugFmt("btc refund address ~p ", [RefundAddress]),
  % create ae account and bitcoin account
  #{result := #{contractId := ContractAddress}} =
    aecli(contract, deploy, "contracts/account.aes", []),
  {ok, BtcAddress} = bitcoin:getnewaddress(ContractAddress),
  ?debugFmt(
    "debug created AE contractid ~p ~p, ",
    [ContractAddress, BtcAddress]
  ),
  ContractCreated =
    aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "set_btc_state",
      [BtcAddress, RefundAddress]
    ),
  ?debugFmt("debug created AE contract ~p", [ContractCreated]),
  #{
    status => <<"ok">>,
    btc_address => BtcAddress,
    ae_contract_address => ContractAddress,
    btc_refund_address => RefundAddress
  }.


store_profile(Account) ->
  % store config schedule etc
  logger:debug("debug ~p", [Account]),
  ok.


check_spend("guest", _Concurrency) -> ok;
check_spend(<<"guest">>, _Concurrency) -> ok;

check_spend(Account, Concurrency) ->
  {ok, BtcBalance} = bitcoin:getreceivedbyaddress(list_to_binary(Account)),
  ?debugFmt("btc_balance ~p", [BtcBalance]),
  {ok, #{balance := Balance, id := Account}} = vanillae:acc(Account),
  case Balance of
    B when B < 1 ->
      ?debugFmt("top up required ~p for concurrency ~p", [B, Concurrency]);

    C when C > 1 ->
      ?debugFmt("top up not required ~p fir concurrency ~p", [C, Concurrency])
  end,
  %check_balance_top_up(Account, Concurrency),
  %contract_call(spend, Account,  Concurrency),
  ok.


balance(Account) ->
  ContractCall =
    aecli(
      contract,
      call,
      binary_to_list(Account),
      "contracts/account.aes",
      "get_state",
      []
    ),
  ?debugFmt("call AE contract ~p", [ContractCall]),
  #{
    decodedResult
    :=
    #{
      btc_address := BtcAddress,
      btc_balance := BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := Usage,
      deployer := _Deployer
    } = Results
  } = ContractCall,
  ?debugFmt("State ~p ", [Results]),
  {ok, Transactions} = bitcoin:listtransactions(Account),
  ?debugFmt("Transactions ~p ", [Transactions]),
  {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
  Mesg =
    io:format(
      "Balance of account ~p usage is ~p btc_balance ~p btc_held ~p.",
      [Account, Usage, BtcBalance, RealBtcBalance]
    ),
  logger:debug(Mesg),
  maps:put(btc_refund_balance, RealBtcBalance, Results).


refund(Account) ->
  #{
    btc_address := BtcAddress,
    btc_refund_address := BtcRefundAddress,
    btc_balance := _BtcBalance,
    deso_address := _DesoAddress,
    deso_balance := _DesoBalance,
    balance := Balance,
    deployer := _Deployer
  } = balance(Account),
  {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
  ?debugFmt("real balance ~p ", [RealBtcBalance]),
  {ok, RefundResult} =
    bitcoin:sendtoaddress(
      BtcRefundAddress,
      RealBtcBalance - binary_to_integer(Balance),
      Account
    ),
  ?debugFmt("Refund result ~p ", [RefundResult]),
  RefundResult.

%update_schedules(Account, JobId, Cron)->
%  ContractCreated =
%    aecli(
%      contract,
%      call,
%      binary_to_list(Account),
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
rlp_encode(BytesList) ->
    %TODO
    BytesList.

sign_tx(UTx) ->
  Password = os:getenv("AE_PASSWORD"),
    sign_tx(UTx, Password).
sign_tx(UTx, PrivateKey) ->
    SignData = <<"ae_uat", UTx/binary>>,
    Signature = enacl:sign_detached(SignData, PrivateKey),
    TagBytes = 11,
    VsnBytes = 1,
    {ok, rlp_encode([TagBytes, VsnBytes, [Signature], UTx])}.

test_contract_call(AeAccount) ->
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
      0, % Amount
      0, % Gas
      0, % GasPrice
      0, % Fee
      AACI,
      sTx,
      "update_schedule",
      []
    ),
  ?debugFmt("contract call ~p", [ContractCall]),
  Password = os:getenv("AE_PASSWORD"),
  {ok, sTx} = sign_tx(ContractCall, Password),
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

