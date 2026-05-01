-module(bitcoin_http).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([from_json/2, to_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Bitcoin"]).
-define(DEFAULT_TX_COUNT, 10).
-define(MAX_LABEL_BYTES, 180).
-define(DEFAULT_MIN_CONF, 1).
-define(DEFAULT_FEE_TARGET_BLOCKS, 6).

trails() ->
    [
        trails:trail(
            "/api/bitcoin/address",
            bitcoin_http,
            #{action => new_address},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description =>
                        "Create a new Bitcoin wallet receive address scoped to the authenticated DamageBDD account.",
                    produces => ["application/json"],
                    parameters => [
                        #{
                            name => <<"label">>,
                            description => <<"Human-readable wallet label suffix.">>,
                            in => <<"body">>,
                            required => false,
                            type => <<"string">>
                        },
                        #{
                            name => <<"address_type">>,
                            description => <<"legacy | p2sh-segwit | bech32 | bech32m">>,
                            in => <<"body">>,
                            required => false,
                            type => <<"string">>
                        }
                    ]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/validate",
            bitcoin_http,
            #{action => validate_address},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Validate a Bitcoin address with Bitcoin Core.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/received",
            bitcoin_http,
            #{action => received_by_address},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description =>
                        "Return BTC received by an address after min_conf confirmations.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/transactions",
            bitcoin_http,
            #{action => list_transactions},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description =>
                        "List wallet transactions for an authenticated user-scoped label.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/fee",
            bitcoin_http,
            #{action => estimate_fee},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Estimate Bitcoin fee rate for a target number of blocks.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/send",
            bitcoin_http,
            #{action => send_to_address},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description =>
                        "Send BTC from the server wallet. Disabled unless bitcoin_http_enable_send=true.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/balance",
            bitcoin_http,
            #{action => balance},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Return authenticated Bitcoin wallet balance.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/wallet",
            bitcoin_http,
            #{action => wallet_info},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Return authenticated Bitcoin wallet information.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/bitcoin/status",
            bitcoin_http,
            #{action => status},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Return sanitized Bitcoin node sync status.",
                    produces => ["application/json"]
                }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

to_json(Req0, #{action := Action} = State) ->
    {Status, Resp} = do_get_action(Action, State),
    Req = reply_json(Status, Resp, Req0),
    {stop, Req, State}.

from_json(Req0, #{action := Action} = State) ->
    {ok, Raw, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Raw) of
        {ok, Json} ->
            {Status, Resp} = do_post_action(Action, Json, State),
            Req = reply_json(Status, Resp, Req1),
            {stop, Req, State};
        {error, Reason} ->
            Req = reply_json(
                400,
                #{status => <<"failed">>, error => <<"BAD_JSON">>, reason => Reason},
                Req1
            ),
            {stop, Req, State}
    end.

do_get_action(balance, _State) ->
    rpc_response(bitcoin:getbalance(), fun(Balance) ->
        #{status => <<"ok">>, balance_btc => Balance}
    end);
do_get_action(wallet_info, _State) ->
    rpc_response(bitcoin:getwalletinfo(), fun(WalletInfo) ->
        #{status => <<"ok">>, wallet => WalletInfo}
    end);
do_get_action(status, _State) ->
    case {bitcoin:getblockchaininfo(), bitcoin:getmempoolinfo()} of
        {{ok, BlockchainInfo}, {ok, MempoolInfo}} ->
            {200, #{
                status => <<"ok">>,
                blockchain => sanitize_blockchaininfo(BlockchainInfo),
                mempool => sanitize_mempoolinfo(MempoolInfo)
            }};
        {{error, Reason}, _} ->
            rpc_error(Reason);
        {_, {error, Reason}} ->
            rpc_error(Reason)
    end;
do_get_action(_Action, _State) ->
    {404, #{status => <<"failed">>, error => <<"UNKNOWN_ENDPOINT">>}}.

do_post_action(new_address, Json, State) ->
    Label0 = json_get(<<"label">>, Json, default_label(State)),
    AddressType = json_get(<<"address_type">>, Json, <<"bech32">>),
    case safe_label(Label0) of
        {ok, Label} ->
            WalletLabel = scoped_label(State, Label),
            rpc_response(
                bitcoin:getnewaddress(WalletLabel, AddressType),
                fun(Address) ->
                    #{
                        status => <<"ok">>,
                        address => Address,
                        label => Label,
                        wallet_label => WalletLabel,
                        address_type => bitcoin_address_type(AddressType)
                    }
                end,
                201
            );
        {error, Reason} ->
            {400, #{status => <<"failed">>, error => <<"BAD_LABEL">>, reason => Reason}}
    end;
do_post_action(validate_address, Json, _State) ->
    case required_bin(<<"address">>, Json) of
        {ok, Address} ->
            rpc_response(bitcoin:validateaddress(Address), fun(Validation) ->
                #{status => <<"ok">>, validation => Validation}
            end);
        {error, Reason} ->
            {400, #{status => <<"failed">>, error => <<"BAD_ADDRESS">>, reason => Reason}}
    end;
do_post_action(received_by_address, Json, _State) ->
    MinConf = json_int(<<"min_conf">>, Json, ?DEFAULT_MIN_CONF),
    case required_bin(<<"address">>, Json) of
        {ok, Address} when MinConf >= 0 ->
            rpc_response(bitcoin:getreceivedbyaddress(Address, MinConf), fun(Amount) ->
                #{status => <<"ok">>, address => Address, min_conf => MinConf, amount_btc => Amount}
            end);
        {ok, _Address} ->
            {400, #{status => <<"failed">>, error => <<"BAD_MIN_CONF">>}};
        {error, Reason} ->
            {400, #{status => <<"failed">>, error => <<"BAD_ADDRESS">>, reason => Reason}}
    end;
do_post_action(list_transactions, Json, State) ->
    Count0 = json_int(<<"count">>, Json, ?DEFAULT_TX_COUNT),
    Count = clamp(Count0, 1, 100),
    Skip = max(0, json_int(<<"skip">>, Json, 0)),
    Label =
        case json_get(<<"label">>, Json, undefined) of
            undefined -> <<"*">>;
            Label0 -> scoped_label(State, Label0)
        end,
    rpc_response(bitcoin:listtransactions(Label, Count, Skip), fun(Transactions) ->
        #{
            status => <<"ok">>,
            label => Label,
            count => Count,
            skip => Skip,
            transactions => Transactions
        }
    end);
do_post_action(estimate_fee, Json, _State) ->
    Target = clamp(json_int(<<"conf_target">>, Json, ?DEFAULT_FEE_TARGET_BLOCKS), 1, 1008),
    rpc_response(bitcoin:estimatesmartfee(Target), fun(FeeInfo) ->
        #{status => <<"ok">>, conf_target => Target, fee => FeeInfo}
    end);
do_post_action(send_to_address, Json, State) ->
    case application:get_env(damage, bitcoin_http_enable_send, false) of
        true ->
            do_send_to_address(Json, State);
        _ ->
            {403, #{
                status => <<"failed">>,
                error => <<"SEND_DISABLED">>,
                message =>
                    <<"Outbound Bitcoin sends are disabled. Set bitcoin_http_enable_send=true only for a locked-down admin deployment.">>
            }}
    end;
do_post_action(_Action, _Json, _State) ->
    {404, #{status => <<"failed">>, error => <<"UNKNOWN_ENDPOINT">>}}.

do_send_to_address(Json, State) ->
    MaxBtc = application:get_env(damage, bitcoin_http_send_max_btc, 0.01),
    Label = scoped_label(State, json_get(<<"label">>, Json, <<"withdrawal">>)),
    case {required_bin(<<"address">>, Json), json_amount(<<"amount_btc">>, Json)} of
        {{ok, Address}, {ok, Amount}} when Amount > 0, Amount =< MaxBtc ->
            case bitcoin:validateaddress(Address) of
                {ok, #{isvalid := true}} ->
                    rpc_response(
                        bitcoin:sendtoaddress(Address, Amount, Label),
                        fun(TxId) ->
                            #{
                                status => <<"ok">>,
                                txid => TxId,
                                address => Address,
                                amount_btc => Amount,
                                label => Label
                            }
                        end,
                        201
                    );
                {ok, Validation} ->
                    {400, #{
                        status => <<"failed">>,
                        error => <<"INVALID_ADDRESS">>,
                        validation => Validation
                    }};
                {error, Reason} ->
                    rpc_error(Reason)
            end;
        {{ok, _Address}, {ok, Amount}} when Amount > MaxBtc ->
            {400, #{status => <<"failed">>, error => <<"AMOUNT_TOO_LARGE">>, max_btc => MaxBtc}};
        {{error, Reason}, _} ->
            {400, #{status => <<"failed">>, error => <<"BAD_ADDRESS">>, reason => Reason}};
        {_, {error, Reason}} ->
            {400, #{status => <<"failed">>, error => <<"BAD_AMOUNT">>, reason => Reason}}
    end.

rpc_response(Result, Fun) ->
    rpc_response(Result, Fun, 200).

rpc_response({ok, Value}, Fun, Status) ->
    {Status, Fun(Value)};
rpc_response({error, Reason}, _Fun, _Status) ->
    rpc_error(Reason).

rpc_error(#{code := Code, message := Message} = Error) ->
    HttpStatus = rpc_code_to_http(Code),
    {HttpStatus, #{status => <<"failed">>, error => Error, message => Message}};
rpc_error(Reason) ->
    {502, #{status => <<"failed">>, error => Reason}}.

rpc_code_to_http(-5) -> 404;
rpc_code_to_http(-18) -> 404;
rpc_code_to_http(-4) -> 409;
rpc_code_to_http(-6) -> 409;
rpc_code_to_http(_) -> 502.

reply_json(Status, Body, Req) ->
    cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body),
        Req
    ).

decode_json(<<>>) ->
    {ok, #{}};
decode_json(Raw) ->
    case catch jsx:decode(Raw, [return_maps]) of
        Json when is_map(Json) -> {ok, Json};
        {'EXIT', _} -> {error, <<"JSON decoding failed">>};
        _Other -> {error, <<"JSON body must be an object">>}
    end.

json_get(Key, Map, Default) when is_binary(Key) ->
    maps:get(Key, Map, maps:get(binary_to_atom_safe(Key), Map, Default)).

json_int(Key, Map, Default) ->
    to_int(json_get(Key, Map, Default), Default).

json_amount(Key, Map) ->
    case json_get(Key, Map, undefined) of
        undefined ->
            {error, <<"amount_btc is required">>};
        Amount when is_integer(Amount), Amount > 0 -> {ok, Amount};
        Amount when is_float(Amount), Amount > 0 -> {ok, Amount};
        Amount when is_binary(Amount) ->
            case catch binary_to_float(Amount) of
                F when is_float(F), F > 0 -> {ok, F};
                _ ->
                    case catch binary_to_integer(Amount) of
                        I when is_integer(I), I > 0 -> {ok, I};
                        _ -> {error, <<"amount_btc must be a positive number">>}
                    end
            end;
        _ ->
            {error, <<"amount_btc must be a positive number">>}
    end.

required_bin(Key, Map) ->
    case json_get(Key, Map, undefined) of
        undefined ->
            {error, <<Key/binary, " is required">>};
        Value ->
            Bin = to_bin(Value),
            case Bin of
                <<>> -> {error, <<Key/binary, " must not be empty">>};
                _ -> {ok, Bin}
            end
    end.

safe_label(Label0) ->
    Label = to_bin(Label0),
    case {byte_size(Label), safe_text(Label)} of
        {0, _} -> {error, <<"label must not be empty">>};
        {N, _} when N > ?MAX_LABEL_BYTES -> {error, <<"label is too long">>};
        {_, false} -> {error, <<"label contains control characters">>};
        _ -> {ok, Label}
    end.

safe_text(Bin) ->
    lists:all(fun(C) -> C >= 32 andalso C =/= 127 end, binary_to_list(Bin)).

scoped_label(State, Label0) ->
    Label = to_bin(Label0),
    Owner = to_bin(maps:get(public_key, State, <<"unknown">>)),
    <<"damagebdd:", Owner/binary, ":", Label/binary>>.

default_label(State) ->
    Owner = to_bin(maps:get(public_key, State, <<"unknown">>)),
    Timestamp = integer_to_binary(erlang:system_time(second)),
    <<"receive:", Owner/binary, ":", Timestamp/binary>>.

bitcoin_address_type(Type0) ->
    Type = to_bin(Type0),
    case Type of
        <<"legacy">> -> Type;
        <<"p2sh-segwit">> -> Type;
        <<"bech32">> -> Type;
        <<"bech32m">> -> Type;
        _ -> <<"bech32">>
    end.

sanitize_blockchaininfo(Info) ->
    pick_keys(
        Info,
        [
            chain,
            blocks,
            headers,
            verificationprogress,
            initialblockdownload,
            pruned,
            size_on_disk,
            warnings
        ]
    ).

sanitize_mempoolinfo(Info) ->
    pick_keys(Info, [loaded, size, bytes, usage, total_fee, mempoolminfee, minrelaytxfee]).

pick_keys(Map, Keys) ->
    lists:foldl(
        fun(Key, Acc) ->
            case maps:find(Key, Map) of
                {ok, Value} -> maps:put(Key, Value, Acc);
                error -> Acc
            end
        end,
        #{},
        Keys
    ).

to_int(Value, _Default) when is_integer(Value) -> Value;
to_int(Value, Default) when is_binary(Value) ->
    case catch binary_to_integer(Value) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
to_int(Value, Default) when is_list(Value) ->
    to_int(to_bin(Value), Default);
to_int(_, Default) ->
    Default.

clamp(N, Min, _Max) when N < Min -> Min;
clamp(N, _Min, Max) when N > Max -> Max;
clamp(N, _Min, _Max) -> N.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_float(V) -> float_to_binary(V, [{decimals, 8}, compact]);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V).

binary_to_atom_safe(<<"label">>) -> label;
binary_to_atom_safe(<<"address">>) -> address;
binary_to_atom_safe(<<"address_type">>) -> address_type;
binary_to_atom_safe(<<"min_conf">>) -> min_conf;
binary_to_atom_safe(<<"count">>) -> count;
binary_to_atom_safe(<<"skip">>) -> skip;
binary_to_atom_safe(<<"conf_target">>) -> conf_target;
binary_to_atom_safe(<<"amount_btc">>) -> amount_btc;
binary_to_atom_safe(_) -> '$undefined_json_key'.
