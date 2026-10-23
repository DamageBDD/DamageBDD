%% Local speaker profiles and wake-phrase selection. Profiles are immutable;
%% training data is bound to speaker, model, device and wake phrase. Only opaque
%% generated IDs form filenames. UI/status never receives embeddings or paths.
-module(erm_voice_profiles).
-include_lib("kernel/include/file.hrl").
-export([open/2,resolve/1,public/1,select/2,wake/2,enrol/3,enrol/4,commit/1,remove/2,delete_file/2,
         normalise_wake/1,label/1,check_name/2,enrol_check/4,sample_check/3]).
open(O,Hash)->
    Base=maps:get(profile_file,O),Root=filename:join(filename:dirname(Base),"voices"),
    Manifest=Base++".voices",
    Store=#{base=>Base,root=>Root,manifest=>Manifest,configured=>maps:get(speaker_profile,O),
        hash=>Hash,device=>maps:get(device,O)},
    State=case erm_phrase_codec:private_read(Manifest,65536) of
        {error,enoent}->
            {Voices,Active,Profile}=case erm_phrase_codec:load_speaker(maps:get(configured,Store),Hash) of
                {ok,P}->{#{<<"configured">>=>maps:get(label,P)},<<"configured">>,P};
                {error,enoent}->{#{},undefined,undefined};
                Error->error({speaker_profile,Error})
            end,
            Wake=normalise_wake(maps:get(wake,O)),
            #{version=>1,voices=>Voices,active=>Active,wake=>Wake,
              legacy_binding=>case Profile of undefined-> <<0:256>>;_->binding(Store,Profile,Wake) end};
        {ok,<<131,80,_/binary>>}->error(compressed_voice_settings_not_supported);
        {ok,B}->validate(binary_to_term(B,[safe]));
        Error->error({voice_settings,Error})
    end,
    Store#{state=>State}.
validate(#{version:=1,voices:=V,active:=Active,wake:=W,legacy_binding:=B}=S)
    when map_size(S)=:=5,is_map(V),map_size(V)=<16,is_binary(B),byte_size(B)=:=32 ->
    true=Active=:=undefined orelse maps:is_key(Active,V),
    W=normalise_wake(W),
    maps:foreach(fun(Id,Label)->true=valid_id(Id),Label=label(Label) end,V),
    true=length(lists:usort(maps:values(V)))=:=map_size(V),S;
validate(_)->error(invalid_voice_settings).
valid_id(<<"configured">>)->true;
valid_id(Id) when is_binary(Id),byte_size(Id)=:=24->
    lists:all(fun(C)->(C>=$0 andalso C=<$9) orelse (C>=$A andalso C=<$F) end,binary_to_list(Id));
valid_id(_)->false.
label(Text)->try checked_label(Text) catch _:_ ->error(invalid_voice_name) end.
checked_label(Text)->
    B=unicode:characters_to_binary(string:trim(Text)),
    true=is_binary(B) andalso byte_size(B)>=1 andalso byte_size(B)=<128,
    true=lists:all(fun(C)->C>=32 andalso C=/=127 end,unicode:characters_to_list(B)),B.
normalise_wake(Text)->try checked_wake(Text) catch _:_ ->error(invalid_wake_phrase) end.
checked_wake(Text)->
    B=unicode:characters_to_binary(string:lowercase(string:trim(Text))),
    true=is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<64,
    %% One to four words, with no control characters or punctuation tricks.
    match=re:run(B,"^[\\p{L}\\p{N}]+(?:[ '-][\\p{L}\\p{N}]+){0,3}$",[unicode,{capture,none}]),B.
check_name(Store,Text)->
    L=label(Text),V=maps:get(voices,maps:get(state,Store)),
    case lists:member(L,maps:values(V)) of true->error(voice_name_already_exists);false->ok end,
    case map_size(V)<16 of true->L;false->error(voice_profile_limit) end.
public(#{state:=S})->
    #{active_voice=>maps:get(active,S),wake=>maps:get(wake,S),
      voices=>[#{id=>I,label=>L} || {L,I}<-lists:sort([{L,I} || {I,L}<-maps:to_list(maps:get(voices,S))])]}.
select(Store=#{state:=S},Id)->
    true=maps:is_key(Id,maps:get(voices,S)),Store#{state=>S#{active=>Id}}.
wake(Store=#{state:=S},Text)->Store#{state=>S#{wake=>normalise_wake(Text)}}.
resolve(Store=#{state:=S})->
    %% Bind the loaded speaker and its fingerprint to the SAME validated read.
    %% A second read here could race with a file replacement during enrolment.
    {Profile,SpeakerMeta}=case maps:get(active,S) of
        undefined->{undefined,undefined};
        Id->
            SpeakerPath=speaker_path(Store,Id),
            {ok,P,Fingerprint}=erm_phrase_codec:load_speaker_with_fingerprint(
                SpeakerPath,maps:get(hash,Store)),
            {P,#{id=>Id,path=>SpeakerPath,fingerprint=>Fingerprint}}
    end,
    Wake=maps:get(wake,S),Binding=binding(Store,Profile,Wake),
    Path=case Binding=:=maps:get(legacy_binding,S) of
        true->maps:get(base,Store);
        false->ensure_root(Store),
            filename:join([maps:get(root,Store),binary_to_list(binary:encode_hex(Binding)),"commands.eph"])
    end,
    {ok,Samples}=erm_phrase_codec:read_profile(Path,Binding),
    #{profile=>Profile,speaker_meta=>SpeakerMeta,
      binding=>Binding,path=>Path,samples=>Samples,wake=>Wake}.
binding(Store,Profile,Wake)->crypto:hash(sha256,term_to_binary(
    {erm_phrase_mfcc_v1,Profile,maps:get(device,Store),Wake},[deterministic])).
speaker_path(Store,<<"configured">>)->maps:get(configured,Store);
speaker_path(Store,Id)->filename:join(maps:get(root,Store),binary_to_list(Id)++".speaker").
enrol(Store,Text,Mean)->enrol(Store,Text,Mean,undefined).
enrol(Store=#{state:=S},Text,Mean,Calibration)->
    L=check_name(Store,Text),Id=binary:encode_hex(crypto:strong_rand_bytes(12)),
    ok=ensure_root(Store),
    Base=#{version=>1,label=>L,model_hash=>maps:get(hash,Store),embedding=>Mean},
    P=case Calibration of undefined->Base;_->
        ok=erm_voice_calibration:validate(Calibration),Base#{voice_calibration=>Calibration} end,
    ok=erm_phrase_codec:atomic_write(speaker_path(Store,Id),term_to_binary(P)),
    Store#{state=>S#{active=>Id,voices=>(maps:get(voices,S))#{Id=>L}}}.
commit(Store)->ok=erm_phrase_codec:atomic_write(maps:get(manifest,Store),term_to_binary(maps:get(state,Store))),ok.

%% Older wake-specific writes could create this managed parent at 0755.
%% Tighten only our voices directory; reject a symlink or non-directory.
ensure_root(Store)->
    Root=maps:get(root,Store),
    case file:read_link_info(Root) of
        {error,enoent}->ok=filelib:ensure_dir(filename:join(Root,"unused")),
            ok=file:change_mode(Root,8#700);
        {ok,#file_info{type=directory}}->ok=file:change_mode(Root,8#700);
        _->error(unsafe_voice_directory)
    end.
remove(Store=#{state:=S},Id)->
    case maps:is_key(Id,maps:get(voices,S)) of false->error(unknown_voice_profile);true->ok end,
    case Id of <<"configured">>->ok;_->ensure_root(Store) end,
    %% Check the target before committing the catalogue change. Never recurse
    %% through a caller-supplied path or remove phrase/corpus directories.
    case erm_phrase_codec:private_read(speaker_path(Store,Id),65536) of
        {ok,_}->ok;{error,enoent}->ok;Error->error({voice_delete_check,Error})
    end,
    Active=case maps:get(active,S) of Id->undefined;Other->Other end,
    Store#{state=>S#{active=>Active,voices=>maps:remove(Id,maps:get(voices,S))}}.
delete_file(Store,Id)->
    %% Called only after the removal is durable: a failed unlink must not
    %% reactivate a deleted identity, including after a process restart.
    case file:delete(speaker_path(Store,Id)) of
        ok->ok;{error,enoent}->ok;{error,Reason}->{error,Reason}
    end.

%% No comparison against the old identity when enrolling a NEW voice. Every
%% accepted take must pass quality checks and be consistent with the preceding
%% takes; all must still match the resulting mean. Raw vectors stay in memory.
enrol_check(U,Previous,Limits,Dim)->
    case sample_check(U,Limits,Dim) of
        {reject,_}=Rejected->Rejected;
        {accept,N,Base}->
            case erm_native_voice:enrolment_check(N,Previous,maps:get(enrolment_threshold,Limits)) of
                {accept,_,C}->{accept,N,Base#{accepted=>true,reason=>consistent_voice,consistency=>C}};
                {reject,C}->{reject,Base#{reason=>enrolment_inconsistent,consistency=>C}}
            end
    end.

%% Repeated enrolment collects quality-checked takes before fitting a batch.
sample_check(U,Limits,Dim)->
    #{embedding:=V,ms:=Ms,quality:=Q,sample:=#{frames:=Frames}}=U,
    Base=#{accepted=>false,audio_ms=>Ms,frames=>Frames,quality=>Q,thresholds=>Limits,
        embedding_dimension=>length(V),expected_embedding_dimension=>Dim},
    Checks=[{audio_too_short,Ms>=maps:get(min_speaker_ms,Limits)},
        {audio_too_quiet,maps:get(rms_dbfs,Q)>=maps:get(min_rms_dbfs,Limits)},
        {audio_clipped,maps:get(clipped_fraction,Q)=<maps:get(max_clipped_fraction,Limits)},
        {missing_embedding,V=/=[]},{embedding_dimension_mismatch,length(V)=:=Dim}],
    case [Why||{Why,false}<-Checks] of
        [Reason|_]->{reject,Base#{reason=>Reason}};
        []->case erm_native_voice:normalise(V) of
            {error,_}->{reject,Base#{reason=>invalid_embedding}};
            {ok,N}->{accept,N,Base#{accepted=>true,reason=>quality_passed}}
        end
    end.
