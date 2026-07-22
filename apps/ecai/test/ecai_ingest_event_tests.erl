-module(ecai_ingest_event_tests).

-include_lib("eunit/include/eunit.hrl").

deterministic_identity_test() ->
    {Chunk, Fields} = fixture(),
    {ok, Event1} = ecai_ingest_event:new_upsert_chunk(
        <<"org.damagebdd.docs/manual/install">>,
        <<"bafy-version-001">>,
        Chunk,
        Fields
    ),
    {ok, Event2} = ecai_ingest_event:new_upsert_chunk(
        <<"org.damagebdd.docs/manual/install">>,
        <<"bafy-version-001">>,
        Chunk,
        Fields
    ),
    ?assertEqual(Event1, Event2),
    ?assertEqual(32, byte_size(maps:get(chunk_id, Event1))),
    ?assertEqual(32, byte_size(maps:get(event_id, Event1))).

golden_vector_test() ->
    {Chunk, Fields} = fixture(),
    {ok, Event} = ecai_ingest_event:new_upsert_chunk(
        <<"org.damagebdd.docs/manual/install">>,
        <<"bafy-version-001">>,
        Chunk,
        Fields
    ),
    ChunkMap = maps:get(chunk, Event),
    ?assertEqual(
        <<"9f770d8fbf2f57711bb5b0c2c13f8a36b554f8d34f8fc9a62907d3fa909c0da9">>,
        ecai_ingest_event:id_hex(maps:get(content_sha256, ChunkMap))
    ),
    ?assertEqual(
        <<"add57b4edb07335eb67420546c40235cc34e0334bdffd2dcc30be0577c8b66c3">>,
        ecai_ingest_event:id_hex(maps:get(index_fields_sha256, Event))
    ),
    ?assertEqual(
        <<"28d1d7e349fcbcebd30bff835bedfc2ad06008d4451bc9d9f9c8252698a3ed0a">>,
        ecai_ingest_event:id_hex(maps:get(chunk_id, Event))
    ),
    ?assertEqual(
        <<"06ff09f9f6722334b4da5561cfc884ac094edbd7262b515eb27ccb2d046946d3">>,
        ecai_ingest_event:id_hex(maps:get(event_id, Event))
    ).

tag_order_and_duplicates_are_canonical_test() ->
    {Chunk, Fields0} = fixture(),
    Fields1 = Fields0#{tags => [<<"beta">>, <<"alpha">>, <<"beta">>]},
    Fields2 = Fields0#{tags => [<<"alpha">>, <<"beta">>]},
    {ok, Event1} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk, Fields1
    ),
    {ok, Event2} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk, Fields2
    ),
    ?assertEqual(Event1, Event2),
    ?assertEqual(
        [<<"alpha">>, <<"beta">>],
        maps:get(tags, maps:get(index_fields, Event1))
    ).

content_change_changes_chunk_and_event_identity_test() ->
    {Chunk1, Fields} = fixture(),
    Text2 = <<"ECAI retrieves a deterministic state!">>,
    Chunk2 = Chunk1#{
        text => Text2,
        byte_end => maps:get(byte_start, Chunk1) + byte_size(Text2)
    },
    {ok, Event1} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk1, Fields
    ),
    {ok, Event2} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk2, Fields
    ),
    ?assertNotEqual(maps:get(chunk_id, Event1), maps:get(chunk_id, Event2)),
    ?assertNotEqual(maps:get(event_id, Event1), maps:get(event_id, Event2)).

metadata_change_preserves_chunk_but_changes_event_test() ->
    {Chunk, Fields1} = fixture(),
    Fields2 = Fields1#{title => <<"Different title">>},
    {ok, Event1} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk, Fields1
    ),
    {ok, Event2} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk, Fields2
    ),
    ?assertEqual(maps:get(chunk_id, Event1), maps:get(chunk_id, Event2)),
    ?assertNotEqual(
        maps:get(index_fields_sha256, Event1),
        maps:get(index_fields_sha256, Event2)
    ),
    ?assertNotEqual(maps:get(event_id, Event1), maps:get(event_id, Event2)).

source_identity_changes_event_test() ->
    {Chunk, Fields} = fixture(),
    {ok, Event1} = ecai_ingest_event:new_upsert_chunk(
        <<"source-a">>, <<"version-1">>, Chunk, Fields
    ),
    {ok, Event2} = ecai_ingest_event:new_upsert_chunk(
        <<"source-b">>, <<"version-1">>, Chunk, Fields
    ),
    {ok, Event3} = ecai_ingest_event:new_upsert_chunk(
        <<"source-a">>, <<"version-2">>, Chunk, Fields
    ),
    ?assertNotEqual(maps:get(event_id, Event1), maps:get(event_id, Event2)),
    ?assertNotEqual(maps:get(event_id, Event1), maps:get(event_id, Event3)).

record_verification_test() ->
    {Chunk, Fields} = fixture(),
    {ok, Event} = ecai_ingest_event:new_upsert_chunk(
        <<"source">>, <<"version">>, Chunk, Fields
    ),
    Record0 = #{
        title => maps:get(title, Fields),
        heading => maps:get(heading, Fields),
        type => maps:get(type, Fields),
        tags => maps:get(tags, maps:get(index_fields, Event)),
        text => maps:get(text, Chunk),
        chunker => maps:get(chunker, Chunk),
        chunk_ordinal => maps:get(ordinal, Chunk),
        chunk_byte_start => maps:get(byte_start, Chunk),
        chunk_byte_end => maps:get(byte_end, Chunk)
    },
    Record = maps:merge(Record0, ecai_ingest_event:record_fields(Event)),
    ?assertEqual(ok, ecai_ingest_event:verify_record(Record)),
    ?assertMatch(
        {error, {identity_mismatch, _}},
        ecai_ingest_event:verify_record(Record#{title => <<"tampered">>})
    ).

invalid_range_rejected_test() ->
    {Chunk, Fields} = fixture(),
    BadChunk = Chunk#{byte_end => maps:get(byte_end, Chunk) + 1},
    ?assertMatch(
        {error, {byte_range_mismatch, _}},
        ecai_ingest_event:new_upsert_chunk(
            <<"source">>, <<"version">>, BadChunk, Fields
        )
    ).

invalid_utf8_chunk_text_rejected_test() ->
    {Chunk, Fields} = fixture(),
    InvalidText = <<16#C3, 16#28>>,
    BadChunk = Chunk#{
        text => InvalidText,
        byte_end => maps:get(byte_start, Chunk) + byte_size(InvalidText)
    },
    ?assertEqual(
        {error, {invalid_utf8, text, 0}},
        ecai_ingest_event:new_upsert_chunk(
            <<"source">>,
            <<"version">>,
            BadChunk,
            Fields
        )
    ).

invalid_utf8_metadata_rejected_test() ->
    {Chunk, Fields} = fixture(),
    BadTitle = <<"valid", 16#F0, 16#28, 16#8C, 16#28>>,
    ?assertEqual(
        {error, {invalid_utf8, title, 5}},
        ecai_ingest_event:new_upsert_chunk(
            <<"source">>,
            <<"version">>,
            Chunk,
            Fields#{title => BadTitle}
        )
    ).

invalid_source_identity_rejected_test() ->
    {Chunk, Fields} = fixture(),
    ?assertEqual(
        {error, {empty_field, source_key}},
        ecai_ingest_event:new_upsert_chunk(<<>>, <<"version">>, Chunk, Fields)
    ),
    ?assertEqual(
        {error, {invalid_field, source_version}},
        ecai_ingest_event:new_upsert_chunk(
            <<"source">>, not_binary, Chunk, Fields
        )
    ).

fixture() ->
    Text = <<"ECAI retrieves a deterministic state.">>,
    Chunk = #{
        chunker => <<"ecai-utf8-window/v1">>,
        ordinal => 7,
        byte_start => 100,
        byte_end => 100 + byte_size(Text),
        text => Text
    },
    Fields = #{
        title => <<"Operator guide">>,
        heading => <<"Atomic identity">>,
        type => <<"ipfs">>,
        tags => [<<"production">>, <<"ecai">>]
    },
    {Chunk, Fields}.
