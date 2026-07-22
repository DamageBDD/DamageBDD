-module(ecai_ingest_record_tests).

-include_lib("eunit/include/eunit.hrl").

round_trip_test() ->
    Record = ecai_step03_test_support:record(1),
    {ok, Encoded} = ecai_ingest_record:encode(Record),
    ?assertMatch(<<"ECAIREC1", 1:8, _/binary>>, Encoded),
    {ok, Decoded} = ecai_ingest_record:decode(Encoded),
    ?assertEqual(Record, Decoded).

canonical_tags_round_trip_test() ->
    Record0 = ecai_step03_test_support:record(1),
    Record1 = Record0#{tags => [<<"wal">>, <<"ecai">>, <<"wal">>]},
    {ok, Normalized} = ecai_ingest_record:normalize(Record1),
    ?assertEqual([<<"ecai">>, <<"wal">>], maps:get(tags, Normalized)),
    {ok, Encoded} = ecai_ingest_record:encode(Record1),
    {ok, Decoded} = ecai_ingest_record:decode(Encoded),
    ?assertEqual(Normalized, Decoded).

trailing_bytes_rejected_test() ->
    {ok, Encoded} = ecai_ingest_record:encode(
        ecai_step03_test_support:record(1)
    ),
    ?assertMatch(
        {error, {trailing_record_bytes, 1}},
        ecai_ingest_record:decode(<<Encoded/binary, 0>>)
    ).

truncated_record_rejected_test() ->
    {ok, Encoded} = ecai_ingest_record:encode(
        ecai_step03_test_support:record(1)
    ),
    Truncated = binary:part(Encoded, 0, byte_size(Encoded) - 7),
    ?assertMatch({error, _}, ecai_ingest_record:decode(Truncated)).

identity_tamper_rejected_test() ->
    Record = ecai_step03_test_support:record(1),
    EventId = maps:get(event_id, Record),
    <<First:8, Rest/binary>> = EventId,
    Tampered = Record#{event_id => <<(First bxor 1):8, Rest/binary>>},
    ?assertMatch(
        {error, {identity_mismatch, event_id}},
        ecai_ingest_record:normalize(Tampered)
    ).

invalid_utf8_text_rejected_test() ->
    Record = ecai_step03_test_support:record(1),
    Tampered = Record#{
        text => <<16#C3, 16#28>>,
        chunk_byte_end => 2
    },
    ?assertMatch(
        {error, {invalid_utf8, text, _}},
        ecai_ingest_record:normalize(Tampered)
    ).

unknown_fields_rejected_test() ->
    Record = ecai_step03_test_support:record(1),
    ?assertEqual(
        {error, {unsupported_record_fields, [operator_note]}},
        ecai_ingest_record:normalize(Record#{operator_note => <<"unsafe">>})
    ).

ipfs_cid_must_match_source_version_test() ->
    Record = ecai_step03_test_support:record(1),
    ?assertMatch(
        {error, {cid_source_version_mismatch, _, _}},
        ecai_ingest_record:normalize(Record#{cid => <<"bafy-wrong">>})
    ).

golden_record_codec_vector_test() ->
    Record = ecai_step03_test_support:golden_record(),
    {ok, Encoded} = ecai_ingest_record:encode(Record),
    ?assertEqual(431, byte_size(Encoded)),
    ?assertEqual(
        <<"1de6f1ba3bd0c44b50d01cf4a8b28535e37c9420b28c3a4bda22958a48e76a00">>,
        ecai_ingest_event:id_hex(crypto:hash(sha256, Encoded))
    ).
