-module(damage_liquidity_http).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([init/2]).
-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([to_json/2]).
-export([from_json/2]).
-export([is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Liquidity"]).
-define(DEFAULT_INVOICE_EXPIRY, 3600).

trails() ->
    [
        trails:trail(
            "/api/liquidity/address",
            damage_liquidity_http,
            #{action => address},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Get a public on-chain Bitcoin deposit address for node liquidity.",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"type">>,
                                    description =>
                                        <<"Address type: bech32, p2tr, or all. Defaults to bech32.">>,
                                    in => <<"query">>,
                                    required => false,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/api/liquidity/invoice",
            damage_liquidity_http,
            #{action => invoice},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Create a public Lightning invoice for adding node liquidity.",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"amount_sats">>,
                                    description => <<"Invoice amount in sats.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"integer">>
                                },
                                #{
                                    name => <<"amount_msat">>,
                                    description => <<"Invoice amount in millisatoshis.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"integer">>
                                },
                                #{
                                    name => <<"description">>,
                                    description => <<"Invoice description.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"expiry">>,
                                    description =>
                                        <<"Invoice expiry in seconds. Defaults to 3600.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"integer">>
                                },
                                #{
                                    name => <<"label">>,
                                    description =>
                                        <<"Optional custom label. If omitted one is generated.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        )
    ].

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

%% Public endpoints
is_authorized(Req, #{action := address} = State) ->
    {true, Req, State};
is_authorized(Req, #{action := invoice} = State) ->
    {true, Req, State};
is_authorized(Req, State) ->
    {true, Req, State}.

to_json(Req, #{action := address} = State) ->
    Type =
        case cowboy_req:match_qs([{type, [], <<"bech32">>}], Req) of
            #{type := T} -> normalize_addr_type(T)
        end,
    case cln:newaddr(Type) of
        {ok, AddrMap} ->
            Resp = normalize_newaddr_response(Type, AddrMap),
            {jsx:encode(Resp), Req, State};
        {error, Reason} ->
            Body = jsx:encode(#{status => <<"failed">>, message => to_bin(Reason)}),
            {stop, cowboy_req:reply(500, cowboy_req:set_resp_body(Body, Req)), State}
    end;
to_json(Req, State) ->
    Body = jsx:encode(#{status => <<"failed">>, message => <<"Unsupported action">>}),
    {stop, cowboy_req:reply(400, cowboy_req:set_resp_body(Body, Req)), State}.

from_json(Req, #{action := invoice} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        {'EXIT', _} ->
            reply_json(
                400, #{status => <<"failed">>, message => <<"Json decode error.">>}, Req0, State
            );
        badarg ->
            reply_json(
                400, #{status => <<"failed">>, message => <<"Json decode error.">>}, Req0, State
            );
        Json when is_map(Json) ->
            handle_create_invoice(Json, Req0, State)
    end;
from_json(Req, State) ->
    reply_json(400, #{status => <<"failed">>, message => <<"Unsupported action">>}, Req, State).

handle_create_invoice(Json, Req, State) ->
    case invoice_amount_msat(Json) of
        {error, Reason} ->
            reply_json(400, #{status => <<"failed">>, message => Reason}, Req, State);
        AmountMsat when is_integer(AmountMsat), AmountMsat > 0 ->
            Description =
                maps:get(description, Json, <<"Node inbound liquidity">>),
            Expiry =
                normalize_int(maps:get(expiry, Json, ?DEFAULT_INVOICE_EXPIRY)),
            Label =
                case maps:get(label, Json, undefined) of
                    undefined -> make_invoice_label();
                    L -> to_bin(L)
                end,
            case cln:create_invoice(AmountMsat, to_bin(Description), Expiry, Label) of
                #{bolt11 := Bolt11} = Invoice ->
                    Resp = #{
                        status => <<"ok">>,
                        purpose => <<"node_inbound_liquidity">>,
                        payment_request => Bolt11,
                        bolt11 => Bolt11,
                        label => maps:get(label, Invoice, Label),
                        amount_msat => maps:get(amount_msat, Invoice, AmountMsat),
                        amount_sats => cln:msat_to_sats(maps:get(amount_msat, Invoice, AmountMsat)),
                        expires_at => maps:get(expires_at, Invoice, undefined),
                        created_index => maps:get(created_index, Invoice, undefined),
                        payment_hash => maps:get(payment_hash, Invoice, undefined)
                    },
                    reply_json(200, Resp, Req, State);
                #{code := _, message := Message} ->
                    reply_json(
                        400,
                        #{status => <<"failed">>, message => to_bin(Message)},
                        Req,
                        State
                    );
                Other ->
                    reply_json(
                        500,
                        #{status => <<"failed">>, message => to_bin(Other)},
                        Req,
                        State
                    )
            end
    end.

invoice_amount_msat(#{amount_msat := Amount}) ->
    normalize_positive_int(Amount, <<"amount_msat must be a positive integer">>);
invoice_amount_msat(#{amount_sats := AmountSats}) ->
    case normalize_positive_int(AmountSats, <<"amount_sats must be a positive integer">>) of
        N when is_integer(N) -> cln:sats_to_msat(N);
        Error -> Error
    end;
invoice_amount_msat(_) ->
    {error, <<"amount_sats or amount_msat is required">>}.

normalize_newaddr_response(Type, AddrMap) ->
    %% CLN may return one or more address fields depending on request type.
    #{
        status => <<"ok">>,
        purpose => <<"node_onchain_liquidity">>,
        requested_type => Type,
        bech32 => maps:get(bech32, AddrMap, undefined),
        p2tr => maps:get(p2tr, AddrMap, undefined),
        all => AddrMap
    }.

normalize_addr_type(<<"bech32">>) -> <<"bech32">>;
normalize_addr_type(<<"p2tr">>) -> <<"p2tr">>;
normalize_addr_type(<<"all">>) -> <<"all">>;
normalize_addr_type("bech32") -> <<"bech32">>;
normalize_addr_type("p2tr") -> <<"p2tr">>;
normalize_addr_type("all") -> <<"all">>;
normalize_addr_type(_) -> <<"bech32">>.

normalize_positive_int(V, _Msg) when is_integer(V), V > 0 ->
    V;
normalize_positive_int(V, Msg) when is_binary(V) ->
    try binary_to_integer(V) of
        N when N > 0 -> N;
        _ -> {error, Msg}
    catch
        _:_ -> {error, Msg}
    end;
normalize_positive_int(V, Msg) when is_list(V) ->
    try list_to_integer(V) of
        N when N > 0 -> N;
        _ -> {error, Msg}
    catch
        _:_ -> {error, Msg}
    end;
normalize_positive_int(_, Msg) ->
    {error, Msg}.

normalize_int(V) when is_integer(V) ->
    V;
normalize_int(V) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> ?DEFAULT_INVOICE_EXPIRY
    end;
normalize_int(V) when is_list(V) ->
    try
        list_to_integer(V)
    catch
        _:_ -> ?DEFAULT_INVOICE_EXPIRY
    end;
normalize_int(_) ->
    ?DEFAULT_INVOICE_EXPIRY.

make_invoice_label() ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    <<"public-inbound-liquidity:", (list_to_binary(Timestamp))/binary>>.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

reply_json(Status, Map, Req, State) ->
    Body = jsx:encode(Map),
    Response = cowboy_req:reply(Status, cowboy_req:set_resp_body(Body, Req)),
    {stop, Response, State}.
