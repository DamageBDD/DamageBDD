-module(ecai_step03_source_coherence_tests).

-include_lib("eunit/include/eunit.hrl").

step03_runtime_contract_test() ->
    Required = [
        {ecai_chunker, validate_utf8, 1},
        {ecai_chunker, chunk_utf8, 3},
        {ecai_chunker, fold_utf8, 5},
        {ecai_terms, version, 0},
        {ecai_terms, terms_from_record, 1},
        {ecai_terms, terms_from_query, 2},
        {ecai_ingest_event, new_upsert_chunk, 4},
        {ecai_ingest_record, normalize, 1},
        {ecai_wal, open, 1},
        {ecai_wal, append_batch, 2},
        {ecai_ingest_writer, submit_batch, 2},
        {ecai_ingest_writer, status, 1},
        {ecai_ingest_sup, start_link, 0},
        {ecai_ingest_sup, writer, 0},
        {ecai_ipfs_ingest, build_records, 4},
        {ecai_ipfs_ingest, build_records, 5},
        {ecai_disk_indexer, add_records, 2},
        {damage_ipfs, get, 1},
        {damage_ipfs, cat_binary, 1}
    ],
    lists:foreach(fun assert_export/1, Required),

    ?assertEqual(ecai_terms:version(), ecai_ingest_event:pipeline_version()),

    {ok, [Chunk]} = ecai_chunker:chunk_utf8(<<"abc">>, 4, 1),
    ?assertEqual(ecai_chunker:version(), maps:get(chunker, Chunk)),

    BadText = <<16#C3, 16#28>>,
    BadChunk = #{
        chunker => ecai_chunker:version(),
        ordinal => 1,
        byte_start => 0,
        byte_end => byte_size(BadText),
        text => BadText
    },
    Fields = #{
        title => <<"title">>,
        heading => <<>>,
        type => <<"ipfs">>,
        tags => []
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

assert_export({Module, Function, Arity}) ->
    ?assertEqual({module, Module}, code:ensure_loaded(Module)),
    ?assert(erlang:function_exported(Module, Function, Arity)).
