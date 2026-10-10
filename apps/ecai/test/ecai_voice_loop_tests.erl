-module(ecai_voice_loop_tests).
-include_lib("eunit/include/eunit.hrl").

labels_and_expected_test() ->
    ?assert(ecai_voice_loop:label_valid(<<"speaker_1">>)),
    ?assert(ecai_voice_loop:label_valid(<<"A-b">>)),
    lists:foreach(fun(B) -> ?assertNot(ecai_voice_loop:label_valid(B)) end,
                  [<<>>, <<"unknown">>, <<"../a">>, <<"a,b">>, <<"--voice">>,
                   <<"x\ny">>, <<"$(touch /tmp/no)">>, <<0>>, binary:copy(<<"a">>, 33), foo]),
    ?assertEqual({ok, undefined}, ecai_voice_loop:expected("")),
    ?assertEqual({ok, unknown}, ecai_voice_loop:expected(<<"unknown">>)),
    ?assertEqual({ok, <<"alice">>}, ecai_voice_loop:expected("alice")),
    ?assertEqual({error, invalid_expected_label}, ecai_voice_loop:expected("../alice")).

feedback_test() ->
    ?assertMatch(<<"Unknown", _/binary>>, ecai_voice_loop:feedback(#{status => unknown})),
    ?assertMatch(<<"Insufficient", _/binary>>, ecai_voice_loop:feedback(#{status => insufficient_audio})),
    ?assertMatch(<<"Voice match: alice.", _/binary>>,
                 ecai_voice_loop:feedback(#{status => matched, speaker => <<"alice">>})).

invalid_session_test() ->
    with_dir(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"alice\n../bob\n">>),
        ?assertEqual({error, invalid_speakers_file}, ecai_voice_loop:rows(Dir)),
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"alice\nalice\n">>),
        ?assertEqual({error, invalid_speakers_file}, ecai_voice_loop:rows(Dir)),
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"alice\nbob\n">>),
        ?assertEqual({error, {missing_recordings, <<"alice">>}}, ecai_voice_loop:rows(Dir))
    end).

short_capture_test() ->
    with_dir(fun(Dir) ->
        Path = filename:join(Dir, "short.wav"),
        ok = ecai_voice_wav:write(Path, <<0:(16000 * 2 * 8)>>),
        ?assertEqual({error, incomplete_capture}, ecai_voice_loop:check(Path, 2)),
        ?assertEqual({error, seconds_must_be_2_to_30}, ecai_voice_loop:check(Path, 1))
    end).

native_session_integration_test_() ->
    {timeout, 240, fun() -> with_dir(fun(Dir) ->
        Fixture = filename:join(Dir, "fixtures"),
        {ok, _} = ecai_voice_demo:generate(Fixture),
        ok = filelib:ensure_dir(filename:join([Dir, "develop", "placeholder"])),
        ok = file:write_file(filename:join(Dir, "speakers.txt"), <<"voice_a\nvoice_b\n">>),
        lists:foreach(fun({Label, Split, Take}) ->
            Name = lists:flatten(io_lib:format("~s_~s_~B.wav", [Label, Split, Take])),
            Dest = lists:flatten(io_lib:format("~s--~s--01.wav", [Split, Label])),
            {ok, _} = file:copy(filename:join(Fixture, Name), filename:join([Dir, "develop", Dest]))
        end, [{voice_a, enroll, 1}, {voice_b, enroll, 1},
              {voice_a, calibrate, 2}, {voice_b, calibrate, 2}, {unknown, calibrate, 2}]),
        {ok, Rs} = ecai_voice_loop:rows(Dir),
        ?assertEqual(5, length(Rs)),
        %% Test files have no role in profile construction, even invalid ones.
        ok = filelib:ensure_dir(filename:join([Dir, "tests", "placeholder"])),
        ok = file:write_file(filename:join([Dir, "tests", "bad.wav"]), <<"not audio">>),
        {ok, _} = ecai_voice_loop:build(Dir),
        ProfilePath = filename:join(Dir, "voices.ecv"),
        {ok, Before} = file:read_file(ProfilePath),
        Query = filename:join(Fixture, "voice_a_test_3.wav"),
        {ok, _} = ecai_voice_loop:check(Query, 2),
        {ok, R} = ecai_voice_loop:score(Dir, Query, <<"voice_a">>, curve),
        ?assertEqual(known_correct, maps:get(outcome, R)),
        ?assert(maps:get(curve_integer_invariant_checked, R)),
        {ok, I} = ecai_voice_loop:score(Dir, Query, <<"voice_a">>, integer),
        ?assertEqual(maps:get(best_distance, R), maps:get(best_distance, I)),
        ?assertEqual({error, expected_speaker_not_enrolled},
                     ecai_voice_loop:score(Dir, Query, <<"not_enrolled">>, curve)),
        {ok, U} = ecai_voice_loop:score(Dir, filename:join(Fixture, "unknown_test_3.wav"), unknown, curve),
        ?assertEqual(unknown_rejected, maps:get(outcome, U)),
        {ok, Reused} = ecai_voice_loop:score(Dir, filename:join(Fixture, "voice_a_enroll_1.wav"), <<"voice_a">>, curve),
        ?assertEqual(development_audio_not_a_test, maps:get(outcome, Reused)),
        ?assertEqual({ok, Before}, file:read_file(ProfilePath)),
        ?assertEqual({error, profile_already_exists}, ecai_voice_loop:build(Dir)),
        Imported = filename:join(Dir, "imported"),
        {ok, _} = ecai_voice_loop:import_profile(ProfilePath, Imported),
        ?assertEqual({ok, Before}, file:read_file(filename:join(Imported, "voices.ecv"))),
        ?assertEqual({error, profile_already_exists}, ecai_voice_loop:import_profile(ProfilePath, Imported))
    end) end}.

with_dir(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; S -> S end,
    Name = "ecai-loop-test-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Dir = filename:join(Base, Name),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
