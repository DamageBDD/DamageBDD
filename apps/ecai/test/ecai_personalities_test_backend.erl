%% Deterministic, in-memory remote services for coordinator lifecycle tests.
%% This module belongs only on the test code path, never a release code path.
-module(ecai_personalities_test_backend).
-export([reset/0, put/2, get/2, calls/1, invoice/1, settle/1,
         ready/0, ready/1, ensure_invoice/1, lookup_invoice/1,
         lookup/1, mint/1, validate_recipient/1, validate_config/1]).

-define(TABLE, ecai_personalities_test_remote).

reset() ->
    case ets:whereis(?TABLE) of
        undefined -> ets:new(?TABLE, [named_table, public, ordered_set]);
        _ -> ets:delete_all_objects(?TABLE)
    end,
    ok.

put(Key, Value) -> ets:insert(?TABLE, {{setting, Key}, Value}), ok.
get(Key, Default) ->
    case ets:lookup(?TABLE, {setting, Key}) of
        [{_, Value}] -> Value;
        [] -> Default
    end.

calls(Operation) ->
    [Argument || {{call, _, Op}, Argument} <- ets:tab2list(?TABLE),
                 Op =:= Operation].

ready() -> run(ready_lightning, #{}, fun() -> {ok, lightning_identity()} end).
ready(Product) -> run(ready_nft, Product, fun() -> ok end).

%% The production adapter's checksum decoder is an external AE dependency.
%% This boundary fixture accepts one known valid account and rejects all others.
validate_recipient(<<"ak_11111111111111111111111111111111273Yts">>) -> ok;
validate_recipient(_) -> {error, invalid_recipient}.

validate_config(Config) when is_map(Config) -> ok;
validate_config(_) -> {error, invalid_config}.

ensure_invoice(Order) ->
    run(ensure_invoice, Order, fun() ->
        Key = {invoice, maps:get(id, Order)},
        case ets:lookup(?TABLE, Key) of
            [{_, Invoice}] -> {ok, Invoice};
            [] ->
                Id = maps:get(id, Order),
                Invoice = maps:merge(lightning_identity(), #{
                    label => maps:get(label, Order),
                    payment_hash => hex(crypto:hash(sha256, Id)),
                    bolt11 => <<"lnbcrt1", (hex(crypto:hash(sha256, Id)))/binary>>,
                    amount_msat => maps:get(price_sats, Order) * 1000,
                    amount_received_msat => 0,
                    status => unpaid,
                    expires_at => erlang:system_time(second) + 900
                }),
                ets:insert(?TABLE, {Key, Invoice}),
                {ok, Invoice}
        end
    end).

lookup_invoice(Order) ->
    run(lookup_invoice, Order, fun() -> invoice(maps:get(id, Order)) end).

invoice(Id) ->
    case ets:lookup(?TABLE, {invoice, Id}) of
        [{_, Invoice}] -> {ok, Invoice};
        [] -> {error, invoice_not_found}
    end.

settle(Id) ->
    {ok, Invoice} = invoice(Id),
    Paid = Invoice#{status => paid,
                    amount_received_msat => maps:get(amount_msat, Invoice)},
    ets:insert(?TABLE, {{invoice, Id}, Paid}),
    ok.

lookup(Order) ->
    run(lookup, Order, fun() ->
        case ets:lookup(?TABLE, {mint, maps:get(id, Order)}) of
            [{_, Receipt}] -> {ok, Receipt};
            [] -> {ok, not_found}
        end
    end).

mint(Order) ->
    run(mint, Order, fun() ->
        Id = maps:get(id, Order),
        Key = {mint, Id},
        case ets:lookup(?TABLE, Key) of
            [{_, Receipt}] -> {ok, Receipt};
            [] ->
                Receipt = maps:merge(nft_identity(), #{
                    order_id => Id,
                    token_id => 1 + length(calls(mint)),
                    recipient => maps:get(recipient, Order),
                    package_sha256 => maps:get(package_sha256, Order, <<>>),
                    manifest_uri => maps:get(manifest_uri, Order, <<>>),
                    tx_hash => <<"th_test_confirmed_transaction">>,
                    confirmed => true
                }),
                ets:insert(?TABLE, {Key, Receipt}),
                case get(after_mint, undefined) of
                    undefined -> {ok, Receipt};
                    Hook -> Hook(Order, Receipt)
                end
        end
    end).

run(Operation, Argument, Default) ->
    ets:insert(?TABLE, {{call, erlang:unique_integer([monotonic, positive]), Operation},
                       Argument}),
    case get(Operation, undefined) of
        undefined -> Default();
        Override when is_function(Override, 1) -> Override(Argument);
        Result -> Result
    end.

lightning_identity() ->
    #{treasury_node => binary:copy(<<"a">>, 66), network => <<"regtest">>}.

nft_identity() ->
    #{contract_id => <<"ct_test_personalities_contract">>, network => <<"ae_dev">>}.

hex(Bin) ->
    << <<(nibble(B bsr 4)), (nibble(B band 15))>> || <<B>> <= Bin >>.
nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + N - 10.
