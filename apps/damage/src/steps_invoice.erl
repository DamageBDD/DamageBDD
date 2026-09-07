%% src/steps_invoice.erl
-module(steps_invoice).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([step_dry/6]).

step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    [
        "I create a Lightning invoice for account",
        _Account,
        "using amount secret",
        _AmountSecret,
        "and recipient email secret",
        _EmailSecret
    ] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(
    Config,
    Context,
    Keyword,
    LineNo,
    [
        "the Lightning invoice email should be accepted"
    ] = Args,
    Body
) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(
    _Config,
    Context,
    <<"When">>,
    _N,
    [
        "I create a Lightning invoice for account",
        Account0,
        "using amount secret",
        AmountSecret0,
        "and recipient email secret",
        EmailSecret0
    ],
    _Body
) ->
    Account = to_bin(Account0),
    Owner = to_bin(maps:get(public_key, Context, <<>>)),
    AmountSecret = to_bin(AmountSecret0),
    EmailSecret = to_bin(EmailSecret0),

    %% The account in user-authored Gherkin is descriptive only: it must match
    %% the authenticated execution owner.  Never let a feature select another
    %% tenant's secret scope.
    case Account =:= Owner andalso Owner =/= <<>> of
        false ->
            maps:put(
                fail,
                <<"invoice account must match the authenticated DamageBDD account">>,
                Context
            );
        true ->
            case {read_secret(Owner, AmountSecret), read_secret(Owner, EmailSecret)} of
                {{ok, AmountRaw}, {ok, EmailRaw}} ->
                    Email = to_bin(EmailRaw),
                    case {parse_sats(AmountRaw), damage_utils:is_valid_email(Email)} of
                        {Sats, true} when is_integer(Sats), Sats > 0 ->
                            create_and_email_invoice(Context, Account, Sats, Email);
                        {bad_amount, _} ->
                            maps:put(
                                fail,
                                <<"scheduled invoice amount secret is not a positive integer sats value">>,
                                Context
                            );
                        {_Sats, false} ->
                            maps:put(
                                fail,
                                <<"scheduled invoice email secret is not a valid email address">>,
                                Context
                            )
                    end;
                {{error, Reason}, _} ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"amount secret lookup failed: ~p">>, [Reason]),
                        Context
                    );
                {_, {error, Reason}} ->
                    maps:put(
                        fail,
                        damage_utils:strf(<<"email secret lookup failed: ~p">>, [Reason]),
                        Context
                    )
            end
    end;
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ["the Lightning invoice email should be accepted"],
    _Body
) ->
    case maps:get(invoice_email_result, Context, undefined) of
        undefined ->
            maps:put(fail, <<"invoice email was not attempted">>, Context);
        error ->
            maps:put(fail, <<"invoice email failed">>, Context);
        {error, Reason} ->
            maps:put(fail, damage_utils:strf(<<"invoice email failed: ~p">>, [Reason]), Context);
        _Accepted ->
            Context
    end.

create_and_email_invoice(Context, Account, Sats, Email) ->
    {ok, Timestamp0} = datestring:format("YmdHMS", erlang:localtime()),
    Timestamp = to_bin(Timestamp0),

    Label = <<"scheduled_invoice:", Account/binary, ":", Timestamp/binary>>,
    Description = <<"DamageBDD scheduled invoice for ", Account/binary>>,
    AmountMsat = Sats * 1000,

    case damage_cln:create_invoice(AmountMsat, Description, 3600, Label) of
        #{
            payment_hash := PaymentHash,
            bolt11 := Bolt11
        } = Invoice ->
            Subject = <<"DamageBDD Lightning Invoice">>,
            TextBody =
                <<
                    "A Lightning invoice has been created for your DamageBDD account.\n\n",
                    "Account: ",
                    Account/binary,
                    "\n",
                    "Invoice:\n",
                    Bolt11/binary,
                    "\n\n",
                    "This invoice expires in 3600 seconds.\n"
                >>,
            HtmlBody =
                <<
                    "<html><body>",
                    "<p>A Lightning invoice has been created for your DamageBDD account.</p>",
                    "<p><b>Account:</b> ",
                    Account/binary,
                    "</p>",
                    "<p><b>Invoice:</b></p>",
                    "<pre>",
                    Bolt11/binary,
                    "</pre>",
                    "<p>This invoice expires in 3600 seconds.</p>",
                    "</body></html>"
                >>,

            Result = damage_utils:send_email(
                {<<"DamageBDD">>, Email},
                Subject,
                TextBody,
                HtmlBody
            ),

            %% Do not store Email or Sats in context/report.
            Context#{
                invoice_email_result => Result,
                invoice_payment_hash => PaymentHash,
                invoice_label => Label,
                invoice_bolt11_sha256 => sha256_urlsafe(Bolt11),
                invoice_created_index => maps:get(created_index, Invoice, undefined)
            };
        Error ->
            maps:put(
                fail,
                damage_utils:strf(<<"failed to create Lightning invoice: ~p">>, [Error]),
                Context
            )
    end.

read_secret(Owner, Name0) ->
    Name = to_bin(Name0),
    case secrets:retrieve_decrypt({account, Owner}, Name) of
        {ok, Value} -> {ok, Value};
        _ -> {error, not_found}
    end.

parse_sats(V) when is_integer(V) ->
    V;
parse_sats(V) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> bad_amount
    end;
parse_sats(V) when is_list(V) ->
    try
        list_to_integer(V)
    catch
        _:_ -> bad_amount
    end;
parse_sats(_) ->
    bad_amount.

sha256_urlsafe(Bin) ->
    base64:encode(crypto:hash(sha256, Bin), #{padding => false, mode => urlsafe}).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).
