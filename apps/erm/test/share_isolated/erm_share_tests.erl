-module(erm_share_tests).
-include_lib("eunit/include/eunit.hrl").

share_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(C) -> ?_test(durable_review(C)) end,
        fun(C) -> ?_test(kde_events(C)) end,
        fun(C) -> ?_test(airdrop_events(C)) end,
        fun(C) -> ?_test(path_boundary(C)) end,
        fun(C) -> ?_test(quotas(C)) end,
        fun(C) -> ?_test(ingest_retry(C)) end,
        fun(C) -> ?_test(tamper(C)) end,
        fun(C) -> ?_test(unsupported(C)) end,
        fun(C) -> ?_test(ui_review(C)) end
    ]}.
setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    Root = "/tmp/erm-share-" ++ binary_to_list(erm_share_files:hex(crypto:strong_rand_bytes(8))),
    Kde = erm_share_files:directory(filename:join(Root, "kde")),
    Air = filename:join(Root, "air"), Dir = filename:join(Root, "inbox"),
    Conf = #{enabled => true, directory => Dir, corpus => <<"private">>, principal => <<"steven">>,
        max_file_bytes => 1024, max_total_bytes => 2048, max_items => 4, poll_ms => 60000,
        kdeconnect => #{enabled => true, helper => "/not/installed", device_ids => [<<"phone">>], roots => [Kde]},
        airdrop => #{enabled => true, directory => Air}},
    application:set_env(erm, share, Conf),
    application:set_env(erm, share_test_result, ok),
    {ok, Pid} = erm_share:start_link(), unlink(Pid),
    #{root => Root, kde => Kde, air => Air, dir => Dir, pid => Pid}.
cleanup(C) ->
    case whereis(erm_share) of undefined -> ok; P -> gen_server:stop(P) end,
    application:unset_env(erm, share),
    application:unset_env(erm, share_test_owner),
    application:unset_env(erm, share_test_fetch),
    application:unset_env(erm, share_test_result),
    file:del_dir_r(maps:get(root, C)).

poll() -> whereis(erm_share) ! poll, _ = erm_share:status(), ok.
spool(C, M) -> write_event(filename:join(maps:get(dir, C), "events"), M).
write_event(Dir, M) ->
    P = filename:join(Dir, binary_to_list(erm_share_files:hex(crypto:strong_rand_bytes(8))) ++ ".json"),
    ok = erm_share_files:write(P, jsx:encode(M)), P.
kde(Kind, V, Device) -> #{v => 1, transport => <<"kdeconnect">>, kind => Kind,
    value_b64 => base64:encode(V), device_b64 => base64:encode(Device)}.

durable_review(_C) ->
    application:set_env(erm, share_test_owner, self()),
    {ok, Id} = erm_share:submit(text, <<"A useful shared note">>, <<"Note">>),
    ?assertMatch([#{state := pending}], erm_share:items()),
    receive {private_index, _, _, _, _} -> error(automatic_indexing) after 0 -> ok end,
    ?assertEqual({ok, Id}, erm_share:submit(text, <<"A useful shared note">>, <<"Note">>)),
    gen_server:stop(erm_share), {ok, P} = erm_share:start_link(), unlink(P),
    ?assertMatch([#{id := Id, state := pending}], erm_share:items()),
    ?assertEqual({ok, indexing}, erm_share:accept(Id)),
    receive {private_index, <<"private">>, <<"steven">>, Id, [#{text := <<"A useful shared note">>}]} -> ok after 2000 -> error(no_private_index) end,
    await(Id, indexed, 100),
    ?assertEqual({error, already_indexed}, erm_share:reject(Id)),
    ?assertEqual(ok, erm_share:forget(Id)), ?assertEqual([], erm_share:items()).

kde_events(C) ->
    File = filename:join(maps:get(kde, C), "quote 'λ'.md"),
    ok = file:write_file(File, <<"content">>),
    URI = unicode:characters_to_binary("file://" ++ File),
    spool(C, kde(<<"uri">>, URI, <<"other">>)), poll(), ?assertEqual([], erm_share:items()),
    spool(C, kde(<<"uri">>, URI, <<"phone">>)), poll(),
    ?assertMatch([#{kind := file, state := pending}], erm_share:items()),
    spool(C, kde(<<"uri">>, <<"https://example.com/path?q=one">>, <<"phone">>)), poll(),
    spool(C, kde(<<"text">>, <<"hello">>, <<"phone">>)), poll(),
    ?assertEqual(3, length(erm_share:items())),
    spool(C, kde(<<"uri">>, <<"file://evil/etc/passwd">>, <<"phone">>)), poll(),
    spool(C, kde(<<"uri">>, <<"javascript:alert(1)">>, <<"phone">>)), poll(),
    ?assertEqual(3, length(erm_share:items())).

airdrop_events(C) ->
    Root = maps:get(air, C), P = filename:join(Root, "note.txt"),
    ok = file:write_file(P, <<"incomplete">>), poll(), ?assertEqual([], erm_share:items()),
    ok = file:write_file(P, <<"completed">>),
    M = #{v => 1, transport => <<"airdrop">>, name_b64 => base64:encode(<<"note.txt">>)},
    spool(C, M), poll(), ?assertEqual([], erm_share:items()),
    write_event(filename:join(Root, ".ecai-events"), M), poll(),
    ?assertMatch([#{transport := <<"airdrop">>, size := 9}], erm_share:items()),
    write_event(filename:join(Root, ".ecai-events"), M#{name_b64 := base64:encode(<<"../secret">>)}),
    poll(), ?assertEqual(1, length(erm_share:items())).

path_boundary(C) ->
    Root = maps:get(kde, C), Outside = filename:join(maps:get(root, C), "secret"),
    ok = file:write_file(Outside, <<"secret">>),
    Link = filename:join(Root, "link"), ok = file:make_symlink(Outside, Link),
    ?assertMatch({error, _}, erm_share_files:read(Link, [Root], 100)),
    ?assertMatch({error, _}, erm_share_files:read(Outside, [Root], 100)),
    ?assertMatch({error, _}, erm_share_files:read(filename:join(Root, "../secret"), [Root], 100)),
    ?assertMatch({error, _}, erm_share_files:read(Root, [Root], 100)),
    SubLink = filename:join(Root, "sub"), ok = file:make_symlink(maps:get(root, C), SubLink),
    ?assertMatch({error, _}, erm_share_files:read(filename:join(SubLink, "secret"), [Root], 100)),
    ?assertMatch({error, _}, erm_share_files:read(Outside, [maps:get(root, C)], 2)).

quotas(C) ->
    ?assertMatch({error, _}, erm_share:submit(text, binary:copy(<<"a">>, 1025), <<"big">>)),
    {ok, _} = erm_share:submit(text, binary:copy(<<"a">>, 1024), <<"one">>),
    {ok, _} = erm_share:submit(text, binary:copy(<<"b">>, 1024), <<"two">>),
    E = spool(C, kde(<<"text">>, <<"wait">>, <<"phone">>)), poll(),
    ?assert(filelib:is_regular(E)),
    [I | _] = erm_share:items(), ok = erm_share:forget(maps:get(id, I)), poll(),
    ?assertNot(filelib:is_regular(E)), ?assertEqual(2, length(erm_share:items())).

ingest_retry(_C) ->
    application:set_env(erm, share_test_owner, self()),
    {ok, Id} = erm_share:submit(text, <<"retry">>, <<"Note">>),
    [I] = erm_share:items(),
    application:set_env(erm, share_test_result, recover),
    application:set_env(erm, share_test_fetch, {ok, #{source_key => Id, source_version => maps:get(sha256, I)}}),
    ?assertEqual({ok, indexing}, erm_share:accept(Id)), await(Id, indexed, 100).

tamper(C) ->
    application:set_env(erm, share_test_owner, self()),
    {ok, Id} = erm_share:submit(text, <<"original">>, <<"Note">>),
    Obj = filename:join([maps:get(dir, C), "objects", binary_to_list(Id)]),
    ok = file:write_file(Obj, <<"modified">>),
    {ok, indexing} = erm_share:accept(Id), await(Id, failed, 100),
    receive {private_index, _, _, _, _} -> error(tamper_indexed) after 0 -> ok end.

unsupported(C) ->
    Root = maps:get(air, C), ok = file:write_file(filename:join(Root, "photo.jpg"), <<255,216,255,224>>),
    write_event(filename:join(Root, ".ecai-events"), #{v => 1, transport => <<"airdrop">>, name_b64 => base64:encode(<<"photo.jpg">>)}),
    poll(), [I] = erm_share:items(), Id = maps:get(id, I),
    {ok, indexing} = erm_share:accept(Id), await(Id, failed, 100),
    ?assertMatch([#{error := unsupported_content}], erm_share:items()).

unicode_chunks_test() ->
    Text = unicode:characters_to_binary(lists:duplicate(40000, 16#1f600)),
    I = #{kind => text, id => <<"id">>, sha256 => <<"hash">>, name => <<"unicode">>, transport => <<"local">>},
    {ok, Records} = ecai_share:records(I, Text),
    ?assert(length(Records) > 1),
    ?assertEqual(Text, iolist_to_binary([maps:get(text, R) || R <- Records])),
    ?assert(lists:all(fun(R) -> is_binary(unicode:characters_to_binary(maps:get(text, R))) end, Records)),
    ?assertEqual({error, unsupported_content}, ecai_share:records(I, <<255>>)).

await(_, _, 0) -> error(state_timeout);
await(Id, State, N) ->
    case [I || I <- erm_share:items(), maps:get(id, I) =:= Id, maps:get(state, I) =:= State] of
        [_] -> ok;
        [] -> timer:sleep(10), await(Id, State, N - 1)
    end.

ui_review(_C) ->
    application:set_env(erm, share_test_owner, self()),
    application:set_env(erm, log_to_file, false),
    {ok, Id} = erm_share:submit(text, <<"UI note">>, <<"UI note">>),
    {ok, Gtk} = gtknode4_sup:start_link(#{mode => fake, gs => #{test_mode => true}}),
    unlink(Gtk),
    try
        {ok, UI} = erm_share_ui:start_link(), unlink(UI),
        try
            #{window := W} = sys:get_state(UI),
            [Root] = gtkgs:read(W, children),
            [_, _, List, _, Actions, _] = gtkgs:read(Root, children),
            [Accept | _] = gtkgs:read(Actions, children),
            ok = gtkgs:config(List, {selected_index, 0}),
            ok = gtkgs:inject(Accept, click, #{}),
            await(Id, indexed, 100),
            ?assertEqual([Id], maps:get(ids, sys:get_state(UI)))
        after gen_server:stop(UI) end
    after gen_server:stop(Gtk), application:unset_env(erm, log_to_file) end.
