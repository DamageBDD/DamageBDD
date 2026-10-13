-module(steps_monero).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% Given the local Monero wallet RPC is available
step(
    _Config,
    Context,
    <<"Given">>,
    _Line,
    ["the local Monero wallet RPC is available"],
    _Body
) ->
    ok = authorize(Context),
    case monero:health() of
        {ok, Health} ->
            maps:put(<<"monero_health">>, Health, Context);
        {error, Reason} ->
            steps_utils:set_fail(Context, "Local Monero wallet RPC is unavailable: ~p", [Reason])
    end;
%% When I refresh the local Monero wallet
step(
    _Config,
    Context,
    <<"When">>,
    _Line,
    ["I refresh the local Monero wallet"],
    _Body
) ->
    ok = authorize(Context),
    case monero:refresh() of
        {ok, RefreshResult} ->
            maps:put(<<"monero_refresh">>, RefreshResult, Context);
        {error, Reason} ->
            steps_utils:set_fail(Context, "Unable to refresh the Monero wallet: ~p", [Reason])
    end;
%% Given I create a Monero invoice for "0.001" XMR in "invoice"
step(
    _Config,
    Context,
    <<"Given">>,
    _Line,
    ["I create a Monero invoice for", Amount0, "XMR in", Variable],
    _Body
) ->
    ok = authorize(Context),
    Amount = render_arg(Amount0, Context),
    Label = invoice_label(Variable),
    case monero:create_invoice(Label, Amount) of
        {ok, Invoice} ->
            ?LOG_INFO(
                "Created Monero invoice subaddress=~p amount=~p XMR",
                [maps:get(subaddress_index, Invoice), maps:get(amount_xmr, Invoice)]
            ),
            maps:put(Variable, Invoice, Context);
        {error, Reason} ->
            steps_utils:set_fail(Context, "Unable to create Monero invoice: ~p", [Reason])
    end;
%% Then the Monero invoice in "invoice" should be paid with "10" confirmations
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    ["the Monero invoice in", Variable, "should be paid with", Confirmations0, "confirmations"],
    _Body
) ->
    ok = authorize(Context),
    case {lookup_context(Variable, Context), parse_non_negative_integer(Confirmations0)} of
        {{ok, Invoice}, {ok, Confirmations}} ->
            case monero:invoice_status(Invoice, Confirmations) of
                {ok, #{paid := true} = Status} ->
                    put_status(Variable, Status, Context);
                {ok, Status} ->
                    Context1 = put_status(Variable, Status, Context),
                    steps_utils:set_fail(
                        Context1,
                        "Monero invoice is not paid: state=~p received=~p XMR confirmed=~p XMR",
                        [
                            maps:get(payment_state, Status),
                            maps:get(received_xmr, Status),
                            maps:get(confirmed_xmr, Status)
                        ]
                    );
                {error, Reason} ->
                    steps_utils:set_fail(Context, "Unable to inspect Monero invoice: ~p", [Reason])
            end;
        {error, _} ->
            steps_utils:set_fail(Context, "Monero invoice variable ~p does not exist", [Variable]);
        {_, {error, Reason}} ->
            steps_utils:set_fail(Context, "Invalid confirmation count ~p: ~p", [
                Confirmations0, Reason
            ])
    end;
%% Then I wait for the Monero invoice in "invoice" to be paid with "10"
%% confirmations for up to "3600" seconds
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    [
        "I wait for the Monero invoice in",
        Variable,
        "to be paid with",
        Confirmations0,
        "confirmations for up to",
        TimeoutSeconds0,
        "seconds"
    ],
    _Body
) ->
    ok = authorize(Context),
    Parsed = {
        lookup_context(Variable, Context),
        parse_non_negative_integer(Confirmations0),
        parse_non_negative_integer(TimeoutSeconds0)
    },
    case Parsed of
        {{ok, Invoice}, {ok, Confirmations}, {ok, TimeoutSeconds}} ->
            case monero:wait_for_invoice(Invoice, Confirmations, TimeoutSeconds) of
                {ok, Status} ->
                    put_status(Variable, Status, Context);
                {error, #{type := invoice_timeout, status := Status}} ->
                    Context1 = put_status(Variable, Status, Context),
                    steps_utils:set_fail(
                        Context1,
                        "Timed out waiting for Monero invoice: state=~p received=~p XMR confirmed=~p XMR",
                        [
                            maps:get(payment_state, Status),
                            maps:get(received_xmr, Status),
                            maps:get(confirmed_xmr, Status)
                        ]
                    );
                {error, Reason} ->
                    steps_utils:set_fail(Context, "Unable to wait for Monero invoice: ~p", [Reason])
            end;
        {error, _, _} ->
            steps_utils:set_fail(Context, "Monero invoice variable ~p does not exist", [Variable]);
        {_, {error, Reason}, _} ->
            steps_utils:set_fail(Context, "Invalid confirmation count ~p: ~p", [
                Confirmations0, Reason
            ]);
        {_, _, {error, Reason}} ->
            steps_utils:set_fail(Context, "Invalid timeout ~p: ~p", [TimeoutSeconds0, Reason])
    end;
%% Then the Monero invoice in "invoice" should not be paid
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    ["the Monero invoice in", Variable, "should not be paid"],
    _Body
) ->
    ok = authorize(Context),
    MinConfirmations = application:get_env(damage, monero_min_confirmations, 10),
    case lookup_context(Variable, Context) of
        {ok, Invoice} ->
            case monero:invoice_status(Invoice, MinConfirmations) of
                {ok, #{paid := false} = Status} ->
                    put_status(Variable, Status, Context);
                {ok, Status} ->
                    Context1 = put_status(Variable, Status, Context),
                    steps_utils:set_fail(
                        Context1,
                        "Monero invoice is already paid: confirmed=~p XMR",
                        [maps:get(confirmed_xmr, Status)]
                    );
                {error, Reason} ->
                    steps_utils:set_fail(Context, "Unable to inspect Monero invoice: ~p", [Reason])
            end;
        error ->
            steps_utils:set_fail(Context, "Monero invoice variable ~p does not exist", [Variable])
    end;
%% Then I store the Monero wallet balance in "balance"
step(
    _Config,
    Context,
    <<"Then">>,
    _Line,
    ["I store the Monero wallet balance in", Variable],
    _Body
) ->
    ok = authorize(Context),
    case monero:get_balance() of
        {ok, Balance} ->
            maps:put(Variable, enrich_balance(Balance), Context);
        {error, Reason} ->
            steps_utils:set_fail(Context, "Unable to read Monero wallet balance: ~p", [Reason])
    end;
%% When I send "0.001" XMR to "{{destination}}" and store the transaction in "tx"
step(
    _Config,
    Context,
    <<"When">>,
    _Line,
    ["I send", Amount0, "XMR to", Address0, "and store the transaction in", Variable],
    _Body
) ->
    ok = authorize(Context),
    Amount = render_arg(Amount0, Context),
    Address = render_arg(Address0, Context),
    Priority = application:get_env(damage, monero_transfer_priority, 0),
    case monero:transfer(Address, Amount, Priority) of
        {ok, TransferResult} ->
            maps:put(Variable, TransferResult, Context);
        {error, Reason} ->
            steps_utils:set_fail(Context, "Unable to send Monero transaction: ~p", [Reason])
    end.

%% ------------------------------------------------------------------
%% Internal helpers
%% ------------------------------------------------------------------

authorize(Context) ->
    case application:get_env(damage, monero_steps_require_admin, true) of
        true -> steps_utils:ensure_admin(Context);
        _ -> ok
    end.

render_arg(Value, Context) ->
    damage_utils:render(to_binary(Value), Context).

invoice_label(Variable) ->
    VariableBin = to_binary(Variable),
    <<"damagebdd:", VariableBin/binary>>.

lookup_context(Variable, Context) ->
    case maps:find(Variable, Context) of
        {ok, Value} ->
            {ok, Value};
        error ->
            maps:find(to_binary(Variable), Context)
    end.

put_status(Variable, Status, Context) ->
    StatusKey = <<(to_binary(Variable))/binary, "_status">>,
    maps:put(StatusKey, Status, Context).

enrich_balance(Balance) when is_map(Balance) ->
    BalanceAtomic = maps:get(balance, Balance, 0),
    UnlockedAtomic = maps:get(unlocked_balance, Balance, 0),
    Balance#{
        balance_xmr => monero:atomic_to_xmr(BalanceAtomic),
        unlocked_balance_xmr => monero:atomic_to_xmr(UnlockedAtomic)
    }.

parse_non_negative_integer(Value) when is_integer(Value), Value >= 0 ->
    {ok, Value};
parse_non_negative_integer(Value) ->
    ValueBin = to_binary(Value),
    try binary_to_integer(ValueBin) of
        Integer when Integer >= 0 -> {ok, Integer};
        _ -> {error, negative_integer}
    catch
        error:badarg -> {error, not_an_integer}
    end.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_float(Value) -> float_to_binary(Value, [short]);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).
