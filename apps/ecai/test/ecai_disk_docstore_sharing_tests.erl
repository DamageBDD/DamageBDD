%% Real DETS/ECS1 regressions. Readers must join the writer's table without
%% publishing its pending postings or replacing its metadata/counter state.
-module(ecai_disk_docstore_sharing_tests).
-include_lib("eunit/include/eunit.hrl").

nested_open_preserves_unsynced_metadata_test() ->
    with_dir(fun(Dir) ->
        One = #{title => <<"first buffered document">>},
        Two = #{title => <<"writer still owns the table">>},
        {ok, Writer} = ecai_disk_docstore:open(Dir),
        try
            {ok, 1} = ecai_disk_docstore:next_id(Writer),
            ok = ecai_disk_docstore:put(Writer, 1, One),
            %% Intentionally no sync before the nested reader open.
            {ok, Reader} = ecai_disk_docstore:open(unicode:characters_to_binary(Dir)),
            try
                ?assertEqual(Writer, Reader),
                ?assertMatch({ecai_disk_docstore, _}, Reader),
                ?assertEqual({ok, One}, ecai_disk_docstore:get(Reader, 1))
            after
                ok = ecai_disk_docstore:close(Reader)
            end,
            {ok, 2} = ecai_disk_docstore:next_id(Writer),
            ok = ecai_disk_docstore:put(Writer, 2, Two)
        after
            ok = ecai_disk_docstore:close(Writer)
        end,
        {ok, Reopened} = ecai_disk_docstore:open(Dir),
        try
            ?assertEqual({ok, One}, ecai_disk_docstore:get(Reopened, 1)),
            ?assertEqual({ok, Two}, ecai_disk_docstore:get(Reopened, 2)),
            ?assertEqual({ok, 3}, ecai_disk_docstore:next_id(Reopened))
        after
            ok = ecai_disk_docstore:close(Reopened)
        end
    end).

reader_exit_does_not_close_writer_test() ->
    with_dir(fun(Dir) ->
        Record = #{title => <<"unsynced document">>},
        {ok, Writer} = ecai_disk_docstore:open(Dir),
        try
            {ok, 1} = ecai_disk_docstore:next_id(Writer),
            ok = ecai_disk_docstore:put(Writer, 1, Record),
            Worker = start_worker(fun() ->
                {ok, Reader} = ecai_disk_docstore:open(Dir),
                %% Process exit, not explicit close, releases this open.
                {Reader, ecai_disk_docstore:get(Reader, 1)}
            end),
            ?assertEqual({Writer, {ok, Record}}, await_worker(Worker)),
            ?assertEqual({ok, Record}, ecai_disk_docstore:get(Writer, 1)),
            ?assertEqual({ok, 2}, ecai_disk_docstore:next_id(Writer)),
            ok = ecai_disk_docstore:sync(Writer)
        after
            ok = ecai_disk_docstore:close(Writer),
            await_closed(Writer, erlang:monotonic_time(millisecond) + 2000)
        end
    end).

parallel_first_opens_allocate_unique_ids_test_() ->
    {timeout, 20, fun() -> with_dir(fun(Dir) ->
        Start = make_ref(),
        Workers = [start_worker(fun() ->
            receive Start -> ok end,
            {ok, Tab} = ecai_disk_docstore:open(Dir),
            try
                {ok, Id} = ecai_disk_docstore:next_id(Tab),
                ok = ecai_disk_docstore:put(Tab, Id, #{writer => N}),
                {Tab, Id, N}
            after
                ok = ecai_disk_docstore:close(Tab)
            end
        end) || N <- lists:seq(1, 12)],
        try
            [Pid ! Start || {Pid, _, _} <- Workers],
            Rows = [await_worker(W) || W <- Workers],
            ?assertEqual(1, length(lists:usort([T || {T, _, _} <- Rows]))),
            ?assertEqual(lists:seq(1, 12), lists:sort([I || {_, I, _} <- Rows])),
            {ok, Tab} = ecai_disk_docstore:open(Dir),
            try
                [?assertEqual({ok, #{writer => N}}, ecai_disk_docstore:get(Tab, Id))
                    || {_, Id, N} <- Rows],
                ?assertEqual({ok, 13}, ecai_disk_docstore:next_id(Tab))
            after
                ok = ecai_disk_docstore:close(Tab)
            end
        after
            [stop_worker(W) || W <- Workers]
        end
    end) end}.

different_directories_are_isolated_test() ->
    with_dir(fun(Dir) ->
        {ok, A} = ecai_disk_docstore:open(filename:join(Dir, "a")),
        try
            {ok, B} = ecai_disk_docstore:open(filename:join(Dir, "b")),
            try
                ?assertNotEqual(A, B),
                {ok, 1} = ecai_disk_docstore:next_id(A),
                {ok, 1} = ecai_disk_docstore:next_id(B),
                ok = ecai_disk_docstore:put(A, 1, #{title => <<"A">>}),
                ?assertEqual(not_found, ecai_disk_docstore:get(B, 1)),
                ok = ecai_disk_docstore:put(B, 1, #{title => <<"B">>}),
                ?assertEqual({ok, #{title => <<"A">>}}, ecai_disk_docstore:get(A, 1))
            after
                ok = ecai_disk_docstore:close(B)
            end
        after
            ok = ecai_disk_docstore:close(A)
        end
    end).

existing_dets_file_needs_no_migration_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join([Dir, "docstore", "ecai_docstore.dets"]),
        ok = filelib:ensure_dir(Path),
        %% The previous creator used an unrelated table name. Names are not
        %% part of the on-disk metadata key/value schema.
        {ok, Legacy} = dets:open_file(?MODULE, [{file, Path}, {type, set}]),
        try
            ok = dets:insert(Legacy, [{'$next_id', 8}, {7, #{title => <<"legacy">>}}])
        after
            ok = dets:close(Legacy)
        end,
        {ok, Tab} = ecai_disk_docstore:open(Dir),
        try
            ?assertEqual({ok, #{title => <<"legacy">>}}, ecai_disk_docstore:get(Tab, 7)),
            ?assertEqual({ok, 8}, ecai_disk_docstore:next_id(Tab))
        after
            ok = ecai_disk_docstore:close(Tab)
        end
    end).

invalid_counter_does_not_close_existing_owner_test() ->
    with_dir(fun(Dir) ->
        {ok, Writer} = ecai_disk_docstore:open(Dir),
        try
            ok = ecai_disk_docstore:put(Writer, 1, #{title => <<"kept">>}),
            ok = dets:insert(Writer, {'$next_id', invalid}),
            ?assertEqual(
                {error, {invalid_next_id_record, [{'$next_id', invalid}]}},
                ecai_disk_docstore:open(Dir)
            ),
            ?assertEqual({ok, #{title => <<"kept">>}}, ecai_disk_docstore:get(Writer, 1)),
            ok = dets:insert(Writer, {'$next_id', 2}),
            ?assertEqual({ok, 2}, ecai_disk_docstore:next_id(Writer))
        after
            ok = ecai_disk_docstore:close(Writer)
        end
    end).

published_search_preserves_pending_batch_test() ->
    with_dir(fun(Dir) ->
        Opts = #{max_docs => 100, flush_interval_ms => 60000},
        S0 = ecai_disk_indexer:new(Dir, Opts),
        S1 = ecai_disk_indexer:add_records(S0, [#{title => <<"Redirect published">>}]),
        S2 = ecai_disk_indexer:flush(S1),
        S3 = ecai_disk_indexer:add_records(S2, [#{title => <<"Redirect pending">>}]),
        try
            %% Unlike an empty-manifest shortcut, this forces metadata reads
            %% while another document is buffered in the same writer.
            {Hits, _} = await_worker(start_worker(fun() ->
                ecai_disk_search:text_search(Dir, <<"redire">>, 10, bool_prefix)
            end)),
            ?assertEqual([1], ids(Hits)),
            ?assertMatch({[], _},
                ecai_disk_search:text_search(Dir, <<"redirect pen">>, 10, bool_prefix)),
            ?assertEqual(1, length(ecai_disk_manifest:list_segments(Dir)))
        after
            ok = ecai_disk_indexer:close(S3)
        end,
        {Published, _} = ecai_disk_search:text_search(Dir, <<"redire">>, 10, bool_prefix),
        ?assertEqual([1, 2], ids(Published)),
        ?assertEqual([<<"Redirect pending">>, <<"Redirect published">>],
            lists:sort([maps:get(title, maps:get(record, H)) || H <- Published]))
    end).

aborted_batch_stays_unpublished_after_reader_test() ->
    with_dir(fun(Dir) ->
        Opts = #{max_docs => 100, flush_interval_ms => 60000},
        S0 = ecai_disk_indexer:new(Dir, Opts),
        S1 = ecai_disk_indexer:add_records(S0, [#{title => <<"Redirect published">>}]),
        S2 = ecai_disk_indexer:flush(S1),
        S3 = ecai_disk_indexer:add_records(S2, [#{title => <<"Redirect aborted">>}]),
        try
            {Hits, _} = ecai_disk_search:text_search(Dir, <<"redire">>, 10, bool_prefix),
            ?assertEqual([1], ids(Hits))
        after
            ok = ecai_disk_indexer:abort(S3)
        end,
        ?assertMatch({[], _},
            ecai_disk_search:text_search(Dir, <<"redirect abo">>, 10, bool_prefix)),
        S4 = ecai_disk_indexer:new(Dir, Opts),
        S5 = ecai_disk_indexer:add_records(S4, [#{title => <<"Redirect next">>}]),
        ok = ecai_disk_indexer:close(S5),
        {Final, _} = ecai_disk_search:text_search(Dir, <<"redire">>, 10, bool_prefix),
        %% Metadata IDs are not reused, but unpublished postings stay hidden.
        ?assertEqual([1, 3], ids(Final))
    end).

ids(Hits) -> lists:sort([maps:get(doc_id, H) || H <- Hits]).

start_worker(Fun) ->
    Ref = make_ref(),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try {ok, Fun()}
                 catch Class:Reason:Stack -> {exception, Class, Reason, Stack}
                 end,
        Parent ! {Ref, Result}
    end),
    {Pid, Mon, Ref}.

await_worker({Pid, Mon, Ref} = Worker) ->
    receive
        {Ref, {ok, Value}} ->
            receive
                {'DOWN', Mon, process, Pid, normal} -> Value;
                {'DOWN', Mon, process, Pid, Why} -> erlang:error({worker_exit, Why})
            after 5000 ->
                stop_worker(Worker),
                erlang:error(worker_exit_timeout)
            end;
        {Ref, {exception, Class, Reason, Stack}} ->
            stop_worker(Worker),
            erlang:raise(Class, Reason, Stack);
        {'DOWN', Mon, process, Pid, Why} ->
            erlang:error({worker_exit, Why})
    after 5000 ->
        stop_worker(Worker),
        erlang:error(worker_timeout)
    end.

stop_worker({Pid, Mon, Ref}) ->
    exit(Pid, kill),
    erlang:demonitor(Mon, [flush]),
    receive {Ref, _} -> ok after 0 -> ok end.

%% DETS handles process-exit notifications asynchronously. Wait for cleanup,
%% not for publication: no query assertion relies on this wait.
await_closed(Tab, Deadline) ->
    case dets:info(Tab) of
        undefined -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error(docstore_close_timeout);
                false ->
                    receive after 5 -> ok end,
                    await_closed(Tab, Deadline)
            end
    end.

with_dir(Fun) ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(Root, "ecai-docstore-sharing-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
