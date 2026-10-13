-module(ecai_ipfs_ingest_step03_tests).

-include_lib("eunit/include/eunit.hrl").

build_records_is_deterministic_and_gap_free_test() ->
    Source = binary:copy(<<"a">>, 1200),
    SourceKey = <<"org.damagebdd.docs/step03">>,
    Cid = <<"bafy-step03-content">>,
    Title = <<"Step 3">>,
    {ok, Records1} = ecai_ipfs_ingest:build_records(
        SourceKey,
        Cid,
        Title,
        Source
    ),
    {ok, Records2} = ecai_ipfs_ingest:build_records(
        SourceKey,
        Cid,
        Title,
        Source
    ),
    ?assertEqual(Records1, Records2),
    ?assertEqual(2, length(Records1)),
    [First, Second] = Records1,
    ?assertEqual(0, maps:get(chunk_byte_start, First)),
    ?assertEqual(1100, maps:get(chunk_byte_end, First)),
    ?assertEqual(960, maps:get(chunk_byte_start, Second)),
    ?assertEqual(1200, maps:get(chunk_byte_end, Second)),
    ?assertEqual(Cid, maps:get(source_version, First)),
    ?assertEqual(Cid, maps:get(cid, First)),
    ?assertEqual(ok, ecai_ingest_event:verify_record(First)),
    ?assertEqual(ok, ecai_ingest_event:verify_record(Second)).

empty_source_is_rejected_test() ->
    ?assertEqual(
        {error, empty_source},
        ecai_ipfs_ingest:build_records(
            <<"source">>,
            <<"bafy-empty">>,
            <<"Empty">>,
            <<>>
        )
    ).

invalid_utf8_is_rejected_before_record_creation_test() ->
    ?assertMatch(
        {error, {invalid_utf8, _}},
        ecai_ipfs_ingest:build_records(
            <<"source">>,
            <<"bafy-invalid">>,
            <<"Invalid">>,
            <<16#C3, 16#28>>
        )
    ).

source_chunk_limit_stops_before_unbounded_record_build_test() ->
    Source = binary:copy(<<"a">>, 1200),
    ?assertEqual(
        {error, {source_chunk_limit_exceeded, 2, 1}},
        ecai_ipfs_ingest:build_records(
            <<"source">>,
            <<"bafy-limit">>,
            <<"Limit">>,
            Source,
            1
        )
    ).
