-module(bitcoin).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-define(BITCOIN_RPC_TIMEOUT, 60000).

-export(
    [
        validateaddress/1,
        getreceivedbyaddress/1,
        listtransactions/1,
        sendtoaddress/3,
        getnewaddress/1,
        getbalance/0,
        createwallet/1,
        listwallets/0,
        loadwallet/1,
        unloadwallet/1
    ]
).

bitcoin_req(Method, Params) ->
    {ok, BtcWallet} = application:get_env(damage, bitcoin_wallet),
    WalletPath = "/wallet/" ++ BtcWallet,
    bitcoin_req(Method, Params, WalletPath).

bitcoin_req(Method, Params, Path) ->
    {ok, BtcRpcHost} = application:get_env(damage, bitcoin_rpc_host),
    {ok, BtcRpcPort} = application:get_env(damage, bitcoin_rpc_port),
    {ok, BtcRpcUser} = application:get_env(damage, bitcoin_rpc_user),
    {ok, ConnPid} = gun:open(BtcRpcHost, BtcRpcPort, #{}),
    Data =
        #{
            jsonrpc => <<"1.0">>,
            id => <<"damagebdd">>,
            method => Method,
            params => Params
        },
    Password = damage_utils:pass_get(bitcoin_rpc_pass_path),
    case os:getenv("BTC_PASSWORD") of
        false -> exit(btc_password_env_not_set);
        Other -> Other
    end,
    ?debugFmt("POST data: ~p", [Data]),
    StreamRef =
        gun:post(
            ConnPid,
            Path,
            [
                {<<"content-type">>, <<"text/plain">>},
                {
                    <<"Authorization">>,
                    [
                        <<"Basic ">>,
                        base64:encode(iolist_to_binary([BtcRpcUser, $:, Password]))
                    ]
                }
            ],
            jsx:encode(Data),
            #{}
        ),
    case gun:await(ConnPid, StreamRef) of
        {response, fin, Status, Headers0} ->
            ?LOG_ERROR("POST Response: ~p ~p", [Status, Headers0]);
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

validateaddress(BtcAddress) -> bitcoin_req(<<"validateaddress">>, [BtcAddress]).

getreceivedbyaddress(BtcAddress) ->
    bitcoin_req(<<"getreceivedbyaddress">>, [BtcAddress]).

listtransactions(Account) -> bitcoin_req(<<"listtransactions">>, [Account]).

%bitcoin_addressinfo(BtcAddress) ->
%  bitcoin_req(<<"getaddressinfo">>, [BtcAddress]).
sendtoaddress(Address, Amount, Label) ->
    bitcoin_req(<<"sendtoaddress">>, [Address, Amount, Label]).

getnewaddress(Label) -> bitcoin_req(<<"getnewaddress">>, [Label, <<"bech32">>]).

createwallet(WalletName) ->
    %" ( disable_private_keys blank "passphrase" avoid_reuse descriptors load_on_startup )
    bitcoin_req(<<"createwallet">>, [WalletName]).

listwallets() ->
    %" ( disable_private_keys blank "passphrase" avoid_reuse descriptors load_on_startup )
    bitcoin_req(<<"listwallets">>, []).

getbalance() -> bitcoin_req(<<"getbalance">>, []).

loadwallet(BtcWalletFilename) ->
    ?debugFmt("loadwallet ~p", [BtcWalletFilename]),
    bitcoin_req(<<"loadwallet">>, [BtcWalletFilename]).

unloadwallet(BtcWalletFilename) ->
    bitcoin_req(<<"unloadwallet">>, [BtcWalletFilename]).
