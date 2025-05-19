-module(damage_invoicing).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_resource/2]).
-export([lookup_invoice/2]).
-export([check_invoices/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Damage Invoices"]).

trails() ->
    [
        trails:trail(
            "/invoices/:payment_request",
            damage_invoicing,
            #{action => get_invoice},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "get invoice status.",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        ),
        trails:trail(
            "/invoices",
            damage_invoicing,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List invoices.",
                        produces => ["application/json"],
                        parameters => []
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Create new invoice.",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"label">>,
                                    description => <<"label for invoice.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"description">>,
                                    description => <<"description for invoice.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"amount_msats">>,
                                    description => <<"amount in micro sats for invoice.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    },
                delete =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Delete invoice.",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"payment_hash">>,
                                    description => <<"payment hash for invoice to cancel.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, #{action := get_invoice} = State) ->
    {true, Req, State};
is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_json(Req, #{action := get_invoice} = State) ->
    case cowboy_req:binding(payment_request, Req) of
        undefined ->
            {jsx:encode(#{}), Req, State};
        InvoiceString ->
            #{invoices := [Invoice | _]} = cln:list_invoices_by_invoicestring(InvoiceString),
            {jsx:encode(Invoice), Req, State}
    end;
to_json(Req, #{public_key := _AeAccount} = State) ->
    {jsx:encode(#{}), Req, State}.

from_json(Req, #{public_key := _AeAccount} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            #{
                label := Label,
                amount_msats := Amount,
                cltv := Cltv,
                description := Description
            } = InvReq ->
                ?LOG_DEBUG("Invoice request ~p", [InvReq]),
                case cln:hold_invoice(Amount, Description, Label, Cltv) of
                    #{
                        bolt11 := _Bolt11,
                        created_index := _Index,
                        expires_at := _Expiry,
                        payment_hash := _PaymentHash,
                        payment_secret := _PaymentSecret
                    } = Invoice ->
                        {202, Invoice};
                    Error ->
                        ?LOG_ERROR("Failed to create invoice ~p", [Error]),
                        {400, "Failed to create invoice."}
                end
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.

delete_resource(Req, #{public_key := _AeAccount} = State) ->
    Deleted =
        lists:foldl(
            fun(PaymentHash, Acc) ->
                ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), PaymentHash]),
                ok = cln:hold_invoice_cancel(PaymentHash),
                Acc + 1
            end,
            0,
            maps:get(path_info, Req)
        ),
    ?LOG_INFO("deleted ~p invoice", [Deleted]),
    {true, Req, State}.

lookup_invoice(Req, State) ->
    ?LOG_INFO("look up invoice ~p ~p", [Req, State]),
    [].

check_invoices() ->
    {Date, _} = calendar:now_to_datetime(os:timestamp()),
    CreationDate =
        integer_to_list(
            date_util:date_to_epoch(date_util:subtract(Date, {days, ?INVOICES_SINCE}))
        ),
    lists:foldl(
        fun check_invoice_foldn/2,
        [],
        cln:list_invoices([{"creation_date_start", CreationDate}])
    ).

do_post_action(invoices, #{amount := Amount}, _Req, _State) when
    Amount > ?MAX_DAMAGE_INVOICE
->
    {
        4000,
        #{
            status => <<"max_damage">>,
            message => <<"invoice amount too large">>,
            max_damage_invoice => ?MAX_DAMAGE_INVOICE
        }
    };
do_post_action(invoices, #{amount := Amount}, _Req, _State) when
    Amount < ?MIN_DAMAGE_INVOICE
->
    {
        ?MIN_DAMAGE_INVOICE,
        #{
            status => <<"max_damage">>,
            message => <<"invoice amount too large">>,
            max_damage_invoice => ?MIN_DAMAGE_INVOICE
        }
    };
do_post_action(invoices, #{amount := Amount}, Req, State) ->
    case damage_http:is_authorized(Req, State) of
        {true, _Req0, #{username := Username, public_key := AeAccount} = _State0} ->
            {
                201,
                #{
                    status => <<"ok">>,
                    invoice => create_invoice(Amount, Username, AeAccount)
                }
            };
        {false, _} ->
            {401, #{status => <<"noauth">>, message => <<"Unauthorized.">>}}
    end.

create_invoice(Amount, Username, AeAccount) ->
    DmgAmount = damage:sats_to_damage(Amount),
    Memo =
        list_to_binary(
            lists:flatten(
                io_lib:format(
                    "Invoice for ~p damage tokens for user ~s, with AE Account ~s",
                    [DmgAmount, Username, AeAccount]
                )
            )
        ),
    ?LOG_DEBUG("creating invoice with memo ~p", [Memo]),
    Invoice = cln:create_invoice(Amount, Memo),
    #{
        payment_hash := _PaymentHash,
        bolt11 := PaymentRequest,
        created_index := _CreatedIndex,
        expires_at := ExpiresAt,
        payment_secret := _PaymentSecret
    } = Invoice,
    ?LOG_DEBUG("saved invoice ~p", [Invoice]),
    #{payment_request => PaymentRequest, expiry => ExpiresAt}.

filter_valid_invoices(Invoices, AeAccount) ->
    lists:filter(
        fun(Invoice) ->
            case Invoice of
                #{<<"state">> := <<"OPEN">>, <<"memo">> := Memo} ->
                    MemoRe = lists:flatten(io_lib:format(".*~s$", [AeAccount])),
                    case re:run(Memo, MemoRe) of
                        {match, _Matched} ->
                            true;
                        NotMatched ->
                            ?LOG_DEBUG("Re Not matched invoice ~p", [NotMatched]),
                            false
                    end;
                NotMatched ->
                    ?LOG_DEBUG("Not matched invoice ~p", [NotMatched]),
                    false
            end
        end,
        Invoices
    ).

check_invoice_foldn(Invoice, Acc) ->
    case maps:get(<<"state">>, Invoice) of
        <<"ACCEPTED">> ->
            ?LOG_INFO("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
            Acc;
        <<"SETTLED">> ->
            ?LOG_INFO("Settled Invoice ~p", [Invoice]),
            AmountPaid = maps:get(<<"amt_paid_sat">>, Invoice),
            case maps:get(<<"memo">>, Invoice) of
                AeAccountEncrypted when is_binary(AeAccountEncrypted) ->
                    ?LOG_INFO("Acceptd Invoice ~p ~p", [Invoice, AmountPaid]),
                    AeAccount = damage_utils:decrypt(AeAccountEncrypted),
                    Result =
                        damage_ae:transfer_damage_tokens(
                            AeAccount,
                            AmountPaid * ?DAMAGE_PRICE
                        ),
                    ?LOG_INFO("Funded contract ~p ~p", [Result, AmountPaid]),
                    Acc ++ [Invoice];
                _ ->
                    Acc
            end;
        <<"CANCELED">> ->
            ?LOG_DEBUG("Cancelled Invoice ~p", [maps:get(<<"memo">>, Invoice)]),
            Acc
    end.
