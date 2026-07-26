-module(ecai_wikipedia_loader_recovery_tests).

-include_lib("eunit/include/eunit.hrl").

bounded_file_replay_is_idempotent_test() ->
    with_tmp(fun(Dir) ->
        SourcePath = filename:join(Dir, "normalized-wikipedia.jsonl"),
        Records = [
            normalized_record(
                101,
                <<"Quantum mechanics">>,
                <<"Physics theory of matter and energy">>,
                <<"Q944">>,
                1000000,
                1
            ),
            normalized_record(
                102,
                <<"Classical mechanics">>,
                <<"Physics of macroscopic bodies">>,
                <<>>,
                1000,
                2
            )
        ],
        ok = write_jsonl(SourcePath, Records),

        Ctx0 = ecai_search:new(),
        Ctx = ecai_search:set_opts(Ctx0, #{root_mode => deferred}),
        Opts = loader_opts(Ctx, Dir),
        try
            ok = ecai_wikipedia_loader:load(SourcePath, Opts),
            ?assertEqual(2, maps:get(docs, ecai_search:size(Ctx))),

            %% A worker/node restart rewinds only this bounded indexing unit.
            %% Stable Wikipedia page IDs make the replay logically idempotent.
            ok = ecai_wikipedia_loader:load(SourcePath, Opts),
            ?assertEqual(2, maps:get(docs, ecai_search:size(Ctx))),

            _ = ecai_search:finalize_roots(Ctx),
            {ok, Search} = ecai_wikimedia_search:search(
                Ctx,
                <<"physics">>,
                #{limit => 10, has_wikidata => true}
            ),
            [Result] = maps:get(results, Search),
            ?assertEqual(<<"101">>, maps:get(doc_id, Result))
        after
            ok = ecai_search:wipe(Ctx)
        end
    end).

malformed_and_invalid_utf8_lines_are_skipped_test() ->
    with_tmp(fun(Dir) ->
        SourcePath = filename:join(Dir, "mixed-wikipedia.jsonl"),
        Valid = jsx:encode(
            normalized_record(
                201,
                <<"Valid article">>,
                <<"Physics survives malformed neighbours">>,
                <<"Q201">>,
                100,
                1
            )
        ),
        Bytes = <<
            "{not-json}\n",
            16#C3,
            16#28,
            "\n",
            Valid/binary,
            "\n"
        >>,
        ok = file:write_file(SourcePath, Bytes, [write, raw, binary, sync]),
        Ctx = ecai_search:new(),
        Opts = loader_opts(Ctx, Dir),
        try
            ok = ecai_wikipedia_loader:load(SourcePath, Opts),
            ?assertEqual(1, maps:get(docs, ecai_search:size(Ctx)))
        after
            ok = ecai_search:wipe(Ctx)
        end
    end).

loader_opts(Ctx, Dir) ->
    #{
        ctx => Ctx,
        auto_tune => false,
        checkpoint_enabled => false,
        checkpoint_dir => filename:join(Dir, "checkpoints"),
        mem_high => 1 bsl 50,
        mem_low => 1 bsl 49,
        bin_high => 1 bsl 49,
        snooze_ms => 1
    }.

normalized_record(PageId, Name, Abstract, WikidataId, Pageviews, Rank) ->
    #{
        <<"name">> => Name,
        <<"url">> => <<"https://en.wikipedia.org/wiki/", Name/binary>>,
        <<"identifier">> => PageId,
        <<"abstract">> => Abstract,
        <<"in_language">> => #{<<"identifier">> => <<"en">>},
        <<"main_entity">> => #{<<"identifier">> => WikidataId},
        <<"visibility">> => #{
            <<"pageviews">> => Pageviews,
            <<"active_months">> => 12,
            <<"rank">> => Rank
        },
        <<"categories">> => [<<"Physics">>],
        <<"redirects">> => [],
        <<"license">> => []
    }.

write_jsonl(Path, Records) ->
    file:write_file(
        Path,
        iolist_to_binary([[jsx:encode(Record), <<"\n">>] || Record <- Records]),
        [write, raw, binary, sync]
    ).

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-wikipedia-loader-recovery-" ++
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
