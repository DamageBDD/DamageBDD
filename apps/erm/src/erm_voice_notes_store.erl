%% Private, durable original PCM notes. Metadata never substitutes synthesized
%% audio for the captured samples. Filenames derive only from generated IDs.
-module(erm_voice_notes_store).
-include_lib("kernel/include/file.hrl").
-export([open/1,begin_note/2,finish/4,abort/2,list/1,get/2,save/2,
         wav_path/2,pcm/4,write_term/2,read_term/2,write_audio/2,header/1,valid_id/1]).
-define(MAX_PCM,19200000).
open(Root0) ->
    Root=filename:absname(Root0),
    case filelib:ensure_dir(filename:join(Root,"note")) of
        ok -> case file:read_link_info(Root) of
            {ok,#file_info{type=directory}} ->
                case file:change_mode(Root,8#700) of ok->{ok,Root};E->E end;
            _ -> {error,invalid_notes_directory}
        end;
        E -> E
    end.
begin_note(Root,Device) ->
    Id=iolist_to_binary([integer_to_list(erlang:system_time(microsecond)),"-",hex(crypto:strong_rand_bytes(8))]),
    Path=path(Root,Id,".pcm.part"),
    case file:open(Path,[write,exclusive,binary,raw]) of
        {ok,Fd} ->
            case file:change_mode(Path,8#600) of
                ok -> {ok,#{schema=>1,id=>Id,created_ms=>erlang:system_time(millisecond),
                    device=>unicode:characters_to_binary(Device),transcript=><<>>,corrected_transcript=><<>>,
                    speaker=><<>>,split=>exclude,analysis=>#{status=>pending},transcription=>#{status=>pending}},Fd};
                E -> file:close(Fd),file:delete(Path),E
            end;
        E -> E
    end.
finish(Root,N,Fd,Extra) ->
    Id=maps:get(id,N), Part=path(Root,Id,".pcm.part"),
    Sync=file:sync(Fd),Close=file:close(Fd),
    case {Sync,Close,file:read_file(Part)} of
        {ok,ok,{ok,PCM}} when byte_size(PCM)>0,byte_size(PCM)=< ?MAX_PCM,byte_size(PCM) rem 2=:=0 ->
            Stats=stats(PCM),
            Note=maps:merge(maps:merge(N,Extra),Stats#{duration_ms=>byte_size(PCM) div 32,
                pcm_sha256=>crypto:hash(sha256,PCM)}),
            case atomic(wav_path(Root,Id),[header(byte_size(PCM)),PCM]) of
                ok -> case save(Root,Note) of
                    ok -> file:delete(Part),{ok,Note};
                    E -> E
                end;
                E -> E
            end;
        {ok,ok,{ok,<<>>}} -> file:delete(Part),{error,no_audio_captured};
        Other -> {error,{note_finalize,Other}}
    end.
abort(Root,#{id:=Id}) -> file:delete(path(Root,Id,".pcm.part")).
list(Root) ->
    case file:list_dir(Root) of
        {ok,Names} ->
            Notes=[N || Name<-Names,filename:extension(Name)=:=".note",
                {ok,N}<-[read_term(filename:join(Root,Name),262144)],valid_note(N),
                filename:basename(Name,".note")=:=binary_to_list(maps:get(id,N)),
                regular(wav_path(Root,maps:get(id,N)))],
            {ok,lists:sort(fun(A,B)->maps:get(id,A)>maps:get(id,B) end,Notes)};
        E -> E
    end.
get(Root,Id) ->
    case valid_id(Id) of
        true -> case read_term(path(Root,Id,".note"),262144) of
            {ok,N} -> case valid_note(N) andalso maps:get(id,N)=:=Id of
                true->{ok,N};false->{error,invalid_note_metadata} end;
            E->E end;
        false -> {error,invalid_note_id}
    end.
save(Root,N) ->
    case valid_note(N) of
        true -> write_term(path(Root,maps:get(id,N),".note"),N);
        false -> {error,invalid_note_metadata}
    end.
valid_note(#{schema:=1,id:=Id,created_ms:=Ms,speaker:=Speaker,split:=Split,
             transcript:=T,corrected_transcript:=C}=N) ->
    valid_id(Id) andalso is_integer(Ms) andalso is_binary(Speaker) andalso byte_size(Speaker)=<128
    andalso lists:member(Split,[exclude,train,validation,test]) andalso
    is_binary(T) andalso byte_size(T)=<65536 andalso is_binary(C) andalso byte_size(C)=<65536
    andalso is_map(maps:get(analysis,N,#{}));
valid_note(_) -> false.
valid_id(B) when is_binary(B),byte_size(B)>=20,byte_size(B)=<48 ->
    re:run(B,"^[0-9]+-[0-9a-f]{16}$",[{capture,none}])=:=match;
valid_id(_) -> false.
path(Root,Id,Ext) -> true=valid_id(Id),filename:join(Root,binary_to_list(Id)++Ext).
wav_path(Root,Id) -> path(Root,Id,".wav").
pcm(Root,Id,OffsetMs,LengthMs) when is_integer(OffsetMs),OffsetMs>=0,
    is_integer(LengthMs),LengthMs>0,LengthMs=<30000 ->
    case file:open(wav_path(Root,Id),[read,binary,raw]) of
        {ok,Fd} -> try file:pread(Fd,44+OffsetMs*32,LengthMs*32) after file:close(Fd) end;
        E -> E
    end.
header(N) -> <<"RIFF",(36+N):32/little,"WAVEfmt ",16:32/little,1:16/little,
    1:16/little,16000:32/little,32000:32/little,2:16/little,16:16/little,"data",N:32/little>>.
stats(PCM) ->
    N=byte_size(PCM) div 2,
    {Sq,Peak,Clips}=stats(PCM,0,0,0),
    Rms=math:sqrt(Sq/N)/32768,
    #{rms_dbfs=>20*math:log10(max(1.0e-9,Rms)),peak_dbfs=>20*math:log10(max(1.0e-9,Peak/32768)),
      clipped_fraction=>Clips/N}.
stats(<<>>,Sq,P,C)->{Sq,P,C};
stats(<<X:16/little-signed,T/binary>>,Sq,P,C)->
    stats(T,Sq+X*X,max(P,abs(X)),C+case abs(X)>=32760 of true->1;false->0 end).
write_term(Path,Term)->atomic(Path,term_to_binary(Term)).
write_audio(Path,PCM) when is_binary(PCM),byte_size(PCM)>0,byte_size(PCM)=< ?MAX_PCM,
    byte_size(PCM) rem 2=:=0 ->atomic(Path,[header(byte_size(PCM)),PCM]).
read_term(Path,Limit)->
    case file:read_link_info(Path) of
        {ok,#file_info{type=regular,size=N}} when N=<Limit ->
            case file:open(Path,[read,binary,raw]) of
                {ok,F}->try
                    case file:read(F,Limit+1) of
                        {ok,<<131,80,_/binary>>}->{error,compressed_metadata};
                        {ok,B} when byte_size(B)=<Limit->
                            try {ok,binary_to_term(B,[safe])} catch _:_->{error,invalid_metadata} end;
                        _->{error,invalid_metadata}
                    end
                after file:close(F) end;
                E->E
            end;
        {error,_}=E->E;
        _->{error,invalid_metadata_file}
    end.
atomic(Path,Data)->
    Temp=Path++".new-"++binary_to_list(hex(crypto:strong_rand_bytes(8))),
    case file:open(Temp,[write,exclusive,binary,raw]) of
        {ok,F}->
            Result=try
                ok=file:change_mode(Temp,8#600),ok=file:write(F,Data),ok=file:sync(F),
                ok=file:close(F),file:rename(Temp,Path)
            catch C:R->{error,{atomic_write,C,R}} end,
            _=file:close(F),_ =file:delete(Temp),Result;
        E->E
    end.
regular(Path)->case file:read_link_info(Path) of {ok,#file_info{type=regular}}->true;_->false end.
hex(B)->iolist_to_binary([io_lib:format("~2.16.0b",[X]) || <<X>><=B]).
