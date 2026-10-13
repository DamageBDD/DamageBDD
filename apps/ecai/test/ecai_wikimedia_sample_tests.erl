-module(ecai_wikimedia_sample_tests).

-include_lib("eunit/include/eunit.hrl").

api_catalog_rewrites_fixture_urls_test_() ->
    {timeout, 30, fun api_catalog_rewrites_fixture_urls_case/0}.

api_catalog_rewrites_fixture_urls_case() ->
    PreviousPort = application:get_env(ecai, port),
    try
        ok = application:set_env(ecai, port, 19003),
        with_fixture_server(fun() ->
            {ok, CatalogPath, Catalog} = ecai_wikimedia_sample:catalog(),
            ?assert(filelib:is_regular(binary_to_list(CatalogPath))),
            Base = <<"http://127.0.0.1:19003/ecai/wikimedia/sample/files/">>,
            [Content] = maps:get(content_shards, Catalog),
            [Pageview] = maps:get(pageview_sources, Catalog),
            ?assertMatch({0, _}, binary:match(maps:get(url, Content), Base)),
            ?assertMatch({0, _}, binary:match(maps:get(url, Pageview), Base)),
            ?assert(
                ecai_wikimedia_sample:source_url_allowed(
                    uri_string:parse(maps:get(url, Content))
                )
            ),
            ?assertNot(
                ecai_wikimedia_sample:source_url_allowed(
                    uri_string:parse(<<"http://127.0.0.1:19004/ecai/wikimedia/sample/files/x">>)
                )
            ),
            {ok, Entry} = ecai_wikimedia_sample:file_entry(
                <<"pageviews-202606-user.bz2">>
            ),
            ?assert(filelib:is_regular(maps:get(path, Entry)))
        end)
    after
        restore_env(port, PreviousPort)
    end.

sample_routes_are_exposed_test() ->
    Routes = ecai_wikimedia_http:trails(),
    Text = iolist_to_binary(io_lib:format("~p", [Routes])),
    ?assertNotEqual(nomatch, binary:match(Text, <<"/ecai/wikimedia/sample">>)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"/ecai/wikimedia/sample/catalog">>)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"/ecai/wikimedia/sample/files/:name">>)).

with_fixture_server(Fun) ->
    case whereis(ecai_wikimedia_fixture_server) of
        Pid when is_pid(Pid) ->
            Fun();
        undefined ->
            PreviousFixturePort = application:get_env(ecai, wikimedia_fixture_port),
            try
                ok = application:set_env(ecai, wikimedia_fixture_port, 0),
                {ok, Pid} = ecai_wikimedia_fixture_server:start_link(),
                unlink(Pid),
                try
                    Fun()
                after
                    ok = ecai_wikimedia_fixture_server:stop(Pid)
                end
            after
                restore_env(wikimedia_fixture_port, PreviousFixturePort)
            end
    end.

restore_env(Key, {ok, Value}) -> application:set_env(ecai, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ecai, Key).
