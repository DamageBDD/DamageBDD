%%%-------------------------------------------------------------------
%%% Durable single-checkout guard for build release NFT sales.
%%%
%%% One token may have at most one active Lightning checkout. The state is
%%% persisted in DETS so a node restart cannot silently open a second payable
%%% invoice for the same NFT.
%%%-------------------------------------------------------------------
-module(damage_release_nft_checkout_store).

-export([get/1, reserve/4, reserve/5, attach_invoice/2, mark_status/2, put_fields/2]).

-define(TABLE, damage_release_nft_checkouts).

get(Key) ->
    with_lock(Key, fun() -> lookup(Key) end).

reserve(Key, Buyer, CheckoutId, Label) ->
    reserve(Key, Buyer, CheckoutId, Label, #{}).

reserve(Key, Buyer, CheckoutId, Label, Fields) when is_map(Fields) ->
    with_lock(Key, fun() ->
        case lookup(Key) of
            not_found ->
                Record = maps:merge(Fields, #{
                    key => Key,
                    buyer => Buyer,
                    checkout_id => CheckoutId,
                    label => Label,
                    status => reserved,
                    created_at => erlang:system_time(second)
                }),
                case persist_record(Key, Record) of
                    ok -> {ok, new, Record};
                    {error, _} = Error -> Error
                end;
            {ok, #{status := Status} = Existing} when Status =:= expired; Status =:= cancelled ->
                %% Preserve durable publication metadata across invoice expiry so
                %% settlement can still replace the Nostr listing after restart.
                Carry = maps:with([listing], Existing),
                Record = maps:merge(maps:merge(Carry, Fields), #{
                    key => Key,
                    buyer => Buyer,
                    checkout_id => CheckoutId,
                    label => Label,
                    status => reserved,
                    created_at => erlang:system_time(second)
                }),
                case persist_record(Key, Record) of
                    ok -> {ok, new, Record};
                    {error, _} = Error -> Error
                end;
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

put_fields(Key, Fields) when is_map(Fields) ->
    update(Key, fun(Record) ->
        maps:merge(Record, Fields#{updated_at => erlang:system_time(second)})
    end).

update(Key, Fun) ->
    with_lock(Key, fun() ->
        case lookup(Key) of
            {ok, Record} ->
                Updated = Fun(Record),
                case persist_record(Key, Updated) of
                    ok -> {ok, Updated};
                    {error, _} = Error -> Error
                end;
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
    %% global:trans/2 expects {ResourceId, LockRequesterId}. Keep the token
    %% key in the resource id and the calling process in the requester id so
    %% unrelated NFTs do not serialize on one global lock.
    LockId = {{?MODULE, Key}, self()},
    case global:trans(LockId, fun() ->
        case ensure_open() of
            ok -> Fun();
            {error, _} = Error -> Error
        end
    end) of
        aborted -> {error, checkout_store_lock_aborted};
        {aborted, Reason} -> {error, {checkout_store_lock_failed, Reason}};
        Result -> Result
    end.

persist_record(Key, Record) ->
    case dets:insert(?TABLE, {Key, Record}) of
        ok ->
            %% Checkout state protects real payments. Force the update to disk
            %% before returning success instead of relying on DETS close/flush.
            dets:sync(?TABLE);
        {error, _} = Error ->
            Error
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
