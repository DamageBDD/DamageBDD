%%% Interactive first-run operator wizard for the local ECAI voice experiment.
%%% Runs in the *calling* Erlang shell: io:get_line/1 must not compete with a
%%% background shell reader. Does not start services, mutate application env,
%%% use a neural model, or incorporate test samples into speaker templates.
%%% Audio commands execute locally to the Erlang node, never on a remote shell.
-module(ecai_voice_session).
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-export([run/0, run/1, options/1, inspect/1, synthesize_take/3]).

%% The default is persistent per-node operator state, not a volatile /tmp dir.
run() -> run(#{}).

run(Input) ->
    case options(Input) of
        {error, _} = Error ->
            Error;
        {ok, Opts} ->
            try
                {ok, _} = application:ensure_all_started(crypto),
                require_audio_tools(),
                consent(),
                Dir = maps:get(session, Opts),
                ensure_private_dir(Dir),
                with_lock(Dir, fun() ->
                    Labels = ensure_labels(Dir, maps:get(speakers, Opts)),
                    ensure_sources(Dir, Labels, Opts),
                    Profile = ensure_profile(Dir, Labels, Opts, 0),
                    io:format("~nReady. Profile: ~ts~n", [filename:join(Dir, "voices.ecv")]),
                    io:format("The test loop does NOT update enrollment or calibration.~n"),
                    test_loop(Dir, Labels, Profile, Opts, next_test_id(Dir), 0)
                end)
            catch
                throw:{voice_session_stop, Reason} ->
                    {ok, #{
                        status => stopped,
                        reason => Reason,
                        session => maps:get(session, Opts)
                    }};
                throw:{voice_session_error, Reason} ->
                    {error, Reason};
                Class:Reason:Stack ->
                    {error, {voice_session_failed, Class, Reason, lists:sublist(Stack, 3)}}
            end
    end.

%% Call without any recording or terminal interaction to check a saved session.
inspect(Dir0) ->
    try
        Dir = string_arg(Dir0),
        Path = filename:join(Dir, "speakers.txt"),
        Labels =
            case file:read_file(Path) of
                {ok, B} -> parse_saved_labels(B);
                {error, enoent} -> [];
                {error, Reason} -> fail({speakers_file, Reason})
            end,
        Counts = [
            {L, #{
                enroll => length(accepted_files(Dir, enroll, L)),
                calibrate => length(accepted_files(Dir, calibrate, L))
            }}
         || L <- Labels
        ],
        Profile =
            case file:read_file_info(filename:join(Dir, "voices.ecv")) of
                {ok, #file_info{type = regular}} ->
                    case ecai_voice:load(filename:join(Dir, "voices.ecv")) of
                        {ok, P} ->
                            ProfileLabels = lists:sort(maps:keys(maps:get(templates, P))),
                            case lists:sort(Labels) =:= ProfileLabels of
                                true ->
                                    #{
                                        status => ready,
                                        labels => ProfileLabels,
                                        thresholds => maps:get(thresholds, P)
                                    };
                                false ->
                                    #{
                                        status => invalid,
                                        reason => session_profile_labels_differ
                                    }
                            end;
                        {error, R} ->
                            #{status => invalid, reason => R}
                    end;
                {error, enoent} ->
                    #{status => absent};
                _ ->
                    #{status => invalid, reason => profile_not_regular_file}
            end,
        {ok, #{
            session => filename:absname(Dir),
            speakers => Labels,
            development => Counts,
            profile => Profile
        }}
    catch
        throw:{voice_session_error, InspectError} -> {error, InspectError};
        InspectClass:InspectReason -> {error, {inspect_failed, InspectClass, InspectReason}}
    end.

options(O) when is_map(O) ->
    Allowed = [
        session,
        speakers,
        device,
        playback,
        seconds,
        settle_ms,
        enroll_takes,
        calibrate_takes,
        backend,
        unknown_calibration,
        speak_results,
        tts_speaker,
        tts_voice,
        tts_speed
    ],
    case maps:keys(O) -- Allowed of
        [] -> validate_options(O);
        Bad -> {error, {unknown_options, Bad}}
    end;
options(_) ->
    {error, options_must_be_map}.

validate_options(O) ->
    try
        Seconds = range(maps:get(seconds, O, 6), 2, 30, seconds),
        Settle = range(maps:get(settle_ms, O, 750), 0, 5000, settle_ms),
        Enroll = range(maps:get(enroll_takes, O, 1), 1, 10, enroll_takes),
        Calibrate = range(maps:get(calibrate_takes, O, 1), 1, 10, calibrate_takes),
        Session = filename:absname(string_arg(maps:get(session, O, default_session()))),
        Device = string_arg(maps:get(device, O, "default")),
        Playback = string_arg(maps:get(playback, O, "default")),
        Backend = maps:get(backend, O, curve),
        Unknown = maps:get(unknown_calibration, O, ask),
        Speak = maps:get(speak_results, O, true),
        TtsSpeaker =
            case maps:get(tts_speaker, O, undefined) of
                undefined -> undefined;
                Label -> unicode:characters_to_binary(string_arg(Label))
            end,
        TtsVoice = string_arg(maps:get(tts_voice, O, "en+f3")),
        TtsSpeed = range(maps:get(tts_speed, O, 155), 100, 220, tts_speed),
        ensure(
            TtsSpeaker =:= undefined orelse ecai_voice_loop:label_valid(TtsSpeaker),
            invalid_tts_speaker
        ),
        ensure(
            length(TtsVoice) =< 64 andalso
                re:run(TtsVoice, "\\A[A-Za-z0-9_+.-]+\\z", [{capture, none}]) =:= match,
            invalid_tts_voice
        ),
        ensure(lists:member(Backend, [curve, integer]), invalid_backend),
        ensure(lists:member(Unknown, [ask, yes, no]), invalid_unknown_calibration),
        ensure(is_boolean(Speak), invalid_speak_results),
        Labels =
            case maps:get(speakers, O, undefined) of
                undefined -> undefined;
                Ls when is_list(Ls), Ls =/= [] -> normalize_labels(Ls);
                _ -> fail(invalid_speakers)
            end,
        {ok, #{
            session => Session,
            speakers => Labels,
            device => Device,
            playback => Playback,
            seconds => Seconds,
            settle_ms => Settle,
            enroll_takes => Enroll,
            calibrate_takes => Calibrate,
            backend => Backend,
            unknown_calibration => Unknown,
            speak_results => Speak,
            tts_speaker => TtsSpeaker,
            tts_voice => TtsVoice,
            tts_speed => TtsSpeed
        }}
    catch
        throw:{voice_session_error, Reason} -> {error, Reason};
        _:_ -> {error, invalid_voice_session_options}
    end.

default_session() ->
    case os:getenv("XDG_STATE_HOME") of
        false ->
            case os:getenv("HOME") of
                false -> filename:absname("_build/ecai_voice_operator");
                Home -> filename:join([Home, ".local", "state", "ecai", "voice"])
            end;
        Root ->
            filename:join([Root, "ecai", "voice"])
    end.

range(N, Lo, Hi, _) when is_integer(N), N >= Lo, N =< Hi -> N;
range(_, _, _, Key) -> fail({invalid_option, Key}).

string_arg(B) when is_binary(B) -> string_arg(unicode:characters_to_list(B));
string_arg(S) when is_list(S), S =/= [], length(S) =< 4096 ->
    ensure(
        lists:all(fun(C) -> is_integer(C) andalso C >= 32 andalso C =/= 127 end, S),
        invalid_text_argument
    ),
    S;
string_arg(_) ->
    fail(invalid_text_argument).

normalize_labels(Ls) ->
    Labels = [unicode:characters_to_binary(string_arg(L)) || L <- Ls],
    ensure(
        length(Labels) >= 2 andalso length(Labels) =< 10 andalso
            length(lists:usort(Labels)) =:= length(Labels) andalso
            lists:all(fun ecai_voice_loop:label_valid/1, Labels),
        invalid_speaker_labels
    ),
    Labels.

parse_saved_labels(B) when is_binary(B), byte_size(B) =< 4096 ->
    Labels = [L || L <- binary:split(B, <<"\n">>, [global]), L =/= <<>>],
    normalize_labels(Labels);
parse_saved_labels(_) ->
    fail(invalid_speakers_file).

require_audio_tools() ->
    lists:foreach(
        fun(Name) ->
            ensure(os:find_executable(Name) =/= false, {missing_audio_executable, Name})
        end,
        ["espeak-ng", "aplay", "arecord"]
    ).

consent() ->
    io:format(
        "~nECAI voice experiment. Recorded voice samples and descriptors are saved locally.~n"
    ),
    io:format("Do not use this prototype for authentication or voiceprint surveillance.~n"),
    case string:lowercase(ask("Do all recorded speakers consent? Type YES to continue: ")) of
        "yes" -> ok;
        _ -> stop(consent_not_given)
    end.

ensure_private_dir(Dir) ->
    ok_value(filelib:ensure_dir(filename:join(Dir, ".ensure"))),
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory}} -> ok;
        {error, enoent} -> ok_value(file:make_dir(Dir));
        _ -> fail({unsafe_session_path, Dir})
    end,
    ok_value(file:change_mode(Dir, 8#700)),
    lists:foreach(
        fun(Sub) ->
            P = filename:join(Dir, Sub),
            case file:read_link_info(P) of
                {error, enoent} -> ok_value(file:make_dir(P));
                {ok, #file_info{type = directory}} -> ok;
                _ -> fail({unsafe_session_subdirectory, P})
            end,
            ok_value(file:change_mode(P, 8#700))
        end,
        ["develop", "takes", "tests", "archive"]
    ).

with_lock(Dir, Fun) ->
    Lock = filename:join(Dir, ".voice-operator.lock"),
    case file:make_dir(Lock) of
        ok ->
            try
                ok_value(file:change_mode(Lock, 8#700)),
                Fun()
            after
                _ = file:del_dir(Lock)
            end;
        {error, eexist} ->
            fail({session_locked, Lock});
        {error, R} ->
            fail({session_lock_failed, R})
    end.

ensure_labels(Dir, Requested) ->
    Path = filename:join(Dir, "speakers.txt"),
    case file:read_file(Path) of
        {ok, B} ->
            Saved = parse_saved_labels(B),
            ensure(
                Requested =:= undefined orelse Requested =:= Saved,
                session_speakers_mismatch
            ),
            io:format("Resuming enrolled speaker names: ~tp~n", [Saved]),
            Saved;
        {error, enoent} ->
            ensure(
                not filelib:is_file(filename:join(Dir, "voices.ecv")),
                profile_exists_without_speaker_manifest
            ),
            Labels =
                case Requested of
                    undefined -> prompt_labels();
                    _ -> Requested
                end,
            ok = write_private_exclusive(Path, [[L, <<"\n">>] || L <- Labels]),
            Labels;
        {error, R} ->
            fail({speakers_file, R})
    end.

prompt_labels() ->
    io:format(
        "Use different people for microphone labels. " ++
            "A synthetic TTS label is allowed only when configured as TTS.~n"
    ),
    case ask("Two or more voice labels, comma-separated [speaker_a,speaker_b]: ") of
        "" ->
            normalize_labels(["speaker_a", "speaker_b"]);
        "q" ->
            stop(operator_quit);
        Raw ->
            Tokens = [string:trim(T) || T <- string:split(Raw, ",", all)],
            normalize_labels(Tokens)
    end.

%% Synthetic audio has to be recorded as such from the first development take.
%% Prevent swapping synthetic and human origins when resuming an old session.
ensure_sources(Dir, Labels, O) ->
    Label = maps:get(tts_speaker, O),
    ensure(
        Label =:= undefined orelse lists:member(Label, Labels),
        tts_speaker_not_enrolled
    ),
    Path = filename:join(Dir, "source-mode.bin"),
    Wanted =
        case Label of
            undefined ->
                undefined;
            _ ->
                term_to_binary(
                    {ecai_voice_tts_source_v1, Label, maps:get(tts_voice, O),
                        maps:get(tts_speed, O)}
                )
        end,
    case file:read_file(Path) of
        {ok, Wanted} ->
            ok;
        {ok, _} ->
            fail(session_source_mode_mismatch);
        {error, enoent} when Wanted =:= undefined -> ok;
        {error, enoent} ->
            ensure(
                not filelib:is_file(filename:join(Dir, "voices.ecv")) andalso
                    lists:all(
                        fun(L) ->
                            accepted_files(Dir, enroll, L) =:= [] andalso
                                accepted_files(Dir, calibrate, L) =:= []
                        end,
                        Labels
                    ),
                cannot_change_sources_of_existing_session
            ),
            write_private_exclusive(Path, Wanted);
        {error, Reason} ->
            fail({source_mode_file, Reason})
    end.

source_for(Label, O) ->
    case maps:get(tts_speaker, O) of
        Label -> synthetic;
        _ -> human
    end.

ensure_profile(Dir, Labels, O, Retry) ->
    Path = filename:join(Dir, "voices.ecv"),
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} ->
            P = value(ecai_voice:load(Path)),
            ensure(
                lists:sort(maps:keys(maps:get(templates, P))) =:= lists:sort(Labels),
                session_profile_labels_differ
            ),
            io:format("Loaded existing calibrated speaker profile; skipping enrollment.~n"),
            P;
        {error, enoent} ->
            collect_development(Dir, Labels, O),
            io:format("Calibrating ECAI speaker matching (no LLM)...~n"),
            case ecai_voice_loop:build(Dir) of
                {ok, Summary} ->
                    io:format("Calibration succeeded: ~tp~n", [Summary]),
                    value(ecai_voice:load(Path));
                {error, Reason} ->
                    io:format("~nCalibration failed: ~tp~n", [Reason]),
                    io:format("No profile created and no thresholds relaxed.~n"),
                    print_development_diagnostics(Dir),
                    case Retry < 2 of
                        true ->
                            case
                                string:lowercase(
                                    ask(
                                        "Re-record ALL enrollment and calibration takes? [r/q]: "
                                    )
                                )
                            of
                                "r" ->
                                    archive_development(Dir),
                                    ensure_profile(Dir, Labels, O, Retry + 1);
                                _ ->
                                    fail({calibration_failed, Reason})
                            end;
                        false ->
                            fail({calibration_failed, Reason})
                    end
            end;
        _ ->
            fail(profile_not_regular_file)
    end.

%% Read-only. If diagnostics themselves fail, preserve the real
%% calibration error and allow the operator to quit or retry as before.
print_development_diagnostics(Dir) ->
    io:format("Examining saved calibration recordings for misranked labels...~n"),
    try ecai_voice_diagnostics:session(Dir) of
        {ok, Report} ->
            ecai_voice_diagnostics:print(Report);
        {error, DiagnosticError} ->
            io:format("Calibration diagnostic unavailable: ~tp~n", [DiagnosticError])
    catch
        DiagnosticClass:DiagnosticReason ->
            io:format(
                "Calibration diagnostic unavailable: ~tp~n",
                [{DiagnosticClass, DiagnosticReason}]
            )
    end.

archive_development(Dir) ->
    Source = filename:join(Dir, "develop"),
    Dest = filename:join([Dir, "archive", unique_id()]),
    ok_value(file:rename(Source, Dest)),
    ok_value(file:make_dir(Source)),
    ok_value(file:change_mode(Source, 8#700)),
    io:format("Archived previous development takes in ~ts~n", [Dest]).

collect_development(Dir, Labels, O) ->
    lists:foreach(
        fun(Split) ->
            Required = maps:get(
                case Split of
                    enroll -> enroll_takes;
                    calibrate -> calibrate_takes
                end,
                O
            ),
            lists:foreach(fun(Label) -> collect_takes(Dir, Split, Label, Required, O) end, Labels)
        end,
        [enroll, calibrate]
    ),
    case accepted_files(Dir, calibrate, unknown) of
        [] ->
            DoUnknown =
                case maps:get(unknown_calibration, O) of
                    yes ->
                        true;
                    no ->
                        false;
                    ask ->
                        string:lowercase(
                            ask(
                                "Third consenting speaker available for UNKNOWN calibration? [y/N]: "
                            )
                        ) =:= "y"
                end,
            case DoUnknown of
                true -> collect_takes(Dir, calibrate, unknown, 1, O);
                false -> io:format("No unknown calibration: rejection limits have less evidence.~n")
            end;
        _ ->
            ok
    end.

accepted_files(Dir, Split, Label) ->
    Prefix = atom_to_list(Split) ++ "--" ++ label_text(Label) ++ "--",
    Path = filename:join(Dir, "develop"),
    case file:list_dir(Path) of
        {ok, Fs} ->
            lists:sort([
                filename:join(Path, F)
             || F <- Fs,
                lists:prefix(Prefix, F),
                filename:extension(F) =:= ".wav"
            ]);
        {error, enoent} ->
            [];
        {error, Reason} ->
            fail({development_files, Reason})
    end.

collect_takes(Dir, Split, Label, Target, O) ->
    Existing = accepted_files(Dir, Split, Label),
    ensure(length(Existing) =< 10, too_many_development_takes),
    lists:foreach(
        fun(N) -> take_until_accepted(Dir, Split, Label, N, O, 1) end,
        lists:seq(length(Existing) + 1, Target)
    ).

take_until_accepted(_, Split, Label, _, _, Attempt) when Attempt > 5 ->
    fail({too_many_attempts, Split, Label});
take_until_accepted(Dir, Split, Label, N, O, Attempt) ->
    Display = label_text(Label),
    Source = source_for(Label, O),
    Text = ecai_voice_tts:script(Source, Split, N),
    io:format("~n~s / ~s / take ~B / source=~p~n", [atom_to_list(Split), Display, N, Source]),
    Take = filename:join([
        Dir,
        "takes",
        atom_to_list(Split) ++ "--" ++ Display ++ "--" ++ unique_id() ++ ".wav"
    ]),
    Capture =
        case Source of
            synthetic ->
                io:format("Synthetic TTS script: ~ts~n", [Text]),
                synthesize_take(Take, Text, O);
            human ->
                io:format("READ THIS PASSAGE ALOUD after the spoken cue:~n  ~ts~n", [Text]),
                case ask("Put on headphones; have the speaker ready. [Enter=record, q=quit]: ") of
                    "q" -> stop(operator_quit);
                    _ -> ok
                end,
                prompt_and_capture(Take, "Please read the passage displayed on the screen.", O)
        end,
    case Capture of
        ok ->
            case ecai_voice_loop:check(Take, maps:get(seconds, O)) of
                {ok, #{quality := Quality}} ->
                    io:format("Sample quality: ~tp~n", [
                        maps:with(
                            [rms, active_seconds_approx, periodic_seconds_approx, clipped_fraction],
                            Quality
                        )
                    ]),
                    Decision =
                        case Source of
                            synthetic -> accept;
                            human -> review_take(Take, O)
                        end,
                    case Decision of
                        accept ->
                            Name = lists:flatten(
                                io_lib:format(
                                    "~s--~s--~2..0B.wav",
                                    [atom_to_list(Split), Display, N]
                                )
                            ),
                            Dest = filename:join([Dir, "develop", Name]),
                            {ok, Data} = file:read_file(Take),
                            ok = write_private_exclusive(Dest, Data),
                            ok = write_private_exclusive(Dest ++ ".script.txt", Text),
                            io:format("Accepted (~p): ~ts~n", [Source, Dest]);
                        retry ->
                            take_until_accepted(Dir, Split, Label, N, O, Attempt + 1)
                    end;
                {error, QualityError} when Source =:= synthetic ->
                    fail({unusable_synthetic_audio, QualityError});
                {error, QualityError} ->
                    io:format("Rejected unusable recording: ~tp~n", [QualityError]),
                    take_until_accepted(Dir, Split, Label, N, O, Attempt + 1)
            end;
        {error, AudioError} when Source =:= synthetic ->
            fail({synthetic_audio_failed, AudioError});
        {error, AudioError} ->
            io:format("Capture failed: ~tp~n", [AudioError]),
            take_until_accepted(Dir, Split, Label, N, O, Attempt + 1)
    end.

review_take(Path, O) ->
    case string:lowercase(ask("Accept take? [Enter=accept, r=retry, p=play, q=quit]: ")) of
        "" ->
            accept;
        "r" ->
            retry;
        "q" ->
            stop(operator_quit);
        "p" ->
            ok = command("aplay", ["-q", "-D", maps:get(playback, O), Path], 35000),
            review_take(Path, O);
        _ ->
            io:format("Choose Enter, r, p, or q.~n"),
            review_take(Path, O)
    end.

test_loop(Dir, Labels, Profile, O, N, Count) ->
    Names = string:join([label_text(L) || L <- Labels], ","),
    Entry = ask("\nExpected speaker [" ++ Names ++ "/unknown]; Enter=unlabelled, q=quit: "),
    case string:lowercase(Entry) of
        "q" ->
            {ok, #{
                status => stopped,
                reason => operator_quit,
                session => Dir,
                attempts_this_run => Count,
                profile => filename:join(Dir, "voices.ecv")
            }};
        _ ->
            case ecai_voice_loop:expected(Entry) of
                {ok, Expected} ->
                    case
                        Expected =:= undefined orelse Expected =:= unknown orelse
                            lists:member(Expected, Labels)
                    of
                        false ->
                            io:format("Not an enrolled label.~n"),
                            test_loop(Dir, Labels, Profile, O, N, Count);
                        true ->
                            TestFile = filename:join([Dir, "tests", test_name(N)]),
                            Source =
                                case Expected of
                                    undefined -> human;
                                    unknown -> human;
                                    Label -> source_for(Label, O)
                                end,
                            Prompt = ecai_voice_tts:script(Source, test, N),
                            io:format("~nTest ~B / source=~p~n", [N, Source]),
                            Capture =
                                case Source of
                                    synthetic ->
                                        io:format(
                                            "Synthesizing known speaker from WAV, no microphone:~n  ~ts~n",
                                            [Prompt]
                                        ),
                                        synthesize_take(TestFile, Prompt, O);
                                    human ->
                                        io:format(
                                            "READ THIS PASSAGE ALOUD after the spoken cue:~n  ~ts~n",
                                            [Prompt]
                                        ),
                                        prompt_and_capture(
                                            TestFile,
                                            "Please read the passage displayed on the screen.",
                                            O
                                        )
                                end,
                            case Capture of
                                ok ->
                                    ok = write_private_exclusive(TestFile ++ ".script.txt", Prompt),
                                    Result = ecai_voice_loop:score(
                                        Dir,
                                        TestFile,
                                        Expected,
                                        maps:get(backend, O)
                                    ),
                                    save_result(TestFile, Result),
                                    print_result(Result),
                                    maybe_feedback(TestFile, Result, O);
                                {error, R} ->
                                    Result = {error, {capture_failed, R}},
                                    save_result(TestFile, Result),
                                    io:format("Test capture failed: ~tp~n", [R])
                            end,
                            test_loop(Dir, Labels, Profile, O, next_test_id(Dir), Count + 1)
                    end;
                {error, R} ->
                    io:format("Invalid label: ~tp~n", [R]),
                    test_loop(Dir, Labels, Profile, O, N, Count)
            end
    end.

save_result(Path, Result) ->
    ok = write_private_exclusive(Path ++ ".result.term", io_lib:format("~tp.~n", [Result])).

print_result({ok, R}) ->
    io:format(
        "ECAI voice result: status=~tp speaker=~tp outcome=~tp~n",
        [maps:get(status, R), maps:get(speaker, R), maps:get(outcome, R)]
    ),
    io:format(
        "best_distance=~tp margin=~tp limits=~tp backend=~tp~n",
        [
            maps:get(best_distance, R, undefined),
            maps:get(margin, R, undefined),
            maps:get(thresholds, R, undefined),
            maps:get(backend, R)
        ]
    );
print_result(Error) ->
    io:format("ECAI matching failed: ~tp~n", [Error]).

maybe_feedback(_, {error, _}, _) ->
    ok;
maybe_feedback(Path, {ok, R}, O) ->
    Speech = ecai_voice_loop:feedback(R),
    ok = write_private_exclusive(Path ++ ".feedback.txt", Speech),
    case maps:get(speak_results, O) of
        false ->
            ok;
        true ->
            try speak(unicode:characters_to_list(Speech), Path ++ ".feedback.wav", O) of
                ok -> ok;
                FeedbackResult -> io:format("Feedback TTS unavailable: ~tp~n", [FeedbackResult])
            catch
                FeedbackClass:FeedbackReason ->
                    io:format(
                        "Feedback TTS unavailable: ~tp~n",
                        [{FeedbackClass, FeedbackReason}]
                    )
            end
    end.

%% Direct file-level loopback: generate a genuine second source without
%% speaker playback bleeding into microphone input. The resulting WAV is
%% validated by the same ecai_voice_loop:check/2 as microphone recordings.
%% Also exposed as a one-shot operator probe for the real eSpeak -> WAV path;
%% it creates a private WAV but does not enroll a voice or modify a profile.
synthesize_take(Path, Text, O) ->
    Raw = Path ++ ".espeak-raw.wav",
    try
        reserve_private(Raw),
        ok = command(
            "espeak-ng",
            [
                "-v",
                maps:get(tts_voice, O),
                "-s",
                integer_to_list(maps:get(tts_speed, O)),
                "-w",
                Raw,
                Text
            ],
            20000
        ),
        case file:read_file_info(Raw) of
            {ok, #file_info{type = regular, size = Bytes}} when
                Bytes > 0, Bytes =< 3 * 1024 * 1024
            ->
                ok;
            _ ->
                fail(invalid_synthetic_wav_size)
        end,
        {ok, Original} = file:read_file(Raw),
        %% value/1 unwraps {ok, WAV} to WAV; it does not return a tuple.
        Converted = value(ecai_voice_tts:normalize(Original, maps:get(seconds, O))),
        write_private_exclusive(Path, Converted)
    catch
        throw:{voice_session_error, SynthesisError} ->
            {error, SynthesisError};
        SynthesisClass:SynthesisReason ->
            {error, {tts_generation_failed, SynthesisClass, SynthesisReason}}
    after
        _ = file:delete(Raw)
    end.

prompt_and_capture(Path, Text, O) ->
    try
        %% Playback and recording are strictly sequential, so the prompt is not
        %% intentionally mixed into the incoming PCM. Use headphones for echo.
        ok = speak(Text, Path ++ ".prompt.wav", O),
        timer:sleep(maps:get(settle_ms, O)),
        reserve_private(Path),
        Seconds = maps:get(seconds, O),
        io:format("Recording ~B seconds (speak now)...~n", [Seconds]),
        ok = command(
            "arecord",
            [
                "-q",
                "-D",
                maps:get(device, O),
                "-t",
                "wav",
                "-f",
                "S16_LE",
                "-r",
                "16000",
                "-c",
                "1",
                "-d",
                integer_to_list(Seconds),
                Path
            ],
            Seconds * 1000 + 5000
        ),
        %% Check negotiated format and duration even if arecord exits 0.
        case ecai_voice_loop:check(Path, Seconds) of
            {ok, _} -> ok;
            {error, R} -> {error, R}
        end
    catch
        throw:{voice_session_error, CaptureError} -> {error, CaptureError};
        CaptureClass:CaptureReason -> {error, {audio_failure, CaptureClass, CaptureReason}}
    end.

speak(Text, Path, O) ->
    reserve_private(Path),
    try
        ok = command("espeak-ng", ["-w", Path, Text], 15000),
        command("aplay", ["-q", "-D", maps:get(playback, O), Path], 25000)
    after
        _ = file:delete(Path)
    end.

command(Name, Args, Timeout) ->
    Exe =
        case os:find_executable(Name) of
            false -> fail({missing_audio_executable, Name});
            Path -> Path
        end,
    Port = open_port({spawn_executable, Exe}, [
        binary,
        exit_status,
        stderr_to_stdout,
        {args, Args}
    ]),
    try
        await_port(Port, erlang:monotonic_time(millisecond) + Timeout, <<>>)
    after
        %% A port normally closes itself after exit_status, so ignore only
        %% the expected badarg when it has already closed.
        try
            erlang:port_close(Port)
        catch
            error:badarg -> ok
        end
    end.

await_port(Port, Deadline, Output) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, B}} when is_binary(B) ->
            Keep = min(byte_size(B), max(0, 4096 - byte_size(Output))),
            await_port(Port, Deadline, <<Output/binary, (binary:part(B, 0, Keep))/binary>>);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Code}} ->
            fail({audio_command_failed, Code, Output})
    after Remaining -> fail(audio_command_timeout)
    end.

next_test_id(Dir) -> next_test_id(Dir, 1).
next_test_id(Dir, N) ->
    Base = filename:join([Dir, "tests", test_name(N)]),
    case
        lists:any(
            fun filelib:is_file/1,
            [
                Base,
                Base ++ ".result.term",
                Base ++ ".prompt.wav",
                Base ++ ".feedback.wav",
                Base ++ ".feedback.txt"
            ]
        )
    of
        true -> next_test_id(Dir, N + 1);
        false -> N
    end.

test_name(N) -> lists:flatten(io_lib:format("test--~8..0B.wav", [N])).
label_text(unknown) -> "unknown";
label_text(L) when is_binary(L) -> binary_to_list(L).
unique_id() -> binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(10))).

reserve_private(Path) ->
    case file:open(Path, [write, binary, raw, exclusive]) of
        {ok, F} ->
            try
                ok_value(file:change_mode(Path, 8#600))
            after
                file:close(F)
            end;
        {error, R} ->
            fail({reserve_file_failed, Path, R})
    end.

write_private_exclusive(Path, Data) ->
    %% WAV payloads are raw binary, not UTF-8; terms/text arrive as chardata.
    B =
        case is_binary(Data) of
            true -> Data;
            false -> unicode:characters_to_binary(Data)
        end,
    reserve_private(Path),
    case file:write_file(Path, B, [binary]) of
        ok -> ok;
        {error, R} -> fail({write_private_file_failed, Path, R})
    end.

ask(Text) ->
    case io:get_line(Text) of
        eof -> stop(end_of_input);
        {error, R} -> fail({terminal_io, R});
        S -> string:trim(S)
    end.

value({ok, V}) -> V;
value({error, R}) -> fail(R).
ok_value(ok) -> ok;
ok_value({error, R}) -> fail(R).
ensure(true, _) -> ok;
ensure(false, R) -> fail(R).
fail(R) -> throw({voice_session_error, R}).
stop(R) -> throw({voice_session_stop, R}).
