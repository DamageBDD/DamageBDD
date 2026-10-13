-module(monero).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_WALLET_RPC_HOST, "127.0.0.1").
-define(DEFAULT_WALLET_RPC_PORT, 18083).
-define(DEFAULT_RPC_TIMEOUT, 120000).
-define(ATOMIC_UNITS_PER_XMR, 1000000000000).

-export([
    rpc/2,
    health/0,
    get_version/0,
    get_height/0,
    refresh/0,
    store/0,
    get_balance/0,
    create_address/1,
    create_address/2,
    create_invoice/2,
    get_transfers/2,
    invoice_status/2,
    wait_for_invoice/3,
    transfer/3,
    xmr_to_atomic/1,
    atomic_to_xmr/1,
    summarize_transfers/3
]).

-type rpc_result() :: {ok, term()} | {error, term()}.
-type invoice() :: #{
    address := binary(),
    account_index := non_neg_integer(),
    subaddress_index := non_neg_integer(),
    amount_atomic := pos_integer(),
    amount_xmr := binary(),
    label := binary(),
    created_at := integer()
}.

%% ------------------------------------------------------------------
%% Public JSON-RPC API
%% ------------------------------------------------------------------

-spec rpc(binary() | atom() | list(), map()) -> rpc_result().
rpc(Method0, Params) when is_map(Params) ->
    Method = to_binary(Method0),
    case rpc_config() of
        {ok, #{host := Host, port := Port, opts := Opts}} ->
            Payload = #{
                jsonrpc => <<"2.0">>,
                id => <<"damagebdd">>,
                method => Method,
                params => Params
            },
            do_rpc(Host, Port, Opts, Payload);
        {error, Reason} ->
            {error, Reason}
    end.

-spec health() -> rpc_result().
health() ->
    case get_version() of
        {ok, Version} ->
            case get_height() of
                {ok, Height} ->
                    {ok, #{version => Version, height => Height}};
                {error, Reason} ->
                    {error, #{type => wallet_height_failed, reason => Reason}}
            end;
        {error, Reason} ->
            {error, #{type => wallet_version_failed, reason => Reason}}
    end.

-spec get_version() -> rpc_result().
get_version() ->
    rpc(<<"get_version">>, #{}).

-spec get_height() -> rpc_result().
get_height() ->
    rpc(<<"get_height">>, #{}).

-spec refresh() -> rpc_result().
refresh() ->
    rpc(<<"refresh">>, #{}).

-spec store() -> rpc_result().
store() ->
    rpc(<<"store">>, #{}).

-spec get_balance() -> rpc_result().
get_balance() ->
    AccountIndex = application:get_env(damage, monero_account_index, 0),
    rpc(<<"get_balance">>, #{account_index => AccountIndex, strict => true}).

-spec create_address(binary() | list()) -> rpc_result().
create_address(Label) ->
    AccountIndex = application:get_env(damage, monero_account_index, 0),
    create_address(AccountIndex, Label).

-spec create_address(non_neg_integer(), binary() | list()) -> rpc_result().
create_address(AccountIndex, Label) when is_integer(AccountIndex), AccountIndex >= 0 ->
    rpc(<<"create_address">>, #{
        account_index => AccountIndex,
        label => to_binary(Label),
        count => 1
    }).

-spec create_invoice(binary() | list(), term()) -> {ok, invoice()} | {error, term()}.
create_invoice(Label0, AmountXmr0) ->
    Label = to_binary(Label0),
    AccountIndex = application:get_env(damage, monero_account_index, 0),
    case xmr_to_atomic(AmountXmr0) of
        {ok, AmountAtomic} when AmountAtomic > 0 ->
            case create_address(AccountIndex, Label) of
                {ok, AddressResult} ->
                    case
                        invoice_from_address_result(
                            AddressResult,
                            AccountIndex,
                            Label,
                            AmountAtomic
                        )
                    of
                        {ok, Invoice} ->
                            maybe_store_invoice(Invoice);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, #{type => create_address_failed, reason => Reason}}
            end;
        {ok, _ZeroOrNegative} ->
            {error, amount_must_be_greater_than_zero};
        {error, Reason} ->
            {error, #{type => invalid_xmr_amount, reason => Reason}}
    end.

-spec get_transfers(non_neg_integer(), non_neg_integer()) -> rpc_result().
get_transfers(AccountIndex, SubaddressIndex) when
    is_integer(AccountIndex),
    AccountIndex >= 0,
    is_integer(SubaddressIndex),
    SubaddressIndex >= 0
->
    rpc(<<"get_transfers">>, #{
        'in' => true,
        out => false,
        pending => false,
        failed => false,
        pool => true,
        account_index => AccountIndex,
        subaddr_indices => [SubaddressIndex]
    }).

-spec invoice_status(invoice(), non_neg_integer()) -> rpc_result().
invoice_status(Invoice, MinConfirmations) when
    is_map(Invoice),
    is_integer(MinConfirmations),
    MinConfirmations >= 0
->
    case invoice_fields(Invoice) of
        {ok, AccountIndex, SubaddressIndex, ExpectedAtomic} ->
            case get_transfers(AccountIndex, SubaddressIndex) of
                {ok, TransfersResult} ->
                    Summary = summarize_transfers(
                        TransfersResult,
                        ExpectedAtomic,
                        MinConfirmations
                    ),
                    {ok, maps:merge(Invoice, Summary)};
                {error, Reason} ->
                    {error, #{type => get_transfers_failed, reason => Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec wait_for_invoice(invoice(), non_neg_integer(), non_neg_integer()) -> rpc_result().
wait_for_invoice(Invoice, MinConfirmations, TimeoutSeconds) when
    is_map(Invoice),
    is_integer(MinConfirmations),
    MinConfirmations >= 0,
    is_integer(TimeoutSeconds),
    TimeoutSeconds >= 0
->
    Deadline = erlang:monotonic_time(millisecond) + (TimeoutSeconds * 1000),
    PollInterval = poll_interval_ms(),
    wait_for_invoice_loop(Invoice, MinConfirmations, Deadline, PollInterval).

%% Spending is deliberately off by default. Enable only on a dedicated wallet:
%%   {monero_allow_spend, true}
-spec transfer(binary() | list(), term(), non_neg_integer()) -> rpc_result().
transfer(Address0, AmountXmr0, Priority) when
    is_integer(Priority),
    Priority >= 0,
    Priority =< 4
->
    case application:get_env(damage, monero_allow_spend, false) of
        true ->
            case xmr_to_atomic(AmountXmr0) of
                {ok, AmountAtomic} when AmountAtomic > 0 ->
                    AccountIndex = application:get_env(damage, monero_account_index, 0),
                    DoNotRelay = application:get_env(damage, monero_do_not_relay, false),
                    rpc(<<"transfer">>, #{
                        destinations => [
                            #{
                                amount => AmountAtomic,
                                address => to_binary(Address0)
                            }
                        ],
                        account_index => AccountIndex,
                        priority => Priority,
                        unlock_time => 0,
                        get_tx_key => false,
                        get_tx_hex => false,
                        get_tx_metadata => false,
                        do_not_relay => DoNotRelay
                    });
                {ok, _ZeroOrNegative} ->
                    {error, amount_must_be_greater_than_zero};
                {error, Reason} ->
                    {error, #{type => invalid_xmr_amount, reason => Reason}}
            end;
        _ ->
            {error, monero_spending_disabled}
    end.

%% ------------------------------------------------------------------
%% Pure amount and payment-summary helpers
%% ------------------------------------------------------------------

-spec xmr_to_atomic(term()) -> {ok, non_neg_integer()} | {error, term()}.
xmr_to_atomic(Value) when is_integer(Value), Value >= 0 ->
    {ok, Value * ?ATOMIC_UNITS_PER_XMR};
xmr_to_atomic(Value) when is_integer(Value), Value < 0 ->
    {error, negative_amount};
xmr_to_atomic(Value) when is_float(Value) ->
    {error, floating_point_amount_not_supported};
xmr_to_atomic(Value) when is_binary(Value) ->
    xmr_to_atomic(binary_to_list(Value));
xmr_to_atomic(Value) when is_list(Value) ->
    parse_xmr_decimal(string:trim(Value));
xmr_to_atomic(Value) ->
    {error, {unsupported_amount_type, Value}}.

-spec atomic_to_xmr(non_neg_integer()) -> binary().
atomic_to_xmr(Atomic) when is_integer(Atomic), Atomic >= 0 ->
    Whole = Atomic div ?ATOMIC_UNITS_PER_XMR,
    Fraction = Atomic rem ?ATOMIC_UNITS_PER_XMR,
    case Fraction of
        0 ->
            integer_to_binary(Whole);
        _ ->
            FractionDigits = integer_to_list(Fraction),
            FractionPadded =
                lists:duplicate(12 - length(FractionDigits), $0) ++ FractionDigits,
            FractionTrimmed = trim_trailing_zeros(FractionPadded),
            iolist_to_binary([integer_to_binary(Whole), $., FractionTrimmed])
    end.

-spec summarize_transfers(map(), pos_integer(), non_neg_integer()) -> map().
summarize_transfers(Result, ExpectedAtomic, MinConfirmations) when
    is_map(Result),
    is_integer(ExpectedAtomic),
    ExpectedAtomic > 0,
    is_integer(MinConfirmations),
    MinConfirmations >= 0
->
    Confirmed0 = maps:get('in', Result, []),
    Pool0 = maps:get(pool, Result, []),
    Tagged =
        [{pool, T} || T <- ensure_list(Pool0)] ++
            [{confirmed, T} || T <- ensure_list(Confirmed0)],
    %% A transaction can briefly appear in both pool and confirmed results.
    %% Insertion order makes the confirmed copy replace the pool copy.
    Unique = lists:foldl(
        fun
            ({Source, Transfer}, Acc) when is_map(Transfer) ->
                maps:put(transfer_key(Transfer), {Source, Transfer}, Acc);
            (_MalformedTransfer, Acc) ->
                Acc
        end,
        #{},
        Tagged
    ),
    Transfers = maps:values(Unique),
    Accepted = [
        {Source, Transfer}
     || {Source, Transfer} <- Transfers,
        accepted_transfer(Transfer)
    ],
    ReceivedAtomic = lists:sum([
        maps:get(amount, Transfer, 0)
     || {_Source, Transfer} <- Accepted
    ]),
    ConfirmedCandidates = [
        Transfer
     || {confirmed, Transfer} <- Accepted,
        maps:get(locked, Transfer, false) =/= true
    ],
    ConfirmedTransfers = [
        Transfer
     || Transfer <- ConfirmedCandidates,
        maps:get(confirmations, Transfer, 0) >= MinConfirmations
    ],
    ConfirmedAtomic = lists:sum([
        maps:get(amount, Transfer, 0)
     || Transfer <- ConfirmedTransfers
    ]),
    Paid = ConfirmedAtomic >= ExpectedAtomic,
    Seen = ReceivedAtomic >= ExpectedAtomic,
    State = payment_state(Paid, Seen, ReceivedAtomic),
    Confirmations = invoice_confirmations(ConfirmedCandidates, ExpectedAtomic),
    #{
        payment_state => State,
        paid => Paid,
        seen => Seen,
        expected_atomic => ExpectedAtomic,
        expected_xmr => atomic_to_xmr(ExpectedAtomic),
        received_atomic => ReceivedAtomic,
        received_xmr => atomic_to_xmr(ReceivedAtomic),
        confirmed_atomic => ConfirmedAtomic,
        confirmed_xmr => atomic_to_xmr(ConfirmedAtomic),
        minimum_confirmations => MinConfirmations,
        confirmations => Confirmations,
        transactions => [public_transfer(Source, Transfer) || {Source, Transfer} <- Accepted]
    }.

%% ------------------------------------------------------------------
%% Internal HTTP implementation
%% ------------------------------------------------------------------

rpc_config() ->
    Host0 = application:get_env(damage, monero_wallet_rpc_host, ?DEFAULT_WALLET_RPC_HOST),
    Host = normalize_host(Host0),
    Port = application:get_env(damage, monero_wallet_rpc_port, ?DEFAULT_WALLET_RPC_PORT),
    Timeout = application:get_env(damage, monero_wallet_rpc_timeout, ?DEFAULT_RPC_TIMEOUT),
    AllowRemote = application:get_env(damage, monero_wallet_rpc_allow_remote, false),
    case
        {
            valid_port(Port),
            valid_timeout(Timeout),
            is_loopback_host(Host) orelse AllowRemote
        }
    of
        {true, true, true} ->
            {ok, #{host => Host, port => Port, opts => rpc_open_opts(Timeout)}};
        {false, _, _} ->
            {error, invalid_monero_wallet_rpc_port};
        {_, false, _} ->
            {error, invalid_monero_wallet_rpc_timeout};
        {_, _, false} ->
            {error, remote_monero_wallet_rpc_refused}
    end.

rpc_open_opts(Timeout) ->
    Base = #{connect_timeout => Timeout},
    case application:get_env(damage, monero_wallet_rpc_transport, tcp) of
        tls ->
            Base#{transport => tls, tls_opts => [{verify, verify_peer}]};
        ssl ->
            Base#{transport => tls, tls_opts => [{verify, verify_peer}]};
        _ ->
            Base#{transport => tcp}
    end.

do_rpc(Host, Port, Opts, Payload) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_RPC_TIMEOUT),
    case gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, Timeout) of
                    {ok, _Protocol} ->
                        post_rpc(ConnPid, Payload, Timeout);
                    {error, Reason} ->
                        {error, #{type => connection_failed, reason => Reason}}
                end
            after
                gun:close(ConnPid)
            end;
        {error, Reason} ->
            {error, #{type => open_failed, reason => Reason}}
    end.

post_rpc(ConnPid, Payload, Timeout) ->
    Body = jsx:encode(Payload),
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>}
    ],
    ?LOG_DEBUG("Monero wallet RPC ~s", [maps:get(method, Payload)]),
    StreamRef = gun:post(ConnPid, <<"/json_rpc">>, Headers, Body, #{}),
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, fin, Status, ResponseHeaders} ->
            decode_rpc_response(Status, ResponseHeaders, <<>>);
        {response, nofin, Status, ResponseHeaders} ->
            case gun:await_body(ConnPid, StreamRef, Timeout) of
                {ok, ResponseBody} ->
                    decode_rpc_response(Status, ResponseHeaders, ResponseBody);
                {error, Reason} ->
                    {error, #{type => body_read_failed, reason => Reason}}
            end;
        {error, Reason} ->
            {error, #{type => request_failed, reason => Reason}};
        Other ->
            {error, #{type => unexpected_gun_response, response => Other}}
    end.

decode_rpc_response(Status, _Headers, Body) when Status >= 200, Status < 300 ->
    try jsx:decode(Body, [{labels, atom}, return_maps]) of
        #{result := Result, error := null} ->
            {ok, Result};
        #{error := Error} when Error =/= null ->
            {error, Error};
        #{result := Result} ->
            {ok, Result};
        Other ->
            {error, #{type => unexpected_rpc_json, body => Other}}
    catch
        _Class:_Reason ->
            {error, #{type => invalid_json, body => Body}}
    end;
decode_rpc_response(401, _Headers, _Body) ->
    {error, #{
        type => unauthorized,
        hint => <<"This loopback client expects monero-wallet-rpc --disable-rpc-login">>
    }};
decode_rpc_response(Status, _Headers, Body) ->
    ErrorBody =
        try jsx:decode(Body, [{labels, atom}, return_maps]) of
            Decoded -> Decoded
        catch
            _Class:_Reason -> Body
        end,
    {error, #{type => http_error, status => Status, body => ErrorBody}}.

%% ------------------------------------------------------------------
%% Internal invoice helpers
%% ------------------------------------------------------------------

invoice_from_address_result(Result, AccountIndex, Label, AmountAtomic) ->
    case {maps:find(address, Result), maps:find(address_index, Result)} of
        {{ok, Address}, {ok, AddressIndex}} when
            is_binary(Address),
            is_integer(AddressIndex),
            AddressIndex >= 0
        ->
            {ok, #{
                address => Address,
                account_index => AccountIndex,
                subaddress_index => AddressIndex,
                amount_atomic => AmountAtomic,
                amount_xmr => atomic_to_xmr(AmountAtomic),
                label => Label,
                created_at => erlang:system_time(second)
            }};
        _ ->
            {error, #{type => invalid_create_address_response, response => Result}}
    end.

maybe_store_invoice(Invoice) ->
    case application:get_env(damage, monero_store_after_invoice, true) of
        true ->
            case store() of
                {ok, _} ->
                    {ok, Invoice};
                {error, Reason} ->
                    {error, #{type => wallet_store_failed, invoice => Invoice, reason => Reason}}
            end;
        _ ->
            {ok, Invoice}
    end.

invoice_fields(Invoice) ->
    case
        {
            maps:find(account_index, Invoice),
            maps:find(subaddress_index, Invoice),
            maps:find(amount_atomic, Invoice)
        }
    of
        {{ok, AccountIndex}, {ok, SubaddressIndex}, {ok, ExpectedAtomic}} when
            is_integer(AccountIndex),
            AccountIndex >= 0,
            is_integer(SubaddressIndex),
            SubaddressIndex >= 0,
            is_integer(ExpectedAtomic),
            ExpectedAtomic > 0
        ->
            {ok, AccountIndex, SubaddressIndex, ExpectedAtomic};
        _ ->
            {error, invalid_monero_invoice}
    end.

accepted_transfer(Transfer) ->
    Amount = maps:get(amount, Transfer, 0),
    UnlockTime = maps:get(unlock_time, Transfer, 0),
    DoubleSpendSeen = maps:get(double_spend_seen, Transfer, false),
    is_integer(Amount) andalso
        Amount > 0 andalso
        UnlockTime =:= 0 andalso
        DoubleSpendSeen =/= true.

transfer_key(Transfer) ->
    TxId = maps:get(txid, Transfer, maps:get(tx_hash, Transfer, undefined)),
    Minor = subaddress_minor(Transfer),
    case TxId of
        undefined ->
            {
                output,
                maps:get(global_index, Transfer, undefined),
                maps:get(amount, Transfer, 0),
                Minor
            };
        _ ->
            %% get_transfers represents an incoming transfer per transaction.
            %% Pool entries do not have a global index, so use the transaction
            %% identity to let a confirmed copy replace its pool predecessor.
            {transaction, TxId, Minor}
    end.

subaddress_minor(Transfer) ->
    case maps:get(subaddr_index, Transfer, undefined) of
        #{minor := Minor} -> Minor;
        Minor when is_integer(Minor) -> Minor;
        _ -> undefined
    end.

public_transfer(Source, Transfer) ->
    #{
        source => Source,
        txid => maps:get(txid, Transfer, maps:get(tx_hash, Transfer, undefined)),
        amount_atomic => maps:get(amount, Transfer, 0),
        amount_xmr => atomic_to_xmr(maps:get(amount, Transfer, 0)),
        confirmations => maps:get(confirmations, Transfer, 0),
        block_height => maps:get(height, Transfer, maps:get(block_height, Transfer, 0)),
        unlock_time => maps:get(unlock_time, Transfer, 0),
        locked => maps:get(locked, Transfer, false),
        double_spend_seen => maps:get(double_spend_seen, Transfer, false),
        subaddress_index => subaddress_minor(Transfer)
    }.

invoice_confirmations([], _ExpectedAtomic) ->
    0;
invoice_confirmations(Transfers, ExpectedAtomic) ->
    Sorted = lists:sort(
        fun(Left, Right) ->
            maps:get(confirmations, Left, 0) > maps:get(confirmations, Right, 0)
        end,
        Transfers
    ),
    invoice_confirmations(Sorted, ExpectedAtomic, 0).

invoice_confirmations([Transfer | Rest], ExpectedAtomic, AccumulatedAtomic) ->
    NewAccumulatedAtomic = AccumulatedAtomic + maps:get(amount, Transfer, 0),
    Confirmations = maps:get(confirmations, Transfer, 0),
    case {NewAccumulatedAtomic >= ExpectedAtomic, Rest} of
        {true, _} ->
            Confirmations;
        {false, []} ->
            Confirmations;
        {false, _} ->
            invoice_confirmations(Rest, ExpectedAtomic, NewAccumulatedAtomic)
    end.

payment_state(true, _Seen, _ReceivedAtomic) -> paid;
payment_state(false, true, _ReceivedAtomic) -> confirming;
payment_state(false, false, ReceivedAtomic) when ReceivedAtomic > 0 -> partial;
payment_state(false, false, _ReceivedAtomic) -> unpaid.

wait_for_invoice_loop(Invoice, MinConfirmations, Deadline, PollInterval) ->
    case invoice_status(Invoice, MinConfirmations) of
        {ok, #{paid := true} = Status} ->
            {ok, Status};
        {ok, Status} ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    {error, #{type => invoice_timeout, status => Status}};
                false ->
                    timer:sleep(erlang:min(PollInterval, Remaining)),
                    wait_for_invoice_loop(
                        Invoice,
                        MinConfirmations,
                        Deadline,
                        PollInterval
                    )
            end;
        {error, Reason} ->
            {error, Reason}
    end.

poll_interval_ms() ->
    Configured = application:get_env(damage, monero_poll_interval_ms, 10000),
    case is_integer(Configured) andalso Configured >= 1000 of
        true -> Configured;
        false -> 10000
    end.

%% ------------------------------------------------------------------
%% Internal amount helpers
%% ------------------------------------------------------------------

parse_xmr_decimal([]) ->
    {error, empty_amount};
parse_xmr_decimal([$- | _]) ->
    {error, negative_amount};
parse_xmr_decimal(String) ->
    case string:split(String, ".", all) of
        [Whole] ->
            decimal_parts_to_atomic(Whole, "");
        [Whole, Fraction] ->
            decimal_parts_to_atomic(Whole, Fraction);
        _ ->
            {error, invalid_decimal}
    end.

decimal_parts_to_atomic(Whole, Fraction) ->
    case
        {
            Whole =/= [],
            all_digits(Whole),
            all_digits(Fraction),
            length(Fraction) =< 12
        }
    of
        {true, true, true, true} ->
            FractionPadded = Fraction ++ lists:duplicate(12 - length(Fraction), $0),
            WholeAtomic = list_to_integer(Whole) * ?ATOMIC_UNITS_PER_XMR,
            FractionAtomic =
                case FractionPadded of
                    [] -> 0;
                    _ -> list_to_integer(FractionPadded)
                end,
            {ok, WholeAtomic + FractionAtomic};
        {_, _, _, false} ->
            {error, too_many_decimal_places};
        _ ->
            {error, invalid_decimal}
    end.

all_digits([]) -> true;
all_digits([C | Rest]) when C >= $0, C =< $9 -> all_digits(Rest);
all_digits(_) -> false.

trim_trailing_zeros(Value) ->
    lists:reverse(trim_leading_zeros(lists:reverse(Value))).

trim_leading_zeros([$0 | Rest]) -> trim_leading_zeros(Rest);
trim_leading_zeros(Rest) -> Rest.

ensure_list(Value) when is_list(Value) -> Value;
ensure_list(_) -> [].

valid_port(Port) -> is_integer(Port) andalso Port > 0 andalso Port =< 65535.
valid_timeout(Timeout) -> is_integer(Timeout) andalso Timeout > 0.

is_loopback_host("127.0.0.1") -> true;
is_loopback_host("localhost") -> true;
is_loopback_host("::1") -> true;
is_loopback_host({127, 0, 0, 1}) -> true;
is_loopback_host({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback_host(_) -> false.

normalize_host(Host) when is_binary(Host) -> binary_to_list(Host);
normalize_host(Host) -> Host.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_float(Value) -> float_to_binary(Value, [short]);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).
