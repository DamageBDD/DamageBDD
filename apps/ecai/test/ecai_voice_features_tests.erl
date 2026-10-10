-module(ecai_voice_features_tests).
-include_lib("eunit/include/eunit.hrl").

fft_reference_test() ->
    Plan = ecai_voice_dsp:plan(),
    X = [{1.0, 0.0}, {2.0, 0.0}, {-1.0, 0.0}, {0.5, 0.0},
         {3.0, 0.0}, {0.0, 0.0}, {4.0, 0.0}, {-2.0, 0.0}],
    Actual = ecai_voice_dsp:fft(X, Plan),
    Expected = dft(X),
    lists:foreach(fun({{AR, AI}, {ER, EI}}) ->
        ?assert(abs(AR - ER) < 1.0e-9), ?assert(abs(AI - EI) < 1.0e-9)
    end, lists:zip(Actual, Expected)).

fft_invalid_length_test() ->
    Plan = ecai_voice_dsp:plan(),
    ?assertError(badarg, ecai_voice_dsp:fft([], Plan)),
    ?assertError(badarg, ecai_voice_dsp:fft([{1.0, 0.0}, {2.0, 0.0}, {3.0, 0.0}], Plan)).

autocorrelation_reference_test() ->
    Input = lists:duplicate(17, 0.0) ++ [1.0] ++ lists:duplicate(622, 0.0),
    [Zero | Rest] = ecai_voice_dsp:autocorrelation(Input, ecai_voice_dsp:plan()),
    ?assert(abs(Zero - 1.0) < 1.0e-9),
    ?assert(lists:all(fun(X) -> abs(X) < 1.0e-9 end, Rest)).

quantile_test() ->
    ?assertEqual(2.5, ecai_voice_dsp:quantile([4, 1, 3, 2], 0.5)),
    ?assertEqual(1.75, ecai_voice_dsp:quantile([4, 1, 3, 2], 0.25)),
    ?assertEqual(7.0, ecai_voice_dsp:quantile([7], 0.25)).

quality_gates_test() ->
    ?assertEqual({error, {insufficient_audio, too_short}}, ecai_voice_features:extract(<<0:16000>>)),
    ?assertEqual({error, {insufficient_audio, silence_or_too_quiet}},
                 ecai_voice_features:extract(<<0:(32000 * 2 * 8)>>)),
    Clipped = binary:copy(<<32767:16/little-signed>>, 32000),
    ?assertEqual({error, {insufficient_audio, excessive_clipping}}, ecai_voice_features:extract(Clipped)),
    ?assertEqual({error, invalid_pcm16_or_duration}, ecai_voice_features:extract(<<1>>)),
    TooLong = <<0:(16000 * 2 * 31 * 8)>>,
    ?assertEqual({error, invalid_pcm16_or_duration}, ecai_voice_features:extract(TooLong)).

feature_reference_test_() ->
    {timeout, 180, fun() ->
        PCM = ecai_voice_demo:synthetic(voice_a, 1, 2),
        {ok, F} = ecai_voice_features:extract(PCM),
        Q = maps:get(q, F),
        %% Independent NumPy/SciPy reference; one-bin tolerance for libm rounding.
        Expected = [72,-17,4,8,-7,-7,4,-2,-6,-2,2,0,-2,8,8,7,9,4,3,3,2,2,4,6,1,1,-17,-17,-17,32],
        ?assertEqual(30, length(Q)),
        ?assert(lists:all(fun({A, B}) -> abs(A - B) =< 1 end, lists:zip(Q, Expected))),
        ?assertEqual(ecai_voice_features:version(), maps:get(frontend, F)),
        {ok, Again} = ecai_voice_features:extract(PCM),
        ?assertEqual(F, Again),
        LowerGain = << <<(round(S * 0.4)):16/little-signed>> || <<S:16/little-signed>> <= PCM >>,
        {ok, Low} = ecai_voice_features:extract(LowerGain),
        {ok, D} = ecai_voice_curve:integer_distance(Q, maps:get(q, Low)),
        ?assert(D =< 20)
    end}.

same_pitch_different_envelope_test_() ->
    {timeout, 180, fun() ->
        {ok, A} = ecai_voice_features:extract(ecai_voice_demo:synthetic(voice_a, 1, 2)),
        {ok, B} = ecai_voice_features:extract(ecai_voice_demo:synthetic(same_pitch_b, 1, 2)),
        PitchA = maps:get(pitch_median_hz, maps:get(quality, A)),
        PitchB = maps:get(pitch_median_hz, maps:get(quality, B)),
        ?assert(abs(PitchA - PitchB) < 10),
        {ok, D} = ecai_voice_curve:integer_distance(maps:get(q, A), maps:get(q, B)),
        ?assert(D > 80)
    end}.

noise_rejection_test_() ->
    {timeout, 180, fun() ->
        PCM = noise(32000, 1, []),
        ?assertEqual({error, {insufficient_audio, insufficient_periodicity}},
                     ecai_voice_features:extract(PCM))
    end}.

noise(0, _, Acc) -> iolist_to_binary(lists:reverse(Acc));
noise(N, Seed, Acc) ->
    Next = (1103515245 * Seed + 12345) band 16#7FFFFFFF,
    S = ((Next bsr 8) rem 16001) - 8000,
    noise(N - 1, Next, [<<S:16/little-signed>> | Acc]).

dft(X) ->
    N = length(X),
    Indexed = lists:zip(X, lists:seq(0, N - 1)),
    [lists:foldl(fun({{R, I}, J}, {SR, SI}) ->
        A = -2 * math:pi() * K * J / N,
        {SR + R * math:cos(A) - I * math:sin(A),
         SI + R * math:sin(A) + I * math:cos(A)}
    end, {0.0, 0.0}, Indexed) || K <- lists:seq(0, N - 1)].
