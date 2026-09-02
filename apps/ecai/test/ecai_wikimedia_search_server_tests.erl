-module(ecai_wikimedia_search_server_tests).

-include_lib("eunit/include/eunit.hrl").

activation_is_owned_and_restartable_test() ->
    OldPath = application:get_env(ecai, wikimedia_active_search_state_path),
    Base = filename:join(
        temp_dir(), "ecai-wikimedia-search-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Snapshot = filename:join(Base, "job-work/search.etf"),
    Active = filename:join(Base, "state/active.etf"),
    ok = filelib:ensure_dir(Snapshot),
    application:set_env(ecai, wikimedia_active_search_state_path, Active),
    Source = ecai_search:new(),
    try
        ok = ecai_search:add_record(Source, <<"enwiki:42">>, #{
            name => <<"Quantum mechanics">>,
            title => <<"Quantum mechanics">>,
            abstract => <<"Physics theory">>,
            category => <<"wikipedia">>,
            language => <<"en">>,
            wikidata_id => <<"Q944">>
        }),
        ok = ecai_search:save(Source, Snapshot),
        {ok, Pid1} = gen_server:start_link(ecai_wikimedia_search_server, [], []),
        Status1 =
            try
                ok = gen_server:call(
                    Pid1, {activate_snapshot, Snapshot, #{job_id => <<"test">>}}, infinity
                ),
                {ok, Search1} = gen_server:call(
                    Pid1, {search, <<"quantum">>, #{limit => 5}}, infinity
                ),
                [Result1 | _] = maps:get(results, Search1),
                ?assertEqual(<<"enwiki:42">>, maps:get(doc_id, Result1)),
                Status = gen_server:call(Pid1, status),
                ?assertEqual(true, maps:get(ready, Status)),
                Installed = binary_to_list(maps:get(snapshot_path, Status)),
                ?assert(filename:absname(Snapshot) =/= filename:absname(Installed)),
                ?assert(string:str(Installed, "wikimedia-search-snapshots") > 0),
                ?assert(filelib:is_regular(Installed)),
                Status
            after
                stop_server(Pid1)
            end,
        %% Simulate cleanup of the job work directory. The active index must
        %% still restore from the server-owned immutable snapshot.
        _ = file:delete(Snapshot),
        {ok, Pid2} = gen_server:start_link(ecai_wikimedia_search_server, [], []),
        try
            {ok, Search2} = gen_server:call(Pid2, {search, <<"quantum">>, #{limit => 5}}, infinity),
            ?assertEqual(<<"enwiki:42">>, maps:get(doc_id, hd(maps:get(results, Search2)))),
            Status2 = gen_server:call(Pid2, status),
            ?assertEqual(maps:get(snapshot_path, Status1), maps:get(snapshot_path, Status2)),
            ?assertEqual(true, maps:is_key(snapshot_sha256, maps:get(metadata, Status2)))
        after
            stop_server(Pid2)
        end
    after
        ok = ecai_search:wipe(Source),
        restore_env(wikimedia_active_search_state_path, OldPath),
        remove_tree(Base)
    end.

stop_server(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    ok.

restore_env(Key, undefined) -> application:unset_env(ecai, Key);
restore_env(Key, {ok, Value}) -> application:set_env(ecai, Key, Value).

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
                    lists:foreach(fun(Name) -> remove_tree(filename:join(Path, Name)) end, Names);
                _ ->
                    ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _} ->
            _ = file:delete(Path),
            ok;
        _ ->
            ok
    end.
