-module(ecai_wikimedia_selector_tests).

-include_lib("eunit/include/eunit.hrl").

pageview_line_parser_test() ->
    ?assertEqual(
        {ok, 15580374, <<"Main_Page">>, 123456},
        ecai_wikimedia_selector:parse_pageview_line(
            <<"en.wikipedia Main_Page 15580374 123456 A1B2C3">>,
            <<"en.wikipedia">>
        )
    ),
    ?assertEqual(
        skip,
        ecai_wikimedia_selector:parse_pageview_line(
            <<"de.wikipedia Hauptseite 1 50 X">>,
            <<"en.wikipedia">>
        )
    ),
    ?assertEqual(malformed, ecai_wikimedia_selector:parse_pageview_line(<<"broken">>, <<"en.wikipedia">>)).

streaming_k_way_selection_test() ->
    with_tmp(fun(Dir) ->
        Catalog = #{
            pageview_project => <<"en.wikipedia">>,
            pageview_months => [<<"2026-06">>]
        },
        {ok, Runtime} = ecai_wikimedia_selector:prepare(
            Dir,
            Catalog,
            #{selection_shards => 8, limit => 3, minimum_active_months => 1, oversample_percent => 100}
        ),
        TopDir = maps:get(top_dir, Runtime),
        lists:foreach(
            fun(P) ->
                Path = filename:join(TopDir, lists:flatten(io_lib:format("top-~4..0B.jsonl", [P]))),
                Records = case P of
                    0 -> [record(8, <<"Eight">>, 80)];
                    1 -> [record(1, <<"One">>, 100), record(9, <<"Nine">>, 10)];
                    2 -> [record(2, <<"Two">>, 90)];
                    _ -> []
                end,
                ok = write_jsonl(Path, Records)
            end,
            lists:seq(0, 7)
        ),
        {ok, Meta} = ecai_wikimedia_selector:merge_selection(Runtime, fun(_) -> ok end),
        ?assertEqual(3, maps:get(selected, Meta)),
        {ok, Tab, 3} = ecai_wikimedia_selector:load_selection(maps:get(selection_path, Runtime)),
        try
            {ok, First} = ecai_wikimedia_selector:lookup(Tab, 1, undefined),
            {ok, Second} = ecai_wikimedia_selector:lookup(Tab, 2, undefined),
            {ok, Third} = ecai_wikimedia_selector:lookup(Tab, 8, undefined),
            {ok, ByTitle} = ecai_wikimedia_selector:lookup(Tab, undefined, <<"Two">>),
            ?assertEqual(1, maps:get(rank, First)),
            ?assertEqual(2, maps:get(rank, Second)),
            ?assertEqual(3, maps:get(rank, Third)),
            ?assertEqual(2, maps:get(page_id, ByTitle)),
            ?assertEqual(not_found, ecai_wikimedia_selector:lookup(Tab, 999, <<"Missing">>))
        after
            ok = ecai_wikimedia_selector:close_selection(Tab)
        end
    end).

record(PageId, Title, Views) ->
    #{
        <<"page_id">> => PageId,
        <<"title">> => Title,
        <<"pageviews">> => Views,
        <<"active_months">> => 1
    }.

write_jsonl(Path, Records) ->
    Bytes = iolist_to_binary([
        [jsx:encode(Record), <<"\n">>]
     || Record <- Records
    ]),
    file:write_file(Path, Bytes, [write, raw, binary]).

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-wikimedia-selector-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try Fun(Dir) after remove_tree(Dir) end.

temp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; V -> V end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} -> lists:foreach(fun(N) -> remove_tree(filename:join(Path, N)) end, Names);
                _ -> ok
            end,
            _ = file:del_dir(Path), ok;
        {ok, _} -> _ = file:delete(Path), ok;
        _ -> ok
    end.
