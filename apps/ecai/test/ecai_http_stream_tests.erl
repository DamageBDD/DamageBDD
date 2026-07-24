-module(ecai_http_stream_tests).

-include_lib("eunit/include/eunit.hrl").

parse_https_url_test() ->
    {ok, Parsed} = ecai_http_stream:parse_url(
        <<"https://dumps.wikimedia.org/other/pageview_complete/monthly/2026/2026-06/file.bz2?x=1">>
    ),
    ?assertEqual(<<"dumps.wikimedia.org">>, maps:get(host, Parsed)),
    ?assertEqual(443, maps:get(port, Parsed)),
    ?assertEqual(tls, maps:get(transport, Parsed)),
    ?assertEqual(
        <<"/other/pageview_complete/monthly/2026/2026-06/file.bz2?x=1">>,
        maps:get(target, Parsed)
    ).

parse_http_custom_port_test() ->
    {ok, Parsed} = ecai_http_stream:parse_url(
        <<"http://127.0.0.1:18080/archive/file.json.bz2">>
    ),
    ?assertEqual(<<"127.0.0.1">>, maps:get(host, Parsed)),
    ?assertEqual(18080, maps:get(port, Parsed)),
    ?assertEqual(tcp, maps:get(transport, Parsed)),
    ?assertEqual(<<"/archive/file.json.bz2">>, maps:get(target, Parsed)).

rejects_unsupported_scheme_test() ->
    ?assertMatch(
        {error, {unsupported_url, _}},
        ecai_http_stream:parse_url(<<"file:///tmp/source">>)
    ).

invalid_arguments_are_rejected_test() ->
    ?assertEqual({error, badarg}, ecai_http_stream:get_binary(<<"https://example.test">>, 0)),
    ?assertEqual({error, badarg}, ecai_http_stream:download(<<"https://example.test">>, invalid_path, #{})).

existing_destination_is_a_cache_hit_test() ->
    with_tmp(fun(Dir) ->
        Destination = filename:join(Dir, "cached.bin"),
        Bytes = <<"already downloaded">>,
        ok = file:write_file(Destination, Bytes, [write, raw, binary, sync]),
        {ok, Meta} = ecai_http_stream:download(
            <<"http://127.0.0.1:1/not-contacted">>,
            Destination,
            #{timeout_ms => 10}
        ),
        ?assertEqual(cached, maps:get(source, Meta)),
        ?assertEqual(byte_size(Bytes), maps:get(bytes, Meta)),
        ?assertEqual(unicode:characters_to_binary(Destination), maps:get(path, Meta)),
        ?assertEqual({ok, Bytes}, file:read_file(Destination))
    end).

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-http-stream-" ++
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
