-module(ecai_wikimedia_fixture_server_tests).

-include_lib("eunit/include/eunit.hrl").

managed_fixture_server_test_() ->
    {timeout, 30, fun managed_fixture_server_test/0}.

managed_fixture_server_test() ->
    with_tmp(fun(RuntimeDir) ->
        FixtureDir = filename:join(RuntimeDir, "fixtures"),
        ok = copy_fixture_files(fixture_dir(), FixtureDir),
        Port = free_port(),
        ListenerRef = ecai_wikimedia_fixture_http_test,
        {ok, Pid} = ecai_wikimedia_fixture_server:start_link(#{
            listener_ref => ListenerRef,
            ip => {127, 0, 0, 1},
            port => Port,
            allow_non_loopback => false,
            fixture_dir => FixtureDir,
            runtime_dir => RuntimeDir
        }),
        unlink(Pid),
        try
            Status = ecai_wikimedia_fixture_server:status(Pid),
            ?assertEqual(true, maps:get(ready, Status)),
            BaseUrl = maps:get(base_url, Status),
            ?assertEqual(
                <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
                BaseUrl
            ),

            {200, HealthHeaders, HealthBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/_ecai/fixture/health">>,
                []
            ),
            ?assertEqual(
                <<"managed-otp">>,
                maps:get(<<"x-ecai-fixture-server">>, HealthHeaders)
            ),
            Health = jsx:decode(HealthBody, [return_maps]),
            ?assertEqual(true, maps:get(<<"ok">>, Health)),
            ?assertEqual(true, maps:get(<<"ready">>, Health)),
            CatalogPath = maps:get(<<"catalog_path">>, Health),
            ?assert(filelib:is_regular(binary_to_list(CatalogPath))),

            {200, _HealthAliasHeaders, HealthAliasBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/healthz">>,
                []
            ),
            HealthAlias = jsx:decode(HealthAliasBody, [return_maps]),
            ?assertEqual(true, maps:get(<<"ready">>, HealthAlias)),

            {200, _CatalogHeaders, CatalogBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/wikimedia-catalog.json">>,
                []
            ),
            Catalog = jsx:decode(CatalogBody, [return_maps]),
            [ContentSource] = maps:get(<<"content_shards">>, Catalog),
            [PageviewSource] = maps:get(<<"pageview_sources">>, Catalog),
            ExpectedPrefix = <<BaseUrl/binary, "/">>,
            ?assertEqual(
                {0, byte_size(ExpectedPrefix)},
                binary:match(maps:get(<<"url">>, ContentSource), ExpectedPrefix)
            ),
            ?assertEqual(
                {0, byte_size(ExpectedPrefix)},
                binary:match(maps:get(<<"url">>, PageviewSource), ExpectedPrefix)
            ),

            SourceBz2 = filename:join(FixtureDir, "pageviews-202606-user.bz2"),
            {ok, ExpectedBody} = file:read_file(SourceBz2),
            {200, FileHeaders, ExpectedBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.bz2">>,
                []
            ),
            ?assertEqual(
                <<"bytes">>,
                maps:get(<<"accept-ranges">>, FileHeaders)
            ),
            Etag = maps:get(<<"etag">>, FileHeaders),

            {304, NotModifiedHeaders, <<>>} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.bz2">>,
                [{<<"if-none-match">>, <<"\"other\", ", Etag/binary>>}]
            ),
            ?assertEqual(Etag, maps:get(<<"etag">>, NotModifiedHeaders)),

            {206, RangeHeaders, RangeBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.bz2">>,
                [
                    {<<"range">>, <<"bytes=0-15">>},
                    {<<"if-range">>, Etag}
                ]
            ),
            ?assertEqual(16, byte_size(RangeBody)),
            ?assertEqual(binary:part(ExpectedBody, 0, 16), RangeBody),
            ?assertEqual(
                <<"bytes 0-15/", (integer_to_binary(byte_size(ExpectedBody)))/binary>>,
                maps:get(<<"content-range">>, RangeHeaders)
            ),

            %% A stale If-Range validator must force a complete 200 response.
            {200, _FullHeaders, ExpectedBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.bz2">>,
                [
                    {<<"range">>, <<"bytes=0-15">>},
                    {<<"if-range">>, <<"\"stale\"">>}
                ]
            ),

            {416, UnsatisfiedHeaders, <<>>} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.bz2">>,
                [{<<"range">>, <<"bytes=999999-1000000">>}]
            ),
            ?assertEqual(
                <<"bytes */", (integer_to_binary(byte_size(ExpectedBody)))/binary>>,
                maps:get(<<"content-range">>, UnsatisfiedHeaders)
            ),

            {405, MethodHeaders, _MethodBody} = raw_request(
                Port,
                <<"POST">>,
                <<"/pageviews-202606-user.bz2">>,
                []
            ),
            ?assertEqual(<<"GET, HEAD">>, maps:get(<<"allow">>, MethodHeaders)),

            %% Uncompressed sidecars are packaged for inspection but not served.
            {404, _PlainHeaders, _PlainBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202606-user.txt">>,
                []
            ),

            {200, HeadHeaders, <<>>} = raw_request(
                Port,
                <<"HEAD">>,
                <<"/pageviews-202606-user.bz2">>,
                []
            ),
            ?assertEqual(
                integer_to_binary(byte_size(ExpectedBody)),
                maps:get(<<"content-length">>, HeadHeaders)
            ),

            {404, _MissingHeaders, _MissingBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/not-an-allowed-fixture">>,
                []
            ),

            %% Reload discovers a new immutable month and atomically replaces
            %% the generated catalog plus Cowboy dispatch.
            NewPageview = filename:join(
                FixtureDir,
                "pageviews-202607-user.bz2"
            ),
            {ok, _CopiedBytes} = file:copy(SourceBz2, NewPageview),
            {ok, Reloaded} = ecai_wikimedia_fixture_server:reload(Pid),
            ?assertEqual(true, maps:get(ready, Reloaded)),
            ?assertEqual(2, maps:get(pageview_files, Reloaded)),

            {200, _ReloadedCatalogHeaders, ReloadedCatalogBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/wikimedia-catalog.json">>,
                []
            ),
            ReloadedCatalog = jsx:decode(ReloadedCatalogBody, [return_maps]),
            ?assertEqual(
                [<<"2026-06">>, <<"2026-07">>],
                maps:get(<<"pageview_months">>, ReloadedCatalog)
            ),
            {200, _NewSourceHeaders, ExpectedBody} = raw_request(
                Port,
                <<"GET">>,
                <<"/pageviews-202607-user.bz2">>,
                []
            )
        after
            ok = ecai_wikimedia_fixture_server:stop(Pid)
        end
    end).

missing_fixture_sources_fail_closed_test() ->
    with_tmp(fun(RuntimeDir) ->
        EmptyFixtureDir = filename:join(RuntimeDir, "empty-fixtures"),
        ok = filelib:ensure_dir(filename:join(EmptyFixtureDir, "x")),
        ?assertEqual(
            {error, no_wikimedia_content_fixtures},
            ecai_wikimedia_fixture_server:start_link(#{
                listener_ref => ecai_wikimedia_fixture_http_missing_test,
                ip => {127, 0, 0, 1},
                port => free_port(),
                fixture_dir => EmptyFixtureDir,
                runtime_dir => filename:join(RuntimeDir, "runtime")
            })
        )
    end).

non_loopback_bind_requires_opt_in_test() ->
    with_tmp(fun(RuntimeDir) ->
        ?assertEqual(
            {error, {fixture_non_loopback_binding_rejected, {0, 0, 0, 0}}},
            ecai_wikimedia_fixture_server:start_link(#{
                listener_ref => ecai_wikimedia_fixture_http_non_loopback_test,
                ip => {0, 0, 0, 0},
                port => free_port(),
                allow_non_loopback => false,
                fixture_dir => fixture_dir(),
                runtime_dir => RuntimeDir
            })
        )
    end).

raw_request(Port, Method, Path, ExtraHeaders) ->
    {ok, Socket} = gen_tcp:connect(
        {127, 0, 0, 1},
        Port,
        [binary, {active, false}, {packet, raw}],
        5000
    ),
    HeaderLines = [
        [Name, <<": ">>, Value, <<"\r\n">>]
     || {Name, Value} <- ExtraHeaders
    ],
    Request = iolist_to_binary([
        Method,
        <<" ">>,
        Path,
        <<" HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        HeaderLines,
        <<"Connection: close\r\n\r\n">>
    ]),
    ok = gen_tcp:send(Socket, Request),
    Response = recv_all(Socket, []),
    ok = gen_tcp:close(Socket),
    parse_response(Response).

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Bin} -> recv_all(Socket, [Bin | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc));
        {error, Reason} -> erlang:error({fixture_http_recv_failed, Reason})
    end.

parse_response(Response) ->
    case binary:split(Response, <<"\r\n\r\n">>) of
        [HeaderBlock, Body] ->
            [StatusLine | HeaderLines] = binary:split(
                HeaderBlock,
                <<"\r\n">>,
                [global]
            ),
            [<<"HTTP/1.1">>, StatusBin | _] = binary:split(
                StatusLine,
                <<" ">>,
                [global]
            ),
            Headers = maps:from_list([
                parse_header(Line)
             || Line <- HeaderLines,
                Line =/= <<>>
            ]),
            {binary_to_integer(StatusBin), Headers, Body};
        _ ->
            erlang:error({invalid_fixture_http_response, Response})
    end.

parse_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value0] ->
            {lower(Name), trim_leading_space(Value0)};
        _ ->
            erlang:error({invalid_fixture_http_header, Line})
    end.

trim_leading_space(<<" ", Rest/binary>>) -> Rest;
trim_leading_space(Bin) -> Bin.

lower(Bin) ->
    unicode:characters_to_binary(
        string:lowercase(unicode:characters_to_list(Bin))
    ).

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true}
    ]),
    {ok, {_Address, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

fixture_dir() ->
    case code:priv_dir(ecai) of
        {error, bad_name} ->
            filename:join(["apps", "ecai", "priv", "wikimedia-fixtures"]);
        PrivDir ->
            filename:join(PrivDir, "wikimedia-fixtures")
    end.

copy_fixture_files(SourceDir, DestinationDir) ->
    ok = filelib:ensure_dir(filename:join(DestinationDir, "x")),
    Names = [
        "pageviews-202606-user.txt",
        "pageviews-202606-user.bz2",
        "enwiki_content-20260720-00000.json",
        "enwiki_content-20260720-00000.json.bz2"
    ],
    lists:foreach(
        fun(Name) ->
            {ok, _Bytes} = file:copy(
                filename:join(SourceDir, Name),
                filename:join(DestinationDir, Name)
            )
        end,
        Names
    ),
    ok.

with_tmp(Fun) ->
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Dir = filename:join(temp_dir(), "ecai-managed-fixture-" ++ Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try Fun(Dir)
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
                {error, _Reason0} -> ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _Info} ->
            _ = file:delete(Path),
            ok;
        {error, _Reason1} ->
            ok
    end.
