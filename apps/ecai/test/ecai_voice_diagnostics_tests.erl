-module(ecai_voice_diagnostics_tests).
-include_lib("eunit/include/eunit.hrl").

synthetic_diagnostics_match_builder_test_() ->
    {timeout, 600, fun() -> with_tmp(fun(Dir) ->
        {ok, Rows} = ecai_voice_demo:generate(Dir),
        {ok, Profile} = ecai_voice:build(Rows),
        {ok, D} = ecai_voice_diagnostics:analyze(Rows),
        ?assertEqual(separable, maps:get(status, D)),
        ?assertEqual([], maps:get(known_misranked_files, D)),
        ?assertEqual(maps:get(calibration, Profile), maps:get(summary, D)),
        ?assertEqual(3, length(maps:get(recordings, D))),
        %% Missing held-out test files must never influence development diagnostics.
        InvalidTests = [case maps:get(split, R) of
            test -> R#{source => {wav, filename:join(Dir, "nonexistent-test.wav")}};
            _ -> R
        end || R <- Rows],
        ?assertEqual({ok, D}, ecai_voice_diagnostics:analyze(InvalidTests))
    end) end}.

wrong_known_label_is_exposed_test_() ->
    {timeout, 600, fun() -> with_tmp(fun(Dir) ->
        {ok, Rows} = ecai_voice_demo:generate(Dir),
        {wav, AlternateA} = maps:get(source, hd([R || R <- Rows,
            maps:get(speaker, R) =:= <<"voice_a">>, maps:get(split, R) =:= test])),
        WrongRows = [case {maps:get(speaker, R), maps:get(split, R)} of
            {<<"voice_b">>, calibrate} -> R#{source => {wav, AlternateA}};
            _ -> R
        end || R <- Rows],
        {ok, D} = ecai_voice_diagnostics:analyze(WrongRows),
        ?assertEqual(not_separable, maps:get(status, D)),
        ?assert(lists:member(AlternateA, maps:get(known_misranked_files, D))),
        [Wrong] = [R || R <- maps:get(recordings, D),
                       maps:get(path, R) =:= AlternateA],
        ?assertEqual(<<"voice_b">>, maps:get(expected, Wrong)),
        ?assertEqual(<<"voice_a">>, maps:get(closest_speaker, Wrong)),
        ?assert(maps:get(genuine_margin, Wrong) < 0),
        {error, {calibration_not_separable, S}} = ecai_voice:build(WrongRows),
        ?assertEqual(S, maps:get(summary, D))
    end) end}.

missing_rows_test() ->
    ?assertEqual({error, invalid_development_rows}, ecai_voice_diagnostics:analyze([])),
    ?assertEqual({error, invalid_development_rows}, ecai_voice_diagnostics:analyze(nope)).

with_tmp(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(Base, "ecai-voice-diagnostic-test-" ++
                              binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
