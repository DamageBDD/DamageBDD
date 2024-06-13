-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).

%-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([check_invoices/0]).
-export([delete_account/1]).
-export([delete_resource/2]).
-export([get_user_info/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("reporting/formatter.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Account Management"]).

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
          produces => ["text/html", "application/json", "application/x-yaml"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create account using form ",
          produces => ["text/html", "application/json", "application/x-yaml"],
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
          produces => ["text/html", "application/json", "application/x-yaml"]
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
          produces => ["text/html", "application/json", "application/x-yaml"],
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
          produces => ["text/html", "application/json", "application/x-yaml"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create a new invoice.",
          produces => ["text/html", "application/json", "application/x-yaml"],
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
          produces => ["text/html", "application/json"],
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


to_json(Req, #{action := confirm} = State) ->
  % for some browsers who send in applicaion/json contenttype
  to_html(Req, State);

to_json(Req, #{action := invoices} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      {jsx:encode(get_invoices(ContractAddress)), Req, State};

    Other ->
      ?LOG_DEBUG("Unexpected ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end;

to_json(Req, #{action := balance} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{ae_account := AeAccount} = _State0} ->
      {jsx:encode(balance(AeAccount)), Req, State};

    Other ->
      ?LOG_DEBUG("Unexpected ~p", [Other]),
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
          #{
            email => Email,
            current_password => Password,
            body => <<"Test">>,
            current_password_type => <<"hidden">>
          }
        ),
      {Body, Req, State};

    notfound -> {<<"Invalid confirmation link. Please try again.">>, Req, State}
  end;

to_html(Req, #{action := invoices} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{ae_account := AeAccount} = _State0} ->
      Invoices = get_invoices(AeAccount),
      {jsx:encode(Invoices), Req, State};

    Other ->
      ?LOG_DEBUG("Unexpected ~p", [Other]),
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

do_post_action(invoices, #{amount := Amount}, _Req, _State)
when Amount > ?MAX_DAMAGE_INVOICE ->
  {
    400,
    #{
      status => <<"max_damage">>,
      message => <<"invoice amount too large">>,
      max_damage_invoice => ?MAX_DAMAGE_INVOICE
    }
  };

do_post_action(invoices, #{amount := Amount}, Req, State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{ae_account := AeAccount} = _State0} ->
      case
      damage_riak:get_index(
        ?INVOICE_BUCKET,
        {binary_index, "ae_account"},
        AeAccount,
        [{return_terms, true}]
      ) of
        [] ->
          #{<<"r_hash">> := RHash} =
            Invoice =
              lnd:create_invoice(Amount, damage_utils:encrypt(AeAccount)),
          Len = byte_size(AeAccount),
          {ok, true} =
            damage_riak:put(
              ?INVOICE_BUCKET,
              <<AeAccount:Len/binary, RHash/binary>>,
              maps:put(ae_account, AeAccount, maps:put(amount, Amount, Invoice)),
              [{{binary_index, "ae_account"}, [AeAccount]}]
            ),
          ?LOG_DEBUG("saved invoice ~p", [Invoice]),
          {201, #{status => <<"ok">>, message => Invoice}};

        [OtherEnc | _] ->
          Other = damage_utils:decrypt(OtherEnc),
          ?LOG_DEBUG("retrieved invoice ~p", [Other]),
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
      ?LOG_DEBUG("Unexpected ~p", [Other]),
      {401, #{status => <<"noauth">>, message => <<"Unauthorized.">>}}
  end.


from_html(Req, #{action := reset_password} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Data0 = maps:from_list(cow_qs:parse_qs(Data)),
  {Status0, Response0} =
    case damage_oauth:reset_password(Data0) of
      {ok, Message} ->
        {ok, ApiUrl} = application:get_env(damage, api_url),
        {
          200,
          damage_utils:load_template(
            "reset_password_response.html.mustache",
            #{status => <<"ok">>, message => Message, login_url => ApiUrl}
          )
        };

      {error, Message} ->
        {
          400,
          damage_utils:load_template(
            "reset_password_response.html.mustache",
            #{status => <<"failed">>, message => Message}
          )
        }
    end,
  {
    stop,
    cowboy_req:reply(Status0, cowboy_req:set_resp_body(Response0, Req)),
    State
  }.


from_json(Req, #{action := Action} = State) ->
  {ok, Data, Req0} = cowboy_req:read_body(Req),
  ?LOG_DEBUG("post action ~p ", [Data]),
  case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
    badarg ->
      Response =
        cowboy_req:set_resp_body(
          jsx:encode(
            #{status => <<"failed">>, message => <<"Json decode error.">>}
          ),
          Req0
        ),
      cowboy_req:reply(400, Response),
      ?LOG_DEBUG("post response 400 ~p ", [Response]),
      {stop, Response, State};

    {'EXIT', {badarg, _}} ->
      Response =
        cowboy_req:set_resp_body(
          jsx:encode(
            #{status => <<"failed">>, message => <<"Json decode error.">>}
          ),
          Req0
        ),
      cowboy_req:reply(400, Response),
      ?LOG_DEBUG("post response 400 ~p ", [Response]),
      {stop, Response, State};

    Data0 ->
      case do_post_action(Action, Data0, Req0, State) of
        {204, <<"">>} ->
          Response = cowboy_req:reply(204, Req0),
          {stop, Response, State};

        {Status0, Response0} ->
          Response = cowboy_req:set_resp_body(jsx:encode(Response0), Req0),
          cowboy_req:reply(Status0, Response),
          ?LOG_DEBUG("post response ~p ~p ", [Status0, Response]),
          {stop, Response, State}
      end
  end.


from_yaml(Req, #{action := reset_password} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case fast_yaml:decode(Data, [maps, {plain_as_atom, true}]) of
      {ok, [Data0]} ->
        case damage_oauth:reset_password(Data0) of
          {ok, Message} -> {200, #{status => <<"ok">>, message => Message}};

          {error, Message} ->
            {400, #{status => <<"failed">>, message => Message}}
        end;

      {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
    end,
  ?LOG_DEBUG("post action ~p resp ~p", [Data, Response0]),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
    ),
    State
  };

from_yaml(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case fast_yaml:decode(Data, [maps, {plain_as_atom, true}]) of
      {ok, [Data0]} -> do_post_action(Action, Data0, Req, State);
      {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
    end,
  ?LOG_DEBUG("post action ~p resp ~p", [Data, Response0]),
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
    {true, _Req0, #{ae_account := AeAccount} = _State0} ->
      case
      damage_riak:get_index(
        ?INVOICE_BUCKET,
        {binary_index, "contract_address"},
        AeAccount,
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
              ?LOG_DEBUG("retrieved invoice delete ~p", [InvoiceObj]),
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


balance(AeAccount) ->
  {ok, Balance} = damage_ae:balance(AeAccount),
  #{amount => Balance}.


check_invoice_foldn(Invoice, Acc) ->
  case maps:get(<<"state">>, Invoice) of
    <<"ACCEPTED">> ->
      ?LOG_DEBUG("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
      Acc;

    <<"SETTLED">> ->
      logger:info("Settled Invoice ~p", [Invoice]),
      AmountPaid = maps:get(<<"amt_paid_sat">>, Invoice),
      case maps:get(<<"memo">>, Invoice) of
        AeAccountEncrypted when is_binary(AeAccountEncrypted) ->
          logger:info("Acceptd Invoice ~p ~p", [Invoice, AmountPaid]),
          AeAccount = damage_utils:decrypt(AeAccountEncrypted),
          {funded, Result} = damage_ae:maybe_fund_wallet(AeAccount, AmountPaid),
          logger:info("Funded contract ~p ~p", [Result, AmountPaid]),
          Acc ++ [Invoice];

        _ -> Acc
      end;

    <<"CANCELED">> ->
      ?LOG_DEBUG("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
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


get_user_info(Username) ->
  case damage_riak:get(?USER_BUCKET, Username) of
    {ok, #{password := UserPw}} -> UserPw;
    _ -> <<"">>
  end.
