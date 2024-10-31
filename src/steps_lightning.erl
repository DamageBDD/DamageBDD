-module(steps_lightning).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["I pay the invoice with payment request", PaymentRequest],
  _
) ->
  maps:put(
    lightning_payment_status,
    lnd:settle_invoice(list_to_binary(PaymentRequest)),
    Context
  ).
