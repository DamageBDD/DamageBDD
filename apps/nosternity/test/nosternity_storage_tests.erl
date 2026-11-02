-module(nosternity_storage_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

storage_test_() ->
    [?_test(isolated(F)) || F <- [fun path_precedence/1, fun validation/1,
        fun fresh_store_and_restart/1, fun auth_default_path/1, fun legacy_guard/1, fun bad_parent/1,
        fun corrupt_store/1, fun replay_failure_closes_store/1]].

path_precedence(Dir) ->
    Default = filename:join([Dir, "state", "dets", "nosternity"]),
    ?assertEqual(Default, nosternity_config:get(data_dir)),
    ?assertEqual(filename:join(Default, "search.dets"), nosternity_config:get(search_store_file)),
    ?assertEqual(filename:join(Default, "accounts.dets"), nosternity_config:get(auth_store_file)),
    application:unset_env(damage, state_dir),
    application:set_env(damage, secrets_state_dir, filename:join(Dir, "legacy-state")),
    ?assertEqual(filename:join([Dir, "legacy-state", "dets", "nosternity"]), nosternity_config:get(data_dir)),
    application:unset_env(damage, secrets_state_dir),
    SavedXdg = os:getenv("XDG_STATE_HOME"),
    try
        os:putenv("XDG_STATE_HOME", filename:join(Dir, "xdg")),
        ?assertEqual(filename:join([Dir, "xdg", "damage", "dets", "nosternity"]), nosternity_config:get(data_dir)),
        os:unsetenv("XDG_STATE_HOME"),
        Expected = case os:getenv("HOME") of
            false -> "/var/lib/damage";
            "" -> "/var/lib/damage";
            Home -> filename:join([Home, ".local", "state", "damage"])
        end,
        ?assertEqual(filename:join([Expected, "dets", "nosternity"]), nosternity_config:get(data_dir))
    after restore_os("XDG_STATE_HOME", SavedXdg) end,
    application:set_env(nosternity, data_dir, unicode:characters_to_binary(filename:join(Dir, "custom-λ"))),
    ?assertEqual(filename:join([Dir, "custom-λ", "accounts.dets"]), nosternity_config:get(auth_store_file)),
    application:set_env(nosternity, search_store_file, <<"relative/events.dets">>),
    ?assertEqual(filename:join([Dir, "relative", "events.dets"]), nosternity_config:get(search_store_file)),
    case os:getenv("HOME") of
        Home0 when is_list(Home0), Home0 =/= "" ->
            application:set_env(nosternity, auth_store_file, <<"~/nosternity/accounts.dets">>),
            ?assertEqual(filename:join([Home0, "nosternity", "accounts.dets"]), nosternity_config:get(auth_store_file));
        _ -> ok
    end,
    %% A per-file override does not evaluate an unrelated invalid data_dir.
    application:set_env(nosternity, data_dir, invalid),
    ?assertEqual(filename:join([Dir, "relative", "events.dets"]), nosternity_config:get(search_store_file)).

validation(_Dir) ->
    lists:foreach(fun(Key) ->
        lists:foreach(fun(Value) ->
            application:set_env(nosternity, Key, Value),
            ?assertError({invalid_configuration, Key}, nosternity_config:get(Key))
        end, [[], <<>>, undefined, [0], <<0>>, <<255>>, [16#110000], [16#d800]]),
        application:unset_env(nosternity, Key)
    end, [data_dir, search_store_file, auth_store_file]),
    ?assertEqual(ok, nosternity_config:validate()).

fresh_store_and_restart(_Dir) ->
    lists:foreach(fun({Key, Name, Repair}) ->
        {ok, Db, File} = nosternity_storage:open(Key, Name, Repair),
        ?assertEqual(filename:absname(File), File),
        ?assertEqual(true, filelib:is_dir(filename:dirname(File))),
        {ok, #file_info{mode = Mode}} = file:read_file_info(File),
        ?assertEqual(8#600, Mode band 8#777),
        Records = [{<<"event-or-account">>, #{retained => true}},
                   {'$node_settings', #{branding => <<"Saved brand">>}},
                   {<<"deletion">>, #{tombstone => true}}],
        ok = dets:insert(Db, Records), ok = dets:sync(Db), ok = dets:close(Db),
        {ok, Db, File} = nosternity_storage:open(Key, Name, Repair),
        ?assertEqual(lists:sort(Records), lists:sort(dets:foldl(fun(E, A) -> [E | A] end, [], Db))),
        ok = dets:close(Db),
        ?assertEqual([], filelib:wildcard(filename:join(filename:dirname(File), ".nosternity-write-*")))
    end, [{search_store_file, storage_events, true}, {auth_store_file, storage_accounts, false}]).

auth_default_path(Dir) ->
    File = filename:join([Dir, "state", "dets", "nosternity", "accounts.dets"]),
    {ok, Pid} = nosternity_auth:start_link(), unlink(Pid),
    try
        ?assertEqual(File, dets:info(nosternity_auth, filename)),
        ?assertMatch({error, unauthorized}, nosternity_auth:lookup(<<"invalid">>)),
        ok = dets:insert(nosternity_auth, {<<"persisted-account">>, #{preferences => #{}}}),
        ok = dets:sync(nosternity_auth),
        ok = gen_server:stop(Pid),
        {ok, Restarted} = nosternity_auth:start_link(), unlink(Restarted),
        ?assertEqual([{<<"persisted-account">>, #{preferences => #{}}}],
            dets:lookup(nosternity_auth, <<"persisted-account">>)),
        ?assertEqual(File, dets:info(nosternity_auth, filename))
    after
        case whereis(nosternity_auth) of
            undefined -> ok;
            Running -> gen_server:stop(Running)
        end
    end.

legacy_guard(Dir) ->
    lists:foreach(fun({Key, Basename}) ->
        Old = filename:join([Dir, "data", "nosternity", Basename]),
        ok = filelib:ensure_dir(Old),
        {ok, Db0} = dets:open_file(storage_legacy, [{file, Old}]),
        ok = dets:insert(Db0, {old_record, preserve}), ok = dets:close(Db0),
        New = nosternity_config:get(Key),
        ?assertMatch({error, {nosternity_store_unavailable, Key,
            #{operation := check_legacy_store, reason := {legacy_store_requires_migration, Old}}}},
            nosternity_storage:open(Key, storage_legacy, false)),
        ?assertEqual(false, filelib:is_file(New)),
        application:set_env(nosternity, Key, Old),
        {ok, Db, Old} = nosternity_storage:open(Key, storage_legacy, false),
        ?assertEqual([{old_record, preserve}], dets:lookup(Db, old_record)),
        ok = dets:close(Db), application:unset_env(nosternity, Key),
        %% Model an operator migration while the service is stopped.
        ok = filelib:ensure_dir(New), {ok, _} = file:copy(Old, New),
        {ok, Db, New} = nosternity_storage:open(Key, storage_legacy, false),
        ?assertEqual([{old_record, preserve}], dets:lookup(Db, old_record)),
        ok = dets:close(Db)
    end, [{search_store_file, "search.dets"}, {auth_store_file, "accounts.dets"}]).

bad_parent(Dir) ->
    Blocker = filename:join(Dir, "regular-file"), ok = file:write_file(Blocker, <<"keep">>),
    lists:foreach(fun({Key, Init}) ->
        File = filename:join(Blocker, "store.dets"), application:set_env(nosternity, Key, File),
        ?assertMatch({stop, {nosternity_store_unavailable, Key,
            #{file := File, operation := ensure_directory, reason := _}}}, Init())
    end, [{search_store_file, fun() -> nosternity_relay:init([]) end},
          {auth_store_file, fun() -> nosternity_auth:init([]) end}]),
    ?assertEqual({ok, <<"keep">>}, file:read_file(Blocker)).

corrupt_store(Dir) ->
    File = filename:join(Dir, "corrupt.dets"), Data = <<"not a DETS file">>,
    ok = file:write_file(File, Data), application:set_env(nosternity, auth_store_file, File),
    ?assertMatch({stop, {nosternity_store_unavailable, auth_store_file,
        #{file := File, operation := open_dets}}}, nosternity_auth:init([])),
    ?assertEqual({ok, Data}, file:read_file(File)).

replay_failure_closes_store(Dir) ->
    File = filename:join(Dir, "invalid-event.dets"),
    {ok, Db} = dets:open_file(nosternity_search_events, [{file, File}]),
    ok = dets:insert(Db, {<<"bad">>, #{}}), ok = dets:close(Db),
    application:set_env(nosternity, search_store_file, File),
    ?assertMatch({stop, {search_store_initialization_failed, File,
        {error, invalid_persisted_event, _}}}, nosternity_relay:init([])),
    ?assertEqual(undefined, dets:info(nosternity_search_events)).

%% Run without DAC override capabilities; deliberately verify real EACCES.
permissions_test() -> isolated(fun(Dir) ->
    Parent = filename:join(Dir, "read-only"), ok = file:make_dir(Parent),
    ok = file:change_mode(Parent, 8#500),
    try
        Missing = filename:join([Parent, "missing", "search.dets"]),
        application:set_env(nosternity, search_store_file, Missing),
        ?assertMatch({stop, {nosternity_store_unavailable, search_store_file,
            #{file := Missing, operation := ensure_directory, reason := eacces}}}, nosternity_relay:init([])),
        Existing = filename:join(Parent, "accounts.dets"),
        application:set_env(nosternity, auth_store_file, Existing),
        ?assertMatch({stop, {nosternity_store_unavailable, auth_store_file,
            #{file := Existing, operation := write_directory, reason := eacces}}}, nosternity_auth:init([]))
    after ok = file:change_mode(Parent, 8#700) end,
    File = filename:join(Parent, "accounts.dets"),
    {ok, Db} = dets:open_file(storage_read_only, [{file, File}]), ok = dets:close(Db),
    ok = file:change_mode(File, 8#400),
    try
        application:set_env(nosternity, auth_store_file, File),
        ?assertMatch({stop, {nosternity_store_unavailable, auth_store_file,
            #{file := File, operation := open_dets, reason := _}}}, nosternity_auth:init([]))
    after ok = file:change_mode(File, 8#600) end
end).

isolated(Fun) ->
    Dir = filename:join("/tmp", "storage-tests-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Keys = [{nosternity, data_dir}, {nosternity, search_store_file}, {nosternity, auth_store_file},
            {damage, state_dir}, {damage, secrets_state_dir}],
    Saved = [{A, K, application:get_env(A, K)} || {A, K} <- Keys],
    {ok, Cwd} = file:get_cwd(), Trap = process_flag(trap_exit, true),
    ok = file:make_dir(Dir), ok = file:set_cwd(Dir),
    [application:unset_env(A, K) || {A, K} <- Keys],
    application:set_env(damage, state_dir, filename:join(Dir, "state")),
    try Fun(Dir)
    after
        [case V of undefined -> application:unset_env(A, K);
             {ok, Old} -> application:set_env(A, K, Old) end || {A, K, V} <- Saved],
        ok = file:set_cwd(Cwd), process_flag(trap_exit, Trap), file:del_dir_r(Dir)
    end.

restore_os(Key, false) -> os:unsetenv(Key);
restore_os(Key, Value) -> os:putenv(Key, Value).
