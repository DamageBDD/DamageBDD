-module(erm_dj_media_tests).
-include_lib("eunit/include/eunit.hrl").

%% Synthetic local audio bytes and archives. No third-party recordings shipped.
roundtrip_cache_integrity_test() ->
    with_cache(fun(Dir) ->
        Data = <<255,251,144,100,0:8000>>,
        Zip = archive([{"Album/01 - Intro.mp3",Data},{"cover.txt",<<"unused">>}]),
        {ok,[Track]} = erm_dj_media:prepare_archive(release(),Zip,Dir,#{}),
        ?assertEqual(Data, element(2,file:read_file(maps:get(local_path,Track)))),
        ?assertEqual(ok,erm_dj_media:verify_track(Track)),
        ?assertEqual(ok,erm_dj_media:verify_track(Track#{score=>12,reasons=>[liked]})),
        ?assertMatch({ok,[Track]},erm_dj_media:prepare_archive(release(),Zip,Dir,#{})),
        ok=file:write_file(maps:get(local_path,Track),<<"tampered">>),
        ?assertEqual({error,cached_file_changed},erm_dj_media:verify_track(Track)),
        ?assertEqual({error,cached_file_changed},erm_dj_media:prepare_archive(release(),Zip,Dir,#{}))
    end).

deflated_audio_bounded_test() ->
    with_cache(fun(Dir) ->
        Data= <<255,251,144,100,(binary:copy(crypto:strong_rand_bytes(8192),8))/binary>>,
        {ok,{_,Z}}=zip:create("deflated.zip",[{"a.mp3",Data}],[memory,{compress,all}]),
        {Pos,4}=binary:match(Z,<<16#50,16#4b,1,2>>),
        MethodPos=Pos+10,
        <<_:MethodPos/binary,Method:16/little,_/binary>>=Z,
        ?assertEqual(8,Method),
        {ok,[Track]}=erm_dj_media:prepare_archive(release(),Z,Dir,#{}),
        ?assertEqual(ok,erm_dj_media:verify_track(Track)),
        %% A malicious directory may lie about the output size. safeInflate
        %% must stop at the actual byte cap rather than trust this header.
        SizePos=Pos+24,
        <<A:SizePos/binary,_:32/little,B/binary>>=Z,
        SmallClaim= <<A/binary,1:32/little,B/binary>>,
        ?assertEqual({error,inflated_audio_limit},erm_dj_media:prepare_archive(release(),SmallClaim,Dir,#{})),
        CRCPos=Pos+16,
        <<C:CRCPos/binary,CRC:32/little,D/binary>>=Z,
        BadCRC= <<C/binary,(CRC bxor 1):32/little,D/binary>>,
        ?assertEqual({error,zip_crc_mismatch},erm_dj_media:prepare_archive(release(),BadCRC,Dir,#{}))
    end).

disguised_audio_rejected_test() ->
    with_cache(fun(Dir) ->
        lists:foreach(fun(Data)->
            ?assertEqual({error,invalid_audio_signature},erm_dj_media:prepare_archive(release(),archive([{"fake.mp3",Data}]),Dir,#{}))
        end,[<<"<html>blocked</html>">>,<<"#EXTM3U\nhttps://example.org/music.mp3">>,
             <<"ID3",4,0,0,0,0,0,0,"#EXTM3U\nhttps://example.org/music.mp3">>])
    end).

licence_gate_test() ->
    ?assertEqual(ok,erm_dj_media:permitted(release(),#{})),
    ?assertEqual({error,noncommercial_licence},erm_dj_media:permitted(release(),#{commercial=>true})),
    ?assertEqual({error,unknown_licence},erm_dj_media:permitted((release())#{license=>#{url=><<"https://example.org/free">>}},#{})),
    ?assertEqual({error,missing_licence},erm_dj_media:permitted(#{},#{})),
    ?assertEqual(ok,erm_dj_media:permitted((release())#{license=>#{url=><<"https://creativecommons.org/licenses/by/4.0/">>}},#{commercial=>true})).

traversal_and_resource_limits_test() ->
    with_cache(fun(Dir) ->
        ?assertEqual({error,unsafe_archive_path},erm_dj_media:prepare_archive(release(),archive([{"../outside.mp3",<<"x">>}]),Dir,#{})),
        ?assertEqual({error,unsafe_archive_path},erm_dj_media:prepare_archive(release(),archive([{"C:/outside.mp3",<<"x">>}]),Dir,#{})),
        ?assertEqual({error,archive_file_too_large},erm_dj_media:prepare_archive(release(),archive([{"a.mp3",<<0:800>>}]),Dir,#{max_audio_bytes=>50})),
        ?assertEqual({error,too_many_archive_entries},erm_dj_media:prepare_archive(release(),archive([{"a.mp3",<<1>>},{"b.mp3",<<2>>}]),Dir,#{max_entries=>1})),
        ?assertEqual({error,no_audio_files},erm_dj_media:prepare_archive(release(),archive([{"run.sh",<<"touch /tmp/nope">>}]),Dir,#{})),
        ?assertMatch({error,_},erm_dj_media:prepare_archive(release(),<<"not zip">>,Dir,#{}))
    end).

header_and_links_test() ->
    with_cache(fun(Dir) ->
        Z=archive([{"a.mp3",<<"audio">>}]),
        %% The central filename and local filename must agree.
        <<Prefix:30/binary,_Old:5/binary,Rest/binary>>=Z,
        Mismatch= <<Prefix/binary,"b.mp3",Rest/binary>>,
        ?assertEqual({error,zip_name_mismatch},erm_dj_media:prepare_archive(release(),Mismatch,Dir,#{})),
        %% Unix S_IFLNK in central external attributes must be rejected.
        {Pos,4}=binary:match(Z,<<16#50,16#4b,1,2>>),
        AttrPos=Pos+38,
        <<A:AttrPos/binary,_:32/little,B/binary>>=Z,
        Link= <<A/binary,(8#120777 bsl 16):32/little,B/binary>>,
        ?assertEqual({error,archive_link_or_special_file},erm_dj_media:prepare_archive(release(),Link,Dir,#{}))
    end).

symlink_cache_rejected_test() ->
    with_cache(fun(Dir) ->
        Real=filename:join(Dir,"real"), ok=file:make_dir(Real),
        Link=filename:join(Dir,"linked"), ok=file:make_symlink(Real,Link),
        ?assertEqual({error,unsafe_cache_path},erm_dj_media:prepare_archive(release(),archive([{"a.mp3",<<"a">>}]),Link,#{})),
        ok=file:delete(Link),ok=file:del_dir(Real)
    end).

unregistered_path_rejected_test() ->
    ?assertMatch({error,_},erm_dj_media:verify_track(#{local_path=>"/etc/passwd",cache_root=>"/etc",sha256=><<"00">>})).

archive(Files) ->
    {ok,{_,Bin}}=zip:create("synthetic.zip",Files,[memory,{compress,[]}]), Bin.
release() ->
    #{id=><<"fixture-release">>,title=><<"Synthetic album">>,artist=><<"Fixture artist">>,
      source_url=><<"https://ektoplazm.com/free-music/fixture">>,tags=>[<<"ambient">>],
      license=>#{id=><<"CC-BY-NC-SA-3.0">>,url=><<"https://creativecommons.org/licenses/by-nc-sa/3.0/">>},
      license_evidence=>#{page_url=><<"https://ektoplazm.com/free-music/fixture">>,html_sha256=>binary:encode_hex(crypto:hash(sha256,<<"fixture">>))}}.
with_cache(F) ->
    Dir=filename:join("/tmp","ecdj-media-test-"++integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok=file:make_dir(Dir),
    try F(Dir) after file:del_dir_r(Dir) end.
