%%--------------------------------------------------------------------
%% Disk-backed metadata store for DocInt -> retrieval metadata.
%%--------------------------------------------------------------------
-module(ecai_disk_docstore).

-export([
    open/1,
    close/1,
    sync/1,
    put/3,
    get/2,
    get_source/3,
    next_id/1
]).

-define(NEXT_KEY, '$next_id').

open(BaseDir0) ->
    try
        BaseDir = path_list(BaseDir0),
        ok = ecai_private_store:assert_public(BaseDir),
        ok = filelib:ensure_dir(filename:join(BaseDir, "docstore/x")),
        Path = filename:absname(filename:join([BaseDir, "docstore", "ecai_docstore.dets"])),
        open_shared(Path)
    catch
        error:badarg -> {error, invalid_base_dir}
    end.

close(Tab) ->
    dets:close(Tab).

sync(Tab) ->
    dets:sync(Tab).

put(Tab, DocInt, MetaMap) when is_integer(DocInt), DocInt > 0, is_map(MetaMap) ->
    case maps:find(source_blob, MetaMap) of
        {ok, #{source_key := Key, source_version := Version} = Ref} ->
            SourceId = {'$source', Key, Version},
            case dets:lookup(Tab, SourceId) of
                [{SourceId, Existing}] when Existing =/= Ref ->
                    {error, source_version_conflict};
                _ -> dets:insert(Tab, [{DocInt, MetaMap}, {SourceId, Ref}])
            end;
        error -> dets:insert(Tab, {DocInt, MetaMap});
        _ -> {error, invalid_source_descriptor}
    end;
put(_Tab, _DocInt, _MetaMap) ->
    {error, badarg}.

get(Tab, DocInt) when is_integer(DocInt), DocInt > 0 ->
    case dets:lookup(Tab, DocInt) of
        [{_, Meta}] -> {ok, Meta};
        [] -> not_found
    end;
get(_Tab, _DocInt) ->
    {error, badarg}.

get_source(Tab, Key, Version) ->
    case dets:lookup(Tab, {'$source', Key, Version}) of
        [{_, Ref}] -> {ok, Ref};
        [] -> not_found
    end.

%% Atomically allocate a monotonically increasing local document ID. The
%% stored value is the next unallocated ID, so update_counter/3 returns one
%% beyond the ID assigned to this caller.
next_id(Tab) ->
    try dets:update_counter(Tab, ?NEXT_KEY, 1) of
        NewNext when is_integer(NewNext), NewNext > 1 ->
            {ok, NewNext - 1}
    catch
        error:Reason -> {error, {next_id_failed, Reason}}
    end.

%% A document store has ONE DETS table per configured absolute path on this
%% node. open_file/1 creates a new anonymous table on every call; it does not
%% join a writer already using the file. Reopening that file independently
%% while the writer has buffered changes can lose metadata or counter updates.
%%
%% DETS names are terms, not necessarily atoms. The tuple avoids an unbounded
%% atom per index while open_file/2 gives each caller a reference-counted open
%% on the same table (including nested opens by the same process). A search's
%% close/1 therefore releases only its own open, not the writer's table.
%%
%% Use the same configured path for all access, and one BEAM node per store.
%% This does not implement a cross-VM lock or resolve filesystem path aliases.
open_shared(Path) ->
    Name = {?MODULE, Path},
    case dets:open_file(Name, [{file, Path}, {type, set}, {repair, true}]) of
        {ok, Tab} ->
            case ensure_next(Tab) of
                ok ->
                    {ok, Tab};
                {error, _Reason} = Error ->
                    _ = dets:close(Tab),
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

ensure_next(Tab) ->
    %% Concurrent first opens must not overwrite a counter that another
    %% caller has already advanced. DETS performs this insert atomically.
    case dets:insert_new(Tab, {?NEXT_KEY, 1}) of
        true -> ok;
        false ->
            case dets:lookup(Tab, ?NEXT_KEY) of
                [{?NEXT_KEY, Next}] when is_integer(Next), Next > 0 -> ok;
                Other -> {error, {invalid_next_id_record, Other}}
            end;
        {error, _Reason} = Error -> Error
    end.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List) -> List;
        _Invalid -> erlang:error(badarg)
    end;
path_list(List) when is_list(List), List =/= [] ->
    List;
path_list(_Other) ->
    erlang:error(badarg).
