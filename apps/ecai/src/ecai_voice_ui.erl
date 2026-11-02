%% Optional local desktop telemetry for ECAI's actual audio commands.
%% No dependency on erm at application startup and no microphone duplication.
-module(ecai_voice_ui).
-include_lib("kernel/include/file.hrl").
-export([begin_audio/3, tick/1, end_audio/2, publish/3, work/2, result/2, wav_info/1]).
publish(Source,Channel,Data) ->
    try erm_voice_events:publish(Source,Channel,Data) catch error:undef -> ok end.
begin_audio(Source,Name,Args) ->
    case Name of
        "arecord" -> begin_meter(Source,input,listening,lists:last(Args));
        "aplay" -> begin_meter(Source,output,speaking,lists:last(Args));
        "espeak-ng" -> begin_meter(Source,output,synthesizing,undefined);
        _ -> undefined
    end.
begin_meter(Source,Channel,Phase,Path) ->
    publish(Source,Channel,#{phase=>Phase,level=>0.0}),
    #{source=>Source,channel=>Channel,path=>Path,started=>erlang:monotonic_time(millisecond)}.
end_audio(undefined,_) -> ok;
end_audio(#{source:=S,channel:=C},Result) ->
    publish(S,C,#{phase=>case Result of ok->idle;_->error end,level=>0.0}).
tick(undefined) -> ok;
tick(#{path:=undefined}) -> ok;
tick(#{source:=S,channel:=C,path:=Path,started:=Start}) ->
    %% Read a bounded window from the recording already being written, or from
    %% the WAV already being played. Playback level follows elapsed time and
    %% is a PCM envelope, not a measurement of speaker/device loopback.
    case file:open(Path,[read,raw,binary]) of
        {ok,F} ->
            try
                case file:pread(F,0,4096) of
                    {ok,H} ->
                        case wav_info(H) of
                            {ok,Rate,Channels,Offset} ->
                                {ok,Size}=file:position(F,eof),
                                Count=Rate*Channels*2 div 10,
                                Now=erlang:monotonic_time(millisecond),
                                At=case C of
                                    input -> max(Offset,Size-Count);
                                    output -> Offset+((Now-Start)*Rate div 1000)*Channels*2
                                end,
                                Level=case file:pread(F,At,Count) of
                                    {ok,B} -> pcm_level(B);
                                    _ -> 0.0
                                end,
                                publish(S,C,#{level=>Level});
                            _ -> ok
                        end;
                    _ -> ok
                end
            catch _:_ -> ok after file:close(F) end;
        _ -> ok
    end.
wav_info(<<"RIFF",_:32/little,"WAVE",Rest/binary>>) -> chunks(Rest,12,undefined);
wav_info(_) -> {error,unsupported_wav}.
chunks(<<"fmt ",N:32/little,1:16/little,C:16/little,R:32/little,
         _:32/little,_:16/little,16:16/little,Rest/binary>>,At,_) when
         N>=16,N=<1024,C>0,C=<8,R>=8000,R=<192000,byte_size(Rest)>=N-16+(N rem 2) ->
    Skip=N-16+(N rem 2), <<_:Skip/binary,Tail/binary>>=Rest,
    chunks(Tail,At+8+N+(N rem 2),{R,C});
chunks(<<"data",_:32/little,_/binary>>,At,{R,C}) -> {ok,R,C,At+8};
chunks(<<_:4/binary,N:32/little,Rest/binary>>,At,Fmt) when N=<4096,byte_size(Rest)>=N+(N rem 2) ->
    Skip=N+(N rem 2), <<_:Skip/binary,Tail/binary>>=Rest,
    chunks(Tail,At+8+Skip,Fmt);
chunks(_,_,_) -> {error,unsupported_wav}.
pcm_level(B) ->
    {Sum,N}=pcm_energy(B,0.0,0),
    case N>0 andalso Sum>0 of
        true -> max(0.0,min(1.0,(10*math:log10(Sum/N)+60)/60));
        false -> 0.0
    end.
pcm_energy(<<V:16/little-signed,Rest/binary>>,Sum,N) -> pcm_energy(Rest,Sum+math:pow(V/32768,2),N+1);
pcm_energy(_,Sum,N) -> {Sum,N}.
work(Source,Fun) ->
    publish(Source,work,#{phase=>processing}),
    try R=Fun(), result(Source,R), R
    catch C:E:Stack -> publish(Source,work,#{phase=>error}),erlang:raise(C,E,Stack) end.
result(Source,R) ->
    Data=case R of
        {error,_} -> #{phase=>error};
        #{speaker:=Speaker} -> #{phase=>idle,text=>unicode:characters_to_binary(io_lib:format("Speaker: ~tp",[Speaker]))};
        {ok,#{speaker:=Speaker}} -> #{phase=>idle,text=>unicode:characters_to_binary(io_lib:format("Speaker: ~tp",[Speaker]))};
        _ -> #{phase=>idle}
    end,
    publish(Source,work,Data).
