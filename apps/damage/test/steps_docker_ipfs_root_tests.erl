%%% Regression tests for Docker export CID selection. No Docker/IPFS service
%%% and no replacement production modules are used by these tests.
-module(steps_docker_ipfs_root_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PATH, <<"/var/lib/damage/runs/run1/docker/ipfs_stage/AABBCC">>).
-define(ROOT, <<"directory-cid">>).

entry(Name, Cid) -> #{<<"Name">> => Name, <<"Hash">> => Cid}.
select(Rows) -> steps_docker:pick_ipfs_root_hash(Rows, ?PATH).

%% Reproduces the reported lib/ wrapper instead of the staged directory root.
absolute_directory_root_not_last_test() ->
    Rows = [
        entry(<<?PATH/binary, "/installation.json">>, <<"manifest-cid">>),
        entry(<<?PATH/binary, "/damage.deb">>, <<"package-cid">>),
        entry(?PATH, ?ROOT),
        entry(<<"var/lib/damage">>, <<"damage-parent-cid">>),
        entry(<<"var">>, <<"root-containing-lib-cid">>)
    ],
    ?assertEqual(?ROOT, select(Rows)).

root_without_leading_slash_test() ->
    <<"/", Relative/binary>> = ?PATH,
    ?assertEqual(?ROOT, select([
        entry(Relative, ?ROOT), entry(<<"">>, <<"wrapper-cid">>)
    ])).

basename_root_test() ->
    ?assertEqual(?ROOT, select([
        entry(<<"AABBCC/installation.json">>, <<"manifest-cid">>),
        entry(<<"AABBCC">>, ?ROOT),
        entry(<<"">>, <<"wrapper-cid">>)
    ])).

root_name_formatting_test_() ->
    <<"/", Relative/binary>> = ?PATH,
    Names = [
        ?PATH,
        binary_to_list(?PATH),
        Relative,
        <<"./", Relative/binary>>,
        <<"/var//lib/damage/runs/run1/docker/ipfs_stage/AABBCC/.">>,
        <<"AABBCC/">>
    ],
    [?_assertEqual(?ROOT, select([entry(Name, ?ROOT)])) || Name <- Names].

response_order_independent_test_() ->
    Rows = [entry(?PATH, ?ROOT), entry(<<"var">>, <<"parent-cid">>),
        entry(<<?PATH/binary, "/damage.deb">>, <<"package-cid">>)],
    [?_assertEqual(?ROOT, select(Permutation)) || Permutation <- permutations(Rows)].

same_root_aliases_deduplicated_test() ->
    ?assertEqual(?ROOT, select([
        entry(?PATH, ?ROOT), entry(<<"AABBCC">>, ?ROOT), entry(?PATH, ?ROOT)
    ])).

conflicting_root_hashes_fail_test() ->
    ?assertError({ipfs_add_ambiguous_root, ?PATH}, select([
        entry(?PATH, ?ROOT), entry(?PATH, <<"different-cid">>)
    ])).

conflicting_root_aliases_fail_test() ->
    ?assertError({ipfs_add_ambiguous_root, ?PATH}, select([
        entry(?PATH, ?ROOT), entry(<<"AABBCC">>, <<"different-cid">>)
    ])).

never_fall_back_to_last_hash_test_() ->
    Cases = [
        [],
        [entry(<<"">>, <<"wrapper-cid">>)],
        [entry(<<"var">>, <<"parent-cid">>)],
        [entry(<<?PATH/binary, "/damage.deb">>, <<"package-cid">>)],
        [entry(<<"elsewhere/AABBCC">>, <<"unrelated-cid">>)],
        [entry(<<"prefixAABBCC">>, <<"unrelated-cid">>)],
        [entry(<<"../AABBCC">>, <<"traversal-cid">>)],
        [entry(<<"AABBCC", 0>>, <<"invalid-cid">>)],
        [entry(?PATH, <<>>)],
        [entry(?PATH, null)],
        [entry(null, ?ROOT)],
        [#{<<"Name">> => ?PATH, <<"Bytes">> => 100}, not_an_entry]
    ],
    [?_assertError({ipfs_add_root_not_found, ?PATH}, select(Rows)) || Rows <- Cases].

progress_rows_ignored_test() ->
    ?assertEqual(?ROOT, select([
        #{<<"Name">> => ?PATH, <<"Bytes">> => 10},
        entry(?PATH, ?ROOT),
        entry(<<"">>, <<"wrapper-cid">>)
    ])).

unexpected_add_response_test() ->
    ?assertError({invalid_ipfs_add_result, ?PATH}, select(not_a_list)).

trailing_dot_does_not_select_unnamed_root_test() ->
    Path = <<?PATH/binary, "/.">>,
    ?assertEqual(?ROOT, steps_docker:pick_ipfs_root_hash([
        entry(?PATH, ?ROOT), entry(<<"">>, <<"wrapper-cid">>)
    ], Path)).

spaces_unicode_and_percent_are_literal_test() ->
    Path = unicode:characters_to_binary("/tmp/build space/" ++ [16#03BB] ++ "%20;$(unused)"),
    ?assertEqual(?ROOT, steps_docker:pick_ipfs_root_hash([
        entry(unicode:characters_to_list(Path), ?ROOT),
        entry(<<"">>, <<"wrapper-cid">>)
    ], Path)).

staged_directory_upload_test() ->
    with_stage(fun(Stage) ->
        ok = file:make_dir(Stage),
        ok = file:write_file(filename:join(Stage, "installation.json"), <<"{}">>),
        ok = file:write_file(filename:join(Stage, "damage.deb"), <<"fixture-package">>),
        Add = fun({directory, Path}) ->
            ?assertEqual(list_to_binary(Stage), Path),
            ?assertMatch({ok, <<"{}">>}, file:read_file(filename:join(Path, <<"installation.json">>))),
            {ok, [
                entry(Path, ?ROOT),
                entry(filename:dirname(Path), <<"parent-cid">>),
                entry(<<"">>, <<"wrapper-cid">>)
            ]}
        end,
        ?assertEqual(?ROOT, steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

single_file_upload_keeps_file_cid_test() ->
    with_stage(fun(Stage) ->
        ok = file:write_file(Stage, <<"package-bytes">>),
        Add = fun({file, Path}) ->
            ?assertEqual(list_to_binary(Stage), Path),
            {ok, [entry(Path, <<"file-cid">>), entry(<<"">>, <<"wrapper-cid">>)]}
        end,
        ?assertEqual(<<"file-cid">>, steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

missing_root_from_add_fails_test() ->
    with_stage(fun(Stage) ->
        ok = file:make_dir(Stage),
        Path = list_to_binary(Stage),
        Add = fun({directory, Path0}) ->
            ?assertEqual(Path, Path0),
            {ok, [entry(filename:dirname(Path), <<"parent-cid">>)]}
        end,
        ?assertError({ipfs_add_root_not_found, Path},
            steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

add_failure_preserved_test() ->
    with_stage(fun(Stage) ->
        ok = file:make_dir(Stage),
        Path = list_to_binary(Stage),
        Add = fun(_) -> {error, unavailable} end,
        ?assertError({ipfs_add_failed, Path, {error, unavailable}},
            steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

missing_stage_never_uploaded_test() ->
    with_stage(fun(Stage) ->
        Path = list_to_binary(Stage),
        Add = fun(_) -> erlang:error(unexpected_upload) end,
        ?assertError({ipfs_upload_target_missing, Path, {error, enoent}},
            steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

symlink_root_never_uploaded_test() ->
    with_stage(fun(Stage) ->
        Target = filename:join(filename:dirname(Stage), "target"),
        ok = file:write_file(Target, <<"must-not-upload">>),
        ok = file:make_symlink(Target, Stage),
        Path = list_to_binary(Stage),
        Add = fun(_) -> erlang:error(unexpected_upload) end,
        ?assertError({invalid_ipfs_upload_target_type, Path, symlink},
            steps_docker:ipfs_add_path_and_get_hash(Stage, Add))
    end).

permutations([]) -> [[]];
permutations(List) -> [[Head | Tail] || Head <- List, Tail <- permutations(List -- [Head])].

with_stage(Fun) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end,
    Root = filename:absname(filename:join(Base,
        "damage-docker-root-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))))),
    ok = file:make_dir(Root),
    try
        Fun(filename:join(Root, "stage"))
    after
        ok = file:del_dir_r(Root)
    end.
