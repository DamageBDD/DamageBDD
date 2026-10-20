-module(ecai_source_retrieval_tests).
-include_lib("eunit/include/eunit.hrl").

exact_utf8_source_survives_docstore_reopen_test() ->
    with_tmp(fun(Dir) ->
        Text = <<"line one\r\n",16#03BB/utf8," and exact trailing spaces  \n">>,
        {ok,Ref} = ecai_source_retrieval:retain(Dir,Text,<<"fixture">>,<<"v1">>),
        {ok,Tab} = ecai_disk_docstore:open(Dir),
        try
            ok = ecai_disk_docstore:put(Tab,1,#{text => <<"preview">>,source_blob => Ref}),
            ok = ecai_disk_docstore:sync(Tab)
        after ecai_disk_docstore:close(Tab) end,
        {ok,Found} = ecai_source_retrieval:disk(Dir,1),
        ?assertEqual(Text,maps:get(text,Found)),
        ?assertEqual(true,maps:get(complete,Found)),
        ?assertEqual(verified_sha256,maps:get(integrity,Found)),
        ?assertEqual({ok,Found},ecai_source_retrieval:disk_source(Dir,<<"fixture">>,<<"v1">>)),
        ?assertEqual(1,length(filelib:wildcard(filename:join([Dir,"sources","*.bin"]))))
    end).

changed_bytes_rejected_test() ->
    with_tmp(fun(Dir) ->
        {ok,Ref} = ecai_source_retrieval:retain(Dir,<<"alpha">>,<<"fixture">>,<<"v1">>),
        {ok,Tab} = ecai_disk_docstore:open(Dir),
        try ok = ecai_disk_docstore:put(Tab,1,#{source_blob => Ref})
        after ecai_disk_docstore:close(Tab) end,
        [Path] = filelib:wildcard(filename:join([Dir,"sources","*.bin"])),
        ok = file:write_file(Path,<<"omega">>),
        ?assertEqual({error,source_hash_mismatch},ecai_source_retrieval:disk(Dir,1)),
        ?assertEqual({error,source_blob_corrupt},
            ecai_source_retrieval:retain(Dir,<<"alpha">>,<<"fixture">>,<<"v1">>))
    end).

same_source_version_cannot_change_content_test() ->
    with_tmp(fun(Dir) ->
        {ok,A} = ecai_source_retrieval:retain(Dir,<<"alpha">>,<<"fixture">>,<<"v1">>),
        {ok,B} = ecai_source_retrieval:retain(Dir,<<"beta">>,<<"fixture">>,<<"v1">>),
        {ok,Tab} = ecai_disk_docstore:open(Dir),
        try
            ok = ecai_disk_docstore:put(Tab,1,#{source_blob => A}),
            ?assertEqual({error,source_version_conflict},ecai_disk_docstore:put(Tab,2,#{source_blob => B}))
        after ecai_disk_docstore:close(Tab) end
    end).

legacy_excerpt_never_claims_complete_test() ->
    Record = #{text => <<"only a preview">>,source_complete => true},
    {ok,Source} = ecai_source_retrieval:from_record(Record),
    ?assertEqual(false,maps:get(complete,Source)),
    ?assertEqual(false,maps:get(complete,ecai_source_retrieval:describe(Record))),
    ?assertEqual(unverified,maps:get(integrity,Source)).

read_does_not_create_index_test() ->
    with_tmp(fun(Dir) ->
        Missing = filename:join(Dir,"missing"),
        ?assertEqual({error,source_not_found},ecai_source_retrieval:disk(Missing,1)),
        ?assertEqual(false,filelib:is_dir(Missing))
    end).

inline_source_pin_is_verified_test() ->
    R = inline(<<"the entire dump text">>),
    {ok,S} = ecai_source_retrieval:from_record(R),
    ?assertEqual(verified_sha256,maps:get(integrity,S)),
    ?assertEqual(false,maps:is_key(source_text,ecai_source_retrieval:summary(R))),
    ?assertEqual({error,source_hash_mismatch},
        ecai_source_retrieval:from_record(R#{source_text => <<"tampered">>})),
    ?assertEqual({error,invalid_source_descriptor},
        ecai_source_retrieval:from_record(R#{source_complete => <<"true">>})).

inline_projection_cannot_override_integrity_descriptor_test() ->
    R = (inline(<<"full">>))#{source_retrieval => #{complete => false,sha256 => <<"fake">>}},
    {ok,S} = ecai_source_retrieval:from_record(R),
    ?assertEqual(true,maps:get(complete,S)),
    ?assertEqual(hash(<<"full">>),maps:get(sha256,S)).

reassembles_overlapping_utf8_chunks_exactly_test() ->
    Text = binary:copy(<<"alpha ",16#03BB/utf8," beta\n">>,40),
    Records = chunks(Text),
    {ok,S} = ecai_source_retrieval:reassemble(lists:reverse(Records),byte_size(Text),hash(Text)),
    ?assertEqual(Text,maps:get(text,S)),
    ?assertEqual(true,maps:get(complete,S)).

rejects_missing_or_mixed_chunks_test() ->
    Text = binary:copy(<<"alpha beta gamma\n">>,40),
    [First,Second|Rest] = Records = chunks(Text),
    ?assertEqual({error,chunk_ordinal_gap},
        ecai_source_retrieval:reassemble([First|Rest],byte_size(Text),hash(Text))),
    ?assertEqual({error,mixed_source_versions},
        ecai_source_retrieval:reassemble([First,Second#{source_version => <<"v2">>}|Rest],byte_size(Text),hash(Text))),
    ?assertEqual({error,incomplete_source},
        ecai_source_retrieval:reassemble(lists:droplast(Records),byte_size(Text),hash(Text))).

rejects_inconsistent_overlap_even_with_updated_chunk_hash_test() ->
    Text = binary:copy(<<"alpha beta gamma\n">>,40),
    [First,Second|Rest] = chunks(Text),
    <<_,Tail/binary>> = maps:get(text,Second),
    Changed = <<$X,Tail/binary>>,
    Bad = Second#{text => Changed,chunk_content_sha256 => crypto:hash(sha256,Changed)},
    ?assertEqual({error,chunk_overlap_mismatch},
        ecai_source_retrieval:reassemble([First,Bad|Rest],byte_size(Text),hash(Text))).

inline(Text) -> #{text => <<"preview">>,source_text => Text,source_sha256 => hash(Text),
    source_bytes => byte_size(Text),source_complete => true,source_representation => <<"test_text_field">>}.
hash(Text) -> ecai_index_job_codec:id_hex(crypto:hash(sha256,Text)).
chunks(Text) ->
    {ok,Cs} = ecai_chunker:chunk_utf8(Text,90,20),
    [#{text => maps:get(text,C),chunk_ordinal => maps:get(ordinal,C),
       chunk_byte_start => maps:get(byte_start,C),chunk_byte_end => maps:get(byte_end,C),
       chunker => maps:get(chunker,C),source_key => <<"fixture">>,source_version => <<"v1">>,
       chunk_content_sha256 => crypto:hash(sha256,maps:get(text,C))} || C <- Cs].
with_tmp(Fun) ->
    Dir = filename:join(temp_root(),"ecai-source-tests-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
temp_root() -> case os:getenv("TMPDIR") of false -> "/tmp"; Path -> Path end.
