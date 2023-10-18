-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([allowed_methods/2]).
-export([create/1, balance/1, check_spend/2, store_profile/1, refund/1]).

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

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

validate_refund_addr(forward, BtcAddress) ->
  case bitcoin_validateaddress(BtcAddress) of
    #{isvalid := true} -> {ok, BtcAddress};
    _Other -> {ok, false}
  end.


do_action(<<"create">>, Req) ->
  case
  cowboy_req:match_qs([{refund_address, fun validate_refund_addr/2, []}], Req) of
    #{refund_address := false} -> <<"Invalid refund_address.">>;
    #{refund_address := RefundAddress} -> create(RefundAddress)
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

bitcoin_validateaddress(BtcAddress) ->
  bitcoin_req(<<"validateaddress">>, [BtcAddress]).

bitcoin_getreceivedbyaddress(BtcAddress) ->
  bitcoin_req(<<"getreceivedbyaddress">>, [BtcAddress]).

bitcoin_listtransactions(Account) ->
  bitcoin_req(<<"listtransactions">>, [Account]).

%bitcoin_addressinfo(BtcAddress) ->
%  bitcoin_req(<<"getaddressinfo">>, [BtcAddress]).
bitcoin_sendtoaddress(Address, Amount, AeContract) ->
  bitcoin_req(<<"sendtoaddress">>, [Address, Amount, AeContract]).

bitcoin_getnewaddress(AeAccount) ->
  bitcoin_req(<<"getnewaddress">>, [AeAccount, <<"bech32">>]).

bitcoin_req(Method, Params) ->
    {ok, } = application:get_env(damage, bitcoin_rpc_host),
    {ok, ConnPid} = gun:open("localhost", 18332, #{}),
  Data =
    #{
      jsonrpc => <<"1.0">>,
      id => <<"curltest">>,
      method => Method,
      params => Params
    },
  UserID = "damagebdd",
  Password = os:getenv("BTC_PASSWORD"),
  ?debugFmt("POST data: ~p ", [Data]),
  StreamRef =
    gun:post(
      ConnPid,
      "/wallet/testwallet",
      [
        {<<"content-type">>, <<"text/plain">>},
        {
          <<"Authorization">>,
          [
            <<"Basic ">>,
            base64:encode(iolist_to_binary([UserID, $:, Password]))
          ]
        }
      ],
      jsx:encode(Data),
      #{}
    ),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, Status, Headers0} ->
      ?debugFmt("POST Response: ~p ~p", [Status, Headers0]),
      logger:debug("POST Response: ~p ~p", [Status, Headers0]);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      ?debugFmt("POST Response: ~p ~p ~p", [Status, Headers0, Body]),
      case jsx:decode(Body, [{labels, atom}, return_maps]) of
        #{result := null, error := Error} ->
          ?debugFmt("bitcoin req error ~p", [Error]),
          {error, Error};

        #{result := Account} ->
          ?debugFmt("bitcoin wallet creation ~p", [Account]),
          {ok, Account}
      end
  end.


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
  AeWallet = "wallets/test0",
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


%sign_tx(Tx) ->
%    {ok, TxSer} = aeser_api_encoder:safe_decode(transaction, Tx),
%    UTx = aetx:deserialize_from_binary(TxSer),
%    STx = aec_test_utils:sign_tx(UTx, [maps:get(privkey, aecore_suite_utils:patron())]),
%    aeser_api_encoder:encode(transaction, aetx_sign:serialize_to_binary(STx)).
%create_account(AeAccount) ->
%  {ok, Nonce} = vanillae:next_nonce(AeAccount),
%  {ok, ConID} =
%    vanillae:contract_create(AeAccount, "contracts/account.aes", []),
%  ?debugFmt("contract create ~p", [ConID]),
%  {ok, AACI} = vanillae:prepare_contract("contracts/account.aes"),
%  ContractCall =
%    vanillae:contract_call(
%      AeAccount,
%      Nonce,
%      0,
%      0,
%      0,
%      0,
%      AACI,
%      ConID,
%      "btc_address",
%      []
%    ),
%  ?debugFmt("contract call ~p", [ContractCall]),
%  sign_tx(ContractCall),

% 
%generate an erlang gen_server process that monitors a bitcoin address for transactions using the bitcoin core json rpc
create(RefundAddress) ->
  ?debugFmt("btc refund address ~p ", [RefundAddress]),
  % create ae account and bitcoin account
  #{result := #{contractId := ContractAddress}} =
    aecli(contract, deploy, "contracts/account.aes", []),
  BtcAddress = bitcoin_getnewaddress(ContractAddress),
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


check_spend(Account, Concurrency) ->
  BtcBalance = bitcoin_getreceivedbyaddress(Account),
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
      balance := Balance,
      deployer := _Deployer
    } = Results
  } = ContractCall,
  ?debugFmt("State ~p ", [Results]),
  Transactions = bitcoin_listtransactions(Account),
  ?debugFmt("Transactions ~p ", [Transactions]),
  {ok, RealBtcBalance} = bitcoin_getreceivedbyaddress(BtcAddress),
  Mesg =
    io:format(
      "Balance of account ~p is ae ~p btc ~p btc_held ~p.",
      [Account, Balance, BtcBalance, RealBtcBalance]
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
  {ok, RealBtcBalance} = bitcoin_getreceivedbyaddress(BtcAddress),
  ?debugFmt("real balance ~p ", [RealBtcBalance]),
  RefundResult =
    bitcoin_sendtoaddress(
      BtcRefundAddress,
      RealBtcBalance - binary_to_integer(Balance),
      Account
    ),
  ?debugFmt("Refund result ~p ", [RefundResult]),
  RefundResult.


%on_payment(Wallet) ->
%    take_fee(Wallet)
%    get_ae(Wallet)
