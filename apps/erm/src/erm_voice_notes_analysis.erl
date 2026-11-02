%% Offline analysis always reads the saved original WAV; UI/capture stay live.
-module(erm_voice_notes_analysis).
-include_lib("kernel/include/file.hrl").
-export([analyze/2,transcribe/3,transcription_config/1,default_cli/0]).
analyze(Root,N)->
    try
        Id=maps:get(id,N),Ms=maps:get(duration_ms,N),
        {Length,Starts}=case Ms of
            _ when Ms=<4000->{Ms,[0]};
            _ when Ms<8000->{Ms div 2,[0,Ms-(Ms div 2)]};
            _->Len=min(4000,Ms div 3),{Len,[0,(Ms-Len) div 2,Ms-Len]}
        end,
        Windows=[window(Root,Id,Start,Length)||Start<-Starts],
        Valid=[F||#{feature:=F}<-Windows],
        case Valid of
            []->#{status=>unavailable,reason=>no_usable_voice_window,windows=>Windows};
            _->Qs=[maps:get(q,F)||F<-Valid],
                Q=[median([lists:nth(I,X)||X<-Qs])||I<-lists:seq(1,30)],
                #{status=>ready,frontend=>ecai_voice_features:version(),q=>Q,
                  sampling=>first_middle_last_up_to_four_seconds,
                  analyzed_ms=>lists:sum([maps:get(duration_ms,W)||W=#{feature:=_}<-Windows]),
                  windows=>Windows,model_scope=>experimental_acoustic_speaker_baseline}
        end
    catch C:R->#{status=>unavailable,reason=>{analysis_failed,C,R}} end.
window(Root,Id,Start,Ms)->
    Base=#{offset_ms=>Start,duration_ms=>Ms},
    case erm_voice_notes_store:pcm(Root,Id,Start,Ms) of
        {ok,PCM}->case ecai_voice_features:extract(PCM) of
            {ok,F}->Base#{feature=>maps:without([pcm],F)};
            {error,R}->Base#{error=>R}
        end;
        E->Base#{error=>E}
    end.
median(V)->lists:nth((length(V)+1) div 2,lists:sort(V)).
default_cli()->
    case os:find_executable("whisper-cli") of
        false->"/opt/whisper.cpp/build/bin/whisper-cli";
        P->P
    end.
transcription_config(O)->
    Cli=maps:get(whisper_cli,O,default_cli()),Model=maps:get(whisper_model,O,""),
    case filelib:is_regular(Cli) andalso Model=/="" andalso Model=/= <<>> andalso filelib:is_regular(Model) of
        true->#{status=>ready,backend=>local_whisper,executable=>Cli,model=>Model};
        false->#{status=>unavailable,reason=>configure_local_whisper_cli_and_model,
            executable=>Cli,model=>Model}
    end.
transcribe(Root,N,O)->
    case transcription_config(O) of
        #{status:=ready,executable:=Cli,model:=Model}->
            Dir=filename:join(Root,".transcribe-"++binary_to_list(maps:get(id,N))++"-"++
                integer_to_list(erlang:unique_integer([positive]))),
            case file:make_dir(Dir) of
                ok->
                    try
                        ok=file:change_mode(Dir,8#700),
                        Prefix=filename:join(Dir,"result"),
                        Args=["-m",filename:absname(Model),"-f",erm_voice_notes_store:wav_path(Root,maps:get(id,N)),
                          "-otxt","-of",Prefix,"-l",maps:get(language,O,"auto"),"-t","4","-nt"],
                        Result=cli(Cli,Args,maps:get(transcription_timeout_ms,O,120000)),
                        case Result of
                            {ok,0,_}->case file:read_file_info(Prefix++".txt") of
                                {ok,#file_info{type=regular,size=Size}} when Size=<65536->
                                    {ok,Text}=file:read_file(Prefix++".txt"),
                                    case unicode:characters_to_binary(Text) of
                                        B when is_binary(B)->#{status=>ready,backend=>local_whisper,
                                            text=>string:trim(B),model=>unicode:characters_to_binary(filename:basename(Model))};
                                        _->#{status=>failed,reason=>invalid_transcript_utf8}
                                    end;
                                _->#{status=>failed,reason=>missing_or_oversized_transcript}
                            end;
                            {ok,Code,Log}->#{status=>failed,reason=>{transcriber_exit,Code},log=>Log};
                            E->#{status=>failed,reason=>E}
                        end
                    catch C:R->#{status=>failed,reason=>{transcription,C,R}}
                    after _=file:delete(filename:join(Dir,"result.txt")),_=file:del_dir(Dir) end;
                E->#{status=>failed,reason=>{transcription_directory,E}}
            end;
        C->C
    end.
cli(Exe,Args,Timeout)->
    P=open_port({spawn_executable,filename:absname(Exe)},[binary,exit_status,use_stdio,stderr_to_stdout,
        {args,Args}]),
    try cli_wait(P,erlang:monotonic_time(millisecond)+Timeout,<<>>)
    after try port_close(P) catch _:_ ->ok end end.
cli_wait(P,Deadline,Log)->
    Remaining=max(0,Deadline-erlang:monotonic_time(millisecond)),
    receive
        {P,{data,B}}->
            Joined= <<Log/binary,B/binary>>,
            Keep=case byte_size(Joined)>8192 of true->binary:part(Joined,byte_size(Joined)-8192,8192);false->Joined end,
            cli_wait(P,Deadline,Keep);
        {P,{exit_status,Code}}->{ok,Code,Log}
    after Remaining->{error,transcription_timeout} end.
