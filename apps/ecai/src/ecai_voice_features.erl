%%% Versioned non-neural acoustic frontend. Research baseline, not a biometric.
-module(ecai_voice_features).
-license("Apache-2.0").
-export([extract/1, version/0, dimension/0]).

-define(FRAME, 640).
-define(HOP, 160).
-define(VERSION, <<"ecai-voice-mfcc13-iqr-ac-erlang-v1">>).

-spec version() -> binary().
version() -> ?VERSION.
-spec dimension() -> pos_integer().
dimension() -> 30.

-spec extract(binary()) -> {ok, map()} | {error, term()}.
extract(PCM) ->
    case ecai_voice_wav:pcm(PCM) of
        {ok, Meta} ->
            try
                extract_valid(PCM, maps:remove(pcm, Meta))
            catch
                throw:{quality, R} -> {error, {insufficient_audio, R}}
            end;
        Error ->
            Error
    end.

extract_valid(PCM, Meta) ->
    N = byte_size(PCM) div 2,
    quality(N >= 24000, too_short),
    Raw = [S / 32768.0 || <<S:16/little-signed>> <= PCM],
    Clip = length([S || S <- Raw, abs(S) >= 0.999]) / N,
    quality(Clip =< 0.02, excessive_clipping),
    Mean = lists:sum(Raw) / N,
    Xs = [X - Mean || X <- Raw],
    Rms = math:sqrt(lists:sum([X * X || X <- Xs]) / N),
    quality(Rms >= 1.0e-5, silence_or_too_quiet),
    Frames = frames(Xs, N, []),
    Energies = [math:sqrt(lists:sum([X * X || X <- F]) / ?FRAME) || F <- Frames],
    Gate = max(1.0e-5, ecai_voice_dsp:quantile(Energies, 0.95) * 0.1),
    Active = [F || {F, E} <- lists:zip(Frames, Energies), E > Gate],
    ActiveSeconds = length(Active) * ?HOP / 16000,
    quality(ActiveSeconds >= 0.75, insufficient_active_audio),
    Plan = ecai_voice_dsp:plan(),
    Rows = [{ecai_voice_dsp:cepstra([X / Rms || X <- F], Plan), pitch(F, Plan)} || F <- Active],
    Pitch = [P || {_, {P, _}} <- Rows],
    Strengths = [S || {_, {_, S}} <- Rows],
    PeriodicSeconds = length(Pitch) * ?HOP / 16000,
    quality(PeriodicSeconds >= 0.25, insufficient_periodicity),
    Ceps = [list_to_tuple(C) || {C, _} <- Rows],
    Columns = [[element(I, C) || C <- Ceps] || I <- lists:seq(1, 13)],
    Center = [ecai_voice_dsp:quantile(C, 0.5) / 6.0 || C <- Columns],
    Spread = [
        (ecai_voice_dsp:quantile(C, 0.75) - ecai_voice_dsp:quantile(C, 0.25)) / 12.0
     || C <- Columns
    ],
    LogPitch = [math:log(P / 150) / math:log(2.0) || P <- Pitch],
    PF = [ecai_voice_dsp:quantile(LogPitch, Q) / 0.5 || Q <- [0.25, 0.5, 0.75]],
    D = Center ++ Spread ++ PF ++ [length(Pitch) / length(Active)],
    %% Erlang round uses halves away from zero. This frontend has its own ID:
    %% Python/NumPy's banker rounding and resampler are not claimed bit-identical.
    RawQ = [round(32 * V) || V <- D],
    Saturated = length([Q || Q <- RawQ, abs(Q) > 255]),
    quality(Saturated =< 3, out_of_feature_range),
    Qs = [max(-255, min(255, Q)) || Q <- RawQ],
    {ok, #{
        frontend => ?VERSION,
        q => Qs,
        quality => Meta#{
            rms => Rms,
            clipped_fraction => Clip,
            active_seconds_approx => ActiveSeconds,
            periodic_seconds_approx => PeriodicSeconds,
            pitch_median_hz => ecai_voice_dsp:quantile(Pitch, 0.5),
            periodicity_median => ecai_voice_dsp:quantile(Strengths, 0.5),
            saturated_coordinates => Saturated
        }
    }}.

quality(true, _) -> ok;
quality(false, R) -> throw({quality, R}).

frames(_, N, Acc) when N < ?FRAME -> lists:reverse(Acc);
frames(Xs, N, Acc) -> frames(lists:nthtail(?HOP, Xs), N - ?HOP, [lists:sublist(Xs, ?FRAME) | Acc]).

pitch(Frame, #{window := Window} = Plan) ->
    Mean = lists:sum(Frame) / ?FRAME,
    Z = [(X - Mean) * W || {X, W} <- lists:zip(Frame, Window)],
    AC0 = ecai_voice_dsp:autocorrelation(Z, Plan),
    Denom = max(1.0e-20, hd(AC0)),
    AC = list_to_tuple([A / Denom || A <- AC0]),
    %% Lags 40..265, corresponding approximately to 60..400 Hz.
    Peaks = [
        {K, element(K + 1, AC)}
     || K <- lists:seq(40, 265),
        element(K + 1, AC) > element(K, AC),
        element(K + 1, AC) >= element(K + 2, AC)
    ],
    pitch_peak(Peaks, AC).

pitch_peak([], _) ->
    unvoiced;
pitch_peak(Peaks, AC) ->
    Peak = lists:max([V || {_, V} <- Peaks]),
    case Peak >= 0.35 of
        false ->
            unvoiced;
        true ->
            [{Lag, _} | _] = [{K, V} || {K, V} <- Peaks, V >= 0.90 * Peak],
            Left = element(Lag, AC),
            Mid = element(Lag + 1, AC),
            Right = element(Lag + 2, AC),
            Den = Left - 2 * Mid + Right,
            Offset =
                case abs(Den) < 1.0e-12 of
                    true -> 0.0;
                    false -> max(-0.5, min(0.5, 0.5 * (Left - Right) / Den))
                end,
            {16000 / (Lag + Offset), Peak}
    end.
