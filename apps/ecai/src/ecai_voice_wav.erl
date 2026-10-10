%%% Strict, bounded PCM16-LE reader. No external process, codec or resampler.
-module(ecai_voice_wav).
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-export([read/1, read/2, decode/1, decode/2, pcm/1, encode_mono/1, write/2]).

-define(MAX_FILE, 4 * 1024 * 1024).
-define(MAX_PCM, 16000 * 2 * 30).

-spec read(file:filename_all()) -> {ok, map()} | {error, term()}.
read(Path) -> read(Path, auto).
-spec read(file:filename_all(), auto | 0 | 1) -> {ok, map()} | {error, term()}.
read(Path, Channel) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_FILE ->
            %% Bound the read itself, not only the preceding stat (file may grow).
            case file:open(Path, [read, binary, raw]) of
                {ok, Fd} ->
                    try
                        case file:read(Fd, ?MAX_FILE + 1) of
                            {ok, Bin} when byte_size(Bin) =< ?MAX_FILE -> decode(Bin, Channel);
                            {ok, _} -> {error, wav_too_large};
                            eof -> {error, empty_wav};
                            {error, R} -> {error, {read_failed, R}}
                        end
                    after file:close(Fd) end;
                {error, R} -> {error, {open_failed, R}}
            end;
        {ok, _} -> {error, not_regular_or_oversized_wav};
        {error, R} -> {error, {file_error, R}}
    end.

-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(Bin) -> decode(Bin, auto).
-spec decode(binary(), auto | 0 | 1) -> {ok, map()} | {error, term()}.
decode(Bin, Channel) when is_binary(Bin), byte_size(Bin) =< ?MAX_FILE,
                          (Channel =:= auto orelse Channel =:= 0 orelse Channel =:= 1) ->
    case Bin of
        <<"RIFF", Size:32/little-unsigned, "WAVE", Rest/binary>>
          when Size =:= byte_size(Rest) + 4 ->
            case chunks(Rest, undefined, undefined) of
                {ok, Fmt, Data} -> select(Fmt, Data, Channel, crypto:hash(sha256, Bin));
                Error -> Error
            end;
        _ -> {error, malformed_riff_wave}
    end;
decode(_, _) -> {error, invalid_wav_or_channel}.

chunks(<<>>, undefined, _) -> {error, missing_format};
chunks(<<>>, _, undefined) -> {error, missing_data};
chunks(<<>>, Fmt, Data) -> {ok, Fmt, Data};
chunks(<<Tag:4/binary, Size:32/little-unsigned, Tail/binary>>, Fmt, Data) ->
    Pad = Size band 1,
    case Tail of
        <<Body:Size/binary, _Padding:Pad/binary, Rest/binary>> ->
            case {Tag, Fmt, Data} of
                {<<"fmt ">>, undefined, _} -> chunks(Rest, Body, Data);
                {<<"fmt ">>, _, _} -> {error, duplicate_format};
                {<<"data">>, _, undefined} -> chunks(Rest, Fmt, Body);
                {<<"data">>, _, _} -> {error, duplicate_data};
                _ -> chunks(Rest, Fmt, Data)
            end;
        _ -> {error, truncated_wav_chunk}
    end;
chunks(_, _, _) -> {error, truncated_chunk_header}.

select(<<1:16/little, Channels:16/little, 16000:32/little, ByteRate:32/little,
         Align:16/little, 16:16/little, Extra/binary>>, Data, Channel, Hash)
  when (Channels =:= 1 orelse Channels =:= 2), ByteRate =:= 32000 * Channels,
       Align =:= 2 * Channels, (Extra =:= <<>> orelse Extra =:= <<0, 0>>) ->
    case byte_size(Data) > 0 andalso byte_size(Data) rem Align =:= 0 andalso
         byte_size(Data) div Channels =< ?MAX_PCM of
        false -> {error, empty_misaligned_or_long_audio};
        true when Channel =:= 1, Channels =:= 1 -> {error, channel_not_present};
        true ->
            {Mono, Selected} = mono(Data, Channels, Channel),
            {ok, A} = pcm(Mono),
            {ok, A#{file_sha256 => Hash, channels => Channels, selected_channel => Selected}}
    end;
select(<<_Format:16/little, _Channels:16/little, Rate:32/little, _/binary>>, _, _, _)
  when Rate =/= 16000 -> {error, {unsupported_sample_rate, Rate, 16000}};
select(_, _, _, _) -> {error, unsupported_wav_format}.

mono(Data, 1, _) -> {Data, 0};
mono(Data, 2, Channel) ->
    Left = << <<L:16/little-signed>> || <<L:16/little-signed, _:16/little-signed>> <= Data >>,
    Right = << <<R:16/little-signed>> || <<_:16/little-signed, R:16/little-signed>> <= Data >>,
    Selected = case Channel of
        auto -> case variance(Right) > variance(Left) of true -> 1; false -> 0 end;
        C -> C
    end,
    case Selected of 0 -> {Left, 0}; 1 -> {Right, 1} end.

variance(Bin) ->
    N = byte_size(Bin) div 2,
    {Sum, Sq} = stats(Bin, 0, 0),
    %% Same channel length: compare exact N*sum(x*x)-sum(x)^2; no cancellation.
    N * Sq - Sum * Sum.
stats(<<>>, S, Q) -> {S, Q};
stats(<<X:16/little-signed, Rest/binary>>, S, Q) -> stats(Rest, S + X, Q + X * X).

-spec pcm(binary()) -> {ok, map()} | {error, term()}.
pcm(Bin) when is_binary(Bin), byte_size(Bin) > 0,
              byte_size(Bin) rem 2 =:= 0, byte_size(Bin) =< ?MAX_PCM ->
    {ok, #{pcm => Bin, sample_rate => 16000, channels => 1, selected_channel => 0,
           seconds => byte_size(Bin) / 32000,
           pcm_sha256 => crypto:hash(sha256, <<"ECAI:VOICE:PCM16LE:16000:V1", Bin/binary>>)}};
pcm(_) -> {error, invalid_pcm16_or_duration}.

-spec encode_mono(binary()) -> {ok, binary()} | {error, term()}.
encode_mono(PCM) ->
    case pcm(PCM) of
        {ok, _} ->
            N = byte_size(PCM),
            {ok, <<"RIFF", (36 + N):32/little, "WAVEfmt ", 16:32/little,
                   1:16/little, 1:16/little, 16000:32/little, 32000:32/little,
                   2:16/little, 16:16/little, "data", N:32/little, PCM/binary>>};
        Error -> Error
    end.
-spec write(file:filename_all(), binary()) -> ok | {error, term()}.
write(Path, PCM) ->
    case encode_mono(PCM) of {ok, Bin} -> file:write_file(Path, Bin); Error -> Error end.
