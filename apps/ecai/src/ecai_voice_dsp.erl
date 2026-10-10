%%% Small reference DSP implementation. Internal numeric API; no learned weights.
-module(ecai_voice_dsp).
-license("Apache-2.0").
-export([plan/0, fft/2, power/3, autocorrelation/2, cepstra/2, quantile/2]).

-spec plan() -> map().
plan() ->
    Twiddles = maps:from_list([
        {N, [{math:cos(-2 * math:pi() * K / N), math:sin(-2 * math:pi() * K / N)}
             || K <- lists:seq(0, N div 2 - 1)]}
        || I <- lists:seq(1, 11), N <- [1 bsl I]
    ]),
    Edges = [700.0 * (math:pow(10.0, (mel(80) + I * (mel(7600) - mel(80)) / 33) / 2595) - 1)
             || I <- lists:seq(0, 33)],
    Bank = mel_filters(Edges),
    Dct = [[math:sqrt(2.0 / 32) * math:cos(math:pi() * K * (I + 0.5) / 32)
            || I <- lists:seq(0, 31)] || K <- lists:seq(1, 13)],
    #{twiddles => Twiddles, mel_bank => Bank, dct => Dct,
      window => [0.5 - 0.5 * math:cos(2 * math:pi() * I / 639) || I <- lists:seq(0, 639)]}.

mel(F) -> 2595 * math:log10(1 + F / 700).
mel_filters([L, C, R | Rest]) ->
    Weights0 = [{K + 1, max(0.0, min((K * 16000 / 1024 - L) / (C - L),
                                   (R - K * 16000 / 1024) / (R - C)))}
                || K <- lists:seq(0, 512)],
    Sum = max(1.0e-12, lists:sum([W || {_, W} <- Weights0])),
    [[{K, W / Sum} || {K, W} <- Weights0, W > 0] | mel_filters([C, R | Rest])];
mel_filters(_) -> [].

%% Complex radix-2 FFT; the caller supplies a supported power-of-two length.
-spec fft([{number(), number()}], map()) -> [{number(), number()}].
fft(Xs, #{twiddles := T}) when is_list(Xs) ->
    N = length(Xs),
    case N >= 1 andalso N =< 2048 andalso (N band (N - 1)) =:= 0 of
        true -> fft_loop(Xs, N, T);
        false -> erlang:error(badarg)
    end;
fft(_, _) -> erlang:error(badarg).
fft_loop([X], 1, _) -> [X];
fft_loop(Xs, N, T) ->
    {Even, Odd} = split(Xs, [], []),
    E = fft_loop(Even, N div 2, T),
    O = fft_loop(Odd, N div 2, T),
    {Lo, Hi} = butterfly(E, O, maps:get(N, T), [], []),
    Lo ++ Hi.

split([], E, O) -> {lists:reverse(E), lists:reverse(O)};
split([A, B | Rest], E, O) -> split(Rest, [A | E], [B | O]).
butterfly([], [], [], L, H) -> {lists:reverse(L), lists:reverse(H)};
butterfly([{ER, EI} | Es], [{OR, OI} | Os], [{WR, WI} | Ws], L, H) ->
    TR = WR * OR - WI * OI,
    TI = WR * OI + WI * OR,
    butterfly(Es, Os, Ws, [{ER + TR, EI + TI} | L], [{ER - TR, EI - TI} | H]).

-spec power([number()], pos_integer(), map()) -> [float()].
power(Xs, N, Plan) ->
    Padded = [{X, 0.0} || X <- Xs] ++ lists:duplicate(N - length(Xs), {0.0, 0.0}),
    [R * R + I * I || {R, I} <- fft(Padded, Plan)].

%% 2048-point zero padding yields linear autocorrelation for a 640-sample frame.
-spec autocorrelation([number()], map()) -> [float()].
autocorrelation(Xs, Plan) ->
    Power = power(Xs, 2048, Plan),
    %% Real power: forward FFT has the same real part as inverse FFT, before /N.
    lists:sublist([R / 2048 || {R, _} <- fft([{P, 0.0} || P <- Power], Plan)], length(Xs)).

-spec cepstra([float()], map()) -> [float()].
cepstra(Frame, #{window := Window, mel_bank := Bank, dct := Dct} = Plan) ->
    Emph = preemphasis(Frame),
    Windowed = [X * W || {X, W} <- lists:zip(Emph, Window)],
    Power = list_to_tuple(power(Windowed, 1024, Plan)),
    Logs = [math:log(max(1.0e-10, lists:sum([element(K, Power) * W || {K, W} <- Band])))
            || Band <- Bank],
    [lists:sum([X * W || {X, W} <- lists:zip(Logs, Row)]) || Row <- Dct].

preemphasis([X | Rest]) -> [0.03 * X | preemphasis(Rest, X)].
preemphasis([], _) -> [];
preemphasis([X | Rest], Prev) -> [X - 0.97 * Prev | preemphasis(Rest, X)].

%% Linear interpolation, equivalent to the usual inclusive sample quantile.
-spec quantile([number(), ...], number()) -> float().
quantile(Xs, Q) when Q >= 0, Q =< 1 ->
    Sorted = list_to_tuple(lists:sort(Xs)),
    Pos = (tuple_size(Sorted) - 1) * float(Q),
    Low = trunc(Pos),
    High = min(Low + 1, tuple_size(Sorted) - 1),
    A = element(Low + 1, Sorted),
    B = element(High + 1, Sorted),
    A + (Pos - Low) * (B - A).
