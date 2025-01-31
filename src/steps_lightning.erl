-module(steps_lightning).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  <<"Then">>,
  _N,
  ["I pay the invoice with payment request", PaymentRequest],
  _
) ->
  true = steps_utils:is_admin(AeAccount),
  maps:put(
    lightning_payment_status,
    cln:settle_invoice(list_to_binary(PaymentRequest)),
    Context
  );

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["I display the qrcode for", PaymentHash],
  _
) ->
  ?LOG_INFO("I display the qrcode for ~p", [PaymentHash]),
  Context;

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["I wait for funds in escrow", PaymentHash],
  _
) ->
  ?LOG_INFO("I release funds in escrow ~p", [PaymentHash]),
  Context;

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["I release funds in escrow", PaymentHash],
  _
) ->
  ?LOG_INFO("I release funds in escrow ~p", [PaymentHash]),
  Context.
