-module(ecai_disk_indexer).

-export([
    new/1,
    add_doc/3,
    add_records/2,
    flush/1,
    close/1
]).

-record(st, {
    base_dir,
    docstore_tab,
    seg_no = 0,
    %% #{TermBin => [DocInt...]}
    batch = #{},
    batch_docs = 0,
    %% Tune: batch size controls RAM.
    max_docs = 50000
}).

new(BaseDir) ->
    ok = filelib:ensure_dir(filename:join(BaseDir, "x")),
    {ok, Tab} = ecai_disk_docstore:open(BaseDir),
    #st{
        base_dir = BaseDir,
        docstore_tab = Tab,
        seg_no = next_seg_no(BaseDir)
    }.

add_records(State0, Records) when is_list(Records) ->
    lists:foldl(
        fun(Record, State) when is_map(Record) ->
            {ok, DocInt} = ecai_disk_docstore:next_id(State#st.docstore_tab),
            add_doc(State, DocInt, Record)
        end,
        State0,
        Records
    );
add_records(_State, _Records) ->
    erlang:error(badarg).

%% add_doc(State, DocInt, RecMap) -> State1
add_doc(
    State0 = #st{batch = Batch0, batch_docs = Count0, max_docs = MaxDocs},
    DocInt,
    Record
) when is_integer(DocInt), DocInt > 0, is_map(Record) ->
    Terms = ecai_terms:terms_from_record(Record),
    Meta = maps:with(
        [
            cid,
            title,
            heading,
            text,
            tags,
            type,
            ts,
            chunk_ordinal,
            chunk_byte_start,
            chunk_byte_end,
            chunker,
            event_schema,
            event_operation,
            event_pipeline,
            source_key,
            source_version,
            chunk_content_sha256,
            index_fields_sha256,
            chunk_id,
            event_id
        ],
        Record
    ),
    ok = ecai_disk_docstore:put(
        State0#st.docstore_tab,
        DocInt,
        normalize_meta(Meta)
    ),
    Batch1 = lists:foldl(
        fun(Term, Acc) ->
            maps:update_with(
                Term,
                fun(DocIds) -> [DocInt | DocIds] end,
                [DocInt],
                Acc
            )
        end,
        Batch0,
        Terms
    ),
    Count1 = Count0 + 1,
    State1 = State0#st{batch = Batch1, batch_docs = Count1},
    case Count1 >= MaxDocs of
        true -> flush(State1);
        false -> State1
    end;
add_doc(_State, _DocInt, _Record) ->
    erlang:error(badarg).

flush(State = #st{batch_docs = 0}) ->
    State;
flush(State = #st{
    base_dir = BaseDir,
    docstore_tab = Docstore,
    seg_no = SegmentNo,
    batch = Batch
}) ->
    %% Document metadata must be durable before the segment becomes visible in
    %% the manifest.
    ok = ecai_disk_docstore:sync(Docstore),
    SegmentName = lists:flatten(io_lib:format("seg_~6..0B.ecs", [SegmentNo])),
    ok = ecai_disk_segment:write(BaseDir, SegmentName, Batch),
    ok = ecai_disk_manifest:append_segment(
        BaseDir,
        filename:join(BaseDir, SegmentName)
    ),
    State#st{
        seg_no = SegmentNo + 1,
        batch = #{},
        batch_docs = 0
    }.

close(State = #st{docstore_tab = Docstore}) ->
    try
        _Flushed = flush(State),
        ecai_disk_docstore:sync(Docstore)
    after
        %% Do not leave the DETS owner open when segment or manifest
        %% publication fails.
        _ = ecai_disk_docstore:close(Docstore)
    end.

normalize_meta(Meta) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            Acc#{Key => normalize_meta_value(Key, Value)}
        end,
        #{},
        Meta
    ).

normalize_meta_value(tags, Tags) when is_list(Tags) ->
    [to_binary(Tag) || Tag <- Tags];
normalize_meta_value(_Key, Bin) when is_binary(Bin) ->
    Bin;
normalize_meta_value(_Key, List) when is_list(List) ->
    unicode:characters_to_binary(List);
normalize_meta_value(_Key, Other) ->
    Other.

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

next_seg_no(BaseDir) ->
    Numbers = [segment_number(Path) || Path <- ecai_disk_manifest:list_segments(BaseDir)],
    case Numbers of
        [] -> 1;
        _ -> lists:max(Numbers) + 1
    end.

segment_number(Path) ->
    Base = filename:basename(Path),
    case string:tokens(Base, "_.") of
        ["seg", NumberString, "ecs"] ->
            try list_to_integer(NumberString) of
                Number when Number >= 0 -> Number
            catch
                error:badarg -> 0
            end;
        _ ->
            0
    end.
