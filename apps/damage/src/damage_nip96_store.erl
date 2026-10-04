%%%-------------------------------------------------------------------
%%% Durable content/ownership metadata for NIP-96 and Blossom IPFS surfaces.
%%%
%%% Objects are keyed by original SHA-256 while Kubo stores immutable bytes by
%%% CID. Legacy NIP-96 owner keys are preserved for on-disk compatibility.
%%% Additional protocol surfaces use source-scoped owner keys so deleting a
%%% Blossom claim cannot silently delete a NIP-96 claim (and vice versa).
%%%-------------------------------------------------------------------
-module(damage_nip96_store).
-behaviour(gen_server).

-export([
    start_link/1,
    claim/4,
    claim_source/5,
    lookup/1,
    release/2,
    release_source/3,
    list/3,
    list_cursor/4,
    status/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(MAX_OWNER_META_BYTES, 65536).
-define(MAX_OBJECT_META_BYTES, 65536).
-define(MAX_LIST_COUNT, 100).

start_link(C) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).

%% Legacy NIP-96 API. Keep the historic key shape for DETS compatibility.
claim(Hash, Pubkey, ObjectMeta, OwnerMeta) when
    is_binary(Hash), is_binary(Pubkey), is_map(ObjectMeta), is_map(OwnerMeta)
->
    call({claim, Hash, Pubkey, ObjectMeta, OwnerMeta}).

%% Source-scoped claim used by Blossom and future HTTP facades.
claim_source(Source, Hash, Pubkey, ObjectMeta, OwnerMeta) when
    is_atom(Source), is_binary(Hash), is_binary(Pubkey), is_map(ObjectMeta), is_map(OwnerMeta)
->
    call({claim_source, Source, Hash, Pubkey, ObjectMeta, OwnerMeta}).

lookup(Hash) when is_binary(Hash) ->
    call({lookup, Hash}).

release(Hash, Pubkey) when is_binary(Hash), is_binary(Pubkey) ->
    call({release, Hash, Pubkey}).

release_source(Source, Hash, Pubkey) when
    is_atom(Source), is_binary(Hash), is_binary(Pubkey)
->
    call({release_source, Source, Hash, Pubkey}).

list(Pubkey, Page, Count) when
    is_binary(Pubkey), is_integer(Page), Page >= 0, is_integer(Count), Count > 0
->
    call({list, Pubkey, Page, Count}).

%% BUD-12 cursor pagination for a source-scoped ownership namespace.
%% Cursor is undefined for the first page or a lowercase sha256 binary.
list_cursor(Source, Pubkey, Cursor, Limit) when
    is_atom(Source),
    is_binary(Pubkey),
    (Cursor =:= undefined orelse is_binary(Cursor)),
    is_integer(Limit),
    Limit > 0
->
    call({list_cursor, Source, Pubkey, Cursor, Limit}).

status() ->
    call(status).

call(Request) ->
    damage_ipfs_config:call(?MODULE, Request, 10000).

init(C) ->
    process_flag(trap_exit, true),
    Path = filename:join(maps:get(data_dir, C), "nip96.dets"),
    case filelib:ensure_dir(Path) of
        ok ->
            case dets:open_file(?MODULE, [{file, Path}, {type, set}, {auto_save, 5000}]) of
                {ok, Tab} -> {ok, #{tab => Tab, config => C}};
                {error, Reason} -> {stop, {nip96_store_open_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {nip96_store_directory_failed, Reason}}
    end.

handle_call({claim, Hash, Pubkey, ObjectMeta, OwnerMeta}, _From, S) ->
    claim_with_key({owner, Hash, Pubkey}, ObjectMeta, OwnerMeta, S);
handle_call({claim_source, Source, Hash, Pubkey, ObjectMeta, OwnerMeta}, _From, S) ->
    claim_with_key({owner, Source, Hash, Pubkey}, ObjectMeta, OwnerMeta, S);
handle_call({lookup, Hash}, _From, S = #{tab := Tab}) ->
    Reply =
        case dets:lookup(Tab, {object, Hash}) of
            [{{object, Hash}, Object}] ->
                Owners = owners_for_hash(Tab, Hash),
                case active_owners(Owners) of
                    [] -> {error, not_found};
                    Active -> {ok, Object, Active}
                end;
            [] ->
                {error, not_found}
        end,
    {reply, Reply, S};
handle_call({release, Hash, Pubkey}, _From, S) ->
    release_key({owner, Hash, Pubkey}, Hash, S);
handle_call({release_source, Source, Hash, Pubkey}, _From, S) ->
    release_key({owner, Source, Hash, Pubkey}, Hash, S);
handle_call({list, Pubkey, Page, Count0}, _From, S = #{tab := Tab}) ->
    Count = min(?MAX_LIST_COUNT, Count0),
    Rows0 = legacy_rows(Tab, Pubkey),
    Rows1 = lists:sort(fun newer_first/2, Rows0),
    Total = length(Rows1),
    Offset = Page * Count,
    Selected = slice(Rows1, Offset, Count),
    Files = rows_with_objects(Tab, Selected),
    {reply, {ok, #{page => Page, count => Count, total => Total, files => Files}}, S};
handle_call({list_cursor, Source, Pubkey, Cursor, Limit0}, _From, S = #{tab := Tab}) ->
    Limit = min(?MAX_LIST_COUNT, Limit0),
    Rows0 = source_rows(Tab, Source, Pubkey),
    Rows1 = lists:sort(fun newer_first/2, Rows0),
    case after_cursor(Rows1, Cursor) of
        {ok, Remaining} ->
            Selected = lists:sublist(Remaining, Limit),
            Files = rows_with_objects(Tab, Selected),
            NextCursor =
                case length(Remaining) > length(Selected) andalso Selected =/= [] of
                    true -> element(1, lists:last(Selected));
                    false -> undefined
                end,
            {reply, {ok, #{files => Files, next_cursor => NextCursor}}, S};
        {error, _} = Error ->
            {reply, Error, S}
    end;
handle_call(status, _From, S = #{tab := Tab}) ->
    {reply, #{running => true, records => dets:info(Tab, size)}, S};
handle_call(_, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, #{tab := Tab}) ->
    _ = dets:sync(Tab),
    _ = dets:close(Tab),
    ok.
code_change(_, S, _) -> {ok, S}.

claim_with_key(OwnerKey, ObjectMeta, OwnerMeta, S = #{tab := Tab}) ->
    case validate_meta(ObjectMeta, OwnerMeta) of
        ok ->
            Hash = owner_key_hash(OwnerKey),
            ObjectKey = {object, Hash},
            Existing = dets:lookup(Tab, ObjectKey),
            case compatible_object(Existing, ObjectMeta) of
                {error, _} = Error ->
                    {reply, Error, S};
                {ok, Newness, StoredObject} ->
                    case capacity_ok(Newness, OwnerKey, S) of
                        true ->
                            StoredOwner = merge_owner_meta(dets:lookup(Tab, OwnerKey), OwnerMeta),
                            ok = dets:insert(Tab, {ObjectKey, StoredObject}),
                            ok = dets:insert(Tab, {OwnerKey, StoredOwner}),
                            ok = dets:sync(Tab),
                            {reply, {ok, Newness, StoredObject}, S};
                        false ->
                            {reply, {error, metadata_limit}, S}
                    end
            end;
        {error, _} = Error ->
            {reply, Error, S}
    end.

release_key(OwnerKey, Hash, S = #{tab := Tab}) ->
    case dets:lookup(Tab, OwnerKey) of
        [] ->
            {reply, {error, not_owner}, S};
        [_] ->
            Object = object_for_hash(Tab, Hash),
            ok = dets:delete(Tab, OwnerKey),
            Remaining = owners_for_hash(Tab, Hash),
            Reply =
                case Remaining of
                    [] ->
                        ok = dets:delete(Tab, {object, Hash}),
                        {ok, last_owner, Object};
                    _ ->
                        {ok, shared, Object}
                end,
            ok = dets:sync(Tab),
            {reply, Reply, S}
    end.

owner_key_hash({owner, Hash, _Pubkey}) -> Hash;
owner_key_hash({owner, _Source, Hash, _Pubkey}) -> Hash.

merge_owner_meta([], OwnerMeta) ->
    OwnerMeta;
merge_owner_meta([{_Key, Old}], OwnerMeta) when is_map(Old) ->
    %% Preserve fields that the other HTTP facade may have recorded. The new
    %% source-specific claim is still allowed to update common policy fields.
    maps:merge(Old, OwnerMeta).

validate_meta(ObjectMeta, OwnerMeta) ->
    case
        {
            erlang:external_size(ObjectMeta) =< ?MAX_OBJECT_META_BYTES,
            erlang:external_size(OwnerMeta) =< ?MAX_OWNER_META_BYTES
        }
    of
        {true, true} -> ok;
        _ -> {error, metadata_too_large}
    end.

compatible_object([], ObjectMeta) ->
    {ok, new, ObjectMeta};
compatible_object([{{object, _Hash}, Stored}], ObjectMeta) ->
    case {maps:get(cid, Stored, undefined), maps:get(cid, ObjectMeta, undefined)} of
        {Cid, Cid} when Cid =/= undefined -> {ok, existing, Stored};
        _ -> {error, hash_cid_conflict}
    end.

capacity_ok(Newness, OwnerKey, #{tab := Tab, config := C}) ->
    Limit = application:get_env(damage, nip96_max_records, maps:get(max_intents, C, 100000)),
    OwnerExists = dets:lookup(Tab, OwnerKey) =/= [],
    Adds =
        case {Newness, OwnerExists} of
            {new, false} -> 2;
            {new, true} -> 1;
            {existing, false} -> 1;
            {existing, true} -> 0
        end,
    is_integer(Limit) andalso Limit > 0 andalso dets:info(Tab, size) + Adds =< Limit * 2.

object_for_hash(Tab, Hash) ->
    case dets:lookup(Tab, {object, Hash}) of
        [{{object, Hash}, Object}] -> Object;
        [] -> undefined
    end.

%% Return a normalized owner tuple so object lifetime accounts for legacy
%% NIP-96 claims as well as source-scoped claims.
owners_for_hash(Tab, Hash) ->
    dets:foldl(
        fun
            ({{owner, Hash0, Pubkey}, Owner}, Acc) when Hash0 =:= Hash ->
                [{nip96, Pubkey, Owner} | Acc];
            ({{owner, Source, Hash0, Pubkey}, Owner}, Acc) when Hash0 =:= Hash ->
                [{Source, Pubkey, Owner} | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ).

active_owners(Owners) ->
    [{Source, Pubkey, Owner} || {Source, Pubkey, Owner} <- Owners, owner_active(Owner)].

legacy_rows(Tab, Pubkey) ->
    dets:foldl(
        fun
            ({{owner, Hash, Pubkey0}, Owner}, Acc) when Pubkey0 =:= Pubkey ->
                maybe_add_active(Hash, Owner, Acc);
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ).

source_rows(Tab, Source, Pubkey) ->
    dets:foldl(
        fun
            ({{owner, Source0, Hash, Pubkey0}, Owner}, Acc) when
                Source0 =:= Source, Pubkey0 =:= Pubkey
            ->
                maybe_add_active(Hash, Owner, Acc);
            (_, Acc) ->
                Acc
        end,
        [],
        Tab
    ).

maybe_add_active(Hash, Owner, Acc) ->
    case owner_active(Owner) of
        true -> [{Hash, Owner} | Acc];
        false -> Acc
    end.

owner_active(Owner) ->
    case maps:get(expiration, Owner, 0) of
        0 -> true;
        undefined -> true;
        Exp when is_integer(Exp) -> Exp > erlang:system_time(second);
        _ -> true
    end.

rows_with_objects(Tab, Rows) ->
    lists:filtermap(
        fun({Hash, Owner}) ->
            case object_for_hash(Tab, Hash) of
                undefined -> false;
                Object -> {true, {Hash, Object, Owner}}
            end
        end,
        Rows
    ).

newer_first({HashA, A}, {HashB, B}) ->
    TsA = maps:get(created_at, A, 0),
    TsB = maps:get(created_at, B, 0),
    case TsA =:= TsB of
        true -> HashA < HashB;
        false -> TsA > TsB
    end.

after_cursor(Rows, undefined) ->
    {ok, Rows};
after_cursor(Rows, Cursor) ->
    drop_through_cursor(Rows, Cursor).

drop_through_cursor([], _Cursor) ->
    {error, cursor_not_found};
drop_through_cursor([{Cursor, _Owner} | Rest], Cursor) ->
    {ok, Rest};
drop_through_cursor([_ | Rest], Cursor) ->
    drop_through_cursor(Rest, Cursor).

slice(List, Offset, Count) ->
    case length(List) =< Offset of
        true -> [];
        false -> lists:sublist(lists:nthtail(Offset, List), Count)
    end.
