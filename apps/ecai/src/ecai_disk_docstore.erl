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

open(BaseDir) ->
    ok = filelib:ensure_dir(filename:join(BaseDir, "docstore/x")),
    Path = filename:join([BaseDir, "docstore", "ecai_docstore.dets"]),
    Name = table_name(BaseDir),
    case dets:open_file(Name, [{file, Path}, {type, set}]) of
        {ok, Tab} ->
            case ensure_next(Tab) of
                ok ->
                    {ok, Tab};
                {error, _Reason} = Error ->
                    _ = dets:close(Tab),
                    Error
            end;
        Error ->
            Error
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

ensure_next(Tab) ->
    case dets:lookup(Tab, ?NEXT_KEY) of
        [] -> dets:insert(Tab, {?NEXT_KEY, 1});
        [{?NEXT_KEY, Next}] when is_integer(Next), Next > 0 -> ok;
        Other -> {error, {invalid_next_id_record, Other}}
    end.

table_name(BaseDir) ->
    %% Compatibility with the existing store layout. Operators should keep the
    %% number of simultaneously opened BaseDirs bounded because DETS names are
    %% atoms and atoms are not garbage collected.
    Hash = erlang:phash2(filename:absname(BaseDir), 1000000),
    list_to_atom("ecai_docstore_" ++ integer_to_list(Hash)).
