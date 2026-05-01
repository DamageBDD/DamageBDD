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
    case resolve_request_session(Req) of
        {ok, Owner, LedgerCt, ClientPubHex} ->
            case timed_balance(Owner, LedgerCt, ClientPubHex, 2500) of
                {ok, BalanceMsat} ->
                    {ok, #{balance => BalanceMsat}};
                {error, timeout} ->
                    {error, nwc_error(<<"TIMEOUT">>, <<"ledger balance lookup timed out">>)};
                {error, Why} ->
                    {error, nwc_error(<<"LEDGER_BALANCE_FAILED">>, fmt(Why))}
            end;
        {error, Code, Message} ->
            {error, nwc_error(Code, Message)}
    end;
handle_nip47_request(
    #{
        <<"method">> := <<"pay_invoice">>,
        <<"params">> := Params
    } = Req
) when is_map(Params) ->
    handle_pay_invoice(Req, Params);
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

handle_pay_invoice(Req, Params) ->
    Invoice = read_bin(Params, [<<"invoice">>, invoice], <<>>),
    case Invoice of
        <<>> ->
            {error, nwc_error(<<"BAD_REQUEST">>, <<"invoice required">>)};
        _ ->
            case resolve_request_session(Req) of
                {ok, Owner, LedgerCt, ClientPubHex} ->
                    AmountMsat = invoice_amount_msat(Params, Invoice),
                    ?LOG_DEBUG("invoce amount ~p", [[AmountMsat, Params, Req, Invoice]]),
                    case AmountMsat > 0 of
                        true ->
                            authorize_and_pay_invoice(
                                Owner,
                                LedgerCt,
                                ClientPubHex,
                                Invoice,
                                AmountMsat
                            );
                        false ->
                            {error,
                                nwc_error(
                                    <<"BAD_REQUEST">>,
                                    <<"invoice amount unavailable; amount is required for zero-amount invoices">>
                                )}
                    end;
                {error, Code, Message} ->
                    {error, nwc_error(Code, Message)}
            end
    end.

authorize_and_pay_invoice(Owner, LedgerCt, ClientPubHex, Invoice, AmountMsat) ->
    case catch damage_nwc_wallet:authorize_amount_msat(Owner, LedgerCt, ClientPubHex, AmountMsat) of
        ok ->
            ?LOG_INFO(
                "NWC pay_invoice authorized owner=~p ledger=~p client=~p amount_msat=~p",
                [Owner, LedgerCt, short_key(ClientPubHex), AmountMsat]
            ),
            pay_invoice_and_debit(Owner, LedgerCt, ClientPubHex, Invoice, AmountMsat);
        {error, Code, Message} ->
            {error, nwc_error(Code, Message)};
        {'EXIT', Reason} ->
            {error, nwc_error(<<"LEDGER_AUTH_FAILED">>, fmt(Reason))};
        Other ->
            {error, nwc_error(<<"LEDGER_AUTH_FAILED">>, fmt(Other))}
    end.

pay_invoice_and_debit(Owner, LedgerCt, ClientPubHex, Invoice, AmountMsat) ->
    PayOpts = pay_opts_for_invoice(Invoice, AmountMsat),
    case catch cln:pay_invoice(Invoice, PayOpts) of
        {'EXIT', Reason} ->
            ?LOG_WARNING("NWC pay_invoice crashed ~p", [Reason]),
            {error, nwc_error(<<"PAYMENT_FAILED">>, fmt(Reason))};
        {error, Why} ->
            {error, nwc_error(<<"PAYMENT_FAILED">>, fmt(Why))};
        {ok, PayRes} ->
            after_paid_invoice(Owner, LedgerCt, ClientPubHex, AmountMsat, Invoice, PayRes);
        PayRes when is_map(PayRes) ->
            after_paid_invoice(Owner, LedgerCt, ClientPubHex, AmountMsat, Invoice, PayRes);
        Other ->
            ?LOG_WARNING("Unexpected CLN pay_invoice result ~p", [Other]),
            {error, nwc_error(<<"PAYMENT_FAILED">>, fmt(Other))}
    end.

pay_opts_for_invoice(Invoice, AmountMsat) ->
    case bolt11_amount_msat(Invoice) of
        InvoiceAmount when is_integer(InvoiceAmount), InvoiceAmount > 0 ->
            #{};
        _ ->
            %% CLN pay requires amount_msat for amountless invoices.
            #{amount_msat => AmountMsat}
    end.

after_paid_invoice(Owner, LedgerCt, ClientPubHex, AmountMsat, Invoice, PayRes) ->
    case normalize_pay_invoice_result(PayRes) of
        {ok, Response0} ->
            Ref = payment_ref(PayRes),
            Meta = payment_meta(Invoice, PayRes),
            ok = damage_nwc_wallet:debit_after_payment(
                Owner,
                LedgerCt,
                ClientPubHex,
                AmountMsat,
                Ref,
                Meta
            ),
            ?LOG_INFO(
                "NWC pay_invoice debited owner=~p ledger=~p client=~p amount_msat=~p ref=~p",
                [Owner, LedgerCt, short_key(ClientPubHex), AmountMsat, Ref]
            ),
            {ok, Response0};
        {error, _} = Error ->
            Error
    end.

normalize_pay_invoice_result(#{status := complete} = Res) ->
    {ok, #{
        preimage => to_bin(
            pick_first([
                maps:get(payment_preimage, Res, undefined),
                maps:get(preimage, Res, undefined)
            ])
        ),
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
    {error, nwc_error(<<"PAYMENT_FAILED">>, fmt(Other))}.

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
            {error, nwc_error(<<"INTERNAL">>, fmt(Reason))};
        #{bolt11 := Bolt11, payment_hash := PaymentHash} = Inv ->
            {ok, #{
                invoice => Bolt11,
                payment_hash => PaymentHash,
                expires_at => maps:get(expires_at, Inv, 0)
            }};
        Other ->
            {error, nwc_error(<<"INTERNAL">>, fmt(Other))}
    end.

handle_lookup_invoice(Params) ->
    case read_optional_bin(Params, [<<"payment_hash">>, payment_hash, <<"invoice">>, invoice]) of
        undefined ->
            {error, nwc_error(<<"BAD_REQUEST">>, <<"payment_hash or invoice required">>)};
        Lookup ->
            case catch cln:list_invoices_by_label(Lookup) of
                {'EXIT', Reason} ->
                    {error, nwc_error(<<"INTERNAL">>, fmt(Reason))};
                #{invoices := Invoices} ->
                    {ok, #{invoices => Invoices}};
                Other ->
                    {ok, normalize_map(Other)}
            end
    end.

handle_list_transactions(_Params) ->
    %% minimal stub so listener no longer returns NOT_IMPLEMENTED
    {ok, #{transactions => []}}.

resolve_request_session(Req) ->
    case request_pubkey(Req) of
        undefined ->
            {error, <<"UNAUTHORIZED">>, <<"No client_pubkey on NIP-47 request">>};
        ClientPub0 ->
            ClientPubHex = normalize_client_pubkey(ClientPub0),
            case catch damage_nwc_wallet:resolve_owner_and_ledger_by_client_pubkey(ClientPubHex) of
                {ok, Owner, LedgerCt} ->
                    {ok, to_bin(Owner), to_bin(LedgerCt), ClientPubHex};
                {error, not_found} ->
                    {error, <<"UNAUTHORIZED">>, <<"No NWC ledger mapping for request pubkey">>};
                {error, Why} ->
                    {error, <<"UNAUTHORIZED">>, fmt(Why)};
                {'EXIT', Reason} ->
                    {error, <<"UNAUTHORIZED">>, fmt(Reason)};
                Other ->
                    {error, <<"UNAUTHORIZED">>, fmt(Other)}
            end
    end.

request_pubkey(#{<<"client_pubkey">> := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(#{client_pubkey := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(#{<<"pubkey">> := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(#{pubkey := WalletPubKey}) ->
    WalletPubKey;
request_pubkey(Unknown) ->
    ?LOG_DEBUG("request_pubkey missing in ~p", [Unknown]),
    undefined.

invoice_amount_msat(Params, Invoice) ->
    ParamAmount = read_optional_int(Params, [<<"amount">>, amount, <<"amount_msat">>, amount_msat]),
    case bolt11_amount_msat(Invoice) of
        InvoiceAmount when is_integer(InvoiceAmount), InvoiceAmount > 0 ->
            maybe_log_amount_mismatch(InvoiceAmount, ParamAmount, Invoice),
            InvoiceAmount;
        _ ->
            case ParamAmount of
                Amount when is_integer(Amount), Amount > 0 -> Amount;
                _ -> 0
            end
    end.

maybe_log_amount_mismatch(_InvoiceAmount, undefined, _Invoice) ->
    ok;
maybe_log_amount_mismatch(InvoiceAmount, ParamAmount, _Invoice) when
    InvoiceAmount =:= ParamAmount
->
    ok;
maybe_log_amount_mismatch(InvoiceAmount, ParamAmount, Invoice) ->
    ?LOG_WARNING(
        "NWC pay_invoice amount param ignored because BOLT11 is fixed amount invoice_amount_msat=~p param_amount_msat=~p invoice=~p",
        [InvoiceAmount, ParamAmount, short_invoice(Invoice)]
    ).

%% BOLT11 amount is encoded in the human-readable prefix.
%% Examples:
%%   lnbc210n... => 21000 msat
%%   lnbc21u...  => 2_100_000 msat
%%   amountless invoices have no amount between network and separator.
bolt11_amount_msat(Invoice0) ->
    Invoice = list_to_binary(string:lowercase(binary_to_list(to_bin(Invoice0)))),
    case
        re:run(
            Invoice,
            <<"^ln(?:bcrt|bc|tb|sb)([0-9]+)([munp]?)1">>,
            [caseless, {capture, [1, 2], binary}]
        )
    of
        {match, [DigitsBin, UnitBin]} ->
            bolt11_amount_to_msat(binary_to_integer(DigitsBin), UnitBin);
        nomatch ->
            undefined
    end.

%% BOLT11 multipliers are denominated in BTC. Convert to millisatoshis.
bolt11_amount_to_msat(Amount, <<>>) -> Amount * 100000000000;
bolt11_amount_to_msat(Amount, <<"m">>) -> Amount * 100000000;
bolt11_amount_to_msat(Amount, <<"u">>) -> Amount * 100000;
bolt11_amount_to_msat(Amount, <<"n">>) -> Amount * 100;
bolt11_amount_to_msat(Amount, <<"p">>) when Amount rem 10 =:= 0 -> Amount div 10;
bolt11_amount_to_msat(_Amount, <<"p">>) -> undefined;
bolt11_amount_to_msat(_Amount, _Unit) -> undefined.

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
        V ->
            case to_int(V) of
                I when is_integer(I) -> I;
                undefined -> Default
            end
    end;
read_int(_Map, [], Default) ->
    Default.

read_optional_int(Map, [K | Ks]) ->
    case maps:get(K, Map, undefined) of
        undefined -> read_optional_int(Map, Ks);
        V -> to_int(V)
    end;
read_optional_int(_Map, []) ->
    undefined.

to_int(V) when is_integer(V) ->
    V;
to_int(#{msat := M}) ->
    to_int(M);
to_int(#{<<"msat">> := M}) ->
    to_int(M);
to_int(V) when is_binary(V) ->
    parse_msat_value(V);
to_int(V) when is_list(V) ->
    parse_msat_value(unicode:characters_to_binary(V));
to_int(_) ->
    undefined.

parse_msat_value(V0) when is_binary(V0) ->
    V = list_to_binary(string:lowercase(string:trim(binary_to_list(V0)))),
    case catch binary_to_integer(V) of
        I when is_integer(I) ->
            I;
        _ ->
            case re:run(V, <<"^([0-9]+)(msat|sat|sats)$">>, [{capture, [1, 2], binary}]) of
                {match, [DigitsBin, <<"msat">>]} ->
                    binary_to_integer(DigitsBin);
                {match, [DigitsBin, Unit]} when Unit =:= <<"sat">>; Unit =:= <<"sats">> ->
                    binary_to_integer(DigitsBin) * 1000;
                nomatch ->
                    undefined
            end
    end.

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
    H;
pick_first([]) ->
    <<>>.

msat_to_int(#{msat := M}) ->
    msat_to_int(M);
msat_to_int(#{<<"msat">> := M}) ->
    msat_to_int(M);
msat_to_int(V) when is_integer(V) ->
    V;
msat_to_int(V) when is_binary(V) ->
    case parse_msat_value(V) of
        I when is_integer(I) -> I;
        undefined -> 0
    end;
msat_to_int(V) when is_list(V) ->
    msat_to_int(unicode:characters_to_binary(V));
msat_to_int(_) ->
    0.

payment_ref(PayRes) ->
    to_bin(
        pick_first([
            maps:get(payment_hash, PayRes, undefined),
            maps:get(<<"payment_hash">>, PayRes, undefined),
            maps:get(hash, PayRes, undefined),
            maps:get(<<"hash">>, PayRes, undefined),
            <<"nwc_payment">>
        ])
    ).

payment_meta(Invoice, PayRes) ->
    jsx:encode(#{
        source => <<"nwc">>,
        invoice => Invoice,
        payment_hash => to_bin(payment_ref(PayRes)),
        fees_paid_msat => pay_fees_msat(PayRes)
    }).

pay_fees_msat(#{amount_sent_msat := Sent, amount_msat := Amt}) ->
    max(0, msat_to_int(Sent) - msat_to_int(Amt));
pay_fees_msat(#{<<"amount_sent_msat">> := Sent, <<"amount_msat">> := Amt}) ->
    max(0, msat_to_int(Sent) - msat_to_int(Amt));
pay_fees_msat(_) ->
    0.

normalize_client_pubkey(ClientPub0) ->
    ClientPub = to_bin(ClientPub0),
    case byte_size(ClientPub) of
        64 -> list_to_binary(string:lowercase(binary_to_list(ClientPub)));
        32 -> lower_hex(ClientPub);
        _ -> ClientPub
    end.

short_key(Bin) when is_binary(Bin), byte_size(Bin) >= 12 ->
    <<Prefix:12/binary, _/binary>> = Bin,
    <<Prefix/binary, "...">>;
short_key(Bin) ->
    to_bin(Bin).

short_invoice(Invoice0) ->
    Invoice = to_bin(Invoice0),
    case byte_size(Invoice) of
        N when N > 24 ->
            <<Prefix:24/binary, _/binary>> = Invoice,
            <<Prefix/binary, "...">>;
        _ ->
            Invoice
    end.

fmt(Term) ->
    to_bin(io_lib:format("~p", [Term])).

normalize_map(Map) when is_map(Map) ->
    maps:from_list([{to_bin(K), normalize_value(V)} || {K, V} <- maps:to_list(Map)]);
normalize_map(Other) ->
    Other.

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

timed_balance(Owner, LedgerCt, ClientPubHex, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Parent ! {Ref, catch damage_nwc_wallet:ledger_balance_msat(Owner, LedgerCt, ClientPubHex)}
    end),
    receive
        {Ref, {ok, BalanceMsat}} when is_integer(BalanceMsat) ->
            {ok, BalanceMsat};
        {Ref, {'EXIT', Reason}} ->
            {error, Reason};
        {Ref, Other} ->
            Other
    after TimeoutMs ->
        exit(Pid, kill),
        {error, timeout}
    end.
