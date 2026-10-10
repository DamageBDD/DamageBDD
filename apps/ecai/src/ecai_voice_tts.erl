%%% Synthetic speaker fixture support for the interactive ECAI voice experiment.
%%% eSpeak's WAV output is converted deterministically in Erlang, with no
%%% ALSA loopback, external resampler, neural model, or microphone capture.
%%% These synthetic references are research fixtures, NOT human identities.
-module(ecai_voice_tts).
-license("Apache-2.0").
-export([script/3, normalize/2]).

-define(MAX_SYNTH_WAV, 3 * 1024 * 1024).
-define(TARGET_RATE, 16000).

%% Each split uses different text. Repeated test rounds use a distinct number.
%% Prompts are intentionally short enough for the default eight-second window.
-spec script(human | synthetic, enroll | calibrate | test, pos_integer()) -> string().
script(human, enroll, N) when is_integer(N), N >= 1 ->
    choose(["I am reading this sentence clearly, using my usual speaking voice.",
            "The small garden behind the house looks peaceful in the morning.",
            "A gentle breeze moved across the trees beside our old driveway.",
            "Every week I enjoy making something useful with my own hands.",
            "The street outside my home becomes quiet after the sun sets.",
            "Today I am practicing a steady rhythm while reading these words.",
            "A paper notebook helps me remember ideas that arrive unexpectedly.",
            "Sometimes the simplest experiments reveal an interesting new result.",
            "Walking through the park gives me a chance to think carefully.",
            "A clear voice sample helps us check the current experiment."], N);
script(human, calibrate, N) when is_integer(N), N >= 1 ->
    choose(["This different sentence checks how my voice sounds on another recording.",
            "Blue morning light slowly appeared above the roofs across the street.",
            "The sound of running water echoed inside the empty hallway.",
            "I placed the wooden chair beside a narrow window yesterday.",
            "An ordinary conversation can contain many distinct vowel sounds.",
            "A quiet room makes it easier to record a useful sample.",
            "Reading another passage allows the system to compare recordings.",
            "Bright clouds drifted past the hills early in the afternoon.",
            "Some short phrases sound different even when one person speaks.",
            "I am trying to maintain the same natural pace and volume."], N);
script(human, test, N) when is_integer(N), N >= 1 ->
    choose(["The afternoon sunshine reached the steps beside my front door.",
            "I wonder whether this recording matches the earlier voice samples.",
            "Four small birds rested briefly near the garden fence.",
            "My voice should sound familiar even when the words change.",
            "A simple repeatable test is better than a convenient assumption."], N);
script(synthetic, enroll, N) when is_integer(N), N >= 1 ->
    choose(["A copper lantern glowed softly beside the old wooden bridge.",
            "The little robot crossed the square before the market opened.",
            "Golden leaves fell beside the quiet red brick building.",
            "A silver compass rested inside the traveller's pocket.",
            "The narrow railway platform was empty after the storm.",
            "A tiny clock chimed above the entrance to the library.",
            "Several painted boats drifted gently along the canal.",
            "The blue bicycle stood beside an open garden gate.",
            "A round wooden table occupied the centre of the room.",
            "The green valley stretched beyond the distant mountain road."], N);
script(synthetic, calibrate, N) when is_integer(N), N >= 1 ->
    choose(["Bright morning sunlight warmed the steps of the old house.",
            "A wooden bell tower overlooked the quiet village square.",
            "Three yellow flowers bloomed beside the narrow stone path.",
            "The blue river curved around a field of tall grass.",
            "A gentle clockwork bird sang beside the workshop door.",
            "Small silver raindrops glittered across the empty bench.",
            "The distant harbour remained calm beneath the evening sky.",
            "A little paper kite floated beyond the garden wall.",
            "The green tram crossed the bridge just before sunrise.",
            "A warm light flickered behind the laboratory window."], N);
script(synthetic, test, N) when is_integer(N), N >= 1 ->
    choose(["Several quiet birds circled above the empty railway station.",
            "A small orange boat sailed slowly across the lake.",
            "The wooden staircase creaked beneath the evening breeze.",
            "A distant clock rang out across the market square.",
            "The narrow path continued towards the old stone fountain."], N)
        ++ " Test number " ++ integer_to_list(N) ++ ".".

choose(Lines, N) -> lists:nth(((N - 1) rem length(Lines)) + 1, Lines).

%% Normalize a standard mono PCM16 RIFF/WAVE returned by espeak-ng -w.
%% A fixed-length 16 kHz PCM16 WAV is required by ecai_voice_loop:check/2.
%% Reject rather than truncate a synthetic utterance that would not fit.
-spec normalize(binary(), pos_integer()) -> {ok, binary()} | {error, term()}.
normalize(Bin, Seconds) when is_binary(Bin), byte_size(Bin) =< ?MAX_SYNTH_WAV,
                             is_integer(Seconds), Seconds >= 2, Seconds =< 30 ->
    case parse_wav(Bin) of
        {ok, Rate, PCM} ->
            SourceSamples = byte_size(PCM) div 2,
            OutSamples = (SourceSamples * ?TARGET_RATE + Rate div 2) div Rate,
            TargetSamples = Seconds * ?TARGET_RATE,
            case OutSamples of
                0 -> {error, empty_tts_audio};
                N when N > TargetSamples ->
                    {error, {tts_audio_too_long, N / ?TARGET_RATE, Seconds}};
                N ->
                    Resampled = case Rate of
                        ?TARGET_RATE -> PCM;
                        _ -> resample(PCM, Rate, N)
                    end,
                    Padding = binary:copy(<<0>>, (TargetSamples - N) * 2),
                    ecai_voice_wav:encode_mono(<<Resampled/binary, Padding/binary>>)
            end;
        Error -> Error
    end;
normalize(_, _) -> {error, invalid_tts_audio_or_duration}.

parse_wav(<<"RIFF", Size:32/little-unsigned, "WAVE", Rest/binary>>)
  when Size =:= byte_size(Rest) + 4 ->
    chunks(Rest, undefined, undefined);
parse_wav(_) -> {error, invalid_tts_riff}.

chunks(<<>>, undefined, _) -> {error, tts_missing_format};
chunks(<<>>, _, undefined) -> {error, tts_missing_samples};
chunks(<<>>, Fmt, PCM) -> format(Fmt, PCM);
chunks(<<Tag:4/binary, Size:32/little-unsigned, Rest/binary>>, Fmt, PCM) ->
    Pad = Size band 1,
    case Rest of
        <<Body:Size/binary, _P:Pad/binary, Tail/binary>> ->
            case Tag of
                <<"fmt ">> when Fmt =:= undefined -> chunks(Tail, Body, PCM);
                <<"data">> when PCM =:= undefined -> chunks(Tail, Fmt, Body);
                <<"fmt ">> -> {error, tts_duplicate_format};
                <<"data">> -> {error, tts_duplicate_samples};
                _ -> chunks(Tail, Fmt, PCM)
            end;
        _ -> {error, invalid_tts_chunk}
    end;
chunks(_, _, _) -> {error, invalid_tts_chunk_header}.

format(<<1:16/little, 1:16/little, Rate:32/little-unsigned,
         ByteRate:32/little-unsigned, 2:16/little, 16:16/little, Extra/binary>>, PCM)
  when Rate >= 8000, Rate =< 48000, ByteRate =:= Rate * 2,
       (Extra =:= <<>> orelse Extra =:= <<0,0>>), byte_size(PCM) > 0,
       byte_size(PCM) rem 2 =:= 0 ->
    {ok, Rate, PCM};
format(_, _) -> {error, tts_unsupported_pcm_format}.

%% Linear, deterministic resampling. This is intentionally a fixture converter,
%% not a high-fidelity resampling claim; no interpolation crosses the end.
resample(PCM, Rate, Count) ->
    SourceCount = byte_size(PCM) div 2,
    iolist_to_binary(resample(PCM, Rate, SourceCount, 0, Count, [])).

resample(_, _, _, Count, Count, Acc) -> lists:reverse(Acc);
resample(PCM, Rate, SourceCount, Index, Count, Acc) ->
    Position = Index * Rate,
    Left = Position div ?TARGET_RATE,
    Fraction = Position rem ?TARGET_RATE,
    <<A:16/little-signed>> = binary:part(PCM, Left * 2, 2),
    Right = min(Left + 1, SourceCount - 1),
    <<B:16/little-signed>> = binary:part(PCM, Right * 2, 2),
    Value = round((A * (?TARGET_RATE - Fraction) + B * Fraction) / ?TARGET_RATE),
    resample(PCM, Rate, SourceCount, Index + 1, Count,
             [<<Value:16/little-signed>> | Acc]).
