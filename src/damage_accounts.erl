-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).

%-export([to_json/2]).
%-export([to_text/2]).
-export(
  [create_contract/1, balance/1, check_spend/2, store_profile/1, refund/1]
).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([update_schedules/3]).
-export([confirm_spend/2]).
-export([is_allowed_hosts/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      %{{<<"application">>, <<"json">>, []}, to_json},
      %{{<<"text">>, <<"plain">>, '*'}, to_text},
      {{<<"text">>, <<"html">>, '*'}, to_html}
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


do_action(<<"create_from_yaml">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" yaml data: ~p ", [Data]),
  {ok, [Data0]} = fast_yaml:decode(Data, [maps]),
  damage_oauth:add_user(Data0);

do_action(<<"balance">>, Req) ->
  #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
  balance(ContractAddress);

do_action(<<"reset_password">>, Req) ->
  {
    ok,
    #{
      email := Email,
      password := Password,
      new_password := NewPassword,
      new_password_confirm := NewPasswordConfirm
    } = Data,
    _Req2
  } = cowboy_req:read_body(Req),
  NewPasswordConfirm = NewPassword,
  ?debugFmt("Form data ~p", [Data]),
  damage_oauth:reset_password(Email, Password, NewPassword);

do_action(<<"refund">>, Req) ->
  #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
  refund(ContractAddress).


%to_json(Req, State) ->
%      #{email := Email} = cowboy_req:match_qs([email], Req),
%  Body = case cowboy_req:binding(action, Req) of
%    <<"create">> ->
%                 jsx:encode(#{action=>
%
%    <<"reset_password">> ->
%        jsx:encode(Result)
%  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
%  %Req =
%  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
%  {Body, Req, State}.
%
%
%to_text(Req, State) -> to_html(Req, State).
to_html(Req, State) ->
  case cowboy_req:binding(action, Req) of
    <<"create">> ->
      Body =
        damage_utils:load_template(
          "create_account.mustache",
          #{body => <<"Test">>}
        ),
      {Body, Req, State};

    <<"confirm">> ->
      #{token := Password} = cowboy_req:match_qs([token], Req),
      {ok, Email} =
        damage_riak:get({<<"Default">>, <<"ConfirmToken">>}, Password),
      Body =
        damage_utils:load_template(
          "reset_password.mustache",
          #{email => Email, current_password => Password, body => <<"Test">>}
        ),
      {Body, Req, State};

    <<"reset_password">> ->
      #{password := Password} = cowboy_req:match_qs([password], Req),
      #{email := Email} = cowboy_req:match_qs([email], Req),
      Body =
        damage_utils:load_template(
          "reset_password.mustache",
          #{email => Email, current_password => Password, body => <<"Test">>}
        ),
      {Body, Req, State}
  end.


from_html(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt("Form data ~p", [Data]),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  case cowboy_req:binding(action, Req) of
    <<"create">> ->
      Result = damage_oauth:add_user(FormData),
      Body = damage_utils:load_template("create_account.mustache", Result),
      Resp = cowboy_req:set_resp_body(Body, Req),
      {stop, cowboy_req:reply(200, Resp), State};

    <<"confirm">> ->
      Body = <<"Ok account activation confirmed.">>,
      Resp = cowboy_req:set_resp_body(Body, Req),
      {stop, cowboy_req:reply(200, Resp), State};

    <<"reset_password">> ->
      #{
        <<"email">> := Email,
        <<"current_password">> := Password,
        <<"new_password_confirmation">> := NewPasswordConfirm,
        <<"new_password">> := NewPassword
      } = FormData,
      NewPassword = NewPasswordConfirm,
      damage_oauth:reset_password(Email, Password, NewPassword),
      Body = <<"Ok password reset confirmed.">>,
      Resp = cowboy_req:set_resp_body(Body, Req),
      {stop, cowboy_req:reply(200, Resp), State}
  end.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" json data: ~p ", [Data]),
  Data0 = jsx:decode(Data, [return_maps]),
  case cowboy_req:binding(action, Req) of
    <<"create">> ->
      Result = damage_oauth:add_user(Data0),
      JsonResult = jsx:encode(Result),
      Resp = cowboy_req:set_resp_body(JsonResult, Req),
      {stop, cowboy_req:reply(201, Resp), State};

    <<"reset_password">> ->
      #{
        email := Email,
        current_password := Password,
        new_password_confirm := NewPasswordConfirm,
        new_password := NewPassword
      } = Data0,
      NewPassword = NewPasswordConfirm,
      Result = damage_oauth:reset_password(Email, Password, NewPassword),
      JsonResult = jsx:encode(Result),
      Resp = cowboy_req:set_resp_body(JsonResult, Req),
      {stop, cowboy_req:reply(201, Resp), State}
  end.


from_yaml(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_yaml">>, Req),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


create_contract(RefundAddress) ->
    ?debugFmt("btc refund address ~p ", [RefundAddress]),
    % create ae account and bitcoin account
    #{result := #{contractId := ContractAddress}} =
    damage_ae:aecli(contract, deploy, "contracts/account.aes", []),
    {ok, BtcAddress} = bitcoin:getnewaddress(ContractAddress),
    ?debugFmt(
    "debug created AE contractid ~p ~p, ",
    [ContractAddress, BtcAddress]
    ),
    _ContractCreated =
    damage_ae:aecli(
        contract,
        call,
        binary_to_list(ContractAddress),
        "contracts/account.aes",
        "set_btc_state",
        [BtcAddress, RefundAddress]
    ),
    %?debugFmt("debug created AE contract ~p", [ContractCreated]),
    #{
    status => <<"ok">>,
    btc_address => BtcAddress,
    ae_contract_address => ContractAddress,
    btc_refund_address => RefundAddress
    }.



store_profile(ContractAddress) ->
  % store config schedule etc
  logger:debug("debug ~p", [ContractAddress]),
  ok.


check_spend("guest", _Concurrency) -> ok;
check_spend(<<"guest">>, _Concurrency) -> ok;

check_spend(ContractAddress, _Concurrency) ->
  #{decodedResult := Balance} =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "total_balance",
      []
    ),
  binary_to_integer(Balance).


balance(ContractAddress) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
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
  {ok, Transactions} = bitcoin:listtransactions(ContractAddress),
  ?debugFmt("Transactions ~p ", [Transactions]),
  {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
  Mesg =
    io:format(
      "Balance of account ~p usage is ~p btc_balance ~p btc_held ~p.",
      [ContractAddress, Usage, BtcBalance, RealBtcBalance]
    ),
  logger:debug(Mesg),
  maps:put(btc_refund_balance, RealBtcBalance, Results).


refund(ContractAddress) ->
  #{
    btc_address := BtcAddress,
    btc_refund_address := BtcRefundAddress,
    btc_balance := _BtcBalance,
    deso_address := _DesoAddress,
    deso_balance := _DesoBalance,
    balance := Balance,
    deployer := _Deployer
  } = balance(ContractAddress),
  case validate_refund_addr(forward, BtcRefundAddress) of
    {ok, BtcRefundAddress} ->
        {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
        ?debugFmt("real balance ~p ", [RealBtcBalance]),
        {ok, RefundResult} =
            bitcoin:sendtoaddress(
            BtcRefundAddress,
            RealBtcBalance - binary_to_integer(Balance),
            ContractAddress
            ),
        ?debugFmt("Refund result ~p ", [RefundResult]),
        RefundResult;
    Other ->
      ?debugFmt("refund_address data: ~p ", [Other]),
      #{status => <<"notok">>, message => <<"Invalid refund_address.">>}
  end.


update_schedules(ContractAddress, JobId, _Cron) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "update_schedules",
      [JobId]
    ),
  ?debugFmt("call AE contract ~p", [ContractCall]),
  #{
    decodedResult
    :=
    #{
      btc_address := _BtcAddress,
      btc_balance := _BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := _Usage,
      deployer := _Deployer
    } = Results
  } = ContractCall,
  ?debugFmt("State ~p ", [Results]).


confirm_spend(<<"guest">>, _) -> ok;

confirm_spend(ContractAddress, Amount) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "confirm_spend",
      [Amount]
    ),
  #{
    decodedResult
    :=
    #{
      btc_address := _BtcAddress,
      btc_balance := _BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := _Usage,
      deployer := _Deployer
    } = Balances
  } = ContractCall,
  ?debugFmt("call AE contract ~p", [Balances]),
  Balances.


is_allowed_hosts(Host, AllowedHosts) ->
  case lists:filter(fun (LHost) -> Host = LHost end, AllowedHosts) of
    [] -> throw({error, <<"Host not allowed", Host/binary>>});

    [Host] ->
      case inet_res:lookup(Host, in, txt) of
        {ok, Records} ->
          case
          lists:filter(
            fun (Record) -> string:substr(Record, "damage") /= 0 end,
            Records
          ) of
            [] -> io:format("No TXT record found for token: ~p~n", [Records]);
            [Token | _] -> ok = check_host_token(Host, Token)
          end
      end
  end.


check_host_token(Host, Token) ->
  Keys =
    damage_riak:get_index(
      {<<"Default">>, <<"HostTokens">>},
      <<"host_bin">>,
      Host
    ),
  case lists:filter(
    fun
      (T) ->
        T = Token,
        true
    end,
    Keys
  ) of
    [Token] -> {ok, Token};
    [] -> {error, notfound}
  end.
