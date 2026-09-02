-module(steps_lightning).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

step(
    _Config,
    #{public_key := AeAccount} = Context,
    <<"Then">>,
    _N,
    ["I pay the invoice with payment request", PaymentRequest],
    _
) ->
    true = steps_utils:is_admin(AeAccount),
    maps:put(
        lightning_payment_status,
        damage_cln:pay_invoice(list_to_binary(PaymentRequest)),
        Context
    );
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ["I display the qrcode for", PaymentHash],
    _
) ->
    ?LOG_INFO("I display the qrcode for ~p", [PaymentHash]),
    Context;
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ["I wait for funds in escrow", PaymentHash],
    _
) ->
    ?LOG_INFO("I wait for funds in escrow ~p", [PaymentHash]),
    Context;
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ["I release funds in escrow", PaymentHash],
    _
) ->
    true = steps_utils:is_admin(Context),
    ?LOG_INFO("I release funds in escrow ~p", [PaymentHash]),
    Context;
%% ------------------------------------------------------------
%% High-level LNAddress/LNURL-pay flow
%% ------------------------------------------------------------

%% When I resolve lnaddress "user@domain"
step(
    _Config,
    Context,
    <<"When">>,
    _N,
    ["I resolve lnaddress", LnAddr0],
    _Body
) ->
    LnAddr = to_bin(LnAddr0),
    case split_lnaddress(LnAddr) of
        {ok, User, Domain} ->
            BaseUrl = <<"https://", Domain/binary>>,
            Path = <<"/.well-known/lnurlp/", User/binary>>,

            %% Use steps_http's gun client to fetch JSON
            C0 = maps:put(base_url, binary_to_list(BaseUrl), Context),
            C1 = steps_http:gun_get([], C0, binary_to_list(<<BaseUrl/binary, Path/binary>>), []),

            case maps:get(response, C1, undefined) of
                [{status_code, 200}, _Headers, {body, Body}] ->
                    case catch jsx:decode(Body, [return_maps]) of
                        {'EXIT', _} ->
                            maps:put(fail, <<"invalid lnurlp json">>, Context);
                        Json ->
                            case maps:get(<<"tag">>, Json, <<>>) of
                                <<"payRequest">> ->
                                    Callback = maps:get(<<"callback">>, Json, <<>>),
                                    C2 = maps:put(lnaddress, LnAddr, Context),
                                    C3 = maps:put(lnurl_callback, Callback, C2),
                                    %% optional metadata
                                    C4 = maps:put(lnurl_meta, Json, C3),
                                    C4;
                                _ ->
                                    maps:put(fail, <<"lnurlp tag is not payRequest">>, Context)
                            end
                    end;
                [{status_code, Status}, _Headers, {body, Body}] ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"lnurlp resolve failed status=~p body=~p">>, [
                            Status, Body
                        ]),
                        Context
                    );
                Other ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"unexpected lnurlp response ~p">>, [Other]),
                        Context
                    )
            end;
        {error, Why} ->
            maps:put(fail, Why, Context)
    end;
%% And I request an invoice for "X" sats
step(
    _Config,
    Context,
    <<"And">>,
    _N,
    ["I request an invoice for", Sats0, "sats"],
    _Body
) ->
    Sats = to_int(Sats0, 0),
    case maps:get(lnurl_callback, Context, undefined) of
        undefined ->
            maps:put(fail, <<"lnurl callback missing (resolve lnaddress first)">>, Context);
        Callback ->
            AmountMsat = Sats * 1000,
            %% Comment is optional; you can swap this for nostr_event_content if you want
            Comment = maps:get(nostr_event_content, Context, <<"">>),

            Url = build_lnurl_invoice_url(to_bin(Callback), AmountMsat, to_bin(Comment)),
            C0 = steps_http:gun_get([], Context, binary_to_list(Url), []),

            case maps:get(response, C0, undefined) of
                [{status_code, 200}, _Headers, {body, Body}] ->
                    case catch jsx:decode(Body, [return_maps]) of
                        {'EXIT', _} ->
                            maps:put(fail, <<"invalid lnurl callback json">>, Context);
                        Json ->
                            case maps:get(<<"pr">>, Json, undefined) of
                                undefined ->
                                    maps:put(fail, <<"no pr in invoice response">>, Context);
                                Pr ->
                                    C1 = maps:put(payment_request, Pr, Context),
                                    maps:put(reward_sats, Sats, C1)
                            end
                    end;
                [{status_code, Status}, _Headers, {body, Body}] ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"invoice request failed status=~p body=~p">>, [
                            Status, Body
                        ]),
                        Context
                    );
                Other ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"unexpected invoice response ~p">>, [Other]),
                        Context
                    )
            end
    end;
%% Then I pay the invoice
step(
    _Config,
    #{public_key := AeAccount} = Context,
    <<"Then">>,
    _N,
    ["I pay the invoice"],
    _Body
) ->
    true = steps_utils:is_admin(AeAccount),
    case maps:get(payment_request, Context, undefined) of
        undefined ->
            maps:put(fail, <<"payment_request missing (request invoice first)">>, Context);
        Pr ->
            Result = damage_cln:pay_invoice(to_bin(Pr)),
            maps:put(lightning_payment_status, Result, Context)
    end;
%% And I record the payment result
step(
    _Config,
    Context,
    <<"And">>,
    _N,
    ["I record the payment result"],
    _Body
) ->
    Now = erlang:system_time(second),
    LnAddr = maps:get(lnaddress, Context, undefined),
    Sats = maps:get(reward_sats, Context, undefined),
    Pr = maps:get(payment_request, Context, undefined),
    PayStatus = maps:get(lightning_payment_status, Context, undefined),
    NostrEv = maps:get(nostr_event, Context, undefined),

    Record = #{
        time => Now,
        lnaddress => LnAddr,
        reward_sats => Sats,
        payment_request => Pr,
        lightning_payment_status => PayStatus,
        nostr_event => NostrEv
    },

    Prev = maps:get(payment_results, Context, []),
    maps:put(payment_results, Prev ++ [Record], maps:put(last_payment_result, Record, Context)).

%% ------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

to_int(V, _Default) when is_integer(V) -> V;
to_int(V, Default) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> Default
    end;
to_int(V, Default) when is_list(V) ->
    try
        list_to_integer(V)
    catch
        _:_ -> Default
    end;
to_int(_, Default) ->
    Default.

split_lnaddress(LnAddr) ->
    case binary:split(LnAddr, <<"@">>, [global]) of
        [User, Domain] when User =/= <<>>, Domain =/= <<>> ->
            {ok, User, Domain};
        _ ->
            {error, <<"invalid lnaddress (expected user@domain)">>}
    end.

build_lnurl_invoice_url(Callback, AmountMsat, Comment) ->
    %% minimal query escaping (good enough for simple comments);
    %% you can tighten later with uri_string:compose_query/1 if needed.
    Sep =
        case binary:match(Callback, <<"?">>) of
            nomatch -> <<"?">>;
            _ -> <<"&">>
        end,
    EncComment = uri_string:quote(Comment),
    list_to_binary(
        binary_to_list(
            <<Callback/binary, Sep/binary, "amount=", (integer_to_binary(AmountMsat))/binary,
                "&comment=", EncComment/binary>>
        )
    ).
