%% Deterministic speech controls. Never replay a media/custom action or ask an LLM
%% to choose a model URL. Only catalogue names reach the model pull service.
-module(erm_voice_tts).
-export([parse/1, execute/1]).
parse(Text) ->
    T=erm_voice_boundary:normalize(Text),
    case T of
        <<"repeat">> -> control(repeat);
        <<"repeat that">> -> control(repeat);
        <<"say that again">> -> control(repeat);
        <<"repeat louder">> -> control({repeat,louder});
        <<"say that louder">> -> control({repeat,louder});
        <<"repeat quieter">> -> control({repeat,quieter});
        <<"speak louder">> -> control(louder);
        <<"voice louder">> -> control(louder);
        <<"speak quieter">> -> control(quieter);
        <<"voice quieter">> -> control(quieter);
        <<"reload voice">> -> control(reload);
        <<"reload tts">> -> control(reload);
        <<"be playful">> -> control({personality,playful});
        <<"be sassy">> -> control({personality,playful});
        <<"be plain">> -> control({personality,plain});
        <<"personality playful">> -> control({personality,playful});
        <<"personality plain">> -> control({personality,plain});
        <<"change voice to ",Name/binary>> when Name=/=<<>> -> control({voice,Name});
        <<"set voice to ",Name/binary>> when Name=/=<<>> -> control({voice,Name});
        <<"use voice ",Name/binary>> when Name=/=<<>> -> control({voice,Name});
        _ -> volume(Text,T)
    end.
control(C)->{ok,#{action=>tts,control=>C}}.
volume(Raw,T)->
    case re:run(T,"^(?:set )?(?:voice|speech|tts) volume(?: to)? ([0-9]{1,3})(?: percent)?$",
                [{capture,[1],binary}]) of
        {match,[N]} ->
            %% Normalisation strips punctuation: never turn -10 or 1.20 into
            %% a different, valid volume. Only unsigned integer input is valid.
            case re:run(unicode:characters_to_binary(Raw),"[-+][[:space:]]*[0-9]|[0-9][.,][0-9]",[{capture,none}]) of
                nomatch -> case binary_to_integer(N) of
                    V when V=<200 -> control({volume,V});
                    _ -> {error,tts_volume_out_of_range}
                end;
                _ -> {error,invalid_tts_volume}
            end;
        _ -> case re:run(T,"^(?:set )?(?:voice|speech|tts) volume(?: |$)",[{capture,none}]) of
            match -> {error,invalid_tts_volume};
            nomatch -> unknown
        end
    end.
execute(#{control:=C})->
    Result=case C of
        repeat -> erm_tts:repeat();
        {repeat,Direction} -> erm_tts:repeat(Direction);
        louder -> erm_tts:louder();
        quieter -> erm_tts:quieter();
        {volume,N} -> erm_tts:set_volume(N);
        {personality,P} -> erm_tts:set_personality(P);
        {voice,Id} -> erm_tts:set_voice(Id);
        reload -> erm_tts:reload();
        _ -> {error,unsupported_tts_control}
    end,
    %% This result is already handled by TTS. In particular, repeat must never
    %% generate a second acknowledgement that replaces the remembered response.
    case Result of ok->{ok,#{tts=>C}};Error->Error end.
