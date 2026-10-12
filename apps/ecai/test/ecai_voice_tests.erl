-module(ecai_voice_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

invalid_requests_test() ->
    ?assertEqual({error, invalid_profile}, ecai_voice:validate(not_a_map)),
    ?assertEqual({error, invalid_profile_fields}, ecai_voice:validate(#{})),
    ?assertEqual({error, dataset_must_have_one_to_two_hundred_rows}, ecai_voice:build([])),
    ?assertEqual({error, invalid_row}, ecai_voice:build([#{}])),
    ?assertEqual({error, invalid_backend}, ecai_voice:identify(#{}, {pcm16, <<0, 0>>}, llm)),
    ?assertEqual(
        {error, window_ms_must_be_1500_to_30000}, ecai_voice:scan(#{}, {pcm16, <<0, 0>>}, 20)
    ),
    ?assertEqual(
        {error, unknown_cannot_be_enrolled},
        ecai_voice:build([
            #{speaker => unknown, split => enroll, source => {pcm16, <<0, 0>>}}
        ])
    ).

end_to_end_test_() ->
    {timeout, 600, fun end_to_end/0}.

end_to_end() ->
    Dir = temp_dir(),
    try
        {ok, Rows} = ecai_voice_demo:generate(Dir),
        {ok, P} = ecai_voice:build(Rows),
        ?assertEqual(ok, ecai_voice:validate(P)),
        %% Build must not open or score test clips, including nonexistent paths.
        MissingTests = [
            case maps:get(split, R) of
                test -> R#{source => {wav, filename:join(Dir, "DOES_NOT_EXIST.wav")}};
                _ -> R
            end
         || R <- Rows
        ],
        ?assertEqual({ok, P}, ecai_voice:build(MissingTests)),
        {ok, C} = ecai_voice:evaluate(P, Rows, curve),
        {ok, I} = ecai_voice:evaluate(P, Rows, integer),
        ?assertEqual(maps:get(counts, C), maps:get(counts, I)),
        ?assertEqual(2, maps:get(known_correct, maps:get(counts, C))),
        ?assertEqual(1, maps:get(unknown_rejected, maps:get(counts, C))),
        ?assertEqual(0, maps:get(unknown_false_match, maps:get(counts, C))),
        lists:foreach(
            fun({CR, IR}) ->
                ?assertEqual(maps:get(speaker, CR), maps:get(speaker, IR)),
                ?assertEqual(maps:get(best_distance, CR), maps:get(best_distance, IR)),
                ?assertEqual(maps:get(ranking, CR), maps:get(ranking, IR)),
                ?assertEqual(true, maps:get(curve_integer_invariant_checked, CR)),
                ?assertEqual(false, maps:get(curve_integer_invariant_checked, IR))
            end,
            lists:zip(maps:get(results, C), maps:get(results, I))
        ),
        Timeline = {wav, filename:join(Dir, "timeline.wav")},
        {ok, Scan} = ecai_voice:scan(P, Timeline, 2000),
        SR = maps:get(results, Scan),
        ?assertEqual(
            [<<"voice_a">>, <<"voice_b">>, <<"voice_a">>, undefined, undefined],
            [maps:get(speaker, R) || R <- SR]
        ),
        ?assertEqual(
            [matched, matched, matched, unknown, insufficient_audio],
            [maps:get(status, R) || R <- SR]
        ),
        %% Partial final windows abstain rather than disappear or crash.
        PCM = <<(ecai_voice_demo:synthetic(voice_a, 3, 2))/binary, 0:(8000 * 2 * 8)>>,
        {ok, Partial} = ecai_voice:scan(P, {pcm16, PCM}, 2000),
        ?assertEqual(insufficient_audio, maps:get(status, lists:last(maps:get(results, Partial)))),
        {ok, Silent} = ecai_voice:identify_pcm(P, <<0:(32000 * 2 * 8)>>),
        ?assertEqual(insufficient_audio, maps:get(status, Silent)),
        EnrollmentSource = maps:get(source, hd(Rows)),
        {ok, Seen} = ecai_voice:identify(P, EnrollmentSource),
        ?assertEqual(true, maps:get(seen_during_build, Seen)),
        ?assertEqual(
            {error, duplicate_audio_across_dataset},
            ecai_voice:evaluate(P, [
                #{speaker => <<"voice_a">>, split => test, source => EnrollmentSource}
            ])
        ),
        ?assertEqual({error, duplicate_audio_across_dataset}, ecai_voice:build(Rows ++ [hd(Rows)])),
        ?assertMatch(
            {error, {calibration_not_separable, _}}, ecai_voice:build(swap_calibration(Rows))
        ),
        persistence_checks(Dir, P),
        %% No server, ECAI NIF, microphone, Ollama or pretrained model was started.
        ?assertEqual(undefined, whereis(ecai_voice))
    after
        cleanup_dir(Dir)
    end.

persistence_checks(Dir, P) ->
    Path = filename:join(Dir, "roundtrip.ecv"),
    ?assertEqual(ok, ecai_voice:save(Path, P)),
    ?assertEqual({ok, P}, ecai_voice:load(Path)),
    ?assertEqual(ok, ecai_voice:save(Path, P)),
    ?assertEqual({ok, P}, ecai_voice:load(Path)),
    {ok, FI} = file:read_file_info(Path),
    case os:type() of
        {unix, _} -> ?assertEqual(8#600, FI#file_info.mode band 8#777);
        _ -> ok
    end,
    {ok, Original} = file:read_file(Path),
    <<Head:40/binary, Byte:8, Tail/binary>> = Original,
    ok = file:write_file(Path, <<Head/binary, (Byte bxor 1):8, Tail/binary>>),
    ?assertEqual({error, profile_checksum_mismatch}, ecai_voice:load(Path)),
    ok = file:write_file(Path, <<Original/binary, 0>>),
    ?assertEqual({error, invalid_profile_envelope}, ecai_voice:load(Path)),
    ok = file:write_file(Path, <<"bad">>),
    ?assertEqual({error, invalid_profile_envelope}, ecai_voice:load(Path)),
    ?assertEqual(
        {error, profile_configuration_mismatch},
        ecai_voice:validate(P#{frontend => <<"wrong-version">>})
    ),
    Templates = maps:get(templates, P),
    [First | Rest] = maps:get(<<"voice_a">>, Templates),
    Bad = First#{points => lists:duplicate(30, <<0>>)},
    ?assertEqual(
        {error, feature_point_mismatch},
        ecai_voice:validate(P#{templates => Templates#{<<"voice_a">> => [Bad | Rest]}})
    ),
    Payload = term_to_binary(P, [compressed]),
    Hash = crypto:hash(sha256, Payload),
    ok = file:write_file(
        Path, <<"ECV1", (byte_size(Payload)):32/big, Hash/binary, Payload/binary>>
    ),
    ?assertEqual({error, compressed_profile_not_allowed}, ecai_voice:load(Path)).

swap_calibration(Rows) ->
    [
        case R of
            #{split := calibrate, speaker := <<"voice_a">>} -> R#{speaker => <<"voice_b">>};
            #{split := calibrate, speaker := <<"voice_b">>} -> R#{speaker => <<"voice_a">>};
            _ -> R
        end
     || R <- Rows
    ].

temp_dir() ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            D -> D
        end,
    Path = filename:join(
        Base,
        "ecai_voice_" ++ os:getpid() ++ "_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = file:make_dir(Path),
    Path.
cleanup_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} -> lists:foreach(fun(F) -> file:delete(filename:join(Dir, F)) end, Files);
        _ -> ok
    end,
    file:del_dir(Dir),
    ok.
