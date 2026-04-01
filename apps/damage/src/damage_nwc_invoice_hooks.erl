-module(damage_nwc_invoice_hooks).

-export([watch_invoice/1, check_invoice/1, handle_settled_invoice/1]).

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
    case cln:list_invoices_by_label(Label) of
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
    AmountPaidSat = maps:get(
        amount_received_msat,
        Invoice,
        maps:get(<<"amount_received_msat">>, Invoice, 0)
    ),
    case parse_nwc_label(Label) of
        {ok, Wallet, Session, Ref} ->
            ?LOG_INFO("NWC invoice settled wallet=~p session=~p ref=~p", [Wallet, Session, Ref]),
            credit_wallet_bucket(Wallet, Session, Ref, AmountPaidSat);
        {error, Why} ->
            ?LOG_WARNING("NWC settled invoice label parse failed label=~p why=~p", [Label, Why]),
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
            ok = damage_nwc_balance_cache:invalidate(Wallet);
        Error ->
            ?LOG_WARNING("wallet resolution failed wallet=~p error=~p", [Wallet, Error]),
            ok
    end.
