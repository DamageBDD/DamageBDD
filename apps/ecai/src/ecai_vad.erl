-module(ecai_vad).

-export([init/1, classify/2]).

-record(vad, {
    mode = energy_zcr,
    energy_threshold = 500,
    zcr_threshold = 120,
    hangover_frames = 8,
    in_speech = false,
    hangover_left = 0
}).

init(Opts) ->
    #vad{
        mode = maps:get(mode, Opts, energy_zcr),
        energy_threshold = maps:get(energy_threshold, Opts, 500),
        zcr_threshold = maps:get(zcr_threshold, Opts, 120),
        hangover_frames = maps:get(hangover_frames, Opts, 8)
    }.

classify(
    FrameBin,
    Vad0 = #vad{
        energy_threshold = EnergyThr,
        zcr_threshold = ZcrThr,
        hangover_frames = HangoverFrames,
        in_speech = InSpeech,
        hangover_left = HangoverLeft
    }
) ->
    {AvgAbs, Zcr} = features(FrameBin),
    RawSpeech = (AvgAbs >= EnergyThr) andalso (Zcr =< ZcrThr),

    {Decision, Vad1} =
        case {RawSpeech, InSpeech, HangoverLeft} of
            {true, _, _} ->
                {speech, Vad0#vad{in_speech = true, hangover_left = HangoverFrames}};
            {false, true, N} when N > 0 ->
                {speech, Vad0#vad{in_speech = true, hangover_left = N - 1}};
            {false, true, 0} ->
                {silence, Vad0#vad{in_speech = false, hangover_left = 0}};
            {false, false, _} ->
                {silence, Vad0#vad{in_speech = false, hangover_left = 0}}
        end,

    Features = #{
        avg_abs => AvgAbs,
        zcr => Zcr,
        raw_speech => RawSpeech,
        in_speech => Vad1#vad.in_speech,
        hangover_left => Vad1#vad.hangover_left
    },

    {Decision, Vad1, Features}.

features(Bin) ->
    features(Bin, 0, 0, 0, 0).

features(<<Sample:16/little-signed, Rest/binary>>, Count, SumAbs, PrevSign, Zcr) ->
    Abs = abs(Sample),
    Sign =
        if
            Sample > 0 -> 1;
            Sample < 0 -> -1;
            true -> 0
        end,
    Zcr1 =
        case {PrevSign, Sign} of
            {0, _} -> Zcr;
            {S1, S2} when S1 =:= S2 -> Zcr;
            {_, 0} -> Zcr;
            {_, _} -> Zcr + 1
        end,
    features(Rest, Count + 1, SumAbs + Abs, Sign, Zcr1);
features(<<>>, 0, _SumAbs, _PrevSign, Zcr) ->
    {0, Zcr};
features(<<>>, Count, SumAbs, _PrevSign, Zcr) ->
    {SumAbs div Count, Zcr}.
