%%%-------------------------------------------------------------------
%%% Durable single-checkout guard for build release NFT sales.
%%%
%%% One token may have at most one active Lightning checkout. The state is
%%% persisted in DETS so a node restart cannot silently open a second payable
%%% invoice for the same NFT.
%%%-------------------------------------------------------------------
-module(damage_release_nft_checkout_store).

-export([get/1, reserve/4, attach_invoice/2, mark_status/2]).

-define(TABLE, damage_release_nft_checkouts).

get(Key) ->
    with_lock(Key, fun() -> lookup(Key) end).

reserve(Key, Buyer, CheckoutId, Label) ->
    with_lock(Key, fun() ->
        case lookup(Key) of
            not_found ->
                Record = #{
                    key => Key,
                    buyer => Buyer,
                    checkout_id => CheckoutId,
                    label => Label,
                    status => reserved,
                    created_at => erlang:system_time(second)
                },
                ok = dets:insert(?TABLE, {Key, Record}),
                {ok, new, Record};
            {ok, #{status := Status} = _Existing} when Status =:= expired; Status =:= cancelled ->
                Record = #{
                    key => Key,
                    buyer => Buyer,
                    checkout_id => CheckoutId,
                    label => Label,
                    status => reserved,
                    created_at => erlang:system_time(second)
                },
                ok = dets:insert(?TABLE, {Key, Record}),
                {ok, new, Record};
            {ok, Existing} ->
                {ok, existing, Existing};
            {error, _} = Error ->
                Error
        end
    end).

attach_invoice(Key, InvoiceFields) when is_map(InvoiceFields) ->
    update(Key, fun(Record) -> maps:merge(Record, InvoiceFields#{status => pending}) end).

mark_status(Key, Status) ->
    update(Key, fun(Record) -> Record#{status => Status, updated_at => erlang:system_time(second)} end).

update(Key, Fun) ->
    with_lock(Key, fun() ->
        case lookup(Key) of
            {ok, Record} ->
                Updated = Fun(Record),
                ok = dets:insert(?TABLE, {Key, Updated}),
                {ok, Updated};
            not_found ->
                {error, checkout_not_found};
            {error, _} = Error ->
                Error
        end
    end).

lookup(Key) ->
    case dets:lookup(?TABLE, Key) of
        [] -> not_found;
        [{Key, Record}] when is_map(Record) -> {ok, Record};
        Other -> {error, {invalid_checkout_store_record, Other}}
    end.

with_lock(Key, Fun) ->
    case global:trans({?MODULE, Key}, fun() ->
        case ensure_open() of
            ok -> Fun();
            {error, _} = Error -> Error
        end
    end) of
        {aborted, Reason} -> {error, {checkout_store_lock_failed, Reason}};
        Result -> Result
    end.

ensure_open() ->
    case dets:info(?TABLE) of
        undefined -> open_table();
        _ -> ok
    end.

open_table() ->
    Path = checkout_store_path(),
    ok = filelib:ensure_dir(Path),
    case dets:open_file(?TABLE, [{file, Path}, {type, set}, {keypos, 1}]) of
        {ok, ?TABLE} -> ok;
        {error, {already_started, ?TABLE}} -> ok;
        {error, Reason} -> {error, {checkout_store_open_failed, Path, Reason}}
    end.

checkout_store_path() ->
    case application:get_env(damage, build_release_nft_checkout_store) of
        {ok, Path} when is_binary(Path) -> binary_to_list(Path);
        {ok, Path} when is_list(Path) -> Path;
        _ -> "damage_release_nft_checkouts.dets"
    end.
