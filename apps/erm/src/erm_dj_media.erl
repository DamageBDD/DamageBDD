%% Private ECDJ media cache. Only release-licensed audio reaches the ERM player.
%% ZIP parsing deliberately supports a small, bounded subset: stored/deflated
%% files, single disk, no ZIP64, encryption, links, or archive-directed paths.
-module(erm_dj_media).
-include_lib("kernel/include/file.hrl").
-export([prepare_release/3, prepare_archive/4, play/1, permitted/2, verify_track/1]).

-define(MIB, 1048576).

prepare_release(Release, CacheDir, Opts) ->
    guarded(fun() ->
        ok = allowed(Release, Opts),
        Limits = limits(Opts),
        Downloads = maps:get(downloads, Release, []),
        URLs = [U || #{url := U, format := zip} <- Downloads],
        URL = case URLs of [First | _] -> First; [] -> fail(no_archive_download) end,
        Archive = require(erm_dj_http:get(URL, #{max_bytes => maps:get(archive, Limits),
                                             timeout => 30000})),
        prepare(Release, Archive, CacheDir, Opts)
    end).

%% Public for offline import/testing. Release is metadata from a trusted source
%% adapter, never an NFT payload. Neither archive paths nor executable content
%% are installed. Licence and all extraction limits are checked here as well.
prepare_archive(Release, Archive, CacheDir, Opts) ->
    guarded(fun() -> prepare(Release, Archive, CacheDir, Opts) end).

permitted(Release, Opts) -> guarded(fun() -> allowed(Release, Opts) end).

allowed(#{license := #{url := URL}, source_url := Source,
          license_evidence := #{page_url := Source, html_sha256 := EvidenceHash}}, Opts)
  when is_binary(URL), is_binary(Source), is_map(Opts) ->
    _ = require(erm_dj_http:validate_url(Source)),
    check(is_binary(EvidenceHash) andalso is_hex(binary_to_list(EvidenceHash)), missing_licence_evidence),
    case re:run(URL, <<"^https?://creativecommons\\.org/licenses/(by|by-sa|by-nd|by-nc|by-nc-sa|by-nc-nd)/(1\\.0|2\\.0|2\\.5|3\\.0|4\\.0)/?$">>,
                [{capture, [1], binary}]) of
        {match, [Kind]} ->
            Commercial = maps:get(commercial, Opts, false),
            case is_boolean(Commercial) of true -> ok; false -> fail(invalid_commercial_option) end,
            case Commercial andalso binary:match(Kind, <<"nc">>) =/= nomatch of
                true -> fail(noncommercial_licence); false -> ok
            end;
        _ -> fail(unknown_licence)
    end;
allowed(_, _) -> fail(missing_licence).

prepare(Release, Archive, CacheDir0, Opts) when is_binary(Archive), is_map(Opts) ->
    ok = allowed(Release, Opts),
    Limits = limits(Opts),
    check(byte_size(Archive) =< maps:get(archive, Limits), archive_too_large),
    Entries = directory(Archive, Limits),
    Audio = [E || E <- Entries, is_audio(maps:get(name, E))],
    check(Audio =/= [], no_audio_files),
    Root = cache_dir(CacheDir0),
    %% A changed source assertion, attribution or descriptor set must never
    %% revive a cache manifest carrying stale metadata for identical bytes.
    ReleaseHash = hex(crypto:hash(sha256, term_to_binary(maps:with(
        [id,source_url,license,license_evidence,title,artist,tags],Release)))),
    ArchiveHash = hex(crypto:hash(sha256, Archive)),
    Key = hex(crypto:hash(sha256, <<ReleaseHash/binary, ArchiveHash/binary>>)),
    Target = filename:join(Root, binary_to_list(Key)),
    case file:read_link_info(Target) of
        {ok, #file_info{type = directory}} ->
            load_cache(Target, Root, ReleaseHash, ArchiveHash);
        {error, enoent} ->
            Stage = Target ++ ".part-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
            require(file:make_dir(Stage)), require(file:change_mode(Stage, 8#700)),
            try
                Tracks = extract_audio(Audio, Archive, Release, Stage, Target, Root, Limits, []),
                Marker = #{version => 1, release_hash => ReleaseHash,
                           archive_hash => ArchiveHash, tracks => Tracks},
                MarkerBinary = term_to_binary(Marker),
                require(file:write_file(filename:join(Stage, "manifest.term"), MarkerBinary,
                                        [binary, exclusive, sync])),
                case file:rename(Stage, Target) of
                    ok -> ok;
                    {error, eexist} -> cleanup(Stage);
                    {error, enotempty} -> cleanup(Stage);
                    {error, Reason} -> fail({cache_commit, Reason})
                end,
                load_cache(Target, Root, ReleaseHash, ArchiveHash)
            after cleanup(Stage) end;
        {ok, _} -> fail(unsafe_cache_entry);
        {error, Reason} -> fail({cache_directory, Reason})
    end;
prepare(_, _, _, _) -> fail(invalid_media_input).

limits(Opts) when is_map(Opts) ->
    #{archive => bounded(max_archive_bytes, Opts, 256*?MIB, 256*?MIB),
      audio => bounded(max_audio_bytes, Opts, 64*?MIB, 128*?MIB),
      total => bounded(max_total_bytes, Opts, 256*?MIB, 512*?MIB),
      entries => bounded(max_entries, Opts, 512, 2048),
      ratio => bounded(max_ratio, Opts, 20, 100)};
limits(_) -> fail(invalid_options).
bounded(Key, Opts, Default, Max) ->
    case maps:get(Key, Opts, Default) of
        N when is_integer(N), N > 0, N =< Max -> N;
        _ -> fail({invalid_limit, Key})
    end.

%% Reject malformed directories before inflating anything. Every entry counts
%% towards the limits, including artwork/text that will never be extracted.
directory(Bin, Limits) ->
    Size = byte_size(Bin),
    Start = max(0, Size - 65557),
    Tail = binary:part(Bin, Start, Size - Start),
    Matches = binary:matches(Tail, <<16#50,16#4b,5,6>>),
    Pos = case Matches of [] -> fail(not_zip); _ -> Start + element(1, lists:last(Matches)) end,
    EOCD = binary:part(Bin, Pos, Size-Pos),
    case EOCD of
        <<16#06054b50:32/little, 0:16, 0:16, N:16/little, N:16/little,
          CDSz:32/little, CDOff:32/little, CommentSz:16/little, Comment/binary>>
          when N < 65535, CDSz < 16#ffffffff, CDOff < 16#ffffffff,
               byte_size(Comment) =:= CommentSz, CDOff + CDSz =:= Pos ->
            check(N =< maps:get(entries, Limits), too_many_archive_entries),
            CD = binary:part(Bin, CDOff, CDSz),
            Entries = central(CD, N, CDOff, []),
            Names = [maps:get(name,E) || E <- Entries],
            check(length(Names) =:= length(lists:usort(Names)), duplicate_archive_name),
            Total = lists:sum([maps:get(size,E) || E <- Entries]),
            check(Total =< maps:get(total,Limits), archive_expansion_limit),
            lists:foreach(fun(E) -> validate_entry(E, Limits) end, Entries),
            Entries;
        _ -> fail(unsupported_zip_directory)
    end.

central(<<>>, 0, _CDOff, Acc) -> lists:reverse(Acc);
central(<<16#02014b50:32/little, _Made:16/little, _Need:16/little,
          Flags:16/little, Method:16/little, _Time:16/little, _Date:16/little,
          CRC:32/little, Comp:32/little, Size:32/little, NSz:16/little,
          ESz:16/little, CSz:16/little, Disk:16/little, _IA:16/little,
          Attr:32/little, Offset:32/little, Rest/binary>>, N, CDOff, Acc) when N > 0 ->
    case Rest of
        <<Name:NSz/binary, _Extra:ESz/binary, _Comment:CSz/binary, More/binary>> ->
            check(Disk =:= 0 andalso Comp < 16#ffffffff andalso Size < 16#ffffffff
                  andalso Offset < CDOff, unsupported_zip_entry),
            Entry = #{name=>Name, flags=>Flags, method=>Method, crc=>CRC,
                      compressed=>Comp, size=>Size, offset=>Offset, attr=>Attr,
                      cd_offset=>CDOff},
            central(More, N-1, CDOff, [Entry|Acc]);
        _ -> fail(truncated_zip_directory)
    end;
central(_, _, _, _) -> fail(malformed_zip_directory).

validate_entry(E, Limits) ->
    Name = maps:get(name,E), Size = maps:get(size,E), Comp = maps:get(compressed,E),
    ModeType = (maps:get(attr,E) bsr 16) band 8#170000,
    check(ModeType =:= 0 orelse ModeType =:= 8#100000 orelse ModeType =:= 8#040000,
          archive_link_or_special_file),
    check(valid_name(Name), unsafe_archive_path),
    check((maps:get(flags,E) band 1) =:= 0, encrypted_archive),
    check(lists:member(maps:get(method,E), [0,8]), unsupported_zip_method),
    check(Size =< maps:get(audio,Limits), archive_file_too_large),
    check(Size =< max(1,Comp) * maps:get(ratio,Limits), archive_compression_ratio).

valid_name(Name) when is_binary(Name), byte_size(Name)>0, byte_size(Name)=<1024 ->
    Parts = binary:split(Name, <<"/">>, [global]),
    NoDot = lists:all(fun(P)-> P=/= <<"..">> andalso P=/= <<".">> end,Parts),
    NoControl = not lists:any(fun(C)->C<32 orelse C=:=127 end,binary_to_list(Name)),
    NoDot andalso NoControl andalso binary:first(Name)=/=$/ andalso
      binary:match(Name, <<"\\">>)=:=nomatch andalso binary:match(Name, <<":">>)=:=nomatch;
valid_name(_) -> false.

is_audio(Name) -> lists:member(string:lowercase(filename:extension(binary_to_list(Name))),
                             [".mp3",".flac",".ogg",".opus",".wav",".m4a"]).

%% Conservative container signatures only, not a codec validator/sandbox. In
%% particular, a licence-page HTML response or M3U named .mp3 is not audio.
audio_format(Name) ->
    case string:lowercase(filename:extension(binary_to_list(Name))) of
        ".mp3" -> <<"mp3">>;
        ".flac" -> <<"flac">>;
        ".ogg" -> <<"ogg">>;
        ".opus" -> <<"ogg">>;
        ".wav" -> <<"wav">>;
        ".m4a" -> <<"mov">>
    end.
valid_audio(<<"mp3">>, <<"ID3",V,_Rev,Flags,A,B,C,D,Rest/binary>>) when V>=2,V=<4 ->
    case ((A bor B bor C bor D) band 128)=:=0 of
        true ->
            TagSize=(A bsl 21)+(B bsl 14)+(C bsl 7)+D,
            Footer=case V=:=4 andalso (Flags band 16)=/=0 of true->10;false->0 end,
            Skip=TagSize+Footer,
            case Rest of <<_:Skip/binary,Frames/binary>> -> mp3_frame(Frames); _ -> false end;
        false -> false
    end;
valid_audio(<<"mp3">>, B) -> mp3_frame(B);
valid_audio(<<"flac">>, <<"fLaC",_:32,_/binary>>) -> true;
valid_audio(<<"ogg">>, <<"OggS",0,_/binary>>) -> true;
valid_audio(<<"wav">>, <<"RIFF",Sz:32/little,"WAVE",Tail/binary>>) -> Sz>=4 andalso Sz=<4+byte_size(Tail);
valid_audio(<<"mov">>, <<Sz:32/big,"ftyp",_:8/binary,Tail/binary>>) -> Sz>=16 andalso Sz=<16+byte_size(Tail);
valid_audio(_,_) -> false.
mp3_frame(<<255,B,C,_D,_/binary>>) ->
    (B band 16#e0)=:=16#e0 andalso ((B bsr 3) band 3)=/=1 andalso
    ((B bsr 1) band 3)=/=0 andalso ((C bsr 4) band 15)>0 andalso
    ((C bsr 4) band 15)<15 andalso ((C bsr 2) band 3)=/=3;
mp3_frame(_) -> false.

extract_audio([], _Archive, _Release, _Stage, _Target, _Root, _Limits, Acc) -> lists:reverse(Acc);
extract_audio([E|Rest], Archive, Release, Stage, Target, Root, Limits, Acc) ->
    Data = extract_entry(E, Archive, Limits),
    Format = audio_format(maps:get(name,E)),
    check(valid_audio(Format,Data), invalid_audio_signature),
    Digest = hex(crypto:hash(sha256,Data)),
    Name = maps:get(name,E),
    %% Generated names ensure even Unicode oddities in archive names never
    %% become installation paths. Preserve original name only as metadata.
    Id = hex(crypto:hash(sha256, <<(maps:get(id,Release))/binary, Name/binary, Digest/binary>>)),
    File = binary_to_list(Id) ++ string:lowercase(filename:extension(binary_to_list(Name))),
    require(file:write_file(filename:join(Stage,File),Data,[binary,exclusive,sync])),
    require(file:change_mode(filename:join(Stage,File),8#600)),
    Track = #{id=>Id, title=>unicode:characters_to_binary(filename:rootname(filename:basename(binary_to_list(Name)))),
              artist=>maps:get(artist,Release,<<"Unknown artist">>),
              album=>maps:get(title,Release,<<>>), archive_name=>Name,
              source=>ektoplazm, source_url=>maps:get(source_url,Release),
              license=>maps:get(license,Release),
              license_evidence=>maps:get(license_evidence,Release,#{}),
              tags=>maps:get(tags,Release,[]), release_id=>maps:get(id,Release),
              sha256=>Digest, bytes=>byte_size(Data), media_format=>Format, cache_root=>Root,
              local_path=>filename:join(Target,File)},
    extract_audio(Rest,Archive,Release,Stage,Target,Root,Limits,[Track|Acc]).

extract_entry(E, Bin, Limits) ->
    Offset = maps:get(offset,E),
    Local = binary:part(Bin,Offset,byte_size(Bin)-Offset),
    case Local of
        <<16#04034b50:32/little, _Need:16/little, Flags:16/little,
          Method:16/little, _Time:16/little, _Date:16/little,
          _CRC:32/little, _Comp:32/little, _Size:32/little,
          NSz:16/little, ESz:16/little, Rest/binary>> ->
            check(Flags=:=maps:get(flags,E) andalso Method=:=maps:get(method,E), zip_header_mismatch),
            Comp = maps:get(compressed,E),
            check(Offset+30+NSz+ESz+Comp =< maps:get(cd_offset,E), overlapping_zip_entry),
            case Rest of
                <<Name:NSz/binary, _Extra:ESz/binary, Compressed:Comp/binary, _/binary>> ->
                    check(Name=:=maps:get(name,E), zip_name_mismatch),
                    Cap = min(maps:get(size,E),maps:get(audio,Limits)),
                    Data = case Method of 0 -> Compressed; 8 -> inflate(Compressed,Cap) end,
                    check(byte_size(Data)=:=maps:get(size,E), zip_size_mismatch),
                    check(erlang:crc32(Data)=:=maps:get(crc,E), zip_crc_mismatch),
                    Data;
                _ -> fail(truncated_zip_file)
            end;
        _ -> fail(malformed_zip_header)
    end.

inflate(Data, Cap) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z,-15),
        Parts = inflate_loop(Z,zlib:safeInflate(Z,Data),Cap,0,[]),
        ok = zlib:inflateEnd(Z),
        iolist_to_binary(lists:reverse(Parts))
    after zlib:close(Z) end.
inflate_loop(Z,{Status,Output},Cap,N,Acc) when Status=:=continue; Status=:=finished ->
    N1 = N+iolist_size(Output), check(N1=<Cap, inflated_audio_limit),
    case Status of
        continue -> inflate_loop(Z,zlib:safeInflate(Z,[]),Cap,N1,[Output|Acc]);
        finished -> [Output|Acc]
    end;
inflate_loop(_,_,_,_,_) -> fail(invalid_deflate_stream).

cache_dir(Dir0) ->
    Dir = filename:join(filename:absname(path(Dir0)), "ecdj-media-v1"),
    check(not lists:any(fun(P)->P=:= ".." orelse P=:= "." end,filename:split(Dir)), unsafe_cache_path),
    ensure_components(filename:split(Dir), ""),
    require(file:change_mode(Dir,8#700)),
    Dir.
ensure_components([],_) -> ok;
ensure_components([Part|Rest],Parent) ->
    Current = case Parent of ""->Part; _->filename:join(Parent,Part) end,
    case file:read_link_info(Current) of
        {ok,#file_info{type=directory}} -> ok;
        {error,enoent} -> require(file:make_dir(Current)), require(file:change_mode(Current,8#700));
        _ -> fail(unsafe_cache_path)
    end,
    ensure_components(Rest,Current).

load_cache(Target, Root, RH, AH) ->
    Marker = marker(Target),
    check(maps:get(release_hash,Marker)=:=RH andalso maps:get(archive_hash,Marker)=:=AH, cache_manifest_mismatch),
    Tracks = maps:get(tracks,Marker),
    check(is_list(Tracks) andalso length(Tracks)=<2048, invalid_cache_manifest),
    lists:foreach(fun(T)-> check(maps:get(cache_root,T)=:=Root, cache_manifest_mismatch),
                             verify_cached(T,Target) end,Tracks),
    {ok,Tracks}.
marker(Target) ->
    Path = filename:join(Target,"manifest.term"),
    case file:read_link_info(Path) of
        {ok,#file_info{type=regular,size=Size}} when Size=<2*?MIB -> ok;
        _ -> fail(invalid_cache_manifest)
    end,
    Bin = require(file:read_file(Path)),
    check(not is_compressed_term(Bin), invalid_cache_manifest),
    case binary_to_term(Bin,[safe]) of
        M=#{version:=1,tracks:=_} -> M;
        _ -> fail(invalid_cache_manifest)
    end.

verify_track(Track) -> guarded(fun()->
    Root = path(maps:get(cache_root,Track)), Path = path(maps:get(local_path,Track)),
    Target = filename:dirname(Path),
    check(filename:dirname(Target)=:=Root, outside_media_cache),
    check(is_hex(filename:basename(Target)), invalid_cache_key),
    ensure_existing_directory(Root), ensure_existing_directory(Target),
    M = marker(Target),
    check(lists:any(fun(Cached) -> maps:with(maps:keys(Cached),Track)=:=Cached end,
                    maps:get(tracks,M)), unregistered_cache_track),
    verify_cached(Track,Target)
end).
verify_cached(T,Target) ->
    P = path(maps:get(local_path,T)),
    check(filename:dirname(P)=:=Target andalso is_audio(unicode:characters_to_binary(P)), outside_media_cache),
    case file:read_link_info(P) of
        {ok,#file_info{type=regular,size=Size}} when Size=<128*?MIB ->
            check(Size=:=maps:get(bytes,T), cached_file_changed);
        _ -> fail(unsafe_cached_file)
    end,
    Data = require(file:read_file(P)),
    check(hex(crypto:hash(sha256,Data))=:=maps:get(sha256,T), cached_file_changed), ok.
ensure_existing_directory(P) ->
    %% Check all ancestors, not only the final directory; do not follow links.
    lists:foldl(fun(Part,Parent)->
        Current = case Parent of ""->Part; _->filename:join(Parent,Part) end,
        case file:read_link_info(Current) of {ok,#file_info{type=directory}}->ok; _->fail(unsafe_cache_path) end,
        Current end,"",filename:split(P)), ok.
is_compressed_term(<<131,80,_/binary>>) -> true;
is_compressed_term(_) -> false.
is_hex(S) -> length(S)=:=64 andalso lists:all(fun(C)->(C>=$0 andalso C=<$9) orelse (C>=$A andalso C=<$F) orelse (C>=$a andalso C=<$f) end,S).

play(Track) ->
    case verify_track(Track) of
        ok -> guarded(fun()->
            Path = maps:get(local_path,Track),
            case whereis(playlist) of undefined->fail(playlist_not_started); _->ok end,
            _ = require(playlist:add_files([Path])),
            case erm_mpv_proc:command(load_cached_audio,[Path,maps:get(media_format,Track)]) of
                ok -> ok;
                {ok,_} -> ok;
                {error,R} -> fail({playback,R});
                Other -> fail({playback,Other})
            end,
            _ = require(playlist:sync_current_path(Path)), ok
        end);
        Error -> Error
    end.

cleanup(Dir) ->
    case file:list_dir(Dir) of
        {ok,Names} -> lists:foreach(fun(Name)-> file:delete(filename:join(Dir,Name)) end,Names), file:del_dir(Dir),ok;
        _ -> ok
    end.
path(B) when is_binary(B) -> unicode:characters_to_list(B);
path(L) when is_list(L), L=/=[] -> L;
path(_) -> fail(invalid_path).
hex(B) -> binary:encode_hex(B).
require(ok) -> ok;
require({ok,V}) -> V;
require({error,R}) -> fail(R);
require(Other) -> fail({unexpected_result,Other}).
check(true,_) -> ok;
check(false,R) -> fail(R).
fail(R) -> throw({dj_media,R}).
guarded(Fun) ->
    try Fun() catch
        throw:{dj_media,R} -> {error,R};
        error:Reason -> {error,{invalid_media,Reason}};
        exit:Reason -> {error,{media_unavailable,Reason}}
    end.
