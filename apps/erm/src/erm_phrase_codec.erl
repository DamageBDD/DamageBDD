%% Bounded protocol/profile boundary for enrolled whole-phrase commands.
%% Never decodes action names into atoms and never stores raw microphone PCM.
-module(erm_phrase_codec).
-include_lib("kernel/include/file.hrl").
-export([actions/0, action_id/1, action/1, command/1, prompt/2, decode/1,
    encode_profile/4, read_profile/2, save_profile/3, load_speaker/2,
    load_speaker_with_fingerprint/2, speaker_file_fingerprint/1,
    model_hash/1, fingerprint/1, validate_samples/1, private_read/2, atomic_write/2]).

-define(MAX_FILE, 1048576).
-define(DIM, 13).

actions() -> [stop_music, pause_music, play_music, next_track, previous_track].
action_id(stop_music) -> 1;
action_id(pause_music) -> 2;
action_id(play_music) -> 3;
action_id(next_track) -> 4;
action_id(previous_track) -> 5;
action_id(_) -> error(bad_phrase_action).
action(1) -> stop_music;
action(2) -> pause_music;
action(3) -> play_music;
action(4) -> next_track;
action(5) -> previous_track;
action(0) -> undefined;
action(_) -> error(bad_phrase_action).
command(stop_music) -> <<"stop">>;
command(pause_music) -> <<"pause">>;
command(play_music) -> <<"play">>;
command(next_track) -> <<"next">>;
command(previous_track) -> <<"previous">>.
prompt(Action, Wake) ->
    Tail = case Action of
        stop_music -> <<"stop music">>; pause_music -> <<"pause music">>;
        play_music -> <<"play music">>; next_track -> <<"next track">>;
        previous_track -> <<"previous track">>
    end,
    <<Wake/binary, " ", Tail/binary>>.

-spec decode(binary()) -> {ok, map()} | {error, invalid_phrase_packet}.
decode(<<"P", Epoch:64, Id:64, Ms:32, Dim:16,
    Rms:32/float-big, Peak:32/float-big, Clip:32/float-big, Gain:32/float-big, Rest/binary>>)
    when Dim =< 4096, Ms > 0, Ms =< 8000,
         Rms >= -120, Rms =< 1, Peak >= -120, Peak =< 1,
         Clip >= 0, Clip =< 1, Gain >= -24, Gain =< 12 ->
    try
        <<Embedding:(Dim*4)/binary, Rev:64, Reason:8, Code:8,
            Distance:32/float-big, Margin:32/float-big,
            1:8, Frames:16, ?DIM:8, Features/binary>> = Rest,
        true = Reason =< 4 andalso Code =< 5 andalso (Reason =/= 0 orelse Code > 0),
        true = Distance >= 0 andalso Distance =< 1000 andalso Margin >= 0 andalso Margin =< 1000,
        true = Frames =< 160,
        true = valid_floats(Embedding, Dim, 1000000.0),
        true = valid_floats(Features, Frames * ?DIM, 64.0),
        {ok, #{epoch => Epoch, id => Id, ms => Ms, revision => Rev,
            embedding => [F || <<F:32/float-big>> <= Embedding],
            quality => #{rms_dbfs => Rms, peak_dbfs => Peak, clipped_fraction => Clip, input_gain_db => Gain},
            result => #{reason => reason(Reason), action => action(Code), distance => Distance, margin => Margin},
            sample => #{ms => Ms, frames => Frames, features => Features}}}
    catch _:_ -> {error, invalid_phrase_packet} end;
decode(_) -> {error, invalid_phrase_packet}.
reason(0) -> matched;
reason(1) -> no_eligible_templates;
reason(2) -> too_far;
reason(3) -> ambiguous;
reason(4) -> no_features.

valid_floats(B, N, Limit) when byte_size(B) =:= N*4 ->
    Fs = [F || <<F:32/float-big>> <= B],
    length(Fs) =:= N andalso lists:all(fun(F) -> abs(F) =< Limit end, Fs);
valid_floats(_, _, _) -> false.

-spec validate_samples(list()) -> ok | {error, invalid_phrase_samples}.
validate_samples(Samples) ->
    try
        true = is_list(Samples) andalso length(Samples) =< 25,
        lists:foreach(fun(#{action := A, ms := Ms, frames := N, features := F} = S) ->
            _ = action_id(A),
            true = maps:size(S) =:= 4,
            true = is_integer(Ms) andalso Ms >= 250 andalso Ms =< 8000,
            true = is_integer(N) andalso N >= 1 andalso N =< 160,
            true = is_binary(F) andalso valid_floats(F, N*?DIM, 64.0)
        end, Samples),
        lists:foreach(fun(A) ->
            Count = length([ok || #{action := X} <- Samples, X =:= A]),
            true = Count =:= 0 orelse (Count >= 3 andalso Count =< 5)
        end, actions()),
        ok
    catch _:_ -> {error, invalid_phrase_samples} end.

body(Samples) ->
    ok = validate_samples(Samples),
    Encoded = [begin
        #{action := A, ms := Ms, frames := N, features := F} = S,
        <<(action_id(A)):8, Ms:32, N:16, F/binary>>
    end || S <- Samples],
    iolist_to_binary([<<(length(Samples)):16>>, Encoded]).

-spec encode_profile(non_neg_integer(), number(), number(), list()) -> binary().
encode_profile(Rev, Radius, Margin, Samples)
    when is_integer(Rev), Rev >= 0, Rev < 18446744073709551616,
         is_number(Radius), Radius >= 0.01, Radius =< 5,
         is_number(Margin), Margin >= 0.001, Margin =< 5 ->
    B = body(Samples),
    <<"L", Rev:64, (float(Radius)):32/float-big, (float(Margin)):32/float-big, B/binary>>.

parse_body(<<Count:16, Rest/binary>>) when Count =< 25 ->
    {Samples, <<>>} = parse_samples(Count, Rest, []),
    ok = validate_samples(Samples), Samples.
parse_samples(0, B, Acc) -> {lists:reverse(Acc), B};
parse_samples(N, <<Code:8, Ms:32, Frames:16, Rest/binary>>, Acc)
    when Code >= 1, Code =< 5, Frames >= 1, Frames =< 160 ->
    Size = Frames * ?DIM * 4,
    <<F:Size/binary, Tail/binary>> = Rest,
    parse_samples(N-1, Tail, [#{action => action(Code), ms => Ms, frames => Frames, features => F} | Acc]).

fingerprint(#{ms := Ms, frames := N, features := F}) ->
    crypto:hash(sha256, <<Ms:32, N:16, F/binary>>).

-spec read_profile(file:filename_all(), binary()) -> {ok, list()} | {error, term()}.
read_profile(Path, Binding) when is_binary(Binding), byte_size(Binding) =:= 32 ->
    case private_read(Path, ?MAX_FILE) of
        {error, enoent} -> {ok, []};
        {ok, <<"EPH", 1, Stored:32/binary, Size:32, Rest/binary>>} when Size =< ?MAX_FILE ->
            try
                true = Stored =:= Binding,
                <<Body:Size/binary, Digest:32/binary>> = Rest,
                Prefix = <<"EPH", 1, Stored/binary, Size:32, Body/binary>>,
                true = crypto:hash(sha256, Prefix) =:= Digest,
                {ok, parse_body(Body)}
            catch _:_ -> {error, phrase_profile_invalid_or_different_speaker_device} end;
        {ok, _} -> {error, invalid_phrase_profile};
        Error -> Error
    end.

-spec save_profile(file:filename_all(), binary(), list()) -> ok | {error, term()}.
save_profile(Path, Binding, Samples) when is_binary(Binding), byte_size(Binding) =:= 32 ->
    try
        Body = body(Samples),
        Prefix = <<"EPH", 1, Binding/binary, (byte_size(Body)):32, Body/binary>>,
        atomic_write(Path, <<Prefix/binary, (crypto:hash(sha256, Prefix))/binary>>)
    catch C:R -> {error, {phrase_profile_save, C, R}} end.

%% A trusted local native-speaker profile, not ECAI's separate speaker POC file.
%% Preserve load_speaker/2's original return value and phrase-binding format.
load_speaker(Path, ExpectedHash) ->
    case load_speaker_with_fingerprint(Path, ExpectedHash) of
        {ok, Speaker, _Fingerprint} -> {ok, Speaker};
        Error -> Error
    end.

load_speaker_with_fingerprint(Path, ExpectedHash) ->
    case private_read(Path, 65536) of
        {ok, <<131, 80, _/binary>>} -> {error, compressed_speaker_profile_not_supported};
        {ok, B} ->
            try
                {module,erm_voice_calibration}=code:ensure_loaded(erm_voice_calibration),
                #{version := 1, model_hash := ExpectedHash, label := Label, embedding := V} = P = binary_to_term(B, [safe]),
                true = is_binary(Label) andalso byte_size(Label) >= 1 andalso byte_size(Label) =< 128,
                true = is_list(V) andalso length(V) >= 1 andalso length(V) =< 4096,
                true = lists:all(fun(X) -> is_number(X) andalso abs(X) =< 1000000 end, V),
                {ok, Normal} = erm_native_voice:normalise(V),
                case maps:get(voice_calibration,P,undefined) of
                    undefined->ok;Calibration->ok=erm_voice_calibration:validate(Calibration)
                end,
                {ok, P#{embedding => Normal}, erm_native_voice:profile_fingerprint(B)}
            catch _:_ -> {error, invalid_or_stale_native_speaker_profile} end;
        Error -> Error
    end.

%% Secure bounded disk read, for checking that an already loaded profile
%% has not been replaced. Never emit embedding bytes into status or logs.
speaker_file_fingerprint(Path) ->
    case private_read(Path, 65536) of
        {ok, Bytes} -> {ok, erm_native_voice:profile_fingerprint(Bytes)};
        Error -> Error
    end.

model_hash(Path) ->
    {ok, F} = file:open(Path, [read, binary, raw]),
    try hash_chunks(F, crypto:hash_init(sha256)) after file:close(F) end.
hash_chunks(F, Context) ->
    case file:read(F, 1048576) of
        {ok, B} -> hash_chunks(F, crypto:hash_update(Context, B));
        eof -> crypto:hash_final(Context);
        {error, R} -> error({model_read, R})
    end.

private_read(Path, Max) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size, mode = Mode, inode = Inode, major_device = Dev}}
            when Size =< Max, Mode band 8#077 =:= 0 ->
            case file:open(Path, [read, binary, raw]) of
                {ok, F} ->
                    try
                        case file:read_file_info(F) of
                            {ok, #file_info{type = regular, inode = Inode, major_device = Dev}} ->
                                case file:read(F, Max+1) of
                                    {ok, B} when byte_size(B) =< Max -> {ok, B};
                                    eof -> {ok, <<>>};
                                    _ -> {error, profile_too_large_or_unreadable}
                                end;
                            _ -> {error, profile_changed_during_open}
                        end
                    after file:close(F) end;
                Error -> Error
            end;
        {ok, _} -> {error, profile_must_be_private_regular_file};
        Error -> Error
    end.

atomic_write(Path, B) ->
    absolute = filename:pathtype(Path),
    Dir = filename:dirname(Path),
    case file:read_link_info(Dir) of
        {error, enoent} ->
            ok = filelib:ensure_dir(filename:join(Dir, "unused")),
            ok = file:change_mode(Dir, 8#700);
        {ok, #file_info{type = directory, mode = Mode}} when Mode band 8#077 =:= 0 -> ok;
        _ -> error(phrase_directory_must_be_private)
    end,
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, #file_info{type = regular, mode = M}} when M band 8#077 =:= 0 -> ok;
        _ -> error(unsafe_phrase_profile_destination)
    end,
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Temp = Path ++ ".tmp." ++ Suffix,
    try
        {ok, F} = file:open(Temp, [write, binary, raw, exclusive]),
        try
            ok = file:change_mode(Temp, 8#600),
            ok = file:write(F, B), ok = file:sync(F)
        after file:close(F) end,
        ok = file:rename(Temp, Path), ok
    after _ = file:delete(Temp) end.
