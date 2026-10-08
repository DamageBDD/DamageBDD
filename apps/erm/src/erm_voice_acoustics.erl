%% Live acoustic configuration and numeric diagnostics; no profile mutation.
-module(erm_voice_acoustics).
-export([defaults/1, keys/0, audio_keys/0, validate/2, reload_options/1, measurement/4]).

defaults(O) -> maps:merge(#{input_gain_db => 0.0, vad_threshold => 0.5,
    min_speech_ms => 250, enrolment_threshold => maps:get(speaker_threshold, O, 0.7)}, O).
audio_keys() -> [input_gain_db, vad_threshold, silence_ms, min_speech_ms, max_segment_ms].
keys() -> audio_keys() ++ [speaker_threshold, enrolment_threshold, min_speaker_ms,
    observe_only, debug_utterances, require_speaker, trigger_phrases].

validate(Input, Current) ->
    try
        Changes = options(Input),
        case maps:keys(Changes) -- keys() of
            [] -> ok;
            Unknown -> throw({unsupported_live_options, lists:sort(Unknown)})
        end,
        O = maps:merge(defaults(Current), Changes),
        [range(K, O, Lo, Hi, Type) || {K, Lo, Hi, Type} <- [
            {input_gain_db, -24, 12, number}, {vad_threshold, 0.05, 0.95, number},
            {speaker_threshold, 0.01, 0.99, number},
            {enrolment_threshold, 0.01, 0.99, number},
            {silence_ms, 200, 2000, integer}, {min_speech_ms, 100, 2000, integer},
            {max_segment_ms, 2000, 15000, integer}, {min_speaker_ms, 500, 15000, integer}]],
        [case is_boolean(maps:get(K, O)) of true -> ok; false -> throw({invalid_option, K}) end
            || K <- [observe_only, debug_utterances, require_speaker]],
        case maps:get(min_speaker_ms, O) < maps:get(max_segment_ms, O) andalso
            maps:get(min_speech_ms, O) < maps:get(max_segment_ms, O) of
            true -> ok;
            false -> throw(invalid_audio_durations)
        end,
        Phrases = maps:get(trigger_phrases, O),
        true = is_list(Phrases) andalso length(Phrases) > 0 andalso length(Phrases) =< 32,
        [begin B = unicode:characters_to_binary(P),
            true = is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< 128
        end || P <- Phrases],
        {ok, O}
    catch throw:Reason -> {error, Reason}; _:_ -> {error, invalid_live_options} end.

range(K, O, Lo, Hi, Type) ->
    V = maps:get(K, O),
    Valid = case Type of integer -> is_integer(V); number -> is_number(V) end,
    case Valid andalso V >= Lo andalso V =< Hi of
        true -> ok;
        false -> throw({invalid_option, K})
    end.
options(M) when is_map(M) -> M;
options(L) when is_list(L) ->
    true = lists:all(fun({K, _}) -> is_atom(K); (_) -> false end, L),
    proplists:to_map(L).

%% /0 uses application env. /1 explicitly consults one sys.config file.
%% Neither executes config scripts nor reloads unrelated applications.
reload_options(env) ->
    extract(application:get_env(erm, whisper_trigger, []));
reload_options(File) ->
    case file:consult(File) of
        {ok, [Config]} when is_list(Config) ->
            try
                Erm = options(proplists:get_value(erm, Config, [])),
                extract(maps:get(whisper_trigger, Erm))
            catch _:_ -> {error, missing_whisper_trigger} end;
        {ok, _} -> {error, invalid_sys_config};
        {error, Reason} -> {error, {config_file, Reason}}
    end.
extract(W0) ->
    try
        W = options(W0),
        true = maps:get(enabled, W, true),
        native = maps:get(backend, W, native),
        N = options(maps:get(native, W)),
        {ok, N#{trigger_phrases => maps:get(trigger_phrases, W, ["bob"])}}
    catch _:_ -> {error, invalid_native_config} end.

measurement(#{id := Id, ms := Ms, embedding := V, text := Text} = U, Dim, Profile, O) ->
    Threshold = maps:get(speaker_threshold, O),
    Base = #{id => Id, audio_ms => Ms, threshold => Threshold,
        min_audio_ms => maps:get(min_speaker_ms, O), embedding_dim => length(V),
        quality => maps:get(quality, U, unavailable),
        wake_detected => case erm_voice_boundary:wake(Text, maps:get(trigger_phrases, O)) of
            {wake, _} -> true; _ -> false end},
    case Ms >= maps:get(min_speaker_ms, O) andalso length(V) =:= Dim of
        false -> Base#{accepted => false, reason => insufficient_audio, score => undefined};
        true ->
            case erm_native_voice:normalise(V) of
                {ok, N} ->
                    case Profile of
                        #{embedding := Known} ->
                            Score = erm_native_voice:score(N, Known),
                            Base#{score => Score, margin => Score - Threshold,
                                accepted => Score >= Threshold,
                                reason => case Score >= Threshold of true -> matched; false -> speaker_mismatch end};
                        _ -> Base#{score => undefined, accepted => false, reason => not_enrolled}
                    end;
                _ -> Base#{score => undefined, accepted => false, reason => invalid_embedding}
            end
    end.
