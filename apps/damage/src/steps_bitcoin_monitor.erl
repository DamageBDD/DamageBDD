%% steps_bitcoin_monitor.erl

-module(steps_bitcoin_monitor).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

-spec step(list(), map(), term(), integer(), list(), binary()) -> map().

step(_Config, Context, <<"Given">>, _N, ["I notify", EventType, "to", "discord", "webhook"], _) ->
    ?debugFmt("Setting up Discord webhook for ~p", [EventType]),
    maps:put(discord_webhook_event, EventType, Context);

step(_Config, Context, <<"Given">>, _N, ["I have a bitcoin wallet", WalletName], _) ->
    BitcoinWallets = maps:get(bitcoin_wallets, Context, #{}),
    Context2 =
        case maps:is_key(WalletName, BitcoinWallets) of
            true -> Context;
            false ->
                {ok, BtcWallet} = bitcoin:createwallet(WalletName),
                maps:put(bitcoin_wallets, maps:put(WalletName, BtcWallet, BitcoinWallets), Context)
        end,
    Context2;

step(_Config, Context, <<"Given">>, _N, ["I have a bitcoin wallets"], WalletsBinary) ->
    WalletsList = binary:split(WalletsBinary, <<"\n">>, [global]),
    WalletsCleaned = lists:filter(fun(W) -> W =/= <<>> end, WalletsList),
    BitcoinWallets = maps:get(bitcoin_wallets, Context, #{}),
    NewWallets = lists:foldl(
        fun(WalletName, AccWallets) ->
            {ok, BtcWallet} = bitcoin:createwallet(WalletName),
            maps:put(WalletName, BtcWallet, AccWallets)
        end,
        BitcoinWallets,
        WalletsCleaned
    ),
    maps:put(bitcoin_wallets, NewWallets, Context);

step(_Config, Context, <<"Then">>, _N, ["I monitor for", EventType, "on", WalletName], _) ->
    %% You could implement here a real-time monitoring, polling, or simple event simulation
    spawn(fun() -> monitor_wallet(EventType, WalletName, Context) end),
    Context.

%% Internal function for monitoring (simple simulation for now)
monitor_wallet(EventType, WalletName, _Context) ->
    timer:sleep(5000), % Simulate checking every 5 seconds
    io:format("Monitoring ~p for ~p events...~n", [WalletName, EventType]),
    %% Here you could query balance, listtransactions, etc.
    ok.

