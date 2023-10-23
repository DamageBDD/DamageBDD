-module(steps_bitcoin).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

step(
  _Config,
  Context,
  given_keyword,
  _N,
  ["I have a bitcoin wallet", WalletLabel],
  _
) ->
  BitcoinWallets = maps:get(bitcoin_wallets, Context, #{}),
  case bitcoin:listwallets(WalletLabel) of
    {ok, [BtcWallet]} ->
      ?debugFmt("  BTC Wallet ~p", [BtcWallet]),
      Context;

    {error, Error} ->
      ?debugFmt("  BTC Wallet Error ~p", [Error]),
      {ok, BtcWallet} = bitcoin:createwallet(WalletLabel),
      maps:put(
        bitcoin_wallets,
        maps:put(WalletLabel, BtcWallet, BitcoinWallets),
        Context
      )
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["I create a new receive address", ReceiveAddress, "with label", Label],
  _
) ->
  ?debugFmt(
    "I create a new receive address \"~p\" with label ~p",
    [ReceiveAddress, Label]
  ),
  maps:put(Label, bitcoin:getnewaddress(Label), Context);

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["I transfer", Amount, "BTC from", FromWallet, "to", ToWallet],
  _
) ->
  ?debugFmt("I transfer ~p BTC from ~p to ~p", [Amount, FromWallet, ToWallet]),
  Result = bitcoin:sendtoaddress(FromWallet, Amount, ToWallet),
  ?debugFmt(
    "I transfered ~p BTC from ~p to ~p result ~p",
    [Amount, FromWallet, ToWallet, Result]
  ),
  Context;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the balance must be greater than", ExpectedBalance],
  _
) ->
  ?debugFmt("the balance must be greater than ~p", [ExpectedBalance]),
  Result = bicoin:getbalance(),
  ?debugFmt("Result ~p", [Result]),
  Context.
