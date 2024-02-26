-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).

%-export([to_text/2]).
-export([create_contract/0, store_profile/1, refund/1]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([update_schedules/3]).
-export([get_account_context/1]).
-export([trails/0]).
-export([check_invoices/0]).
-export([delete_account/1]).
-export([delete_resource/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

-define(MAX_DAMAGE_INVOICE, 4000).
-define(INVOICE_BUCKET, {<<"Default">>, <<"Invoices">>}).
-define(USER_BUCKET, {<<"Default">>, <<"Users">>}).
-define(CONTEXT_BUCKET, {<<"Default">>, <<"Contexts">>}).
-define(CONFIRM_TOKEN_BUCKET, {<<"Default">>, <<"ConfirmTokens">>}).
-define(TRAILS_TAG, ["Account Management"]).
-define(INVOICES_SINCE, 30).

trails() ->
  [
    trails:trail(
      "/accounts/create",
      damage_accounts,
      #{action => create},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to create an account on this DamageBDD server.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create account using form ",
          produces => ["text/html"],
          parameters
          =>
          [
            #{
              name => <<"email">>,
              description
              =>
              <<"A valid email address for user account recovery.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"full_name">>,
              description => <<"A name to reffer to user in communications.">>,
              in => <<"body">>,
              required => false,
              type => <<"string">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/balance",
      damage_accounts,
      #{action => balance},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "do some action ",
          produces => ["text/plain"]
        }
      }
    ),
    trails:trail(
      "/accounts/confirm",
      damage_accounts,
      #{action => confirm},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Confirm account.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"token">>,
              description
              =>
              <<"A valid confirmation token sent to account email.">>,
              in => <<"query">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/invoices",
      damage_accounts,
      #{action => invoices},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "list invoices for account",
          produces => ["text/plain"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create a new invoice.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              amount => <<"amount">>,
              description => <<"ammount to create invoice">>,
              in => <<"body">>,
              required => true,
              type => <<"integer">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/reset_password",
      damage_accounts,
      #{action => reset_password},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Reset password using reset token sent to email.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"token">>,
              description
              =>
              <<"A valid reset password token sent to account email.">>,
              in => <<"query">>,
              required => true,
              type => <<"string">>
            }
          ]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Submit reset password form.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"current_password">>,
              description => <<"Current password">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"new_password">>,
              description => <<"New password">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"new_password_confirm">>,
              description => <<"New password confirmation">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
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

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

validate_refund_addr(forward, BtcAddress) ->
  case bitcoin:validateaddress(BtcAddress) of
    {ok, #{isvalid := true, address := BtcAddress}} -> {ok, BtcAddress};
    _Other -> {ok, false}
  end.


get_invoices(ContractAddress) ->
  case
  damage_riak:get_index(
    ?INVOICE_BUCKET,
    {binary_index, "contract_address"},
    ContractAddress
  ) of
    [] -> [];

    Invoices when is_list(Invoices) ->
      lists:map(
        fun
          (X) ->
            {ok, Resp} =
              damage_riak:get(?INVOICE_BUCKET, damage_utils:decrypt(X)),
            Resp
        end,
        Invoices
      )
  end.


to_json(Req, #{action := invoices} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      {jsx:encode(get_invoices(ContractAddress)), Req, State};

    Other ->
      logger:debug("Unexpected ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end;

to_json(Req, #{action := balance} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      {jsx:encode(balance(ContractAddress)), Req, State};

    Other ->
      logger:debug("Unexpected ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end.


to_html(Req, #{action := create} = State) ->
  Body =
    damage_utils:load_template("create_account.mustache", #{body => <<"Test">>}),
  {Body, Req, State};

to_html(Req, #{action := confirm} = State) ->
  #{token := Password} = cowboy_req:match_qs([token], Req),
  case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Password) of
    {ok, #{email := Email, expiry := _Expiry}} ->
      Body =
        damage_utils:load_template(
          "reset_password.mustache",
          #{email => Email, current_password => Password, body => <<"Test">>}
        ),
      {Body, Req, State};

    notfound -> {<<"Invalid confirmation link. Please try again.">>, Req, State}
  end;

to_html(Req, #{action := invoices} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      Invoices = get_invoices(ContractAddress),
      {jsx:encode(Invoices), Req, State};

    Other ->
      logger:debug("Unexpected ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end;

to_html(Req, #{action := reset_password} = State) ->
  Body =
    case damage_oauth:reset_password(cowboy_req:match_qs([token], Req)) of
      {ok, Body0} -> Body0;
      {error, Msg} -> Msg
    end,
  {Body, Req, State}.


-spec do_post_action(atom(), map(), cowboy_req:req(), map()) ->
  {integer(), map()}.
do_post_action(create, Data, _Req, _State) ->
  case damage_oauth:add_user(Data) of
    {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
  end;

do_post_action(invoices, #{<<"amount">> := Amount}, _Req, _State)
when Amount > ?MAX_DAMAGE_INVOICE ->
  {
    400,
    #{
      status => <<"max_damage">>,
      message => <<"invoice amount too large">>,
      max_damage_invoice => ?MAX_DAMAGE_INVOICE
    }
  };

do_post_action(invoices, #{<<"amount">> := Amount}, Req, State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      case
      damage_riak:get_index(
        ?INVOICE_BUCKET,
        {binary_index, "contract_address"},
        ContractAddress,
        [{return_terms, true}]
      ) of
        [] ->
          #{<<"r_hash">> := RHash} =
            Invoice =
              lnd:create_invoice(Amount, damage_utils:encrypt(ContractAddress)),
          Len = byte_size(ContractAddress),
          {ok, true} =
            damage_riak:put(
              ?INVOICE_BUCKET,
              <<ContractAddress:Len/binary, RHash/binary>>,
              maps:put(
                contract_address,
                ContractAddress,
                maps:put(amount, Amount, Invoice)
              ),
              [{{binary_index, "contract_address"}, [ContractAddress]}]
            ),
          logger:debug("saved invoice ~p", [Invoice]),
          {201, #{status => <<"ok">>, message => Invoice}};

        [OtherEnc | _] ->
          Other = damage_utils:decrypt(OtherEnc),
          logger:debug("retrieved invoice ~p", [Other]),
          case damage_riak:get(?INVOICE_BUCKET, Other) of
            {ok, InvoiceObj} ->
              {200, #{status => <<"ok">>, message => InvoiceObj}};

            _ ->
              {
                201,
                #{
                  status => <<"exists">>,
                  message
                  =>
                  <<
                    "unpaid invoices exists please cancel previous invoice before creatig new invoices"
                  >>
                }
              }
          end
      end;

    Other ->
      logger:debug("Unexpected ~p", [Other]),
      {401, #{status => <<"noauth">>, message => <<"Unauthorized.">>}}
  end;

do_post_action(reset_password, Data, _Req, _State) ->
  case damage_oauth:reset_password(Data) of
    {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
  end.


from_html(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  {Status0, Response0} = do_post_action(Action, FormData, Req, State),
  Body =
    case Action of
      create -> <<"Account created successfuly and password set.">>;

      refund ->
        #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
        refund(ContractAddress);

      _ -> Response0
    end,
  {
    stop,
    cowboy_req:reply(Status0, cowboy_req:set_resp_body(jsx:encode(Body), Req)),
    State
  }.


from_json(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  logger:debug("post action ~p ", [Data]),
  {Status0, Response0} =
    case catch jsx:decode(Data, [return_maps]) of
      badarg ->
        {400, #{status => <<"failed">>, message => <<"Json decode error.">>}};

      Data0 -> do_post_action(Action, Data0, Req, State)
    end,
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(jsx:encode(Response0), Req)
    ),
    State
  }.


from_yaml(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case fast_yaml:decode(Data, [maps]) of
      {ok, [Data0]} -> do_post_action(Action, Data0, Req, State);
      {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
    end,
  logger:debug("post action ~p resp ~p", [Data, Response0]),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
    ),
    State
  }.


delete_resource(Req, #{action := invoices} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      case
      damage_riak:get_index(
        ?INVOICE_BUCKET,
        {binary_index, "contract_address"},
        ContractAddress,
        [{return_terms, true}]
      ) of
        [] -> {true, Req, State};

        [OtherEnc | _] ->
          Other = damage_utils:decrypt(OtherEnc),
          case damage_riak:get(?INVOICE_BUCKET, Other) of
            {
              ok,
              #{payment_request := _PaymentRequest, r_hash := RHash} =
                InvoiceObj
            } ->
              logger:debug("retrieved invoice delete ~p", [InvoiceObj]),
              case lnd:cancel_invoice(RHash) of
                #{<<"code">> := 5} ->
                  logger:info("Invoice not found ~p", [RHash]);

                Other -> logger:info("Invoice found ~p", [Other])
              end,
              {true, Req, State};

            _ -> {false, Req, State}
          end
      end;

    _Other -> {<<"Unauthorized.">>, Req, State}
  end.


create_contract() ->
  % create ae account and bitcoin account
  #{result := #{contractId := ContractAddress}} =
    damage_ae:aecli(contract, deploy, "contracts/account.aes", []),
  %?debugFmt("debug created AE contract ~p", [ContractCreated]),
  #{status => <<"ok">>, ae_contract_address => ContractAddress}.


store_profile(ContractAddress) ->
  % store config schedule etc
  logger:debug("debug ~p", [ContractAddress]),
  ok.


balance(ContractAddress) -> #{balance => damage_ae:balance(ContractAddress)}.

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


get_account_context(Account) ->
  case damage_riak:get(?CONTEXT_BUCKET, Account) of
    {ok, Context} ->
      logger:debug("got context ~p", [Context]),
      Context;

    Other ->
      logger:debug("got context ~p", [Other]),
      #{}
  end.


check_invoice_foldn(Invoice, Acc) ->
  case maps:get(<<"state">>, Invoice) of
    <<"ACCEPTED">> ->
      logger:debug("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
      Acc;

    <<"SETTLED">> ->
      logger:info("Settled Invoice ~p", [Invoice]),
      AmountPaid = maps:get(<<"amt_paid_sat">>, Invoice),
      SettledTs = binary_to_integer(maps:get(<<"settled_date">>, Invoice)),
      case maps:get(<<"memo">>, Invoice) of
        ContractAddressEncrypted when is_binary(ContractAddressEncrypted) ->
          logger:info("Acceptd Invoice ~p ~p", [Invoice, AmountPaid]),
          ContractAddress = damage_utils:decrypt(ContractAddressEncrypted),
          #{decodedResult := Balance} =
            damage_ae:aecli(
              contract,
              call,
              binary_to_list(ContractAddress),
              "contracts/account.aes",
              "fund",
              [AmountPaid, SettledTs]
            ),
          logger:info("Funded contract ~p ~p", [Balance, AmountPaid]),
          Acc ++ [Invoice];

        _ -> Acc
      end;

    <<"CANCELED">> ->
      logger:debug("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
      Acc
  end.


check_invoices() ->
  {Date, _} = calendar:now_to_datetime(os:timestamp()),
  CreationDate =
    integer_to_list(
      date_util:date_to_epoch(date_util:subtract(Date, {days, ?INVOICES_SINCE}))
    ),
  lists:foldl(
    fun check_invoice_foldn/2,
    [],
    lnd:list_invoices([{"creation_date_start", CreationDate}])
  ).


delete_account(Email) ->
  case damage_riak:delete(?USER_BUCKET, Email) of
    ok -> ok;
    _ -> fail
  end.
