-module(steps_bitcoin).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

%% @doc This function loads a bitcoin wallet from the provided `WalletPath0' and performs the necessary actions based on the success or failure of the load operation. It updates the `Context' map with the loaded bitcoin wallet information if successful, or creates a new wallet and adds it to the `bitcoin_wallets' map in the `Context' if the load operation fails due to the wallet already being loaded or an error occurs.
%%
%% - `WalletPath' : Path of the loaded bitcoin wallet as a term.
%%
%% Returns:
%% - If load operation is successful:
%%     - `Context' map with updated bitcoin wallet information.
%% - If wallet is already loaded:
%%     - `Context' map with no changes.
%% - If an error occurs during load operation:
%%     - Tuple `{ok, BtcWallet}' representing the newly created wallet.
%%     - `maps:put(bitcoin_wallets, maps:put(WalletPath, BtcWallet, BitcoinWallets), Context)' where `BitcoinWallets' is the existing bitcoin wallets map in the `Context'.
%% @return : Updated `Context' map or a tuple containing `ok' status and a new map.
%% @end
%%

-spec step(
    Config :: list(),
    Context :: map(),
    Keyword :: term(),
    N :: integer(),
    WalletPath0 :: list(),
    Data :: binary()
) ->
    map().
step(
    _Config,
    Context,
    <<"Given">>,
    _N,
    ["I have created a bitcoin wallet at path", WalletPath0],
    _
) ->
    BitcoinWallets = maps:get(bitcoin_wallets, Context, #{}),
    WalletPath = list_to_binary(WalletPath0),
    {ok, BtcWallet} = bitcoin:createwallet(WalletPath),
    maps:put(
        bitcoin_wallets,
        maps:put(WalletPath, BtcWallet, BitcoinWallets),
        Context
    );
step(
    _Config,
    Context,
    <<"Given">>,
    _N,
    ["I have loaded a bitcoin wallet from path", WalletPath0],
    _
) ->
    BitcoinWallets = maps:get(bitcoin_wallets, Context, #{}),
    WalletPath = list_to_binary(WalletPath0),
    case bitcoin:loadwallet(WalletPath) of
        {ok, #{name := WalletPath}} ->
            ?debugFmt("  BTC Wallet ~p", [WalletPath]),
            Context;
        {error, #{code := -35}} ->
            ?debugFmt("  BTC Wallet already loaded ~p", [WalletPath]),
            Context;
        {error, Error} ->
            ?debugFmt("  BTC Wallet Error ~p", [Error]),
            {ok, BtcWallet} = bitcoin:createwallet(WalletPath),
            maps:put(
                bitcoin_wallets,
                maps:put(WalletPath, BtcWallet, BitcoinWallets),
                Context
            )
    end;
step(
    _Config,
    Context,
    <<"Then">>,
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
    <<"Then">>,
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
    <<"Then">>,
    _N,
    ["the balance must be greater than", ExpectedBalance],
    _
) ->
    ?debugFmt("the balance must be greater than ~p", [ExpectedBalance]),
    Result = bicoin:getbalance(),
    ?debugFmt("Result ~p", [Result]),
    Context.
