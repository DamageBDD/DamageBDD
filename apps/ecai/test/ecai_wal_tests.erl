-module(ecai_wal_tests).

-include_lib("eunit/include/eunit.hrl").

committed_batches_recover_in_order_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2, R3] = ecai_step03_test_support:records(3),
        {ok, Wal0, Recovery0} = ecai_wal:open(BaseDir),
        ?assertEqual([], maps:get(records, Recovery0)),
        {ok, Wal1, Meta1} = ecai_wal:append_batch(Wal0, [R1, R2]),
        {ok, Wal2, Meta2} = ecai_wal:append_batch(Wal1, [R3]),
        ?assertEqual(2, maps:get(event_count, Meta1)),
        ?assertEqual(1, maps:get(event_count, Meta2)),
        ok = ecai_wal:close(Wal2),

        {ok, Wal3, Recovery1} = ecai_wal:open(BaseDir),
        ?assertEqual([R1, R2, R3], maps:get(records, Recovery1)),
        ?assertEqual(2, maps:get(batch_count, Recovery1)),
        ?assertEqual(3, maps:get(event_count, Recovery1)),
        ?assertEqual(0, maps:get(repaired_bytes, Recovery1)),
        ok = ecai_wal:close(Wal3)
    end).

partial_second_commit_is_discarded_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2] = ecai_step03_test_support:records(2),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, _Meta1} = ecai_wal:append_batch(Wal0, [R1]),
        {ok, Wal2, Meta2} = ecai_wal:append_batch(Wal1, [R2]),
        Path = ecai_wal:path(Wal2),
        OriginalBytes = maps:get(batch_end, Meta2),
        CutAt = maps:get(commit_offset, Meta2) + 5,
        SecondStart = maps:get(batch_start, Meta2),
        ok = ecai_wal:close(Wal2),
        ok = ecai_step03_test_support:truncate_file(Path, CutAt),

        {ok, Wal3, Recovery} = ecai_wal:open(BaseDir),
        ?assertEqual([R1], maps:get(records, Recovery)),
        ?assertEqual(SecondStart, maps:get(wal_bytes, Recovery)),
        ?assertEqual(CutAt - SecondStart, maps:get(repaired_bytes, Recovery)),
        ?assert(OriginalBytes > CutAt),
        ok = ecai_wal:close(Wal3)
    end).

partial_first_batch_recovers_empty_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, Meta} = ecai_wal:append_batch(Wal0, [R1]),
        Path = ecai_wal:path(Wal1),
        CutAt = maps:get(commit_offset, Meta) + 3,
        ok = ecai_wal:close(Wal1),
        ok = ecai_step03_test_support:truncate_file(Path, CutAt),

        {ok, Wal2, Recovery} = ecai_wal:open(BaseDir),
        ?assertEqual([], maps:get(records, Recovery)),
        ?assertEqual(0, maps:get(wal_bytes, Recovery)),
        ?assertEqual(CutAt, maps:get(repaired_bytes, Recovery)),
        ok = ecai_wal:close(Wal2)
    end).

short_garbage_tail_is_repaired_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, Meta} = ecai_wal:append_batch(Wal0, [R1]),
        Path = ecai_wal:path(Wal1),
        DurableBytes = maps:get(batch_end, Meta),
        ok = ecai_wal:close(Wal1),
        Garbage = <<"torn-tail">>,
        ok = ecai_step03_test_support:append_bytes(Path, Garbage),

        {ok, Wal2, Recovery} = ecai_wal:open(BaseDir),
        ?assertEqual([R1], maps:get(records, Recovery)),
        ?assertEqual(DurableBytes, maps:get(wal_bytes, Recovery)),
        ?assertEqual(byte_size(Garbage), maps:get(repaired_bytes, Recovery)),
        ok = ecai_wal:close(Wal2)
    end).

committed_payload_corruption_fails_closed_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, Meta} = ecai_wal:append_batch(Wal0, [R1]),
        [EventOffset] = maps:get(event_frame_offsets, Meta),
        Path = ecai_wal:path(Wal1),
        ok = ecai_wal:close(Wal1),
        PayloadOffset = EventOffset + ecai_wal:header_size() + 70,
        ok = ecai_step03_test_support:flip_byte(Path, PayloadOffset),

        ?assertMatch(
            {error, {wal_corrupt, #{offset := EventOffset}}},
            ecai_wal:open(BaseDir)
        )
    end).

committed_header_corruption_fails_closed_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, Meta} = ecai_wal:append_batch(Wal0, [R1]),
        [EventOffset] = maps:get(event_frame_offsets, Meta),
        Path = ecai_wal:path(Wal1),
        ok = ecai_wal:close(Wal1),
        %% Byte 12 is inside the payload-length field covered by header CRC32.
        ok = ecai_step03_test_support:flip_byte(Path, EventOffset + 12),

        ?assertMatch(
            {error,
                {wal_corrupt, #{
                    offset := EventOffset,
                    reason := {header_checksum_mismatch, _, _}
                }}},
            ecai_wal:open(BaseDir)
        )
    end).

direct_duplicate_event_ids_are_rejected_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        ?assertMatch(
            {error, {duplicate_event_id_in_batch, 2, _}},
            ecai_wal:append_batch(Wal0, [R1, R1])
        ),
        ?assertEqual(0, maps:get(wal_bytes, ecai_wal:stats(Wal0))),
        ok = ecai_wal:close(Wal0)
    end).

batch_event_limit_is_enforced_before_write_test() ->
    with_tmp(fun(BaseDir) ->
        [R1, R2] = ecai_step03_test_support:records(2),
        {ok, Wal0, _} = ecai_wal:open(
            BaseDir,
            #{max_batch_events => 1, max_batch_bytes => 1048576}
        ),
        ?assertEqual(
            {error, {batch_event_limit_exceeded, 2, 1}},
            ecai_wal:append_batch(Wal0, [R1, R2])
        ),
        ?assertEqual(0, maps:get(wal_bytes, ecai_wal:stats(Wal0))),
        ok = ecai_wal:close(Wal0)
    end).

batch_byte_limit_is_enforced_before_write_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(
            BaseDir,
            #{max_batch_events => 10, max_batch_bytes => 128}
        ),
        ?assertMatch(
            {error, {batch_byte_limit_exceeded, _, 128}},
            ecai_wal:append_batch(Wal0, [R1])
        ),
        ?assertEqual(0, maps:get(wal_bytes, ecai_wal:stats(Wal0))),
        ok = ecai_wal:close(Wal0)
    end).

golden_single_event_wal_vector_test() ->
    with_tmp(fun(BaseDir) ->
        Record = ecai_step03_test_support:golden_record(),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        {ok, Wal1, Meta} = ecai_wal:append_batch(Wal0, [Record]),
        Path = ecai_wal:path(Wal1),
        ?assertEqual(643, maps:get(bytes, Meta)),
        ?assertEqual([60], maps:get(event_frame_offsets, Meta)),
        ?assertEqual(583, maps:get(commit_offset, Meta)),
        ?assertEqual(
            <<"a3ff3659967604fa5ec36994327e5f823fa2392c9cd7541facd3569b67a76e08">>,
            ecai_ingest_event:id_hex(maps:get(batch_id, Meta))
        ),
        ok = ecai_wal:close(Wal1),
        {ok, WalBytes} = file:read_file(Path),
        ?assertEqual(643, byte_size(WalBytes)),
        ?assertEqual(
            <<"4739f6b1c458b19961d062fabf3feabc51d5d9a53e7deb8248da0788d280a91a">>,
            ecai_ingest_event:id_hex(crypto:hash(sha256, WalBytes))
        )
    end).

external_size_change_is_detected_before_append_test() ->
    with_tmp(fun(BaseDir) ->
        R1 = ecai_step03_test_support:record(1),
        {ok, Wal0, _} = ecai_wal:open(BaseDir),
        Path = ecai_wal:path(Wal0),
        ok = ecai_step03_test_support:append_bytes(Path, <<0>>),
        ?assertEqual(
            {error, {wal_size_changed, 0, 1}},
            ecai_wal:append_batch(Wal0, [R1])
        ),
        ok = ecai_wal:close(Wal0)
    end).

with_tmp(Fun) ->
    BaseDir = ecai_step03_test_support:temp_dir(),
    try
        Fun(BaseDir)
    after
        ok = ecai_step03_test_support:cleanup(BaseDir)
    end.
