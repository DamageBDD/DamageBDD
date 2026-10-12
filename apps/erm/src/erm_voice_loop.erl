%%% ERM entry point: interactive ECAI enrollment, calibration, and testing.
%%% run/0 (or start/0) runs in the calling shell, not a background tty reader.
-module(erm_voice_loop).
-license("Apache-2.0").
-export([
    run/0, run/1,
    start/0, start/1,
    inspect/0, inspect/1,
    diagnose/0, diagnose/1,
    tts_demo/0, tts_demo/1,
    next/1,
    loop/2,
    pause/1,
    status/1,
    stop/1
]).

%% One command: consent -> enrol -> calibrate -> repeated voice tests. On later
%% calls the persisted profile is reused. Does not require standalone scripts.
run() -> ecai_voice_session:run().
run(Options) -> ecai_voice_session:run(Options).
start() -> run().

%% Interactive one-human/one-synthetic demonstration, isolated from existing
%% all-microphone sessions (including prior aliases of the same person).
tts_demo() -> tts_demo(#{}).
tts_demo(Overrides) when is_map(Overrides) ->
    case ecai_voice_session:options(#{}) of
        {ok, Defaults} ->
            DemoDefaults = #{
                session => maps:get(session, Defaults) ++ "-tts-demo",
                speakers => [<<"human">>, <<"tts_demo">>],
                tts_speaker => <<"tts_demo">>,
                tts_voice => "en+f3",
                tts_speed => 155,
                unknown_calibration => no,
                seconds => 8,
                enroll_takes => 2,
                calibrate_takes => 2
            },
            io:format(
                "ECAI TTS demo: one microphone speaker and one SYNTHETIC WAV speaker.~n" ++
                    "This does not validate recognition between two people.~n"
            ),
            ecai_voice_session:run(maps:merge(DemoDefaults, Overrides));
        Error ->
            Error
    end;
tts_demo(_) ->
    {error, options_must_be_map}.

%% Preserve the original asynchronous test-only API when given an explicit
%% existing profile; options without one invoke the first-run operator wizard.
start(Options) when is_map(Options) ->
    case maps:is_key(profile, Options) of
        true -> ecai_voice_live:start_link(Options);
        false -> run(Options)
    end;
start(_) ->
    {error, options_must_be_map}.

inspect() ->
    case ecai_voice_session:options(#{}) of
        {ok, O} -> inspect(maps:get(session, O));
        Error -> Error
    end.
inspect(Dir) -> ecai_voice_session:inspect(Dir).

%% Inspect development samples after failed calibration, without re-recording,
%% changing thresholds, or evaluating held-out test samples.
diagnose() ->
    case ecai_voice_session:options(#{}) of
        {ok, Opts} -> diagnose(maps:get(session, Opts));
        Error -> Error
    end.
diagnose(Dir) ->
    case ecai_voice_diagnostics:session(Dir) of
        {ok, Report} ->
            ok = ecai_voice_diagnostics:print(Report),
            {ok, Report};
        Error ->
            Error
    end.

%% Legacy explicit-profile gen_server controls.
next(Pid) -> ecai_voice_live:next(Pid).
loop(Pid, IntervalMs) -> ecai_voice_live:loop(Pid, IntervalMs).
pause(Pid) -> ecai_voice_live:pause(Pid).
status(Pid) -> ecai_voice_live:status(Pid).
stop(Pid) -> ecai_voice_live:stop(Pid).
