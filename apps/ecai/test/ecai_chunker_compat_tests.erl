-module(ecai_chunker_compat_tests).

-include_lib("eunit/include/eunit.hrl").

merged_runtime_contract_test() ->
    {module, ecai_chunker} = code:ensure_loaded(ecai_chunker),
    Required = [
        {start_link, 0},
        {start, 3},
        {start, 4},
        {status, 0},
        {cancel, 0},
        {make_chunks_ndjson, 3},
        {make_chunks_ndjson, 4},
        {chunk_path, 1},
        {version, 0},
        {validate_utf8, 1},
        {chunk_utf8, 3},
        {fold_utf8, 5}
    ],
    lists:foreach(
        fun({Function, Arity}) ->
            ?assert(erlang:function_exported(ecai_chunker, Function, Arity))
        end,
        Required
    ).

loader_path_contract_test() ->
    {module, ecai_yelp_loader} = code:ensure_loaded(ecai_yelp_loader),
    {module, ecai_wikipedia_loader} = code:ensure_loaded(ecai_wikipedia_loader),
    {module, ecai_wikipedia_chunker} = code:ensure_loaded(ecai_wikipedia_chunker),
    ?assert(erlang:function_exported(ecai_yelp_loader, make_chunks_ndjson, 3)),
    ?assert(erlang:function_exported(ecai_yelp_loader, index_chunks, 3)),
    ?assert(erlang:function_exported(ecai_wikipedia_loader, load, 1)),
    ?assert(erlang:function_exported(ecai_wikipedia_loader, load, 2)),
    ?assert(erlang:function_exported(ecai_wikipedia_loader, load_chunks, 1)),
    ?assert(erlang:function_exported(ecai_wikipedia_loader, load_chunks, 2)),
    ?assertEqual(ok, ecai_wikipedia_loader:load_chunks([], #{})).

utf8_compatibility_facade_test() ->
    {module, ecai_utf8_chunker} = code:ensure_loaded(ecai_utf8_chunker),
    ?assertEqual(ecai_chunker:version(), ecai_utf8_chunker:version()),
    ?assertEqual(
        ecai_chunker:chunk_utf8(<<"abcdef">>, 3, 1),
        ecai_utf8_chunker:chunk_utf8(<<"abcdef">>, 3, 1)
    ),
    ?assertEqual(
        {error, {invalid_utf8, 0}},
        ecai_utf8_chunker:validate_utf8(<<16#C3, 16#28>>)
    ).

chunk_reference_compatibility_test() ->
    Path = <<"/tmp/chunk.ndjson">>,
    ?assertEqual(Path, ecai_chunker:chunk_path(Path)),
    ?assertEqual(Path, ecai_chunker:chunk_path(binary_to_list(Path))),
    ?assertEqual(Path, ecai_chunker:chunk_path(#{path => Path})),
    ?assertEqual(Path, ecai_chunker:chunk_path(#{<<"path">> => Path})),
    ?assertEqual(Path, ecai_chunker:chunk_path({Path, <<"cid">>})).

yelp_and_wikipedia_line_chunking_test_() ->
    {setup, fun setup_files/0, fun cleanup_files/1, fun(Context) ->
        [
            ?_test(assert_yelp_compatibility(Context)),
            ?_test(assert_wikipedia_compatibility(Context)),
            ?_test(assert_legacy_async_yelp_job(Context))
        ]
    end}.

setup_files() ->
    Unique = integer_to_list(erlang:unique_integer([monotonic, positive])),
    Base = filename:join(temp_dir(), "ecai_chunker_merge_" ++ Unique),
    Input = filename:join(Base, "source.jsonl"),
    YelpOut = filename:join(Base, "yelp"),
    WikiOut = filename:join(Base, "wiki"),
    AsyncOut = filename:join(Base, "async_yelp"),
    ok = filelib:ensure_dir(Input),
    Source = <<
        "{\"n\":1}\n",
        "{\"n\":2}\n",
        "{\"n\":3}\n",
        "{\"n\":4}\n",
        "{\"n\":5}\n"
    >>,
    ok = file:write_file(Input, Source, [raw, binary]),
    #{
        base => Base,
        input => Input,
        yelp_out => YelpOut,
        wiki_out => WikiOut,
        async_out => AsyncOut
    }.

cleanup_files(#{base := Base}) ->
    remove_tree(Base).

assert_yelp_compatibility(#{input := Input, yelp_out := OutDir}) ->
    Paths = ecai_yelp_loader:make_chunks_ndjson(Input, OutDir, 2),
    ?assertEqual(
        [
            <<"chunk_000001.ndjson">>,
            <<"chunk_000002.ndjson">>,
            <<"chunk_000003.ndjson">>
        ],
        [filename:basename(Path) || Path <- Paths]
    ),
    ?assertEqual(
        [
            <<"{\"n\":1}\n{\"n\":2}\n">>,
            <<"{\"n\":3}\n{\"n\":4}\n">>,
            <<"{\"n\":5}\n">>
        ],
        [read_file(Path) || Path <- Paths]
    ).

assert_wikipedia_compatibility(#{input := Input, wiki_out := OutDir}) ->
    Chunks = ecai_wikipedia_chunker:make_chunks_ndjson(Input, OutDir, 2),
    ?assertEqual([0, 1, 2], [maps:get(index, Chunk) || Chunk <- Chunks]),
    ?assertEqual([1, 3, 5], [maps:get(start_line, Chunk) || Chunk <- Chunks]),
    ?assertEqual([2, 2, 1], [maps:get(line_count, Chunk) || Chunk <- Chunks]),
    ?assertEqual(
        [
            <<"wiki_chunk_000000.jsonl">>,
            <<"wiki_chunk_000001.jsonl">>,
            <<"wiki_chunk_000002.jsonl">>
        ],
        [filename:basename(maps:get(path, Chunk)) || Chunk <- Chunks]
    ),
    ?assertEqual(
        [
            legacy_wikipedia_chunk_id(Input, 1, 2),
            legacy_wikipedia_chunk_id(Input, 3, 2),
            legacy_wikipedia_chunk_id(Input, 5, 1)
        ],
        [maps:get(chunk_id, Chunk) || Chunk <- Chunks]
    ),
    ?assert(
        lists:all(
            fun(Chunk) ->
                maps:get(chunker, Chunk) =:= ecai_chunker:line_version()
            end,
            Chunks
        )
    ),
    ?assertEqual(
        [
            <<"{\"n\":1}\n{\"n\":2}\n">>,
            <<"{\"n\":3}\n{\"n\":4}\n">>,
            <<"{\"n\":5}\n">>
        ],
        [read_file(maps:get(path, Chunk)) || Chunk <- Chunks]
    ).

assert_legacy_async_yelp_job(#{input := Input, async_out := OutDir}) ->
    WasRunning = is_pid(whereis(ecai_chunker)),
    try
        {ok, JobId} = ecai_chunker:start(Input, OutDir, 2),
        Status = wait_for_chunk_job(JobId, 200),
        ?assertEqual(done, maps:get(status, Status)),
        Result = maps:get(result, Status),
        Paths = maps:get(paths, Result),
        ?assertEqual(3, maps:get(count, Result)),
        ?assertEqual(yelp, maps:get(profile, Result)),
        ?assertEqual(Paths, persistent_term:get(ecai_admin_chunks)),
        ?assertEqual(
            [
                <<"chunk_000001.ndjson">>,
                <<"chunk_000002.ndjson">>,
                <<"chunk_000003.ndjson">>
            ],
            [filename:basename(Path) || Path <- Paths]
        )
    after
        case WasRunning of
            false ->
                case whereis(ecai_chunker) of
                    undefined -> ok;
                    _Pid -> gen_server:stop(ecai_chunker)
                end;
            true ->
                ok
        end,
        _ = persistent_term:erase(ecai_admin_chunks)
    end.

wait_for_chunk_job(_JobId, 0) ->
    erlang:error(chunk_job_timeout);
wait_for_chunk_job(JobId, Attempts) ->
    case ecai_chunker:status() of
        #{job_id := JobId, status := done} = Status ->
            Status;
        #{job_id := JobId, status := error} = Status ->
            erlang:error({chunk_job_failed, Status});
        #{job_id := JobId, status := canceled} = Status ->
            erlang:error({chunk_job_canceled, Status});
        _Other ->
            timer:sleep(10),
            wait_for_chunk_job(JobId, Attempts - 1)
    end.

legacy_wikipedia_chunk_id(Input, StartLine, LineCount) ->
    crypto:hash(
        sha256,
        term_to_binary({path_list(Input), StartLine, LineCount})
    ).

read_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

path_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
path_list(List) when is_list(List) -> unicode:characters_to_list(List).

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Child = filename:join(Path, Name),
                    case filelib:is_dir(Child) of
                        true -> remove_tree(Child);
                        false -> _ = file:delete(Child)
                    end
                end,
                Names
            ),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} ->
            ok;
        {error, _Reason} ->
            ok
    end.
