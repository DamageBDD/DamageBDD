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
    next_id/1
]).

-define(NEXT_KEY, '$next_id').
-define(CREATOR_TABLE, ecai_disk_docstore_creator).

open(BaseDir0) ->
    try
        BaseDir = path_list(BaseDir0),
        ok = filelib:ensure_dir(filename:join(BaseDir, "docstore/x")),
        Path = filename:join([BaseDir, "docstore", "ecai_docstore.dets"]),
        case ensure_table_file(Path) of
            ok -> open_existing(Path);
            {error, _Reason} = Error -> Error
        end
    catch
        error:badarg -> {error, invalid_base_dir}
    end.

close(Tab) ->
    dets:close(Tab).

sync(Tab) ->
    dets:sync(Tab).

put(Tab, DocInt, MetaMap) when is_integer(DocInt), DocInt > 0, is_map(MetaMap) ->
    dets:insert(Tab, {DocInt, MetaMap});
put(_Tab, _DocInt, _MetaMap) ->
    {error, badarg}.

get(Tab, DocInt) when is_integer(DocInt), DocInt > 0 ->
    case dets:lookup(Tab, DocInt) of
        [{_, Meta}] -> {ok, Meta};
        [] -> not_found
    end;
get(_Tab, _DocInt) ->
    {error, badarg}.

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

open_existing(Path) ->
    %% open_file/1 returns an anonymous table reference and therefore avoids
    %% allocating one permanent VM atom for every operator-selected BaseDir.
    case dets:open_file(Path) of
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

ensure_table_file(Path) ->
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            LockId = {{?MODULE, create_table_file}, self()},
            case global:trans(LockId, fun() -> create_table_file_if_missing(Path) end) of
                aborted -> {error, docstore_create_lock_aborted};
                Result -> Result
            end
    end.

create_table_file_if_missing(Path) ->
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            case
                dets:open_file(?CREATOR_TABLE, [
                    {file, Path},
                    {type, set},
                    {repair, true}
                ])
            of
                {ok, Tab} ->
                    try
                        case ensure_next(Tab) of
                            ok -> dets:sync(Tab);
                            {error, _Reason} = Error -> Error
                        end
                    after
                        _ = dets:close(Tab)
                    end;
                {error, _Reason} = Error ->
                    Error
            end
    end.

ensure_next(Tab) ->
    case dets:lookup(Tab, ?NEXT_KEY) of
        [] -> dets:insert(Tab, {?NEXT_KEY, 1});
        [{?NEXT_KEY, Next}] when is_integer(Next), Next > 0 -> ok;
        Other -> {error, {invalid_next_id_record, Other}}
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
