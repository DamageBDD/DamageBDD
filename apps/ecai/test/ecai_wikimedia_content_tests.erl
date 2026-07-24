-module(ecai_wikimedia_content_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_cirrus_document_test() ->
    Runtime = runtime_fixture(),
    Source = #{
        <<"page_id">> => 42,
        <<"title">> => <<"Douglas Adams">>,
        <<"namespace">> => 0,
        <<"opening_text">> => <<"English author and humorist.">>,
        <<"wikibase_item">> => <<"Q42">>,
        <<"category">> => [<<"English writers">>, <<"Science fiction authors">>],
        <<"redirect">> => [#{<<"title">> => <<"Douglas Noel Adams">>}],
        <<"timestamp">> => <<"2026-07-01T00:00:00Z">>,
        <<"revision_id">> => 123
    },
    Visibility = #{rank => 1, page_id => 42, title => <<"Douglas_Adams">>, pageviews => 5000, active_months => 12},
    {ok, Document} = ecai_wikimedia_content:normalize_document(
        Source,
        Visibility,
        Runtime,
        <<"Douglas Adams">>
    ),
    ?assertEqual(<<"Douglas Adams">>, maps:get(<<"name">>, Document)),
    ?assertEqual(<<"Q42">>, maps:get(<<"identifier">>, maps:get(<<"main_entity">>, Document))),
    ?assertEqual(5000, maps:get(<<"pageviews">>, maps:get(<<"visibility">>, Document))),
    SourceMeta = maps:get(<<"ecai_source">>, Document),
    ?assertEqual(123, maps:get(<<"revision_id">>, SourceMeta)).


utf8_abstract_truncation_preserves_codepoint_boundary_test() ->
    Runtime = (runtime_fixture())#{abstract_max_bytes => 5},
    Source = #{
        <<"page_id">> => 7,
        <<"title">> => <<"UTF-8">>,
        <<"namespace">> => 0,
        <<"opening_text">> => <<"a", 16#1F642/utf8, "b">>
    },
    Visibility = #{
        rank => 1,
        page_id => 7,
        title => <<"UTF-8">>,
        pageviews => 10,
        active_months => 1
    },
    {ok, Document} = ecai_wikimedia_content:normalize_document(
        Source,
        Visibility,
        Runtime,
        <<"UTF-8">>
    ),
    Abstract = maps:get(<<"abstract">>, Document),
    ?assertEqual(<<"a", 16#1F642/utf8>>, Abstract),
    ?assertEqual(ok, ecai_chunker:validate_utf8(Abstract)).

exact_top_n_deduplicates_ranks_test() ->
    with_tmp(fun(Dir) ->
        Catalog = catalog_fixture(),
        Selector = #{selection_path => filename:join(Dir, "selection.jsonl"), limit => 2, candidate_limit => 3},
        {ok, Runtime} = ecai_wikimedia_content:prepare(
            Dir,
            Catalog,
            Selector,
            #{index_chunk_lines => 100, publish_extracted_ipfs => false}
        ),
        ExtractDir = maps:get(extract_dir, Runtime),
        A = normalized(1, 1, <<"One">>),
        DuplicateRank = normalized(99, 1, <<"Duplicate one">>),
        B = normalized(2, 2, <<"Two">>),
        C = normalized(3, 3, <<"Three">>),
        ok = write_jsonl(filename:join(ExtractDir, "a.selected.jsonl"), [A, B]),
        ok = write_jsonl(filename:join(ExtractDir, "b.selected.jsonl"), [DuplicateRank, C]),
        {ok, Meta} = ecai_wikimedia_content:finalize_ranked(Runtime, fun(_) -> ok end),
        ?assertEqual(2, maps:get(selected_records, Meta)),
        [IndexFile] = ecai_wikimedia_content:index_files(Runtime),
        {ok, Bytes} = file:read_file(IndexFile),
        Lines = [L || L <- binary:split(Bytes, <<"\n">>, [global]), L =/= <<>>],
        ?assertEqual(2, length(Lines))
    end).

runtime_fixture() ->
    #{
        project => <<"enwiki">>,
        pageview_project => <<"en.wikipedia">>,
        release => <<"20260720">>,
        abstract_max_bytes => 16384,
        current_shard => <<"enwiki_content_0.json.bz2">>
    }.

catalog_fixture() ->
    #{
        project => <<"enwiki">>,
        pageview_project => <<"en.wikipedia">>,
        cirrus_release => <<"20260720">>
    }.

normalized(Id, Rank, Name) ->
    #{
        <<"name">> => Name,
        <<"url">> => <<"https://en.wikipedia/wiki/", Name/binary>>,
        <<"identifier">> => Id,
        <<"abstract">> => <<"text">>,
        <<"in_language">> => #{<<"identifier">> => <<"en">>},
        <<"main_entity">> => #{<<"identifier">> => <<>>},
        <<"visibility">> => #{<<"rank">> => Rank, <<"pageviews">> => 1000 - Rank, <<"active_months">> => 12}
    }.

write_jsonl(Path, Records) ->
    file:write_file(
        Path,
        iolist_to_binary([[jsx:encode(R), <<"\n">>] || R <- Records]),
        [write, raw, binary]
    ).

with_tmp(Fun) ->
    Dir = filename:join(temp_dir(), "ecai-wikimedia-content-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try Fun(Dir) after remove_tree(Dir) end.

temp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; V -> V end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of {ok, Ns} -> lists:foreach(fun(N) -> remove_tree(filename:join(Path, N)) end, Ns); _ -> ok end,
            _ = file:del_dir(Path), ok;
        {ok, _} -> _ = file:delete(Path), ok;
        _ -> ok
    end.
