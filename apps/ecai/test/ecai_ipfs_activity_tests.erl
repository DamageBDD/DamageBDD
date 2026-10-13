-module(ecai_ipfs_activity_tests).

-include_lib("eunit/include/eunit.hrl").

local_activity_rotation_and_recovery_test() ->
    with_tmp(fun(Dir) ->
        {ok, A0} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false, sync_every => 1, block_bytes => 1048576}
        ),
        {ok, A1} = ecai_ipfs_activity:append(A0, #{type => started}),
        {ok, A2} = ecai_ipfs_activity:append(
            A1,
            #{type => checkpoint, completed => 1}
        ),
        {ok, A3} = ecai_ipfs_activity:flush(A2),
        Status1 = ecai_ipfs_activity:status(A3),
        ?assertEqual(2, maps:get(sequence, Status1)),
        ?assertEqual(0, maps:get(pending_events, Status1)),
        ?assertEqual(1, maps:get(published_blocks, Status1)),
        ?assertMatch(<<"sha256:", _/binary>>, maps:get(previous_cid, Status1)),
        ?assertEqual(
            1,
            length(
                filelib:wildcard(
                    filename:join([Dir, "activity", "activity-*.ndjson"])
                )
            )
        ),

        {ok, Recovered} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false}
        ),
        Status2 = ecai_ipfs_activity:status(Recovered),
        ?assertEqual(2, maps:get(sequence, Status2)),
        ?assertEqual(0, maps:get(pending_events, Status2)),
        ?assertEqual(1, maps:get(published_blocks, Status2))
    end).

pending_activity_recovers_last_sequence_test() ->
    with_tmp(fun(Dir) ->
        {ok, A0} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false, sync_every => 1, block_bytes => 1048576}
        ),
        {ok, A1} = ecai_ipfs_activity:append(A0, #{type => started}),
        {ok, _A2} = ecai_ipfs_activity:append(A1, #{type => progress}),

        {ok, Recovered0} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false, sync_every => 1, block_bytes => 1048576}
        ),
        Status0 = ecai_ipfs_activity:status(Recovered0),
        ?assertEqual(2, maps:get(sequence, Status0)),
        ?assertEqual(2, maps:get(pending_events, Status0)),

        {ok, Recovered1} = ecai_ipfs_activity:append(
            Recovered0,
            #{type => resumed}
        ),
        ?assertEqual(3, maps:get(sequence, ecai_ipfs_activity:status(Recovered1)))
    end).

torn_pending_tail_is_repaired_test() ->
    with_tmp(fun(Dir) ->
        {ok, A0} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false, sync_every => 1, block_bytes => 1048576}
        ),
        {ok, A1} = ecai_ipfs_activity:append(A0, #{type => started}),
        Pending = maps:get(pending_path, A1),
        ok = file:write_file(
            Pending,
            <<"{\"sequence\":2">>,
            [append, raw, binary, sync]
        ),
        {ok, Recovered} = ecai_ipfs_activity:open(
            Dir,
            #{publish_ipfs => false}
        ),
        Status = ecai_ipfs_activity:status(Recovered),
        ?assertEqual(1, maps:get(sequence, Status)),
        ?assertEqual(1, maps:get(pending_events, Status)),
        ?assert(maps:get(repaired_bytes_at_startup, Status) > 0)
    end).

corrupt_state_fails_closed_test() ->
    with_tmp(fun(Dir) ->
        ActivityDir = filename:join(Dir, "activity"),
        ok = filelib:ensure_dir(filename:join(ActivityDir, "x")),
        StatePath = filename:join(ActivityDir, "state.json"),
        ok = file:write_file(
            StatePath,
            <<"{not-json">>,
            [write, raw, binary, sync]
        ),
        ?assertMatch(
            {error, {activity_state_corrupt, StatePath, _}},
            ecai_ipfs_activity:open(Dir, #{publish_ipfs => false})
        )
    end).

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-ipfs-activity-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try
        Fun(Dir)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    lists:foreach(
                        fun(Name) -> remove_tree(filename:join(Path, Name)) end,
                        Names
                    );
                _ ->
                    ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _Info} ->
            _ = file:delete(Path),
            ok;
        _ ->
            ok
    end.
