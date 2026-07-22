-module(ecai_disk_docstore_step04a_tests).

-include_lib("eunit/include/eunit.hrl").

anonymous_docstore_round_trip_test() ->
    Dir = temp_dir(),
    try
        {ok, Tab1} = ecai_disk_docstore:open(Dir),
        ?assert(is_reference(Tab1)),
        {ok, 1} = ecai_disk_docstore:next_id(Tab1),
        ok = ecai_disk_docstore:put(Tab1, 1, #{title => <<"one">>}),
        ok = ecai_disk_docstore:sync(Tab1),
        ok = ecai_disk_docstore:close(Tab1),

        {ok, Tab2} = ecai_disk_docstore:open(Dir),
        ?assert(is_reference(Tab2)),
        ?assertEqual(
            {ok, #{title => <<"one">>}},
            ecai_disk_docstore:get(Tab2, 1)
        ),
        {ok, 2} = ecai_disk_docstore:next_id(Tab2),
        ok = ecai_disk_docstore:close(Tab2)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(
        Root,
        "ecai-docstore-step04a-" ++
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
        {error, enoent} -> ok;
        {error, _Reason} -> ok
    end.
