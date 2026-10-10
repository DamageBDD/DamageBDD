%%% Local enrolled-speaker matching experiment, independent of ECAI startup/NIFs.
%%% No transcription, overlap separation, unknown-speaker clustering or liveness.
-module(ecai_voice).
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-export([extract_wav/1, extract_pcm/1, build/1, build/2,
         identify/2, identify/3, identify_wav/2, identify_pcm/2,
         evaluate/2, evaluate/3, scan/3, scan/4, save/2, load/1, validate/1]).

-define(SCHEMA, <<"ecai-voice-erlang/1">>).
-define(MAX_PROFILE, 4 * 1024 * 1024).
-type source() :: {wav, file:filename_all()} | {pcm16, binary()}.
-type backend() :: curve | integer.
-export_type([source/0, backend/0]).

-spec extract_wav(file:filename_all()) -> {ok, map()} | {error, term()}.
extract_wav(Path) -> extract_source({wav, Path}).
-spec extract_pcm(binary()) -> {ok, map()} | {error, term()}.
extract_pcm(PCM) -> extract_source({pcm16, PCM}).
extract_source(Source) ->
    protect(fun() ->
        C = ecai_voice_curve:new(),
        {ok, feature(audio(Source, auto), C)}
    end).

-spec build([map()]) -> {ok, map()} | {error, term()}.
build(Rows) -> build(Rows, #{}).
-spec build([map()], map()) -> {ok, map()} | {error, term()}.
build(Rows, Options) ->
    protect(fun() ->
        rows_valid(Rows),
        require(is_map(Options), invalid_options),
        require((maps:keys(Options) -- [channel]) =:= [], unknown_option),
        Channel = maps:get(channel, Options, auto),
        require(lists:member(Channel, [auto, 0, 1]), invalid_channel),
        C = ecai_voice_curve:new(),
        %% Test recordings are neither opened nor scored during build.
        Development = [R || R <- Rows, maps:get(split, R) =/= test],
        {Loaded, Seen} = load_development(Development, Channel, C, [], #{}),
        Enrolled = [R || R <- Loaded, maps:get(split, R) =:= enroll],
        Templates0 = lists:foldl(fun(#{speaker := L, feature := F}, T) ->
            T#{L => [F | maps:get(L, T, [])]}
        end, #{}, Enrolled),
        Templates = maps:map(fun(_, Fs) ->
            lists:sort(fun(A, B) -> pcm_hash(A) < pcm_hash(B) end, Fs)
        end, Templates0),
        require(map_size(Templates) >= 2 andalso map_size(Templates) =< 100,
                enroll_two_to_one_hundred_speakers),
        require(lists:all(fun(Fs) -> length(Fs) =< 20 end, maps:values(Templates)),
                too_many_templates_per_speaker),
        CalibrationRows = [R || R <- Loaded, maps:get(split, R) =:= calibrate],
        {Thresholds, Calibration} = calibrate(CalibrationRows, Templates, C),
        Profile = #{schema => ?SCHEMA, frontend => ecai_voice_features:version(),
                    curve => secp256k1, bound => 255, dimension => 30, quantization => 32,
                    channel => Channel, templates => Templates, thresholds => Thresholds,
                    calibration => Calibration, used_pcm_hashes => lists:sort(maps:keys(Seen))},
        profile_valid(Profile, C),
        {ok, Profile}
    end).

load_development([], _, _, Acc, Seen) -> {lists:reverse(Acc), Seen};
load_development([R | Rest], Channel, C, Acc, Seen) ->
    A = audio(maps:get(source, R), Channel),
    NewSeen = unique_audio(A, Seen),
    F = feature(A, C),
    load_development(Rest, Channel, C, [R#{feature => F} | Acc], NewSeen).

calibrate(Rows, Templates, C) ->
    Labels = lists:sort(maps:keys(Templates)),
    Covered = lists:usort([maps:get(speaker, R) || R <- Rows, maps:get(speaker, R) =/= unknown]),
    require(Covered =:= Labels, each_speaker_needs_separate_calibration),
    {Genuine, Impostor, Margins, UnknownCount} = lists:foldl(
        fun(#{speaker := L, feature := F}, {Gs, Is, Ms, Us}) ->
            Scores = ranking(Templates, F, C, curve),
            case L of
                unknown -> {Gs, [maps:get(distance, hd(Scores)) | Is], Ms, Us + 1};
                _ ->
                    [Own] = [maps:get(distance, S) || S <- Scores, maps:get(speaker, S) =:= L],
                    Other = lists:min([maps:get(distance, S) || S <- Scores, maps:get(speaker, S) =/= L]),
                    {[Own | Gs], [Other | Is], [Other - Own | Ms], Us}
            end
        end, {[], [], [], 0}, Rows),
    MaxG = lists:max(Genuine),
    MinI = lists:min(Impostor),
    MinM = lists:min(Margins),
    Summary = #{worst_genuine => MaxG, nearest_impostor => MinI,
                minimum_genuine_margin => MinM, known_count => length(Genuine),
                unknown_count => UnknownCount},
    require(MaxG < MinI andalso MinM > 0, {calibration_not_separable, Summary}),
    {#{max_distance => (MaxG + MinI) div 2, min_margin => max(1, MinM div 2)}, Summary}.

-spec identify(map(), source()) -> {ok, map()} | {error, term()}.
identify(Profile, Source) -> identify(Profile, Source, curve).
-spec identify(map(), source(), backend()) -> {ok, map()} | {error, term()}.
identify(Profile, Source, Backend) ->
    protect(fun() ->
        backend_valid(Backend),
        C = ecai_voice_curve:new(),
        profile_valid(Profile, C),
        A = audio(Source, maps:get(channel, Profile)),
        Result = classify_audio(Profile, A, C, Backend),
        {ok, Result#{seen_during_build => lists:member(maps:get(pcm_sha256, A),
                                                      maps:get(used_pcm_hashes, Profile))}}
    end).
-spec identify_wav(map(), file:filename_all()) -> {ok, map()} | {error, term()}.
identify_wav(Profile, Path) -> identify(Profile, {wav, Path}).
-spec identify_pcm(map(), binary()) -> {ok, map()} | {error, term()}.
identify_pcm(Profile, PCM) -> identify(Profile, {pcm16, PCM}).

classify_audio(Profile, A, C, Backend) ->
    try
        F = feature(A, C),
        Scores = ranking(maps:get(templates, Profile), F, C, Backend),
        [Best, Next | _] = Scores,
        D = maps:get(distance, Best),
        Gap = maps:get(distance, Next) - D,
        #{max_distance := Radius, min_margin := MinMargin} = maps:get(thresholds, Profile),
        {Status, Label, Reason} = case {D =< Radius, Gap >= MinMargin} of
            {true, true} -> {matched, maps:get(speaker, Best), within_calibrated_limits};
            {false, _} -> {unknown, undefined, too_far};
            _ -> {unknown, undefined, ambiguous}
        end,
        #{status => Status, speaker => Label, reason => Reason, best_distance => D,
          margin => Gap, thresholds => maps:get(thresholds, Profile), ranking => Scores,
          backend => Backend, curve_integer_invariant_checked => Backend =:= curve,
          quality => maps:get(quality, F)}
    catch
        throw:{voice_error, {insufficient_audio, R}} ->
            #{status => insufficient_audio, speaker => undefined, reason => R,
              backend => Backend, curve_integer_invariant_checked => false}
    end.

ranking(Templates, Query, C, Backend) ->
    Tuples = [begin
        Distances = [compare(Query, F, C, Backend) || F <- Fs],
        {D, I} = lists:min(lists:zip(Distances, lists:seq(1, length(Fs)))),
        {D, Label, I}
    end || {Label, Fs} <- maps:to_list(Templates)],
    [#{speaker => Label, distance => D, template_index => I}
     || {D, Label, I} <- lists:sort(Tuples)].

compare(A, B, C, Backend) ->
    Ordinary = value(ecai_voice_curve:integer_distance(maps:get(q, A), maps:get(q, B))),
    case Backend of
        integer -> Ordinary;
        curve ->
            Elliptic = value(ecai_voice_curve:distance(maps:get(points, A), maps:get(points, B), C)),
            require(Elliptic =:= Ordinary, elliptic_integer_invariant_failed),
            Elliptic
    end.

-spec evaluate(map(), [map()]) -> {ok, map()} | {error, term()}.
evaluate(Profile, Rows) -> evaluate(Profile, Rows, curve).
-spec evaluate(map(), [map()], backend()) -> {ok, map()} | {error, term()}.
evaluate(Profile, Rows, Backend) ->
    protect(fun() ->
        Start = erlang:monotonic_time(microsecond),
        rows_valid(Rows),
        backend_valid(Backend),
        C = ecai_voice_curve:new(),
        profile_valid(Profile, C),
        Tests = [R || R <- Rows, maps:get(split, R) =:= test],
        require(Tests =/= [], no_held_out_tests),
        Seen0 = maps:from_list([{H, true} || H <- maps:get(used_pcm_hashes, Profile)]),
        {ResultsRev, _, Seconds} = lists:foldl(fun(R, {Acc, Seen, Sec}) ->
            Label = maps:get(speaker, R),
            require(Label =:= unknown orelse maps:is_key(Label, maps:get(templates, Profile)),
                    test_speaker_not_enrolled),
            A = audio(maps:get(source, R), maps:get(channel, Profile)),
            Seen1 = unique_audio(A, Seen),
            Result = classify_audio(Profile, A, C, Backend),
            Correct = (Label =:= unknown andalso maps:get(status, Result) =:= unknown) orelse
                      (Label =/= unknown andalso maps:get(speaker, Result) =:= Label),
            {[Result#{expected => Label, correct => Correct} | Acc], Seen1, Sec + maps:get(seconds, A)}
        end, {[], Seen0, 0.0}, Tests),
        Results = lists:reverse(ResultsRev),
        Elapsed = (erlang:monotonic_time(microsecond) - Start) / 1000000,
        {ok, #{backend => Backend, counts => counts(Results), results => Results,
               audio_seconds => Seconds, elapsed_seconds => Elapsed,
               processing_seconds_per_audio_second => Elapsed / Seconds,
               caveat => development_test_not_biometric_validation}}
    end).

counts(Results) ->
    Known = [R || R <- Results, maps:get(expected, R) =/= unknown],
    Unknown = [R || R <- Results, maps:get(expected, R) =:= unknown],
    #{total => length(Results), known => length(Known),
      known_correct => length([R || R <- Known, maps:get(correct, R)]),
      known_wrong_match => length([R || R <- Known, maps:get(status, R) =:= matched,
                                    not maps:get(correct, R)]),
      known_abstained => length([R || R <- Known, maps:get(status, R) =/= matched]),
      unknown => length(Unknown),
      unknown_rejected => length([R || R <- Unknown, maps:get(status, R) =:= unknown]),
      unknown_false_match => length([R || R <- Unknown, maps:get(status, R) =:= matched]),
      insufficient_audio => length([R || R <- Results, maps:get(status, R) =:= insufficient_audio])}.

-spec scan(map(), source(), pos_integer()) -> {ok, map()} | {error, term()}.
scan(Profile, Source, WindowMs) -> scan(Profile, Source, WindowMs, curve).
-spec scan(map(), source(), pos_integer(), backend()) -> {ok, map()} | {error, term()}.
scan(Profile, Source, WindowMs, Backend) ->
    protect(fun() ->
        require(is_integer(WindowMs) andalso WindowMs >= 1500 andalso WindowMs =< 30000,
                window_ms_must_be_1500_to_30000),
        backend_valid(Backend),
        C = ecai_voice_curve:new(),
        profile_valid(Profile, C),
        A = audio(Source, maps:get(channel, Profile)),
        Results = scan_windows(maps:get(pcm, A), 32 * WindowMs, 0, Profile, C, Backend, []),
        {ok, #{mode => coarse_enrolled_speaker_windows, window_ms => WindowMs,
               warning => no_overlap_detection_or_unknown_speaker_clustering,
               results => Results}}
    end).

scan_windows(<<>>, _, _, _, _, _, Acc) -> lists:reverse(Acc);
scan_windows(PCM, Size, Offset, Profile, C, Backend, Acc) ->
    N = min(Size, byte_size(PCM)),
    <<Chunk:N/binary, Rest/binary>> = PCM,
    A = value(ecai_voice_wav:pcm(Chunk)),
    Result = classify_audio(Profile, A, C, Backend),
    Row = Result#{start_seconds => Offset / 32000, end_seconds => (Offset + N) / 32000},
    scan_windows(Rest, Size, Offset + N, Profile, C, Backend, [Row | Acc]).

-spec validate(map()) -> ok | {error, term()}.
validate(Profile) -> protect(fun() -> profile_valid(Profile, ecai_voice_curve:new()), ok end).

profile_valid(P, C) ->
    require(is_map(P), invalid_profile),
    Keys = [schema, frontend, curve, bound, dimension, quantization, channel, templates,
            thresholds, calibration, used_pcm_hashes],
    require(lists:sort(maps:keys(P)) =:= lists:sort(Keys), invalid_profile_fields),
    require(maps:get(schema, P) =:= ?SCHEMA andalso
            maps:get(frontend, P) =:= ecai_voice_features:version() andalso
            maps:get(curve, P) =:= secp256k1 andalso maps:get(bound, P) =:= 255 andalso
            maps:get(dimension, P) =:= 30 andalso maps:get(quantization, P) =:= 32,
            profile_configuration_mismatch),
    require(lists:member(maps:get(channel, P), [auto, 0, 1]), invalid_profile_channel),
    Templates = maps:get(templates, P),
    require(is_map(Templates) andalso map_size(Templates) >= 2 andalso map_size(Templates) =< 100,
            invalid_profile_templates),
    maps:foreach(fun(L, Fs) ->
        require(label_valid(L) andalso L =/= unknown, invalid_profile_label),
        require(is_list(Fs) andalso length(Fs) >= 1 andalso length(Fs) =< 20, invalid_templates),
        lists:foreach(fun(F) -> feature_valid(F, C) end, Fs)
    end, Templates),
    require(lists:sum([length(Fs) || Fs <- maps:values(Templates)]) =< 200, too_many_templates),
    T = maps:get(thresholds, P),
    require(is_map(T) andalso map_size(T) =:= 2 andalso
            int_range(maps:get(max_distance, T, bad), 0, 15300) andalso
            int_range(maps:get(min_margin, T, bad), 1, 15300), invalid_thresholds),
    Hs = maps:get(used_pcm_hashes, P),
    require(is_list(Hs) andalso length(Hs) >= 4 andalso length(Hs) =< 200 andalso
            lists:all(fun hash_valid/1, Hs) andalso length(lists:usort(Hs)) =:= length(Hs),
            invalid_audio_hashes),
    require(lists:all(fun(F) -> lists:member(pcm_hash(F), Hs) end,
                      lists:append(maps:values(Templates))), missing_template_hash),
    S = maps:get(calibration, P),
    require(is_map(S) andalso map_size(S) =:= 5 andalso
            int_range(maps:get(worst_genuine, S, bad), 0, 15300) andalso
            int_range(maps:get(nearest_impostor, S, bad), 1, 15300) andalso
            int_range(maps:get(minimum_genuine_margin, S, bad), 1, 15300) andalso
            int_range(maps:get(known_count, S, bad), map_size(Templates), 200) andalso
            int_range(maps:get(unknown_count, S, bad), 0, 200), invalid_calibration),
    require(maps:get(worst_genuine, S) < maps:get(nearest_impostor, S) andalso
            maps:get(max_distance, T) =:=
                (maps:get(worst_genuine, S) + maps:get(nearest_impostor, S)) div 2 andalso
            maps:get(min_margin, T) =:= max(1, maps:get(minimum_genuine_margin, S) div 2),
            inconsistent_calibration),
    ok.

feature_valid(F, C) ->
    require(is_map(F) andalso map_size(F) =:= 4, invalid_feature),
    require(maps:get(frontend, F, undefined) =:= ecai_voice_features:version(), frontend_mismatch),
    Q = maps:get(q, F, undefined),
    require(is_list(Q) andalso length(Q) =:= 30, invalid_feature_dimension),
    ExpectedPoints = value(ecai_voice_curve:encode(Q, C)),
    require(maps:get(points, F, undefined) =:= ExpectedPoints, feature_point_mismatch),
    M = maps:get(quality, F, undefined),
    require(is_map(M), invalid_feature_quality),
    require(hash_valid(maps:get(pcm_sha256, M, bad)), invalid_feature_hash),
    Allowed = [sample_rate, channels, selected_channel, seconds, pcm_sha256, file_sha256,
               rms, clipped_fraction, active_seconds_approx, periodic_seconds_approx,
               pitch_median_hz, periodicity_median, saturated_coordinates],
    require((maps:keys(M) -- Allowed) =:= [], unknown_quality_field),
    require(maps:fold(fun(K, V, OK) -> OK andalso case K of
        pcm_sha256 -> hash_valid(V);
        file_sha256 -> hash_valid(V);
        _ -> is_number(V) andalso abs(V) =< 1000000
    end end, true, M), invalid_quality_value).

rows_valid(Rows) ->
    require(is_list(Rows) andalso length(Rows) >= 1 andalso length(Rows) =< 200,
            dataset_must_have_one_to_two_hundred_rows),
    lists:foreach(fun(R) ->
        require(is_map(R) andalso lists:sort(maps:keys(R)) =:= [source, speaker, split], invalid_row),
        L = maps:get(speaker, R),
        Split = maps:get(split, R),
        require(label_valid(L) andalso lists:member(Split, [enroll, calibrate, test]), invalid_label_or_split),
        require(not (L =:= unknown andalso Split =:= enroll), unknown_cannot_be_enrolled),
        require(source_valid(maps:get(source, R)), invalid_source)
    end, Rows).

label_valid(unknown) -> true;
label_valid(B) -> is_binary(B) andalso byte_size(B) >= 1 andalso byte_size(B) =< 64.
source_valid({wav, P}) -> (is_list(P) andalso P =/= []) orelse (is_binary(P) andalso P =/= <<>>);
source_valid({pcm16, B}) -> is_binary(B);
source_valid(_) -> false.

feature(A, C) ->
    F0 = value(ecai_voice_features:extract(maps:get(pcm, A))),
    Quality = maps:merge(maps:get(quality, F0), maps:remove(pcm, A)),
    Points = value(ecai_voice_curve:encode(maps:get(q, F0), C)),
    F0#{quality => Quality, points => Points}.
audio({wav, Path}, Channel) -> value(ecai_voice_wav:read(Path, Channel));
audio({pcm16, PCM}, Channel) when Channel =:= auto; Channel =:= 0 -> value(ecai_voice_wav:pcm(PCM));
audio({pcm16, _}, _) -> fail(raw_pcm_is_mono);
audio(_, _) -> fail(invalid_source).

pcm_hash(F) -> maps:get(pcm_sha256, maps:get(quality, F)).
unique_audio(A, Seen) ->
    H = maps:get(pcm_sha256, A),
    require(not maps:is_key(H, Seen), duplicate_audio_across_dataset),
    Seen#{H => true}.
backend_valid(B) -> require(B =:= curve orelse B =:= integer, invalid_backend).
hash_valid(H) -> is_binary(H) andalso byte_size(H) =:= 32.
int_range(N, L, H) -> is_integer(N) andalso N >= L andalso N =< H.

%% Versioned, uncompressed ETF payload inside a length+SHA256 envelope.
%% Checksum detects accidental damage, NOT malicious modification/authorship.
-spec save(file:filename_all(), map()) -> ok | {error, term()}.
save(Path, Profile) ->
    protect(fun() ->
        profile_valid(Profile, ecai_voice_curve:new()),
        Payload = term_to_binary(Profile, [deterministic]),
        require(byte_size(Payload) =< ?MAX_PROFILE, profile_too_large),
        Hash = crypto:hash(sha256, Payload),
        Envelope = <<"ECV1", (byte_size(Payload)):32/unsigned-big, Hash/binary, Payload/binary>>,
        atomic_write(Path, Envelope)
    end).

-spec load(file:filename_all()) -> {ok, map()} | {error, term()}.
load(Path) ->
    protect(fun() ->
        %% Load schema atoms before safe decoding on a fresh VM.
        {module, ecai_voice_features} = code:ensure_loaded(ecai_voice_features),
        {module, ecai_voice_wav} = code:ensure_loaded(ecai_voice_wav),
        Bin = bounded_read(Path),
        case Bin of
            <<"ECV1", N:32/unsigned-big, Hash:32/binary, Payload:N/binary>> when N =< ?MAX_PROFILE ->
                require(crypto:hash(sha256, Payload) =:= Hash, profile_checksum_mismatch),
                case Payload of
                    <<131, 80, _/binary>> -> fail(compressed_profile_not_allowed);
                    <<131, _/binary>> -> ok;
                    _ -> fail(invalid_profile_encoding)
                end,
                {Profile, Used} = binary_to_term(Payload, [safe, used]),
                require(Used =:= byte_size(Payload), trailing_profile_payload),
                profile_valid(Profile, ecai_voice_curve:new()),
                {ok, Profile};
            _ -> fail(invalid_profile_envelope)
        end
    end).

bounded_read(Path) ->
    Info = value(file:read_file_info(Path)),
    require(Info#file_info.type =:= regular andalso Info#file_info.size =< ?MAX_PROFILE + 40,
            not_regular_or_oversized_profile),
    Fd = value(file:open(Path, [read, binary, raw])),
    try
        case file:read(Fd, ?MAX_PROFILE + 41) of
            {ok, B} when byte_size(B) =< ?MAX_PROFILE + 40 -> B;
            {ok, _} -> fail(profile_too_large);
            eof -> fail(empty_profile);
            {error, R} -> fail({read_profile, R})
        end
    after file:close(Fd) end.

atomic_write(Path0, Bin) ->
    Path = unicode:characters_to_list(Path0),
    ok_value(filelib:ensure_dir(Path)),
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Tmp = Path ++ "." ++ Suffix ++ ".tmp",
    Fd = value(file:open(Tmp, [write, exclusive, binary, raw])),
    try
        %% Apply owner-only permissions before placing any voice template bytes.
        ok_value(file:change_mode(Tmp, 8#600)),
        ok_value(file:write(Fd, Bin)),
        ok_value(file:sync(Fd)),
        ok_value(file:close(Fd)),
        ok_value(file:rename(Tmp, Path)),
        ok
    after
        file:close(Fd),
        file:delete(Tmp)
    end.

value({ok, V}) -> V;
value({error, R}) -> fail(R).
ok_value(ok) -> ok;
ok_value({error, R}) -> fail(R).
require(true, _) -> ok;
require(false, R) -> fail(R).
fail(R) -> throw({voice_error, R}).
protect(Fun) ->
    try Fun()
    catch
        throw:{voice_error, R} -> {error, R};
        error:badarg -> {error, invalid_argument_or_encoding};
        Class:Reason -> {error, {internal_error, Class, Reason}}
    end.
