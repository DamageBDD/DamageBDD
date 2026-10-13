-module(damage_nwc_invoice_hooks).

-export([watch_invoice/1, check_invoice/1, handle_settled_invoice/1, handle_topup_invoice_settled/1]).

-include_lib("kernel/include/logger.hrl").

watch_invoice(Label) when is_binary(Label) ->
    spawn(fun() -> poll_until_settled(Label, 60) end),
    ok.

poll_until_settled(_Label, 0) ->
    ok;
poll_until_settled(Label, N) ->
    case check_invoice(Label) of
        settled ->
            ok;
        open ->
            timer:sleep(2000),
            poll_until_settled(Label, N - 1);
        _Other ->
            timer:sleep(2000),
            poll_until_settled(Label, N - 1)
    end.

check_invoice(Label) ->
    case damage_cln:list_invoices_by_label(Label) of
        #{invoices := Invoices} ->
            case find_settled_invoice(Invoices) of
                {ok, Invoice} ->
                    handle_settled_invoice(Invoice),
                    settled;
                false ->
                    open
            end;
        Other ->
            ?LOG_WARNING("check_invoice failed label=~p res=~p", [Label, Other]),
            error
    end.

find_settled_invoice(Invoices) ->
    case
        lists:filter(
            fun
                (#{state := <<"SETTLED">>}) -> true;
                (#{<<"state">> := <<"SETTLED">>}) -> true;
                (_) -> false
            end,
            Invoices
        )
    of
        [Invoice | _] -> {ok, Invoice};
        [] -> false
    end.

handle_settled_invoice(Invoice) ->
    Label = maps:get(label, Invoice, maps:get(<<"label">>, Invoice, <<>>)),
    AmountReceivedMsat = maps:get(
        amount_received_msat,
        Invoice,
        maps:get(<<"amount_received_msat">>, Invoice, 0)
    ),
    AmountMsat = msat_to_int(AmountReceivedMsat),
    case parse_nwc_label(Label) of
        {ok, Wallet, Session, Ref} ->
            ?LOG_INFO("NWC invoice settled wallet=~p session=~p ref=~p", [Wallet, Session, Ref]),
            credit_wallet_bucket(Wallet, Session, Ref, AmountMsat);
        {error, Why} ->
            ?LOG_WARNING("NWC settled invoice label parse failed label=~p why=~p", [Label, Why]),
            ok
    end.

handle_topup_invoice_settled(PaymentHash) ->
    case damage_nwc_topup_store:get(PaymentHash) of
        {ok, #{
            status := pending,
            owner := Owner,
            ledger_ct := LedgerCt,
            client_pubkey := ClientPubHex,
            amount_sat := AmountSat
        }} ->
            case
                damage_nwc_http:credit_settled_topup(
                    Owner, LedgerCt, ClientPubHex, AmountSat, PaymentHash
                )
            of
                ok ->
                    _ = damage_nwc_topup_store:mark_settled(
                        PaymentHash, erlang:system_time(second)
                    ),
                    ok = damage_nwc_balance_cache:invalidate(Owner),
                    ok;
                {error, Why} = Error ->
                    ?LOG_WARNING(
                        "NWC topup credit failed payment_hash=~p reason=~p",
                        [PaymentHash, Why]
                    ),
                    Error
            end;
        {ok, #{status := settled}} ->
            ok;
        {error, not_found} ->
            ok
    end.
parse_nwc_label(Label) when is_binary(Label) ->
    case binary:split(Label, <<":">>, [global]) of
        [<<"nwc">>, Wallet, Session, Ref] ->
            {ok, Wallet, Session, Ref};
        [<<"nwc">>, Wallet, Ref] ->
            {ok, Wallet, <<"default">>, Ref};
        _ ->
            {error, bad_label}
    end.

credit_wallet_bucket(Wallet, Session, Ref, AmountReceivedMsat) ->
    case damage_nwc_registry:resolve_wallet(Wallet) of
        {ok, Owner, LedgerCt, ClientPubHex} ->
            damage_nwc_ledger:credit(
                Owner, LedgerCt, ClientPubHex, AmountReceivedMsat, Ref, Session
            ),
            _ = damage_nwc_ledger_cache:apply_local_credit(
                LedgerCt,
                ClientPubHex,
                AmountReceivedMsat,
                Ref,
                #{source => nwc_invoice, session => Session}
            ),
            ok = damage_nwc_balance_cache:invalidate(Owner);
        Error ->
            ?LOG_WARNING("wallet resolution failed wallet=~p error=~p", [Wallet, Error]),
            ok
    end.

msat_to_int(I) when is_integer(I) ->
    I;
msat_to_int(B) when is_binary(B) ->
    Digits = <<<<C>> || <<C>> <= B, C >= $0, C =< $9>>,
    case Digits of
        <<>> ->
            0;
        _ ->
            try binary_to_integer(Digits) of
                V -> V
            catch
                _:_ -> 0
            end
    end;
msat_to_int(L) when is_list(L) ->
    msat_to_int(unicode:characters_to_binary(L));
msat_to_int(_) ->
    0.
