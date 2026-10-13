%%% Procedural source/filter fixtures. Synthetic plumbing tests, NOT human voices.
-module(ecai_voice_demo).
-license("Apache-2.0").
-export([run/0, run/1, generate/1, synthetic/3]).

-spec run() -> {ok, map()} | {error, term()}.
run() -> run("_build/ecai_voice_demo").
-spec run(file:filename_all()) -> {ok, map()} | {error, term()}.
run(Directory) ->
    case generate(Directory) of
        {ok, Rows} -> run_generated(Directory, Rows);
        Error -> Error
    end.

run_generated(Dir, Rows) ->
    case ecai_voice:build(Rows) of
        {ok, Profile} ->
            ProfilePath = filename:join(Dir, "voices.ecv"),
            case ecai_voice:save(ProfilePath, Profile) of
                ok ->
                    case ecai_voice:load(ProfilePath) of
                        {ok, Loaded} -> evaluate_generated(Dir, Rows, Loaded, ProfilePath);
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

evaluate_generated(Dir, Rows, P, ProfilePath) ->
    case {ecai_voice:evaluate(P, Rows, curve), ecai_voice:evaluate(P, Rows, integer)} of
        {{ok, Curve}, {ok, Integer}} ->
            CurveDecisions = decisions(Curve),
            IntegerDecisions = decisions(Integer),
            case CurveDecisions =:= IntegerDecisions of
                false ->
                    {error, backend_decision_mismatch};
                true ->
                    TimelinePath = filename:join(Dir, "timeline.wav"),
                    case ecai_voice:scan(P, {wav, TimelinePath}, 2000) of
                        {ok, Timeline} ->
                            Result = #{
                                kind => synthetic_only_not_human_validation,
                                profile => ProfilePath,
                                calibration => maps:get(calibration, P),
                                curve_integer_decisions_identical => true,
                                curve => Curve,
                                integer => Integer,
                                timeline => Timeline,
                                otp_release => erlang:system_info(otp_release)
                            },
                            case
                                file:write_file(
                                    filename:join(Dir, "results.term"),
                                    io_lib:format("~tp.~n", [Result])
                                )
                            of
                                ok -> {ok, Result};
                                Error -> Error
                            end;
                        Error ->
                            Error
                    end
            end;
        {{error, R}, _} ->
            {error, R};
        {_, {error, R}} ->
            {error, R}
    end.

decisions(#{results := Results}) ->
    [
        maps:with([status, speaker, best_distance, margin, ranking, expected, correct], R)
     || R <- Results
    ].

%% No downloads, model weights, random seeds or new application dependencies.
-spec generate(file:filename_all()) -> {ok, [map()]} | {error, term()}.
generate(Dir) ->
    try
        ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
        Specs = [
            {voice_a, enroll, 1},
            {voice_b, enroll, 1},
            {voice_a, calibrate, 2},
            {voice_b, calibrate, 2},
            {unknown, calibrate, 2},
            {voice_a, test, 3},
            {voice_b, test, 3},
            {unknown, test, 3}
        ],
        Rows = [
            begin
                Name = lists:flatten(io_lib:format("~s_~s_~B.wav", [Kind, Split, Take])),
                Path = filename:absname(filename:join(Dir, Name)),
                ok = ecai_voice_wav:write(Path, synthetic(Kind, Take, 2)),
                Label =
                    case Kind of
                        unknown -> unknown;
                        _ -> atom_to_binary(Kind, utf8)
                    end,
                #{speaker => Label, split => Split, source => {wav, Path}}
            end
         || {Kind, Split, Take} <- Specs
        ],
        Timeline = iolist_to_binary([
            synthetic(voice_a, 4, 2),
            synthetic(voice_b, 4, 2),
            synthetic(voice_a, 5, 2),
            synthetic(unknown, 4, 2),
            <<0:(16000 * 2 * 2 * 8)>>
        ]),
        ok = ecai_voice_wav:write(filename:join(Dir, "timeline.wav"), Timeline),
        ok = file:write_file(filename:join(Dir, "dataset.term"), io_lib:format("~tp.~n", [Rows])),
        {ok, Rows}
    catch
        Class:Reason -> {error, {demo_generation_failed, Class, Reason}}
    end.

-spec synthetic(voice_a | voice_b | unknown | same_pitch_b, pos_integer(), 1..30) -> binary().
synthetic(Kind, Take, Seconds) when
    is_integer(Take),
    Take > 0,
    is_integer(Seconds),
    Seconds >= 1,
    Seconds =< 30
->
    {F0, Shift, Tilt} =
        case Kind of
            voice_a -> {125.0, 0.85, 1.2};
            voice_b -> {210.0, 1.15, 1.0};
            unknown -> {310.0, 1.38, 1.6};
            same_pitch_b -> {125.0, 1.35, 0.6}
        end,
    Vowels = [{500, 1500, 2500}, {300, 2200, 3000}, {700, 1200, 2600}, {350, 900, 2300}],
    WeightTable = list_to_tuple([harmonics(F0, Shift, Tilt, V) || V <- Vowels]),
    Raw = [sample(I / 16000, Take, F0, WeightTable) || I <- lists:seq(0, Seconds * 16000 - 1)],
    Peak = lists:max([abs(X) || X <- Raw]),
    Gain =
        case Take rem 3 of
            0 -> 0.22;
            _ -> 0.55
        end,
    <<<<(round(32767 * Gain * X / Peak)):16/little-signed>> || X <- Raw>>.

harmonics(F0, Shift, Tilt, {F1, F2, F3}) ->
    [
        {H,
            (0.03 + resonance(H * F0, F1 * Shift, 100) +
                0.75 * resonance(H * F0, F2 * Shift, 150) +
                0.55 * resonance(H * F0, F3 * Shift, 200)) / math:pow(H, Tilt)}
     || H <- lists:seq(1, trunc(7000 / F0))
    ].
resonance(F, Center, Width) -> 1.0 / (1.0 + math:pow((F - Center) / Width, 2)).

sample(T, Take, F0, Weights) ->
    Vowel = (trunc(T * 2) + Take - 1) rem 4 + 1,
    Phase =
        2 * math:pi() * F0 * T + 0.18 * math:sin(2 * math:pi() * (1.1 + Take * 0.02) * T) +
            Take * 0.37,
    Envelope = 0.70 + 0.30 * math:sin(2 * math:pi() * 2 * T + 0.1 * Take),
    Signal = lists:sum([W * math:sin(H * Phase + 0.07 * H * H) || {H, W} <- element(Vowel, Weights)]),
    Envelope * Signal + 0.0002 * math:sin(2 * math:pi() * 7191 * T + Take).
