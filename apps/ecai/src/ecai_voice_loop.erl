%%% File/API bridge for the local TTS -> microphone -> ECAI test loop.
%%% Audio orchestration is in test/run_voice_loop.sh. No automatic enrollment
%%% from test results, no transcription, no application/supervisor startup.
-module(ecai_voice_loop).
-license("Apache-2.0").
-export([main/0, rows/1, build/1, import_profile/2, check/2,
         score/4, expected/1, label_valid/1, feedback/1]).

%% A static -s entry point: paths/labels are data in environment variables,
%% never interpolated into an Erlang expression or converted to atoms.
main() ->
    Result = protect(fun() ->
        {ok, _} = application:ensure_all_started(crypto),
        dispatch(env("ECAI_VOICE_LOOP_ACTION"))
    end),
    io:format("~tp~n", [Result]),
    case Result of {ok, _} -> halt(0); ok -> halt(0); _ -> halt(1) end.

dispatch("build") ->
    Dir = env("ECAI_VOICE_LOOP_SESSION"),
    Result = build(Dir),
    ok_value(write_term(filename:join(Dir, "build.result.term"), Result)),
    Result;
dispatch("inspect") ->
    Dir = env("ECAI_VOICE_LOOP_SESSION"),
    P = value(ecai_voice:load(filename:join(Dir, "voices.ecv"))),
    Ls = lists:sort(maps:keys(maps:get(templates, P))),
    require(maps:get(channel, P) =/= 1, profile_requires_stereo_channel_one),
    require(Ls =:= lists:sort(labels(Dir)), session_profile_labels_differ),
    {ok, #{labels => Ls, calibration => maps:get(calibration, P),
           thresholds => maps:get(thresholds, P)}};
dispatch("import") ->
    import_profile(env("ECAI_VOICE_LOOP_PROFILE"), env("ECAI_VOICE_LOOP_SESSION"));
dispatch("check") ->
    Path = env("ECAI_VOICE_LOOP_SAMPLE"),
    Result = check(Path, seconds()),
    ok_value(write_term(Path ++ ".quality.term", Result)),
    Result;
dispatch("score") ->
    Path = env("ECAI_VOICE_LOOP_SAMPLE"),
    Result = protect(fun() ->
        _ = capture(Path, seconds()),
        Backend = case env("ECAI_VOICE_LOOP_BACKEND") of
            "curve" -> curve;
            "integer" -> integer;
            _ -> fail(invalid_backend)
        end,
        E = value(expected(env("ECAI_VOICE_LOOP_EXPECTED"))),
        score(env("ECAI_VOICE_LOOP_SESSION"), Path, E, Backend)
    end),
    ok_value(write_term(Path ++ ".result.term", Result)),
    case Result of
        {ok, R} -> ok_value(write_bytes(Path ++ ".feedback.txt", feedback(R)));
        _ -> ok
    end,
    Result;
dispatch(_) -> {error, invalid_loop_action}.

-spec label_valid(term()) -> boolean().
label_valid(B) when is_binary(B), byte_size(B) >= 1, byte_size(B) =< 32 ->
    B =/= <<"unknown">> andalso
    re:run(B, "\\A[A-Za-z0-9][A-Za-z0-9_-]{0,31}\\z", [{capture, none}]) =:= match;
label_valid(_) -> false.

-spec expected(string() | binary()) -> {ok, binary() | unknown | undefined} | {error, term()}.
expected(Value) -> protect(fun() ->
    case unicode:characters_to_binary(Value) of
        <<>> -> {ok, undefined};
        <<"unknown">> -> {ok, unknown};
        B -> require(label_valid(B), invalid_expected_label), {ok, B}
    end
end).

-spec rows(file:filename_all()) -> {ok, [map()]} | {error, term()}.
rows(Dir) -> protect(fun() ->
    Labels = labels(Dir),
    Development = lists:append([begin
        Enroll = recordings(Dir, enroll, L),
        Calibrate = recordings(Dir, calibrate, L),
        require(Enroll =/= [] andalso Calibrate =/= [], {missing_recordings, L}),
        Enroll ++ Calibrate
    end || L <- Labels]),
    Result = Development ++ recordings(Dir, calibrate, unknown),
    require(length(Result) =< 200, too_many_development_recordings),
    {ok, Result}
end).

labels(Dir) ->
    B = value(file:read_file(filename:join(Dir, "speakers.txt"))),
    require(byte_size(B) =< 4096, speakers_file_too_large),
    Ls = [L || L <- binary:split(B, <<"\n">>, [global]), L =/= <<>>],
    require(length(Ls) >= 2 andalso length(Ls) =< 10 andalso
            length(lists:usort(Ls)) =:= length(Ls) andalso
            lists:all(fun label_valid/1, Ls), invalid_speakers_file),
    Ls.

recordings(Dir, Split, Label) ->
    L = case Label of unknown -> "unknown"; _ -> binary_to_list(Label) end,
    Prefix = atom_to_list(Split) ++ "--" ++ L ++ "--",
    DevDir = filename:join(Dir, "develop"),
    Names = case file:list_dir(DevDir) of
        {ok, Ns} -> Ns;
        {error, enoent} -> [];
        {error, Reason} -> fail({development_directory, Reason})
    end,
    Paths = lists:sort([filename:join(DevDir, N) || N <- Names,
                        lists:prefix(Prefix, N), filename:extension(N) =:= ".wav"]),
    require(length(Paths) =< 10, too_many_takes_per_split),
    [#{speaker => Label, split => Split,
       source => {wav, filename:absname(P)}} || P <- Paths].

-spec build(file:filename_all()) -> {ok, map()} | {error, term()}.
build(Dir) -> protect(fun() ->
    Path = filename:join(Dir, "voices.ecv"),
    require(not filelib:is_file(Path), profile_already_exists),
    Rows = value(rows(Dir)),
    ok_value(write_term(filename:join(Dir, "dataset.term"), Rows)),
    %% ecai_voice:build refuses non-separable calibration. No fallback radius.
    P = value(ecai_voice:build(Rows)),
    ok_value(ecai_voice:save(Path, P)),
    {ok, #{profile => filename:absname(Path),
           calibration => maps:get(calibration, P), thresholds => maps:get(thresholds, P)}}
end).

-spec import_profile(file:filename_all(), file:filename_all()) -> {ok, map()} | {error, term()}.
import_profile(Source, Dir) -> protect(fun() ->
    Dest = filename:join(Dir, "voices.ecv"),
    require(not filelib:is_file(Dest), profile_already_exists),
    P = value(ecai_voice:load(Source)),
    require(maps:get(channel, P) =/= 1, profile_requires_stereo_channel_one),
    Ls = lists:sort(maps:keys(maps:get(templates, P))),
    require(length(Ls) =< 10 andalso lists:all(fun label_valid/1, Ls),
            profile_labels_not_supported_by_loop),
    ok_value(write_bytes(filename:join(Dir, "speakers.txt"), [[L, "\n"] || L <- Ls])),
    ok_value(write_term(filename:join(Dir, "import.term"),
                       #{source => filename:absname(Source),
                         sha256 => crypto:hash(sha256, value(file:read_file(Source)))})),
    ok_value(ecai_voice:save(Dest, P)),
    {ok, #{profile => filename:absname(Dest), labels => Ls}}
end).

%% arecord may negotiate a different format or exit early. Do not accept that
%% as a complete take just because it returned exit status zero.
capture(Path, Seconds) ->
    require(is_integer(Seconds) andalso Seconds >= 2 andalso Seconds =< 30,
            seconds_must_be_2_to_30),
    A = value(ecai_voice_wav:read(Path)),
    require(maps:get(channels, A) =:= 1, capture_must_be_mono),
    require(abs(maps:get(seconds, A) - Seconds) =< 0.05, incomplete_capture),
    A.

-spec check(file:filename_all(), pos_integer()) -> {ok, map()} | {error, term()}.
check(Path, Seconds) -> protect(fun() ->
    _ = capture(Path, Seconds),
    F = value(ecai_voice:extract_wav(Path)),
    {ok, #{status => usable, quality => maps:get(quality, F)}}
end).

-spec score(file:filename_all(), file:filename_all(), binary() | unknown | undefined,
            curve | integer) -> {ok, map()} | {error, term()}.
score(Dir, Sample, Expected, Backend) -> protect(fun() ->
    ProfilePath = filename:join(Dir, "voices.ecv"),
    P = value(ecai_voice:load(ProfilePath)),
    require(Expected =:= undefined orelse Expected =:= unknown orelse
            maps:is_key(Expected, maps:get(templates, P)), expected_speaker_not_enrolled),
    R = value(ecai_voice:identify(P, {wav, Sample}, Backend)),
    %% This is a diagnostic label, not a benchmark score or probability.
    Outcome = outcome(R, Expected),
    {ok, R#{expected => Expected, outcome => Outcome,
            sample => filename:absname(Sample),
            profile_payload_sha256 => crypto:hash(sha256, term_to_binary(P, [deterministic])),
            scored_at_utc_seconds => erlang:system_time(second),
            diagnostic_only => true}}
end).

outcome(#{seen_during_build := true}, _) -> development_audio_not_a_test;
outcome(#{status := insufficient_audio}, _) -> insufficient_audio;
outcome(_, undefined) -> unlabelled;
outcome(#{status := matched}, unknown) -> unknown_false_match;
outcome(#{status := unknown}, unknown) -> unknown_rejected;
outcome(#{status := matched, speaker := L}, L) -> known_correct;
outcome(#{status := matched}, _) -> known_wrong_match;
outcome(_, _) -> known_abstained.

-spec feedback(map()) -> binary().
feedback(#{status := insufficient_audio}) ->
    <<"Insufficient usable speech. Try speaking clearly for the full recording.">>;
feedback(#{status := unknown}) ->
    <<"Unknown voice. No enrolled voice met the calibrated matching limits.">>;
feedback(#{status := matched, speaker := Label}) ->
    case label_valid(Label) of
        true -> <<"Voice match: ", Label/binary, ". This is an experimental match, not authentication.">>;
        false -> <<"Voice match found. See the screen for the label.">>
    end.

%% Trusted local reports, written as Erlang terms for file:consult/1.
%% A flushed temporary file is renamed into place; no shell parsing/evaluation.
write_term(Path, Term) -> write_bytes(Path, io_lib:format("~tp.~n", [Term])).
write_bytes(Path0, Data) -> protect(fun() ->
    Path = unicode:characters_to_list(Path0),
    ok_value(filelib:ensure_dir(Path)),
    Tmp = Path ++ "." ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))) ++ ".tmp",
    F = value(file:open(Tmp, [write, exclusive, raw, binary])),
    try
        ok_value(file:change_mode(Tmp, 8#600)),
        ok_value(file:write(F, unicode:characters_to_binary(Data))),
        ok_value(file:sync(F)),
        ok_value(file:close(F)),
        ok_value(file:rename(Tmp, Path)),
        ok
    after file:close(F), file:delete(Tmp) end
end).

seconds() -> list_to_integer(env("ECAI_VOICE_LOOP_SECONDS")).
env(Name) -> case os:getenv(Name) of false -> fail({missing_environment, Name}); S -> S end.
require(true, _) -> ok;
require(false, R) -> fail(R).
value({ok, V}) -> V;
value({error, R}) -> fail(R).
ok_value(ok) -> ok;
ok_value({error, R}) -> fail(R).
fail(R) -> throw({voice_loop_error, R}).
protect(Fun) ->
    try Fun() catch
        throw:{voice_loop_error, R} -> {error, R};
        Class:Reason -> {error, {loop_error, Class, Reason}}
    end.
