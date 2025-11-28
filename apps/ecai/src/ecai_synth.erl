-module(ecai_synth).

-export([
    render_loop/2,
    render_wobble/2,
    mix_wavs/2,
    add_track/3,
    test/0
]).

-define(DEFAULT_SR, 44100).

-include_lib("kernel/include/logger.hrl").
%% LoopSpec map:
%%  #{
%%      bpm => 120,
%%      seconds => 10.0,
%%      notes => [220.0, 277.18, 329.63, 392.0],  % Hz (A, C#, E, G)
%%      lfo_hz => 0.25
%%  }.
%%
%% This is the *data* you can tweak / swap / generate in Erlang.

%% -------------------------------------------------------------------
%% Basic arp loop
%% -------------------------------------------------------------------
render_loop(Path, Spec) ->
    Bpm = maps:get(bpm, Spec, 120),
    Seconds = maps:get(seconds, Spec, 8.0),
    SR = maps:get(sample_rate, Spec, ?DEFAULT_SR),
    Notes = maps:get(notes, Spec, [220.0]),
    LfoHz = maps:get(lfo_hz, Spec, 0.25),
    % multipliers
    Voices = maps:get(voices, Spec, [1.0, 2.0]),
    Amp = maps:get(amp, Spec, 0.55),

    TotalSamples = trunc(Seconds * SR),
    BeatLen = 60.0 / Bpm,
    NoteCount = length(Notes),

    PcmBin = build_pcm(
        0,
        TotalSamples,
        SR,
        BeatLen,
        Notes,
        NoteCount,
        LfoHz,
        Voices,
        Amp,
        <<>>
    ),

    case write_wav(Path, SR, 1, 16, PcmBin) of
        ok -> {ok, Path};
        Else -> Else
    end.

build_pcm(N, Total, _SR, _BeatLen, _Notes, _NC, _LfoHz, _Voices, _Amp, Acc) when
    N >= Total
->
    Acc;
build_pcm(N, Total, SR, BeatLen, Notes, NC, LfoHz, Voices, Amp, Acc) ->
    T = N / SR,
    BeatIndex = trunc(T / BeatLen),
    NoteIdx = (BeatIndex rem NC) + 1,
    Note = lists:nth(NoteIdx, Notes),

    %% multi-osc/voices synth: sum over Voices multipliers
    Base = lists:foldl(
        fun(Mul, Sum) ->
            Sum + math:sin(2 * math:pi() * Note * Mul * T)
        end,
        0.0,
        Voices
    ),

    Lfo = 0.5 * (1.0 + math:sin(2 * math:pi() * LfoHz * T)),
    SampleF = Amp * Base * Lfo,
    Clamped = clamp(SampleF, -1.0, 1.0),
    Int16 = trunc(Clamped * 32767.0),

    build_pcm(
        N + 1,
        Total,
        SR,
        BeatLen,
        Notes,
        NC,
        LfoHz,
        Voices,
        Amp,
        <<Acc/binary, Int16:16/little-signed>>
    ).

%% -------------------------------------------------------------------
%% Wobble / pad layer
%% -------------------------------------------------------------------
render_wobble(Path, Spec) ->
    SR = maps:get(sample_rate, Spec, 44100),
    Seconds = maps:get(seconds, Spec, 21.0),
    Total = trunc(Seconds * SR),

    Drone = maps:get(drone_note, Spec),
    Partials = maps:get(drone_partials, Spec, [1.0, 2.0]),
    Shimmer = maps:get(shimmer_notes, Spec, []),
    Detune = maps:get(detune, Spec, 0.05),
    NoiseAmp = maps:get(noise_amp, Spec, 0.02),
    NoiseLfoHz = maps:get(noise_lfo_hz, Spec, 0.1),
    LfoHz = maps:get(lfo_hz, Spec, 0.18),
    Amp = maps:get(amp, Spec, 0.4),

    PCM = build_wobble_loop(
        Total,
        SR,
        Drone,
        Partials,
        Shimmer,
        Detune,
        NoiseAmp,
        NoiseLfoHz,
        LfoHz,
        Amp
    ),

    case write_wav(Path, SR, 1, 16, PCM) of
        ok -> {ok, Path};
        Else -> Else
    end.

build_wobble_loop(
    N,
    SR,
    Drone,
    Partials,
    Shimmer,
    Detune,
    NoiseAmp,
    NoiseLfo,
    LfoHz,
    Amp
) ->
    build_wobble_loop(
        0,
        N,
        SR,
        Drone,
        Partials,
        Shimmer,
        Detune,
        NoiseAmp,
        NoiseLfo,
        LfoHz,
        Amp,
        <<>>
    ).

build_wobble_loop(
    I,
    Total,
    _SR,
    _Drone,
    _Partials,
    _Shimmer,
    _Detune,
    _NoiseAmp,
    _NoiseLfo,
    _LfoHz,
    _Amp,
    Acc
) when
    I >= Total
->
    Acc;
build_wobble_loop(
    I,
    Total,
    SR,
    Drone,
    Partials,
    Shimmer,
    Detune,
    NoiseAmp,
    NoiseLfo,
    LfoHz,
    Amp,
    Acc
) ->
    T = I / SR,

    %% Drone partials
    DroneSum =
        lists:foldl(
            fun(P, S) ->
                S + math:sin(2 * math:pi() * Drone * P * T)
            end,
            0.0,
            Partials
        ),

    %% Shimmer upper harmonics
    ShimmerSum =
        lists:foldl(
            fun(F, S) ->
                S + math:sin(2 * math:pi() * F * T)
            end,
            0.0,
            Shimmer
        ),

    %% Detuned saw-like smear
    DetuneSum =
        math:sin(2 * math:pi() * Drone * (1.0 + Detune) * T) +
            math:sin(2 * math:pi() * Drone * (1.0 - Detune) * T),

    %% Noise bed (low-level hiss with slow drift)
    Noise =
        NoiseAmp *
            (2.0 * (rand:uniform() - 0.5)) *
            (0.7 + 0.3 * math:sin(2 * math:pi() * NoiseLfo * T)),

    %% Global wobble
    Wobble = 0.5 * (1.0 + math:sin(2 * math:pi() * LfoHz * T)),

    SampleF =
        Amp * Wobble *
            (0.5 * DroneSum + 0.3 * DetuneSum + 0.2 * ShimmerSum) +
            Noise,

    Clamped = clamp(SampleF, -1.0, 1.0),
    Int16 = trunc(Clamped * 32767),

    build_wobble_loop(
        I + 1,
        Total,
        SR,
        Drone,
        Partials,
        Shimmer,
        Detune,
        NoiseAmp,
        NoiseLfo,
        LfoHz,
        Amp,
        <<Acc/binary, Int16:16/little-signed>>
    ).

%% -------------------------------------------------------------------
%% Track mixing / composition
%%   - mix_wavs/2: mix many track files into one WAV
%%   - add_track/3: convenience "add this track" wrapper
%% -------------------------------------------------------------------

%% Mix a list of mono 16-bit PCM WAVs into a single WAV.
%% All tracks must share SR / channels / bits.
mix_wavs(_OutputPath, []) ->
    {error, no_tracks};
mix_wavs(OutputPath, Paths) when is_list(Paths) ->
    case decode_all_wavs(Paths) of
        {ok, SR, Channels, Bits, Pcms} ->
            MixedPcm = mix_pcm(Pcms),
            case write_wav(OutputPath, SR, Channels, Bits, MixedPcm) of
                ok -> {ok, OutputPath};
                Else -> Else
            end;
        Error ->
            Error
    end.

%% Convenience: add a new track on top of an existing composition.
%% add_track(OutputPath, BaseTrack, NewTrack)
add_track(OutputPath, BasePath, NewTrackPath) ->
    mix_wavs(OutputPath, [BasePath, NewTrackPath]).

%% -------------------------------------------------------------------
%% Internal WAV decode / PCM helpers
%% -------------------------------------------------------------------

decode_all_wavs(Paths) ->
    decode_all_wavs(Paths, undefined).

decode_all_wavs([], undefined) ->
    {error, no_tracks};
decode_all_wavs([], {SR, Ch, Bits, Acc}) ->
    {ok, SR, Ch, Bits, lists:reverse(Acc)};
decode_all_wavs([P | Ps], undefined) ->
    case decode_wav(P) of
        {ok, SR, Ch, Bits, Pcm} ->
            decode_all_wavs(Ps, {SR, Ch, Bits, [Pcm]});
        Error ->
            Error
    end;
decode_all_wavs([P | Ps], {SR0, Ch0, Bits0, Acc}) ->
    case decode_wav(P) of
        {ok, SR, Ch, Bits, Pcm} when
            SR =:= SR0,
            Ch =:= Ch0,
            Bits =:= Bits0
        ->
            decode_all_wavs(Ps, {SR0, Ch0, Bits0, [Pcm | Acc]});
        {ok, SR, Ch, Bits, _} ->
            {error, {incompatible_format, P, {SR, Ch, Bits}, {SR0, Ch0, Bits0}}};
        Error ->
            Error
    end.

%% Decode the simple PCM WAV we write in write_wav/5
decode_wav(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case Bin of
                <<
                    "RIFF",
                    _ChunkSize:32/little-unsigned,
                    "WAVE",
                    "fmt ",
                    _Subchunk1Size:32/little-unsigned,
                    AudioFmt:16/little-unsigned,
                    NumChannels:16/little-unsigned,
                    SampleRate:32/little-unsigned,
                    _ByteRate:32/little-unsigned,
                    _BlockAlign:16/little-unsigned,
                    BitsPerSample:16/little-unsigned,
                    "data",
                    DataSize:32/little-unsigned,
                    PCM:DataSize/binary,
                    _Rest/binary
                >> when AudioFmt =:= 1 ->
                    {ok, SampleRate, NumChannels, BitsPerSample, PCM};
                _ ->
                    {error, invalid_wav}
            end;
        Error ->
            Error
    end.

pcm_to_samples(PCM) ->
    pcm_to_samples(PCM, []).

pcm_to_samples(<<>>, Acc) ->
    lists:reverse(Acc);
pcm_to_samples(<<S:16/little-signed, Rest/binary>>, Acc) ->
    pcm_to_samples(Rest, [S | Acc]).

samples_to_pcm(Samples) ->
    lists:foldl(
        fun(S, Bin) ->
            <<Bin/binary, S:16/little-signed>>
        end,
        <<>>,
        Samples
    ).

pad_samples(L, MaxLen) ->
    Len = length(L),
    case Len >= MaxLen of
        true -> L;
        false -> L ++ lists:duplicate(MaxLen - Len, 0)
    end.

mix_pcm([]) ->
    <<>>;
mix_pcm(Pcms) ->
    SampleLists = [pcm_to_samples(P) || P <- Pcms],
    MaxLen = lists:max([length(L) || L <- SampleLists]),
    Padded = [pad_samples(L, MaxLen) || L <- SampleLists],
    Indices = lists:seq(1, MaxLen),

    %% Sum across tracks per-sample
    Mixed0 =
        [
            lists:sum([lists:nth(I, L) || L <- Padded])
         || I <- Indices
        ],

    %% Peak-normalize to 16-bit range
    MaxAbs = lists:max([abs(S) || S <- Mixed0] ++ [1]),
    Factor = 32767 / MaxAbs,
    Normalized = [trunc(S * Factor) || S <- Mixed0],

    samples_to_pcm(Normalized).

%% -------------------------------------------------------------------
%% WAV writer / utility
%% -------------------------------------------------------------------

clamp(X, Min, _Max) when X < Min -> Min;
clamp(X, _Min, Max) when X > Max -> Max;
clamp(X, _Min, _Max) -> X.

write_wav(Path, SR, Channels, BitsPerSample, PCM) ->
    ByteRate = SR * Channels * BitsPerSample div 8,
    BlockAlign = Channels * BitsPerSample div 8,
    Subchunk2Sz = byte_size(PCM),
    ChunkSize = 36 + Subchunk2Sz,

    Header = <<
        "RIFF",
        ChunkSize:32/little-unsigned,
        "WAVE",
        "fmt ",
        % subchunk1 size
        16:32/little-unsigned,
        % PCM
        1:16/little-unsigned,
        Channels:16/little-unsigned,
        SR:32/little-unsigned,
        ByteRate:32/little-unsigned,
        BlockAlign:16/little-unsigned,
        BitsPerSample:16/little-unsigned,
        "data",
        Subchunk2Sz:32/little-unsigned
    >>,

    file:write_file(Path, [Header, PCM]).

%% -------------------------------------------------------------------
%% Quick test – still uses the Bitcoiner specs & composition
%% -------------------------------------------------------------------
test() ->
    LoopSpec = #{
        bpm => 160,
        seconds => 10.0,
        notes => [220.0, 277.18, 329.63, 392.0],
        lfo_hz => 1.25,
        voices => [1.0, 2.0],
        amp => 0.55
    },
    {ok, AudioPath} = ecai_synth:render_loop("/tmp/ecai_isogeny.wav", LoopSpec),
    ?LOG_DEBUG("Ecai isogeny loop ~p", [AudioPath]).

%BitcoinerIconic = #{
    %    bpm => 126,
    %    seconds => 21.0,
    %    notes => [146.83, 174.61, 220.0, 261.63],
    %    lfo_hz => 0.21,
    %    voices => [1.0, 2.0, 0.5],
    %    amp => 0.6,
    %    sample_rate => 44100
    %},

    %BitcoinerCathedral = #{
    %    bpm => 105,
    %    seconds => 21.0,
    %    drone_note => 146.83,   % D3
    %    drone_partials => [1.0, 1.5, 2.0, 2.5, 3.0],
    %    shimmer_notes => [587.33, 880.0],
    %    detune => 0.07,
    %    noise_amp => 0.03,
    %    noise_lfo_hz => 0.13,
    %    lfo_hz => 0.18,
    %    amp => 0.45,
    %    sample_rate => 44100
    %},

    %%% 1. Main track
    %{ok, BassPath} =
    %    ecai_synth:render_loop("/tmp/ecai_isogeny_bass.wav",
    %                           BitcoinerIconic),

    %%% 2. Wobble pad
    %{ok, PadPath} =
    %    ecai_synth:render_wobble("/tmp/ecai_isogeny_pad.wav",
    %                             BitcoinerCathedral),

    %%% 3. Compose into a single mix
    %{ok, MixPath} =
    %    ecai_synth:mix_wavs("/tmp/ecai_isogeny_mix.wav",
    %                        [BassPath, PadPath]),

    %{ok, MixPath}.
