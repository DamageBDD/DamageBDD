-module(ecai_voice_session_tests).
-include_lib("eunit/include/eunit.hrl").

options_test() ->
    {ok, O} = ecai_voice_session:options(#{}),
    ?assertEqual(6, maps:get(seconds, O)),
    ?assertEqual(curve, maps:get(backend, O)),
    ?assertEqual(ask, maps:get(unknown_calibration, O)),
    ?assertEqual(undefined, maps:get(speakers, O)),
    ?assertEqual(750, maps:get(settle_ms, O)),
    ?assertMatch({error, _}, ecai_voice_session:options(not_a_map)),
    ?assertMatch({error, {unknown_options, [_]}}, ecai_voice_session:options(#{foo => bar})),
    ?assertEqual({error, {invalid_option, seconds}},
                 ecai_voice_session:options(#{seconds => 31})),
    ?assertEqual({error, invalid_backend},
                 ecai_voice_session:options(#{backend => foo})),
    ?assertEqual({error, invalid_speaker_labels},
                 ecai_voice_session:options(#{speakers => ["alice", "alice"]})),
    ?assertEqual({error, invalid_speaker_labels},
                 ecai_voice_session:options(#{speakers => ["../alice", "bob"]})),
    ?assertEqual({error, invalid_unknown_calibration},
                 ecai_voice_session:options(#{unknown_calibration => foo})),
    ?assertEqual({error, invalid_speak_results},
                 ecai_voice_session:options(#{speak_results => no})),
    {ok, S} = ecai_voice_session:options(#{speakers => ["alice", <<"bob">>],
                                          seconds => 2, backend => integer}),
    ?assertEqual([<<"alice">>, <<"bob">>], maps:get(speakers, S)),
    ?assertEqual(integer, maps:get(backend, S)).

missing_session_test() ->
    with_tmp(fun(Dir) ->
        ?assertEqual({ok, #{session => filename:absname(Dir), speakers => [],
                            development => [], profile => #{status => absent}}},
                     ecai_voice_session:inspect(Dir))
    end).

malformed_manifest_test() ->
    with_tmp(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"alice\nalice\n">>),
        ?assertEqual({error, invalid_speaker_labels}, ecai_voice_session:inspect(Dir)),
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"alice\n../bob\n">>),
        ?assertEqual({error, invalid_speaker_labels}, ecai_voice_session:inspect(Dir))
    end).

saved_development_resume_test_() ->
    {timeout, 240, fun() -> with_tmp(fun(Dir) ->
        {ok, _} = application:ensure_all_started(crypto),
        Fixtures = filename:join(Dir, "fixtures"),
        {ok, _} = ecai_voice_demo:generate(Fixtures),
        ok = file:make_dir(filename:join(Dir, "develop")),
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"voice_a\nvoice_b\n">>),
        lists:foreach(fun({Label, Split, Take}) ->
            Name = lists:flatten(io_lib:format("~s_~s_~B.wav", [Label, Split, Take])),
            Dest = lists:flatten(io_lib:format("~s--~s--01.wav", [Split, Label])),
            {ok, _} = file:copy(filename:join(Fixtures, Name),
                                filename:join([Dir, "develop", Dest]))
        end, [{voice_a, enroll, 1}, {voice_b, enroll, 1},
              {voice_a, calibrate, 2}, {voice_b, calibrate, 2},
              {unknown, calibrate, 2}]),
        {ok, Before} = ecai_voice_session:inspect(Dir),
        ?assertEqual(#{status => absent}, maps:get(profile, Before)),
        ?assertEqual(1, maps:get(enroll, proplists:get_value(<<"voice_a">>,
                                                       maps:get(development, Before)))),
        {ok, _} = ecai_voice_loop:build(Dir),
        {ok, After} = ecai_voice_session:inspect(Dir),
        ?assertMatch(#{status := ready, thresholds := _}, maps:get(profile, After)),
        ?assertEqual([<<"voice_a">>, <<"voice_b">>], maps:get(speakers, After))
    end) end}.

with_tmp(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(Base, "ecai-voice-session-test-" ++
                              binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
