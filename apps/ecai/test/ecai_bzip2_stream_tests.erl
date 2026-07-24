-module(ecai_bzip2_stream_tests).

-include_lib("eunit/include/eunit.hrl").

folds_lines_without_materializing_source_test() ->
    with_bzip2(fun() ->
        {ok, LinesRev, Stats} = ecai_bzip2_stream:fold_lines(
            fixture_path(),
            fun(Line, Acc) -> {ok, [Line | Acc]} end,
            [],
            #{timeout_ms => 5000}
        ),
        ?assertEqual(
            [<<"alpha">>, <<"beta">>, <<"gamma">>],
            lists:reverse(LinesRev)
        ),
        ?assertEqual(3, maps:get(lines, Stats)),
        ?assertEqual(false, maps:get(stopped, Stats))
    end).

fold_can_stop_early_test() ->
    with_bzip2(fun() ->
        {ok, LinesRev, Stats} = ecai_bzip2_stream:fold_lines(
            fixture_path(),
            fun
                (<<"beta">> = Line, Acc) -> {stop, [Line | Acc]};
                (Line, Acc) -> {ok, [Line | Acc]}
            end,
            [],
            #{timeout_ms => 5000}
        ),
        ?assertEqual([<<"alpha">>, <<"beta">>], lists:reverse(LinesRev)),
        ?assertEqual(2, maps:get(lines, Stats)),
        ?assertEqual(true, maps:get(stopped, Stats))
    end).

missing_source_is_reported_test() ->
    ?assertMatch(
        {error, {source_not_found, _}},
        ecai_bzip2_stream:fold_lines(
            <<"/definitely/not/present.wikimedia.bz2">>,
            fun(_Line, Acc) -> {ok, Acc} end,
            []
        )
    ).

invalid_arguments_are_rejected_test() ->
    ?assertEqual(
        {error, badarg},
        ecai_bzip2_stream:fold_lines(fixture_path(), not_a_function, [], #{})
    ).

with_bzip2(Fun) ->
    case ecai_bzip2_stream:executable() of
        {ok, _} -> Fun();
        {error, bzip2_not_found} -> ok
    end.

fixture_path() ->
    filename:join(
        filename:dirname(?FILE),
        "fixtures/wikimedia-lines.txt.bz2"
    ).
