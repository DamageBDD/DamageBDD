-module(ecai_wikimedia_catalog_tests).

-include_lib("eunit/include/eunit.hrl").

default_months_are_chronological_test() ->
    Months = ecai_wikimedia_catalog:default_months(12),
    ?assertEqual(12, length(Months)),
    ?assertEqual(Months, lists:sort(Months)),
    lists:foreach(
        fun(Month) ->
            ?assertMatch(
                {match, _},
                re:run(Month, <<"^[0-9]{4}-[0-9]{2}$">>)
            )
        end,
        Months
    ).

catalog_local_roundtrip_test() ->
    with_tmp(fun(Dir) ->
        Catalog = fixture_catalog(),
        {ok, Meta} = ecai_wikimedia_catalog:write(
            Dir,
            Catalog,
            #{publish_ipfs => false}
        ),
        ?assertEqual(null, maps:get(cid, Meta)),
        Path = maps:get(path, Meta),
        ?assert(filelib:is_regular(binary_to_list(Path))),
        {ok, Read} = ecai_wikimedia_catalog:read(Path),
        ?assertEqual(Catalog, Read),
        Summary = ecai_wikimedia_catalog:summary(Read),
        ?assertEqual(1, maps:get(content_shards, Summary)),
        ?assertEqual(2, maps:get(pageview_files, Summary)),
        ?assertEqual(3, maps:get(source_count, Summary))
    end).

resolve_uses_pinned_local_catalog_test() ->
    with_tmp(fun(Dir) ->
        Catalog = fixture_catalog(),
        {ok, Meta} = ecai_wikimedia_catalog:write(
            Dir,
            Catalog,
            #{publish_ipfs => false}
        ),
        {ok, Resolved} = ecai_wikimedia_catalog:resolve(#{
            catalog_path => maps:get(path, Meta),
            project => <<"ignored-because-catalog-is-pinned">>
        }),
        ?assertEqual(Catalog, Resolved)
    end).

invalid_release_and_project_are_rejected_before_network_test() ->
    ?assertEqual(
        {error, {invalid_field, project}},
        ecai_wikimedia_catalog:list_cirrus_shards(
            <<"enwiki/../../">>,
            <<"20260720">>
        )
    ),
    ?assertEqual(
        {error, {invalid_release, <<"2026-07-20">>}},
        ecai_wikimedia_catalog:list_cirrus_shards(
            <<"enwiki">>,
            <<"2026-07-20">>
        )
    ).

invalid_month_count_is_rejected_test() ->
    ?assertError(badarg, ecai_wikimedia_catalog:default_months(0)),
    ?assertError(badarg, ecai_wikimedia_catalog:default_months(121)).

fixture_catalog() ->
    #{
        schema => ecai_wikimedia_catalog:version(),
        project => <<"enwiki">>,
        pageview_project => <<"en.wikipedia">>,
        cirrus_release => <<"20260720">>,
        content_shards => [
            #{
                ordinal => 1,
                name => <<"enwiki_content_0.json.bz2">>,
                url => <<"https://example.invalid/content-0.json.bz2">>
            }
        ],
        pageview_months => [<<"2026-05">>, <<"2026-06">>],
        pageview_sources => [
            #{
                ordinal => 1,
                month => <<"2026-05">>,
                name => <<"pageviews-202605-user.bz2">>,
                url => <<"https://example.invalid/pageviews-202605-user.bz2">>,
                project => <<"en.wikipedia">>
            },
            #{
                ordinal => 2,
                month => <<"2026-06">>,
                name => <<"pageviews-202606-user.bz2">>,
                url => <<"https://example.invalid/pageviews-202606-user.bz2">>,
                project => <<"en.wikipedia">>
            }
        ]
    }.

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-wikimedia-catalog-" ++
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
        {error, _Reason} ->
            ok
    end.
