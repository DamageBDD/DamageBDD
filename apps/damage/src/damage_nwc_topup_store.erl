-module(damage_nwc_topup_store).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([
    start/0,
    get/1,
    get_by_label/1,
    put/1,
    update/2,
    update_by_label/2,
    mark_settled/2,
    delete/1,
    invalidate/1
]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, ?MODULE).
-define(LABEL_TABLE, damage_nwc_topup_store_by_label).

start() ->
    ensure_tables(),
    ok.

-spec get(binary() | list()) -> {ok, map()} | {error, not_found}.
get(PaymentHash0) ->
    ensure_tables(),
    PaymentHash = to_bin(PaymentHash0),
    case ets:lookup(?TABLE, PaymentHash) of
        [{PaymentHash, Topup}] when is_map(Topup) ->
            {ok, Topup};
        [] ->
            {error, not_found}
    end.

-spec get_by_label(binary() | list()) -> {ok, map()} | {error, not_found}.
get_by_label(Label0) ->
    ensure_tables(),
    Label = to_bin(Label0),
    case ets:lookup(?LABEL_TABLE, Label) of
        [{Label, PaymentHash}] ->
            get(PaymentHash);
        [] ->
            {error, not_found}
    end.

-spec put(map()) -> ok.
put(Topup0) when is_map(Topup0) ->
    ensure_tables(),
    Topup = normalize_topup(Topup0),
    PaymentHash = maps:get(payment_hash, Topup),
    Label = maps:get(label, Topup, undefined),
    true = ets:insert(?TABLE, {PaymentHash, Topup}),
    maybe_put_label(Label, PaymentHash),
    ok.

-spec update(binary() | list(), map() | fun((map()) -> map())) ->
    {ok, map()} | {error, not_found}.
update(PaymentHash0, PatchOrFun) ->
    ensure_tables(),
    PaymentHash = to_bin(PaymentHash0),
    case get(PaymentHash) of
        {ok, Topup0} ->
            Topup1 =
                case PatchOrFun of
                    Fun when is_function(Fun, 1) ->
                        normalize_topup(Fun(Topup0));
                    Patch when is_map(Patch) ->
                        normalize_topup(maps:merge(Topup0, normalize_topup(Patch)))
                end,
            Label0 = maps:get(label, Topup0, undefined),
            Label1 = maps:get(label, Topup1, undefined),
            true = ets:insert(?TABLE, {PaymentHash, Topup1}),
            maybe_reindex_label(Label0, Label1, PaymentHash),
            {ok, Topup1};
        {error, not_found} ->
            {error, not_found}
    end.

-spec update_by_label(binary() | list(), map() | fun((map()) -> map())) ->
    {ok, map()} | {error, not_found}.
update_by_label(Label0, PatchOrFun) ->
    ensure_tables(),
    Label = to_bin(Label0),
    case ets:lookup(?LABEL_TABLE, Label) of
        [{Label, PaymentHash}] ->
            update(PaymentHash, PatchOrFun);
        [] ->
            {error, not_found}
    end.

-spec mark_settled(binary() | list(), integer()) -> ok | {error, not_found}.
mark_settled(PaymentHash0, SettledAt) when is_integer(SettledAt) ->
    case
        update(PaymentHash0, #{
            status => settled,
            settled_at => SettledAt
        })
    of
        {ok, _} ->
            ok;
        {error, not_found} = Error ->
            Error
    end.

-spec delete(binary() | list()) -> ok.
delete(PaymentHash0) ->
    ensure_tables(),
    PaymentHash = to_bin(PaymentHash0),
    case ets:lookup(?TABLE, PaymentHash) of
        [{PaymentHash, Topup}] ->
            Label = maps:get(label, Topup, undefined),
            ets:delete(?TABLE, PaymentHash),
            maybe_delete_label(Label),
            ok;
        [] ->
            ok
    end.

invalidate(PaymentHash) ->
    delete(PaymentHash).

ensure_tables() ->
    ensure_table(?TABLE),
    ensure_table(?LABEL_TABLE),
    ok.

ensure_table(Name) ->
    case ets:info(Name) of
        undefined ->
            _ = ets:new(Name, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

normalize_topup(Map) when is_map(Map) ->
    maps:from_list([{normalize_key(K), normalize_value(V)} || {K, V} <- maps:to_list(Map)]).

normalize_key(K) when is_atom(K) ->
    K;
normalize_key(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) of
        A -> A
    catch
        _:_ -> binary_to_atom(K, utf8)
    end;
normalize_key(K) when is_list(K) ->
    normalize_key(unicode:characters_to_binary(K));
normalize_key(K) ->
    K.

normalize_value(V) when is_map(V) ->
    normalize_topup(V);
normalize_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [normalize_value(X) || X <- V]
    end;
normalize_value(V) ->
    V.

maybe_put_label(undefined, _PaymentHash) ->
    ok;
maybe_put_label(<<>>, _PaymentHash) ->
    ok;
maybe_put_label(Label0, PaymentHash) ->
    Label = to_bin(Label0),
    true = ets:insert(?LABEL_TABLE, {Label, PaymentHash}),
    ok.

maybe_delete_label(undefined) ->
    ok;
maybe_delete_label(<<>>) ->
    ok;
maybe_delete_label(Label0) ->
    Label = to_bin(Label0),
    ets:delete(?LABEL_TABLE, Label),
    ok.

maybe_reindex_label(Label, Label, _PaymentHash) ->
    ok;
maybe_reindex_label(OldLabel, NewLabel, PaymentHash) ->
    maybe_delete_label(OldLabel),
    maybe_put_label(NewLabel, PaymentHash).

to_bin(V) when is_binary(V) ->
    V;
to_bin(V) when is_list(V) ->
    unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
to_bin(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).
