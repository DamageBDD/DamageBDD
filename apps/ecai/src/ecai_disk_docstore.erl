%% ecai_disk_docstore.erl
%% Disk-backed metadata store for DocInt -> #{cid,title,heading,text,...}
%% Uses DETS for simplicity and durability.

-module(ecai_disk_docstore).
-export([open/1, close/1, put/3, get/2, next_id/1]).

-define(NEXT_KEY, '$next_id').

open(BaseDir) ->
    ok = filelib:ensure_dir(filename:join(BaseDir, "docstore/x")),
    Path = filename:join([BaseDir, "docstore", "ecai_docstore.dets"]),
    Name = table_name(BaseDir),
    case dets:open_file(Name, [{file, Path}, {type, set}]) of
        {ok, Tab} ->
            ensure_next(Tab),
            {ok, Tab};
        Error ->
            Error
    end.

close(Tab) ->
    dets:close(Tab).

put(Tab, DocInt, MetaMap) when is_integer(DocInt), is_map(MetaMap) ->
    dets:insert(Tab, {DocInt, MetaMap}),
    ok.

get(Tab, DocInt) when is_integer(DocInt) ->
    case dets:lookup(Tab, DocInt) of
        [{_, M}] -> {ok, M};
        [] -> not_found
    end.

%% Allocate monotonically increasing DocInt (stored in DETS).
next_id(Tab) ->
    [{?NEXT_KEY, N}] = dets:lookup(Tab, ?NEXT_KEY),
    ok = dets:insert(Tab, {?NEXT_KEY, N + 1}),
    {ok, N}.

ensure_next(Tab) ->
    case dets:lookup(Tab, ?NEXT_KEY) of
        [] ->
            ok = dets:insert(Tab, {?NEXT_KEY, 1});
        _ ->
            ok
    end.

table_name(BaseDir) ->
    %% Avoid atom blowup by limiting to one table name per base dir hash.
    %% If you run many BaseDirs in one VM, consider a single table and store BaseDir in key.
    H = erlang:phash2(BaseDir, 1000000),
    list_to_atom("ecai_docstore_" ++ integer_to_list(H)).
