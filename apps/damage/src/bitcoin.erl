-module(bitcoin).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-define(BITCOIN_RPC_TIMEOUT, 60000).
-define(DEFAULT_ADDRESS_TYPE, <<"bech32">>).

%% Low-level RPC API
-export([
    rpc/2,
    rpc/3,
    node_rpc/2
]).

%% Wallet / node convenience API
-export([
    validateaddress/1,
    getaddressinfo/1,
    getreceivedbyaddress/1,
    getreceivedbyaddress/2,
    listtransactions/1,
    listtransactions/3,
    sendtoaddress/3,
    getnewaddress/1,
    getnewaddress/2,
    getbalance/0,
    getwalletinfo/0,
    listunspent/0,
    listunspent/3,
    createwallet/1,
    listwallets/0,
    loadwallet/1,
    unloadwallet/1,
    getblockchaininfo/0,
    getnetworkinfo/0,
    getmempoolinfo/0,
    estimatesmartfee/1
]).

%% Backwards-compatible internal name for existing callers.
bitcoin_req(Method, Params) ->
    rpc(Method, Params).

bitcoin_req(Method, Params, Path) ->
    rpc(Method, Params, Path).

%% -------------------------------------------------------------------
%% Public RPC helpers
%% -------------------------------------------------------------------

-spec rpc(binary() | atom() | list(), list()) -> {ok, term()} | {error, term()}.
rpc(Method, Params) ->
    rpc(Method, Params, default_wallet_path()).

-spec node_rpc(binary() | atom() | list(), list()) -> {ok, term()} | {error, term()}.
node_rpc(Method, Params) ->
    rpc(Method, Params, <<"/">>).

-spec rpc(binary() | atom() | list(), list(), binary() | list()) ->
    {ok, term()} | {error, term()}.
rpc(Method0, Params, Path0) when is_list(Params) ->
    Method = to_binary(Method0),
    Path = to_binary(Path0),
    case rpc_config() of
        {ok, #{host := Host, port := Port, user := User, password := Password, opts := Opts}} ->
            Payload = #{
                jsonrpc => <<"1.0">>,
                id => <<"damagebdd">>,
                method => Method,
                params => Params
            },
            do_rpc(Host, Port, Opts, User, Password, Path, Payload);
        {error, Reason} ->
            {error, Reason}
    end.

%% -------------------------------------------------------------------
%% Bitcoin Core RPC wrappers
%% -------------------------------------------------------------------

validateaddress(BtcAddress) ->
    node_rpc(<<"validateaddress">>, [to_binary(BtcAddress)]).

getaddressinfo(BtcAddress) ->
    rpc(<<"getaddressinfo">>, [to_binary(BtcAddress)]).

getreceivedbyaddress(BtcAddress) ->
    getreceivedbyaddress(BtcAddress, 1).

getreceivedbyaddress(BtcAddress, MinConf) when is_integer(MinConf), MinConf >= 0 ->
    rpc(<<"getreceivedbyaddress">>, [to_binary(BtcAddress), MinConf]).

listtransactions(Label) ->
    listtransactions(Label, 10, 0).

listtransactions(Label, Count, Skip) when
    is_integer(Count), Count > 0, is_integer(Skip), Skip >= 0
->
    rpc(<<"listtransactions">>, [to_binary(Label), Count, Skip, true]).

sendtoaddress(Address, Amount, Label) when is_number(Amount) ->
    %% Public HTTP callers should normally not expose this. Keep this as the
    %% private Erlang API for carefully controlled outbound spends.
    rpc(<<"sendtoaddress">>, [to_binary(Address), Amount, to_binary(Label)]).

getnewaddress(Label) ->
    getnewaddress(Label, ?DEFAULT_ADDRESS_TYPE).

getnewaddress(Label, AddressType0) ->
    AddressType = normalize_address_type(AddressType0),
    rpc(<<"getnewaddress">>, [to_binary(Label), AddressType]).

getbalance() ->
    rpc(<<"getbalance">>, []).

getwalletinfo() ->
    rpc(<<"getwalletinfo">>, []).

listunspent() ->
    listunspent(1, 9999999, []).

listunspent(MinConf, MaxConf, Addresses) when
    is_integer(MinConf),
    MinConf >= 0,
    is_integer(MaxConf),
    MaxConf >= MinConf,
    is_list(Addresses)
->
    rpc(<<"listunspent">>, [MinConf, MaxConf, [to_binary(A) || A <- Addresses]]).

createwallet(WalletName) ->
    %% Node-level method, not wallet-scoped.
    node_rpc(<<"createwallet">>, [to_binary(WalletName)]).

listwallets() ->
    node_rpc(<<"listwallets">>, []).

loadwallet(BtcWalletFilename) ->
    node_rpc(<<"loadwallet">>, [to_binary(BtcWalletFilename)]).

unloadwallet(BtcWalletFilename) ->
    node_rpc(<<"unloadwallet">>, [to_binary(BtcWalletFilename)]).

getblockchaininfo() ->
    node_rpc(<<"getblockchaininfo">>, []).

getnetworkinfo() ->
    node_rpc(<<"getnetworkinfo">>, []).

getmempoolinfo() ->
    node_rpc(<<"getmempoolinfo">>, []).

estimatesmartfee(ConfTarget) when is_integer(ConfTarget), ConfTarget > 0 ->
    node_rpc(<<"estimatesmartfee">>, [ConfTarget]).

%% -------------------------------------------------------------------
%% Internal RPC implementation
%% -------------------------------------------------------------------

rpc_config() ->
    Host = application:get_env(damage, bitcoin_rpc_host, "localhost"),
    Timeout = application:get_env(damage, bitcoin_rpc_timeout, ?BITCOIN_RPC_TIMEOUT),
    case
        {
            application:get_env(damage, bitcoin_rpc_port),
            application:get_env(damage, bitcoin_rpc_user),
            secrets:retrieve_decrypt(bitcoin_rpc_password)
        }
    of
        {{ok, Port}, {ok, User}, {ok, Password}} ->
            {ok, #{
                host => normalize_host(Host),
                port => Port,
                user => to_binary(User),
                password => to_binary(Password),
                opts => rpc_open_opts(Timeout)
            }};
        {{ok, _Port}, {ok, _User}, _MissingPassword} ->
            ?LOG_INFO("Bitcoin integration disabled: set `bitcoin_rpc_password` secret.", []),
            {error, bitcoin_rpc_password_not_configured};
        {error, _, _} ->
            {error, bitcoin_rpc_port_not_configured};
        {_, error, _} ->
            {error, bitcoin_rpc_user_not_configured};
        Other ->
            ?LOG_WARNING("Invalid Bitcoin RPC configuration: ~p", [redact_config_error(Other)]),
            {error, invalid_bitcoin_rpc_config}
    end.

rpc_open_opts(Timeout) ->
    Base = #{connect_timeout => Timeout},
    case application:get_env(damage, bitcoin_rpc_transport, tcp) of
        {ok, tls} ->
            Base#{transport => tls, tls_opts => [{verify, verify_peer}]};
        {ok, ssl} ->
            Base#{transport => tls, tls_opts => [{verify, verify_peer}]};
        _ ->
            Base#{transport => tcp}
    end.

do_rpc(Host, Port, Opts, User, Password, Path, Payload) ->
    Timeout = maps:get(connect_timeout, Opts, ?BITCOIN_RPC_TIMEOUT),
    case gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, Timeout) of
                    {ok, _Protocol} ->
                        post_rpc(ConnPid, User, Password, Path, Payload, Timeout);
                    {error, Reason} ->
                        {error, #{type => connection_failed, reason => Reason}}
                end
            after
                gun:close(ConnPid)
            end;
        {error, Reason} ->
            {error, #{type => open_failed, reason => Reason}}
    end.

post_rpc(ConnPid, User, Password, Path, Payload, Timeout) ->
    Body = jsx:encode(Payload),
    Auth = basic_auth(User, Password),
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"authorization">>, Auth}
    ],
    ?LOG_DEBUG("Bitcoin RPC ~s path=~s", [maps:get(method, Payload), Path]),
    StreamRef = gun:post(ConnPid, Path, Headers, Body, #{}),
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, fin, Status, Headers0} ->
            decode_rpc_response(Status, Headers0, <<>>);
        {response, nofin, Status, Headers0} ->
            case gun:await_body(ConnPid, StreamRef, Timeout) of
                {ok, ResponseBody} ->
                    decode_rpc_response(Status, Headers0, ResponseBody);
                {error, Reason} ->
                    {error, #{type => body_read_failed, reason => Reason}}
            end;
        {error, Reason} ->
            {error, #{type => request_failed, reason => Reason}};
        Other ->
            {error, #{type => unexpected_gun_response, response => Other}}
    end.

decode_rpc_response(Status, _Headers, Body) when Status >= 200, Status < 300 ->
    case catch jsx:decode(Body, [{labels, atom}, return_maps]) of
        #{result := Result, error := null} ->
            {ok, Result};
        #{result := null, error := Error} when Error =/= null ->
            {error, Error};
        #{error := Error} when Error =/= null ->
            {error, Error};
        #{result := Result} ->
            {ok, Result};
        {'EXIT', _} ->
            {error, #{type => invalid_json, body => Body}};
        Other ->
            {error, #{type => unexpected_rpc_json, body => Other}}
    end;
decode_rpc_response(Status, _Headers, Body) ->
    ErrorBody =
        case catch jsx:decode(Body, [{labels, atom}, return_maps]) of
            {'EXIT', _} -> Body;
            Decoded -> Decoded
        end,
    {error, #{type => http_error, status => Status, body => ErrorBody}}.

basic_auth(User, Password) ->
    Encoded = base64:encode(iolist_to_binary([User, $:, Password])),
    <<"Basic ", Encoded/binary>>.

normalize_address_type(Type0) ->
    Type = to_binary(Type0),
    case Type of
        <<"legacy">> -> Type;
        <<"p2sh-segwit">> -> Type;
        <<"bech32">> -> Type;
        <<"bech32m">> -> Type;
        _ -> ?DEFAULT_ADDRESS_TYPE
    end.

default_wallet_path() ->
    case application:get_env(damage, bitcoin_wallet) of
        {ok, Wallet} when Wallet =:= undefined; Wallet =:= <<>>; Wallet =:= "" ->
            <<"/">>;
        {ok, Wallet} ->
            <<"/wallet/", (quote_path_segment(Wallet))/binary>>;
        _ ->
            <<"/">>
    end.

quote_path_segment(Value) ->
    Bin = to_binary(Value),
    iolist_to_binary([quote_byte(C) || <<C:8>> <= Bin]).

quote_byte(C) when C >= $a, C =< $z -> <<C>>;
quote_byte(C) when C >= $A, C =< $Z -> <<C>>;
quote_byte(C) when C >= $0, C =< $9 -> <<C>>;
quote_byte($-) -> <<"-">>;
quote_byte($_) -> <<"_">>;
quote_byte($.) -> <<".">>;
quote_byte($~) -> <<"~">>;
quote_byte(C) -> io_lib:format("%~2.16.0B", [C]).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_float(V) -> float_to_binary(V, [{decimals, 8}, compact]);
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V).

normalize_host(Host) when is_binary(Host) -> binary_to_list(Host);
normalize_host(Host) -> Host.

redact_config_error({Port, User, Password}) ->
    {Port, User, redact_password_result(Password)};
redact_config_error(Other) ->
    Other.

redact_password_result({ok, _}) -> {ok, <<"***">>};
redact_password_result(Other) -> Other.
