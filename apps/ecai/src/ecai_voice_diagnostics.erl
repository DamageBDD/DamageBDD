%%% Read-only calibration diagnostics for the ECAI voice POC.
%%% No threshold changes, enrollment updates or test-audio access.
%%% This reports exact bounded curve/integer distances and ranking mistakes.
-module(ecai_voice_diagnostics).
-license("Apache-2.0").
-export([session/1, analyze/1, print/1]).

-spec session(file:filename_all()) -> {ok, map()} | {error, term()}.
session(Dir) ->
    case ecai_voice_loop:rows(Dir) of
        {ok, Rows} -> analyze(Rows);
        {error, _} = Error -> Error
    end.

-spec analyze([map()]) -> {ok, map()} | {error, term()}.
analyze(Rows) ->
    try
        diagnose_rows(Rows)
    catch
        throw:{voice_diagnostic_error, DiagnosticError} ->
            {error, DiagnosticError};
        DiagnosticClass:DiagnosticReason ->
            {error, {diagnostic_failed, DiagnosticClass, DiagnosticReason}}
    end.

diagnose_rows(Rows) when is_list(Rows) ->
    %% Deliberately do not load rows marked test. A build failure must not
    %% become an excuse to tune the thresholds against held-out test samples.
    Dev = [R || R <- Rows, maps:get(split, R, test) =/= test],
    ensure(Dev =/= [] andalso length(Dev) =< 200, invalid_development_rows),
    Loaded = [load_row(R) || R <- Dev],
    Enroll = [R || R <- Loaded, maps:get(split, R) =:= enroll],
    Calibrate = [R || R <- Loaded, maps:get(split, R) =:= calibrate],
    Templates = lists:foldl(
        fun(#{speaker := Speaker, feature := Feature}, Acc) ->
            ensure(Speaker =/= unknown, unknown_cannot_be_enrolled),
            Acc#{Speaker => [Feature | maps:get(Speaker, Acc, [])]}
        end,
        #{},
        Enroll
    ),
    Labels = lists:sort(maps:keys(Templates)),
    ensure(length(Labels) >= 2, need_two_distinct_enrolled_labels),
    Known = lists:sort([
        S
     || S <- lists:usort([maps:get(speaker, R) || R <- Calibrate]),
        S =/= unknown
    ]),
    ensure(Known =:= Labels, missing_known_calibration),
    Context = ecai_voice_curve:new(),
    Reports = [diagnose_calibration(R, Templates, Context) || R <- Calibrate],
    KnownReports = [R || R <- Reports, maps:get(expected, R) =/= unknown],
    UnknownReports = [R || R <- Reports, maps:get(expected, R) =:= unknown],
    WorstGenuine = lists:max([maps:get(own_distance, R) || R <- KnownReports]),
    NearestImpostor = lists:min(
        [maps:get(nearest_other_distance, R) || R <- KnownReports] ++
            [maps:get(best_distance, R) || R <- UnknownReports]
    ),
    MinMargin = lists:min([maps:get(genuine_margin, R) || R <- KnownReports]),
    Separable = WorstGenuine < NearestImpostor andalso MinMargin > 0,
    Summary = #{
        worst_genuine => WorstGenuine,
        nearest_impostor => NearestImpostor,
        minimum_genuine_margin => MinMargin,
        known_count => length(KnownReports),
        unknown_count => length(UnknownReports)
    },
    Mistakes = [
        maps:get(path, R)
     || R <- KnownReports,
        maps:get(closest_speaker, R) =/= maps:get(expected, R)
    ],
    {ok, #{
        status =>
            case Separable of
                true -> separable;
                false -> not_separable
            end,
        summary => Summary,
        recordings => Reports,
        known_misranked_files => Mistakes,
        caution => diagnostic_on_development_only_not_a_biometric_benchmark
    }};
diagnose_rows(_) ->
    fail(invalid_development_rows).

load_row(R) when is_map(R) ->
    Split = maps:get(split, R, invalid),
    ensure(Split =:= enroll orelse Split =:= calibrate, invalid_development_split),
    Speaker = maps:get(speaker, R, invalid),
    ensure(
        Speaker =:= unknown orelse
            (is_binary(Speaker) andalso byte_size(Speaker) >= 1),
        invalid_speaker
    ),
    case maps:get(source, R, invalid) of
        {wav, Path} when is_list(Path); is_binary(Path) ->
            Feature = value(ecai_voice:extract_wav(Path)),
            R#{feature => Feature};
        _ ->
            fail(diagnostics_require_wav_paths)
    end;
load_row(_) ->
    fail(invalid_development_row).

diagnose_calibration(R, Templates, Context) ->
    Expected = maps:get(speaker, R),
    Feature = maps:get(feature, R),
    Distances = [
        begin
            D = lists:min([distance(Feature, F, Context) || F <- Fs]),
            {D, Speaker}
        end
     || {Speaker, Fs} <- maps:to_list(Templates)
    ],
    [{BestDistance, BestSpeaker} | _] = lists:sort(Distances),
    {wav, Path} = maps:get(source, R),
    Quality = maps:with(
        [
            rms,
            active_seconds_approx,
            periodic_seconds_approx,
            pitch_median_hz,
            saturated_coordinates
        ],
        maps:get(quality, Feature)
    ),
    Base = #{
        path => Path,
        expected => Expected,
        closest_speaker => BestSpeaker,
        best_distance => BestDistance,
        quality => Quality
    },
    case Expected of
        unknown ->
            Base#{
                classification => unknown_reference,
                own_distance => undefined,
                nearest_other_distance => BestDistance,
                genuine_margin => undefined
            };
        _ ->
            [{Own, _}] = [{D, L} || {D, L} <- Distances, L =:= Expected],
            Other = lists:min([D || {D, L} <- Distances, L =/= Expected]),
            Base#{
                classification =>
                    case BestSpeaker =:= Expected of
                        true -> correct_nearest;
                        false -> wrong_nearest
                    end,
                own_distance => Own,
                nearest_other_distance => Other,
                genuine_margin => Other - Own
            }
    end.

distance(A, B, Context) ->
    Integer = value(ecai_voice_curve:integer_distance(maps:get(q, A), maps:get(q, B))),
    Curve = value(
        ecai_voice_curve:distance(
            maps:get(points, A),
            maps:get(points, B),
            Context
        )
    ),
    ensure(Curve =:= Integer, elliptic_integer_invariant_failed),
    Curve.

-spec print(map()) -> ok.
print(#{
    status := Status,
    summary := Summary,
    recordings := Recordings,
    known_misranked_files := Wrong
}) ->
    io:format("~nECAI calibration diagnostic (development recordings only)~n", []),
    io:format(
        "  status=~p worst_own=~p nearest_impostor=~p min_margin=~p~n",
        [
            Status,
            maps:get(worst_genuine, Summary),
            maps:get(nearest_impostor, Summary),
            maps:get(minimum_genuine_margin, Summary)
        ]
    ),
    lists:foreach(
        fun(R) ->
            io:format(
                "  expected=~ts nearest=~ts own=~tp other=~tp margin=~tp~n    file=~ts~n",
                [
                    label(maps:get(expected, R)),
                    label(maps:get(closest_speaker, R)),
                    maps:get(own_distance, R),
                    maps:get(nearest_other_distance, R),
                    maps:get(genuine_margin, R),
                    maps:get(path, R)
                ]
            ),
            Quality = maps:get(quality, R),
            io:format(
                "    pitch_hz=~tp rms=~tp active_s=~tp saturated_coords=~tp~n",
                [
                    maps:get(pitch_median_hz, Quality, undefined),
                    maps:get(rms, Quality, undefined),
                    maps:get(active_seconds_approx, Quality, undefined),
                    maps:get(saturated_coordinates, Quality, undefined)
                ]
            )
        end,
        Recordings
    ),
    case Wrong of
        [] ->
            ok;
        _ ->
            io:format(
                "~nAt least one known recording is closest to the WRONG label.~n" ++
                    "Check that each label belongs to a DIFFERENT PERSON, not an alias,~n" ++
                    "and that the correct speaker actually made each recording.~n"
            )
    end,
    case Status of
        not_separable ->
            io:format(
                "The calibration distances overlap. Repeating identical speaker~n" ++
                    "aliases or widening the threshold will not fix this evidence.~n"
            );
        separable ->
            ok
    end,
    ok.

label(unknown) -> "unknown";
label(B) when is_binary(B) -> binary_to_list(B).

value({ok, V}) -> V;
value({error, Reason}) -> fail(Reason).
ensure(true, _) -> ok;
ensure(false, Reason) -> fail(Reason).
fail(Reason) -> throw({voice_diagnostic_error, Reason}).
