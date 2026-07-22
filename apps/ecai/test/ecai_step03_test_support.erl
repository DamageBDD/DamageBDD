%% coding: utf-8
%%--------------------------------------------------------------------
%% Shared fixtures and filesystem helpers for Step 3 EUnit tests.
%%--------------------------------------------------------------------
-module(ecai_step03_test_support).

-export([
    temp_dir/0,
    cleanup/1,
    record/1,
    records/1,
    golden_record/0,
    event_id/1,
    wal_path/1,
    file_size/1,
    truncate_file/2,
    flip_byte/2,
    append_bytes/2
]).

temp_dir() ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Dir = filename:join(Root, "ecai-step03-" ++ Suffix),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    Dir.

cleanup(Path) ->
    remove_path(Path).

record(N) when is_integer(N), N > 0 ->
    Number = integer_to_binary(N),
    Text = <<"durable ECAI event ", Number/binary, " — IPFS">>,
    SourceKey = <<"org.damagebdd.step03/document/", Number/binary>>,
    SourceVersion = <<"bafy-step03-version-", Number/binary>>,
    Chunk = #{
        chunker => ecai_chunker:version(),
        ordinal => N,
        byte_start => 0,
        byte_end => byte_size(Text),
        text => Text
    },
    IndexFields = #{
        title => <<"Step 3 document ", Number/binary>>,
        heading => <<"Durable ingestion">>,
        type => <<"ipfs">>,
        tags => [<<"wal">>, <<"ecai">>, <<"wal">>]
    },
    {ok, Event} = ecai_ingest_event:new_upsert_chunk(
        SourceKey,
        SourceVersion,
        Chunk,
        IndexFields
    ),
    CanonicalFields = maps:get(index_fields, Event),
    Record0 = #{
        cid => SourceVersion,
        title => maps:get(title, CanonicalFields),
        heading => maps:get(heading, CanonicalFields),
        text => Text,
        tags => maps:get(tags, CanonicalFields),
        type => maps:get(type, CanonicalFields),
        chunk_ordinal => N,
        chunk_byte_start => 0,
        chunk_byte_end => byte_size(Text),
        chunker => ecai_chunker:version()
    },
    {ok, Record} = ecai_ingest_record:normalize(
        maps:merge(Record0, ecai_ingest_event:record_fields(Event))
    ),
    Record.

records(Count) when is_integer(Count), Count >= 0 ->
    [record(N) || N <- lists:seq(1, Count)].

golden_record() ->
    Text = <<"ECAI retrieves a deterministic state.">>,
    Chunk = #{
        chunker => <<"ecai-utf8-window/v1">>,
        ordinal => 7,
        byte_start => 100,
        byte_end => 137,
        text => Text
    },
    Fields = #{
        title => <<"Operator guide">>,
        heading => <<"Atomic identity">>,
        type => <<"ipfs">>,
        tags => [<<"production">>, <<"ecai">>]
    },
    SourceKey = <<"org.damagebdd.docs/manual/install">>,
    SourceVersion = <<"bafy-version-001">>,
    {ok, Event} = ecai_ingest_event:new_upsert_chunk(
        SourceKey,
        SourceVersion,
        Chunk,
        Fields
    ),
    CanonicalFields = maps:get(index_fields, Event),
    Record0 = #{
        cid => SourceVersion,
        title => maps:get(title, CanonicalFields),
        heading => maps:get(heading, CanonicalFields),
        text => Text,
        tags => maps:get(tags, CanonicalFields),
        type => maps:get(type, CanonicalFields),
        chunk_ordinal => 7,
        chunk_byte_start => 100,
        chunk_byte_end => 137,
        chunker => maps:get(chunker, Chunk)
    },
    {ok, Record} = ecai_ingest_record:normalize(
        maps:merge(Record0, ecai_ingest_event:record_fields(Event))
    ),
    Record.

event_id(Record) ->
    maps:get(event_id, Record).

wal_path(BaseDir) ->
    ecai_wal:wal_path(BaseDir).

file_size(Path) ->
    {ok, Info} = file:read_file_info(Path),
    element(2, Info).

truncate_file(Path, Size) when is_integer(Size), Size >= 0 ->
    {ok, Fd} = file:open(Path, [raw, binary, read, write]),
    try
        {ok, Size} = file:position(Fd, {bof, Size}),
        ok = file:truncate(Fd),
        ok = file:sync(Fd)
    after
        ok = file:close(Fd)
    end.

flip_byte(Path, Offset) when is_integer(Offset), Offset >= 0 ->
    {ok, Fd} = file:open(Path, [raw, binary, read, write]),
    try
        {ok, <<Byte:8>>} = file:pread(Fd, Offset, 1),
        ok = file:pwrite(Fd, Offset, <<(Byte bxor 16#01):8>>),
        ok = file:sync(Fd)
    after
        ok = file:close(Fd)
    end.

append_bytes(Path, Bytes) when is_binary(Bytes) ->
    {ok, Fd} = file:open(Path, [raw, binary, read, write]),
    try
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, Bytes),
        ok = file:sync(Fd)
    after
        ok = file:close(Fd)
    end.

remove_path(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} ->
            case element(3, Info) of
                directory ->
                    case file:list_dir(Path) of
                        {ok, Names} ->
                            lists:foreach(
                                fun(Name) ->
                                    remove_path(filename:join(Path, Name))
                                end,
                                Names
                            ),
                            ok = file:del_dir(Path);
                        {error, enoent} ->
                            ok
                    end;
                _ ->
                    ok = file:delete(Path)
            end;
        {error, enoent} ->
            ok
    end.
