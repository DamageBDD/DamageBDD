-module(ecai_index_source_tests).

-include_lib("eunit/include/eunit.hrl").

source_descriptor_detects_change_test() ->
    Dir = temp_dir(),
    Path1 = filename:join(Dir, "a.ndjson"),
    Path2 = filename:join(Dir, "b.ndjson"),
    try
        ok = file:write_file(Path1, <<"a\n">>, [raw, binary]),
        ok = file:write_file(Path2, <<"b\n">>, [raw, binary]),
        Paths = [unicode:characters_to_binary(Path1), unicode:characters_to_binary(Path2)],
        {ok, Identity} = ecai_index_source:describe_paths(Paths),
        ?assertEqual(ok, ecai_index_source:verify_paths(Paths, Identity)),
        #{files := [First, Second]} = Identity,
        ?assertEqual(1, maps:get(ordinal, First)),
        ?assertEqual(2, maps:get(ordinal, Second)),
        ?assertEqual(2, maps:get(bytes, First)),
        ok = file:write_file(Path2, <<"changed\n">>, [raw, binary]),
        ?assertMatch(
            {error, {source_changed, _, _}},
            ecai_index_source:verify_paths(Paths, Identity)
        )
    after
        remove_tree(Dir)
    end.

source_identity_does_not_include_local_path_test() ->
    Dir = temp_dir(),
    Path1 = filename:join(Dir, "one/source.ndjson"),
    Path2 = filename:join(Dir, "two/source.ndjson"),
    try
        ok = filelib:ensure_dir(Path1),
        ok = filelib:ensure_dir(Path2),
        Bytes = <<"same deterministic bytes\n">>,
        ok = file:write_file(Path1, Bytes, [raw, binary]),
        ok = file:write_file(Path2, Bytes, [raw, binary]),
        {ok, Identity1} = ecai_index_source:describe_paths([Path1]),
        {ok, Identity2} = ecai_index_source:describe_paths([Path2]),
        ?assertEqual(Identity1, Identity2)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Dir = filename:join(
        Root,
        "ecai-index-source-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

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
