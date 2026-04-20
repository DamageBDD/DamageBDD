-module(damage_nwc_request_handler).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([handle_nip47_request/1]).

handle_nip47_request(#{<<"method">> := <<"get_info">>}) ->
    {ok, #{
        alias => <<"DamageBDD">>,
        color => <<"#f7931a">>,
        pubkey => damage_nostr:public_key_hex(),
        network => <<"bitcoin">>,
        block_height => 0,
        methods => [
            <<"get_info">>,
            <<"get_balance">>,
            <<"pay_invoice">>,
            <<"make_invoice">>,
            <<"lookup_invoice">>,
            <<"list_transactions">>
        ]
    }};
handle_nip47_request(#{<<"method">> := <<"get_balance">>} = Req) ->
    case request_pubkey(Req) of
        undefined ->
            {error, nwc_error(<<"UNAUTHORIZED">>, <<"No account mapping for request pubkey">>)};
        AeAccount ->
            case catch damage_ae:balance(AeAccount) of
                Balance when is_integer(Balance) ->
                    {ok, #{balance => Balance}};
                Error ->
                    {error, nwc_error(<<"INTERNAL">>, to_bin(Error))}
            end
    end;
handle_nip47_request(
    #{
        <<"method">> := <<"pay_invoice">>,
        <<"params">> := #{<<"invoice">> := Invoice}
    } = Req
) ->
    handle_pay_invoice(Req, Invoice);
handle_nip47_request(
    #{
        <<"method">> := <<"pay_invoice">>,
        <<"params">> := #{invoice := Invoice}
    } = Req
) ->
    handle_pay_invoice(Req, Invoice);
handle_nip47_request(
    #{
        <<"method">> := <<"make_invoice">>,
        <<"params">> := Params
    }
) ->
    handle_make_invoice(Params);
handle_nip47_request(
    #{
        <<"method">> := <<"lookup_invoice">>,
        <<"params">> := Params
    }
) ->
    handle_lookup_invoice(Params);
handle_nip47_request(
    #{
        <<"method">> := <<"list_transactions">>,
        <<"params">> := Params
    }
) ->
    handle_list_transactions(Params);
handle_nip47_request(Req) ->
    ?LOG_WARNING("Unhandled NIP-47 request ~p", [Req]),
    {error, nwc_error(<<"NOT_IMPLEMENTED">>, <<"NIP-47 method is not implemented yet">>)}.

handle_pay_invoice(Req, Invoice0) ->
    Invoice = to_bin(Invoice0),
    case request_pubkey(Req) of
        undefined ->
            {error, nwc_error(<<"UNAUTHORIZED">>, <<"No account mapping for request pubkey">>)};
        _AeAccount ->
            ?LOG_INFO("NWC pay_invoice request invoice=~p", [Invoice]),
            case catch cln:pay_invoice(Invoice) of
                {'EXIT', Reason} ->
                    ?LOG_WARNING("NWC pay_invoice crashed ~p", [Reason]),
                    {error, nwc_error(<<"PAYMENT_FAILED">>, to_bin(Reason))};
                PayRes ->
                    ?LOG_INFO("NWC pay_invoice success ~p", [PayRes]),
                    normalize_pay_invoice_result(PayRes)
            end
    end.

normalize_pay_invoice_result(#{status := complete} = Res) ->
    {ok, #{
        preimage => pick_first([
            maps:get(payment_preimage, Res, undefined),
            maps:get(preimage, Res, undefined)
        ]),
        fees_paid => msat_to_int(maps:get(amount_sent_msat, Res, 0)) -
            msat_to_int(maps:get(amount_msat, Res, 0)),
        type => <<"outgoing">>,
        invoice => maps:get(bolt11, Res, <<>>)
    }};
normalize_pay_invoice_result(#{status := <<"complete">>} = Res) ->
    normalize_pay_invoice_result(maps:put(status, complete, Res));
normalize_pay_invoice_result(#{payment_preimage := Preimage} = Res) ->
    {ok, #{
        preimage => to_bin(Preimage),
        fees_paid => msat_to_int(maps:get(amount_sent_msat, Res, 0)) -
            msat_to_int(maps:get(amount_msat, Res, 0)),
        type => <<"outgoing">>,
        invoice => maps:get(bolt11, Res, <<>>)
    }};
normalize_pay_invoice_result(#{preimage := Preimage} = Res) ->
    {ok, #{
        preimage => to_bin(Preimage),
        fees_paid => msat_to_int(maps:get(amount_sent_msat, Res, 0)) -
            msat_to_int(maps:get(amount_msat, Res, 0)),
        type => <<"outgoing">>,
        invoice => maps:get(bolt11, Res, <<>>)
    }};
normalize_pay_invoice_result(#{code := _, message := _} = Err) ->
    {error, nwc_error(<<"PAYMENT_FAILED">>, jsx:encode(normalize_map(Err)))};
normalize_pay_invoice_result(#{<<"code">> := _, <<"message">> := _} = Err) ->
    {error, nwc_error(<<"PAYMENT_FAILED">>, jsx:encode(Err))};
normalize_pay_invoice_result(Other) ->
    ?LOG_WARNING("Unexpected CLN pay_invoice result ~p", [Other]),
    {error, nwc_error(<<"PAYMENT_FAILED">>, to_bin(Other))}.

handle_make_invoice(Params) ->
    AmountMsat = read_int(Params, [<<"amount">>, amount, <<"amount_msat">>, amount_msat], 0),
    Description = read_bin(
        Params,
        [<<"description">>, description, <<"memo">>, memo],
        <<"DamageBDD NWC invoice">>
    ),
    Expiry = read_int(Params, [<<"expiry">>, expiry], 3600),
    Label = make_nwc_label(),
    case catch cln:create_invoice(AmountMsat, Description, Expiry, Label) of
        {'EXIT', Reason} ->
            {error, nwc_error(<<"INTERNAL">>, to_bin(Reason))};
        #{bolt11 := Bolt11, payment_hash := PaymentHash} = Inv ->
            {ok, #{
                invoice => Bolt11,
                payment_hash => PaymentHash,
                expires_at => maps:get(expires_at, Inv, 0)
            }};
        Other ->
            {error, nwc_error(<<"INTERNAL">>, to_bin(Other))}
    end.

handle_lookup_invoice(Params) ->
    case read_optional_bin(Params, [<<"payment_hash">>, payment_hash, <<"invoice">>, invoice]) of
        undefined ->
            {error, nwc_error(<<"BAD_REQUEST">>, <<"payment_hash or invoice required">>)};
        Lookup ->
            case catch cln:list_invoices_by_label(Lookup) of
                {'EXIT', Reason} ->
                    {error, nwc_error(<<"INTERNAL">>, to_bin(Reason))};
                #{invoices := Invoices} ->
                    {ok, #{invoices => Invoices}};
                Other ->
                    {ok, normalize_map(Other)}
            end
    end.

handle_list_transactions(_Params) ->
    %% minimal stub so listener no longer returns NOT_IMPLEMENTED
    {ok, #{transactions => []}}.

request_pubkey(#{<<"client_pubkey">> := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(#{client_pubkey := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(Unknown) ->
    ?LOG_DEBUG("request_pubkey ~p", [Unknown]),
    undefined.

nwc_error(Code, Message) ->
    #{
        error => #{
            code => Code,
            message => to_bin(Message)
        }
    }.

make_nwc_label() ->
    Ts = integer_to_binary(erlang:system_time(second)),
    Rand = lower_hex(crypto:strong_rand_bytes(6)),
    <<"nwc:", Ts/binary, ":", Rand/binary>>.

read_int(Map, [K | Ks], Default) ->
    case maps:get(K, Map, undefined) of
        undefined ->
            read_int(Map, Ks, Default);
        V when is_integer(V) -> V;
        V when is_binary(V) ->
            case catch binary_to_integer(V) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        V when is_list(V) ->
            case catch list_to_integer(V) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        _ ->
            Default
    end;
read_int(_Map, [], Default) ->
    Default.

read_bin(Map, [K | Ks], Default) ->
    case maps:get(K, Map, undefined) of
        undefined -> read_bin(Map, Ks, Default);
        V -> to_bin(V)
    end;
read_bin(_Map, [], Default) ->
    Default.

read_optional_bin(Map, [K | Ks]) ->
    case maps:get(K, Map, undefined) of
        undefined -> read_optional_bin(Map, Ks);
        V -> to_bin(V)
    end;
read_optional_bin(_Map, []) ->
    undefined.

pick_first([undefined | T]) ->
    pick_first(T);
pick_first([<<>> | T]) ->
    pick_first(T);
pick_first([H | _]) ->
    to_bin(H);
pick_first([]) ->
    <<>>.

msat_to_int(V) when is_integer(V) ->
    V;
msat_to_int(V) when is_binary(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> 0
    end;
msat_to_int(V) when is_list(V) ->
    case catch list_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> 0
    end;
msat_to_int(_) ->
    0.

normalize_map(Map) when is_map(Map) ->
    maps:from_list([{to_bin(K), normalize_value(V)} || {K, V} <- maps:to_list(Map)]).

normalize_value(V) when is_map(V) ->
    normalize_map(V);
normalize_value(V) when is_list(V) ->
    case io_lib:printable_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [normalize_value(I) || I <- V]
    end;
normalize_value(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
normalize_value(V) ->
    V.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).
