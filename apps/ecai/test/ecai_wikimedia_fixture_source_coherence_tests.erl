-module(ecai_wikimedia_fixture_source_coherence_tests).

-include_lib("eunit/include/eunit.hrl").

runtime_contract_test() ->
    Required = [
        {ecai_wikimedia_fixture_server, start_link, 0},
        {ecai_wikimedia_fixture_server, start_link, 1},
        {ecai_wikimedia_fixture_server, child_spec, 0},
        {ecai_wikimedia_fixture_server, child_spec, 1},
        {ecai_wikimedia_fixture_server, start_supervised, 1},
        {ecai_wikimedia_fixture_server, start_supervised, 2},
        {ecai_wikimedia_fixture_server, stop, 0},
        {ecai_wikimedia_fixture_server, stop, 1},
        {ecai_wikimedia_fixture_server, status, 0},
        {ecai_wikimedia_fixture_server, status, 1},
        {ecai_wikimedia_fixture_server, reload, 0},
        {ecai_wikimedia_fixture_server, reload, 1},
        {ecai_wikimedia_fixture_server, base_url, 0},
        {ecai_wikimedia_fixture_server, base_url, 1},
        {ecai_wikimedia_fixture_server, catalog_path, 0},
        {ecai_wikimedia_fixture_server, catalog_path, 1},
        {ecai_wikimedia_fixture_server, catalog_url, 0},
        {ecai_wikimedia_fixture_server, catalog_url, 1},
        {ecai_wikimedia_fixture_handler, init, 2},
        {ecai_wikimedia_fixture_handler, parse_range, 2},
        {ecai_wikimedia_ops, fixture_status, 0},
        {ecai_wikimedia_ops, fixture_base_url, 0},
        {ecai_wikimedia_ops, fixture_catalog_url, 0},
        {ecai_wikimedia_ops, fixture_catalog_path, 0},
        {ecai_wikimedia_ops, fixture_reload, 0}
    ],
    lists:foreach(
        fun({Module, Function, Arity}) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module)),
            ?assert(erlang:function_exported(Module, Function, Arity))
        end,
        Required
    ).

child_spec_is_permanent_worker_test() ->
    Spec = ecai_wikimedia_fixture_server:child_spec(),
    ?assertEqual(ecai_wikimedia_fixture_server, maps:get(id, Spec)),
    ?assertEqual(
        {ecai_wikimedia_fixture_server, start_link, []},
        maps:get(start, Spec)
    ),
    ?assertEqual(permanent, maps:get(restart, Spec)),
    ?assertEqual(5000, maps:get(shutdown, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)).

priv_fixture_files_test() ->
    Dir = source_dir(),
    Names = [
        "pageviews-202606-user.txt",
        "pageviews-202606-user.bz2",
        "enwiki_content-20260720-00000.json",
        "enwiki_content-20260720-00000.json.bz2"
    ],
    lists:foreach(
        fun(Name) ->
            Path = filename:join(Dir, Name),
            ?assert(filelib:is_regular(Path)),
            ?assert(filelib:file_size(Path) > 0)
        end,
        Names
    ).

source_dir() ->
    case code:priv_dir(ecai) of
        {error, bad_name} ->
            filename:join([
                "apps",
                "ecai",
                "priv",
                "wikimedia-fixtures"
            ]);
        PrivDir ->
            filename:join(PrivDir, "wikimedia-fixtures")
    end.
