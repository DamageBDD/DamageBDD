-module(ecai_voice_tts_tests).
-include_lib("eunit/include/eunit.hrl").

scripts_are_disjoint_test() ->
    Human = [ecai_voice_tts:script(human, S, N)
             || S <- [enroll, calibrate, test], N <- lists:seq(1, 5)],
    Synthetic = [ecai_voice_tts:script(synthetic, S, N)
                 || S <- [enroll, calibrate, test], N <- lists:seq(1, 5)],
    ?assertEqual(length(Human), length(lists:usort(Human))),
    ?assertEqual(length(Synthetic), length(lists:usort(Synthetic))),
    ?assertEqual([], [Text || Text <- Human, lists:member(Text, Synthetic)]),
    ?assert(ecai_voice_tts:script(synthetic, test, 50) =/=
            ecai_voice_tts:script(synthetic, test, 51)).

normalizes_espeak_rate_test() ->
    PCM = tone(22050, 176, 2),
    {ok, Converted} = ecai_voice_tts:normalize(wav(22050, PCM), 8),
    {ok, A} = ecai_voice_wav:decode(Converted),
    ?assertEqual(16000, maps:get(sample_rate, A)),
    ?assertEqual(1, maps:get(channels, A)),
    ?assertEqual(8.0, maps:get(seconds, A)),
    ?assertEqual(8 * 32000, byte_size(maps:get(pcm, A))),
    <<First:32000/binary, _/binary>> = maps:get(pcm, A),
    ?assert(First =/= binary:copy(<<0>>, byte_size(First))),
    ?assertEqual(0, binary:at(maps:get(pcm, A), 8 * 32000 - 1)).

passes_through_target_rate_test() ->
    PCM = tone(16000, 180, 2),
    {ok, Converted} = ecai_voice_tts:normalize(wav(16000, PCM), 4),
    {ok, #{pcm := Normal}} = ecai_voice_wav:decode(Converted),
    ?assertEqual(PCM, binary:part(Normal, 0, byte_size(PCM))),
    ?assertEqual(binary:copy(<<0>>, byte_size(PCM)),
                 binary:part(Normal, byte_size(PCM), byte_size(PCM))).

rejects_bad_tts_samples_test() ->
    ?assertMatch({error, _}, ecai_voice_tts:normalize(<<"broken">>, 8)),
    ?assertMatch({error, {tts_audio_too_long, _, 3}},
                 ecai_voice_tts:normalize(wav(16000, tone(16000, 176, 4)), 3)),
    ?assertMatch({error, _}, ecai_voice_tts:normalize(wav(22050, <<>>), 8)),
    ?assertMatch({error, _}, ecai_voice_tts:normalize(<<>>, 31)).

tts_options_test() ->
    {ok, Opts} = ecai_voice_session:options(#{speakers => [<<"human">>, <<"tts_demo">>],
        tts_speaker => <<"tts_demo">>, tts_voice => "en+f3", tts_speed => 155}),
    ?assertEqual(<<"tts_demo">>, maps:get(tts_speaker, Opts)),
    ?assertEqual("en+f3", maps:get(tts_voice, Opts)),
    ?assertEqual(155, maps:get(tts_speed, Opts)),
    ?assertEqual({error, invalid_tts_speaker},
                 ecai_voice_session:options(#{tts_speaker => <<"unknown">>})),
    ?assertEqual({error, invalid_tts_voice},
                 ecai_voice_session:options(#{tts_voice => "foo bar"})),
    ?assertEqual({error, {invalid_option, tts_speed}},
                 ecai_voice_session:options(#{tts_speed => 99})).

%% Exercise the production session synthesis path rather than just normalize/2.
%% Skip only when eSpeak is absent; there is no microphone dependency.
real_espeak_session_roundtrip_test_() ->
    case os:find_executable("espeak-ng") of
        false -> [];
        _ -> {timeout, 45, fun real_espeak_session_roundtrip/0}
    end.

real_espeak_session_roundtrip() ->
    {ok, _} = application:ensure_all_started(crypto),
    TempRoot = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Unique = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Dir = filename:join(TempRoot, "ecai-voice-tts-test-" ++ Unique),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "voice.wav"),
    try
        Options = #{tts_voice => "en+f3", tts_speed => 155, seconds => 8},
        Text = ecai_voice_tts:script(synthetic, enroll, 1),
        ?assertEqual(ok, ecai_voice_session:synthesize_take(Path, Text, Options)),
        {ok, Audio} = ecai_voice_wav:read(Path),
        ?assertEqual(16000, maps:get(sample_rate, Audio)),
        ?assertEqual(1, maps:get(channels, Audio)),
        ?assertEqual(8.0, maps:get(seconds, Audio)),
        ?assertEqual(8 * 32000, byte_size(maps:get(pcm, Audio)))
    after
        _ = file:delete(Path),
        _ = file:delete(Path ++ ".espeak-raw.wav"),
        _ = file:del_dir(Dir)
    end.

tone(Rate, Freq, Seconds) ->
    list_to_binary([begin
        Value = round(10000 * math:sin(2 * math:pi() * Freq * N / Rate)),
        <<Value:16/little-signed>>
    end || N <- lists:seq(0, Rate * Seconds - 1)]).

wav(Rate, PCM) ->
    N = byte_size(PCM),
    <<"RIFF", (36 + N):32/little, "WAVEfmt ", 16:32/little,
      1:16/little, 1:16/little, Rate:32/little, (Rate * 2):32/little,
      2:16/little, 16:16/little, "data", N:32/little, PCM/binary>>.
