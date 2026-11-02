%% Synchronous bounded native operations. Call from a monitored worker, not a
%% BEAM scheduler-blocking NIF. Closing its port cancels native playback too.
-module(erm_phrase_lab_native).
-export([request/2, render/4, evaluate/3, play/2, profile/1, controls/1]).

profile(S) -> erm_phrase_codec:encode_profile(maps:get(revision, S),
    maps:get(max_distance, S), maps:get(min_margin, S), maps:get(samples, S)).
controls(M) when is_map(M) ->
    true = maps:without([speed,pitch,noise,acoustic], M) =:= #{},
    O = maps:merge(#{speed => 1.0, pitch => 1.0, noise => 0.15, acoustic => true}, M),
    lists:foreach(fun({K, Lo, Hi}) -> V=maps:get(K,O),
        true=is_number(V) andalso V>=Lo andalso V=<Hi end,
        [{speed,0.85,1.15},{pitch,0.8,1.2},{noise,0.0,0.3}]),
    true=is_boolean(maps:get(acoustic,O)), O.
render(O, Model, Profile, Input) ->
    C=controls(Input), Speed=float(maps:get(speed,C)), Pitch=float(maps:get(pitch,C)), Noise=float(maps:get(noise,C)),
    B= <<"Y",Speed:32/float-big,Pitch:32/float-big,Noise:32/float-big,
        (byte_size(Model)):32,Model/binary,(byte_size(Profile)):32,Profile/binary>>,
    case request(O,B) of
        {ok, <<"Y",Match:10/binary,Ms:32,Rms:32/float-big,Peak:32/float-big,Clip:32/float-big,N:32,Wav:N/binary>>}
            when Ms>0,Ms=<8000,Rms>= -120,Rms=<1,Peak>= -120,Peak=<1,Clip>=0,Clip=<1,N=<256044 ->
            {ok,#{result=>match(Match),ms=>Ms,quality=>#{rms_dbfs=>Rms,peak_dbfs=>Peak,clipped_fraction=>Clip},wav=>Wav}};
        {ok,_} -> {error,invalid_synthesis_response};
        Error -> Error
    end.
evaluate(O, Profile, #{ms:=Ms,frames:=N,features:=F}) ->
    case request(O, <<"V",(byte_size(Profile)):32,Profile/binary,Ms:32,N:16,F/binary>>) of
        {ok,<<"V",Match:10/binary>>} -> {ok,match(Match)};
        {ok,_} -> {error,invalid_evaluation_response};
        Error -> Error
    end.
match(<<Reason:8,Code:8,D:32/float-big,M:32/float-big>>)
    when Reason=<4,Code=<5,D>=0,D=<1000,M>=0,M=<1000 ->
    #{reason=>Reason,action=>erm_phrase_codec:action(Code),distance=>D,margin=>M}.
play(O,Wav) ->
    %% Quiet lead/trail only, never an audible cue that could be learned as speech.
    <<"RIFF",_:32/little,"WAVEfmt ",16:32/little,1:16/little,1:16/little,
        16000:32/little,32000:32/little,2:16/little,16:16/little,"data",N:32/little,PCM:N/binary>>=Wav,
    Padded= <<0:64000,PCM/binary,0:64000>>, Size=byte_size(Padded),
    W= <<"RIFF",(Size+36):32/little,"WAVEfmt ",16:32/little,1:16/little,1:16/little,
        16000:32/little,32000:32/little,2:16/little,16:16/little,"data",Size:32/little,Padded/binary>>,
    case request(O, <<"B",(byte_size(W)):32,W/binary>>) of
        {ok,<<"B">>} -> ok; {ok,_} -> {error,invalid_playback_response}; Error -> Error
    end.
request(O, B) when is_binary(B), byte_size(B)=<1048576 ->
    Old=process_flag(trap_exit,true),
    try
        P=open_port({spawn_executable,maps:get(binary,O)},
            [binary,{packet,4},use_stdio,exit_status,{args,[maps:get(player,O),maps:get(device,O)]}]),
        try
            true=port_command(P,B),
            receive
                {P,{data,<<"E",Why/binary>>}} when byte_size(Why)=<256 -> {error,{native,Why}};
                {P,{data,Data}} when byte_size(Data)=<300000 -> {ok,Data};
                {P,{exit_status,Code}} -> {error,{native_exit,Code}};
                {'EXIT',P,Why} -> {error,{native_port,Why}}
            after 20000 -> {error,native_timeout}
            end
        after try port_close(P) catch error:_ -> ok end end
    catch Class:Reason -> {error,{native_request,Class,Reason}}
    after process_flag(trap_exit,Old) end.
