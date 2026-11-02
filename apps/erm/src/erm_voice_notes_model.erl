%% Locally reviewed ECAI acoustic references. No guessed transcript or score is
%% ever promoted to a speaker label. Validation calibrates; test stays held out.
-module(erm_voice_notes_model).
-export([build/1,score/2,evaluate/2]).
build(Notes)->
    try
        Rows=[row(N)||N<-Notes,lists:member(maps:get(split,N,exclude),[train,validation]),usable(N)],
        Hashes=[maps:get(hash,R)||R<-Rows],
        true_or_error(length(Hashes)=:=length(lists:usort(Hashes)),duplicate_recording_in_dataset),
        Train=[R||R=#{split:=train,speaker:=L}<-Rows,L=/= <<"unknown">>],
        true_or_error(Train=/=[],no_reviewed_training_notes),
        true_or_error(length(Train)=<500,training_limit_500_notes),
        Labels=lists:usort([maps:get(speaker,R)||R<-Train]),
        Val=[R||R=#{split:=validation}<-Rows],
        Model=#{schema=>1,frontend=>ecai_voice_features:version(),
          revision=>erlang:system_time(microsecond),templates=>Train,speakers=>Labels,
          training_count=>length(Train),validation_count=>length(Val),
          development_hashes=>Hashes,test_used_for_build=>false},
        {ok,Model#{calibration=>calibration(Val,Model)}}
    catch throw:R->{error,R};_:R->{error,{model_build,R}} end.
usable(#{speaker:=L,analysis:=#{q:=Q,frontend:=V},pcm_sha256:=H}) ->
    is_binary(L) andalso byte_size(L)>0 andalso byte_size(L)=<128 andalso
    V=:=ecai_voice_features:version() andalso is_binary(H) andalso byte_size(H)=:=32 andalso
    is_list(Q) andalso length(Q)=:=30 andalso
    lists:all(fun(X)->is_integer(X) andalso abs(X)=<255 end,Q);
usable(_)->false.
row(N)->#{id=>maps:get(id,N),hash=>maps:get(pcm_sha256,N),speaker=>maps:get(speaker,N),
    split=>maps:get(split,N),q=>maps:get(q,maps:get(analysis,N))}.
score(#{analysis:=#{q:=Q}}=N,Model)->
    case maps:get(frontend,maps:get(analysis,N),undefined)=:=maps:get(frontend,Model) of
        false->#{status=>unavailable,reason=>frontend_mismatch};
        true->score_q(Q,maps:get(pcm_sha256,N),Model)
    end;
score(_,_) -> #{status=>unavailable,reason=>no_usable_acoustic_features}.
score_q(Q,Hash,Model)->
    All=maps:get(templates,Model),
    Seen=lists:any(fun(R)->maps:get(hash,R)=:=Hash end,All),
    %% Leave out this exact waveform, including copies saved under other IDs.
    Train=[R||R<-All,maps:get(hash,R)=/=Hash],
    Ranked=lists:sort([{distance(Q,maps:get(q,R)),maps:get(speaker,R),maps:get(id,R)}||R<-Train]),
    Labels=lists:usort([L||{_,L,_}<-Ranked]),
    BySpeaker=lists:sort([begin
        Ds=[D||{D,X,_}<-Ranked,X=:=L],K=min(3,length(Ds)),
        {lists:sum(lists:sublist(Ds,K))/K,L}
    end||L<-Labels]),
    case BySpeaker of
        []->#{status=>unavailable,reason=>no_independent_reference,seen_in_training=>Seen};
        [{D,L}|Rest]->
            Margin=case Rest of [{D2,_}|_]->D2-D;[]->undefined end,
            Base=#{speaker=>L,distance=>D,margin=>Margin,seen_in_training=>Seen,
                score_scale=>quantized_l1_lower_is_closer,ranking=>BySpeaker,
                reference_count=>length(Train),model_revision=>maps:get(revision,Model)},
            case maps:get(calibration,Model,#{status=>uncalibrated}) of
                #{status:=calibrated,max_distance:=Max,min_margin:=Min}=C ->
                    Match=D=<Max andalso (Min=:=0 orelse (is_number(Margin) andalso Margin>=Min)),
                    Base#{status=>case Match of true->matched;false->unknown end,limits=>C};
                C->Base#{status=>uncalibrated,calibration=>C}
            end
    end.
distance(A,B)->{ok,D}=ecai_voice_curve:integer_distance(A,B),D.
calibration([],_) -> #{status=>uncalibrated,reason=>add_separate_validation_notes};
calibration(Rows,Model)->
    Labels=maps:get(speakers,Model),
    Covered=lists:usort([L||#{speaker:=L}<-Rows,lists:member(L,Labels)]),
    case Covered=:=Labels of
        false->#{status=>uncalibrated,reason=>validation_needed_for_every_speaker};
        true->
            Results=[{R,score_q(maps:get(q,R),maps:get(hash,R),Model)}||R<-Rows],
            Genuine=[own_distance(R,Model)||{R,_}<-Results,lists:member(maps:get(speaker,R),Labels)],
            Impostor=lists:append([impostor_distances(R,Model)||{R,_}<-Results]),
            Correct=lists:all(fun({R,S})->
                L=maps:get(speaker,R),L=:= <<"unknown">> orelse
                (maps:get(speaker,S,undefined)=:=L)
            end,Results),
            case {Genuine,Impostor,Correct} of
                {[_|_],[_|_],true}->
                    G=lists:max(Genuine),I=lists:min(Impostor),
                    case G<I of
                        true->
                            Margins=[maps:get(margin,S)||{R,S}<-Results,
                              maps:get(speaker,R)=/= <<"unknown">>,is_number(maps:get(margin,S,undefined))],
                            #{status=>calibrated,max_distance=>(G+I)/2,
                              min_margin=>case Margins of []->0;_->max(0,lists:min(Margins)/2) end,
                              worst_genuine=>G,nearest_impostor=>I,validation_count=>length(Rows)};
                        false->#{status=>uncalibrated,reason=>validation_distributions_overlap,
                            worst_genuine=>G,nearest_impostor=>I}
                    end;
                _->#{status=>uncalibrated,reason=>need_correct_genuine_and_other_speaker_validation}
            end
    end.
label_distance(Q,L,Model)->
    Ds=lists:sort([distance(Q,maps:get(q,T))||T<-maps:get(templates,Model),maps:get(speaker,T)=:=L]),
    K=min(3,length(Ds)),lists:sum(lists:sublist(Ds,K))/K.
own_distance(#{q:=Q,speaker:=L},Model)->label_distance(Q,L,Model).
impostor_distances(#{q:=Q,speaker:=L},Model)->
    [label_distance(Q,X,Model)||X<-maps:get(speakers,Model),X=/=L].
evaluate(Notes,Model)->
    case maps:get(calibration,Model) of
        #{status:=calibrated}->
            Test=[N||N<-Notes,maps:get(split,N,exclude)=:=test,usable(N)],
            Hashes=[maps:get(pcm_sha256,N)||N<-Test],
            Development=maps:get(development_hashes,Model,[]),
            case length(Hashes)=:=length(lists:usort(Hashes)) andalso
                not lists:any(fun(H)->lists:member(H,Development) end,Hashes) of
                false->#{status=>unavailable,reason=>duplicate_audio_across_development_and_test};
                true->
            Results=[#{id=>maps:get(id,N),expected=>maps:get(speaker,N),result=>score(N,Model)}||N<-Test],
            Correct=length([ok||#{expected:=E,result:=R}<-Results,correct(E,R)]),
            #{status=>evaluated,model_revision=>maps:get(revision,Model),count=>length(Results),
                correct=>Correct,errors=>length(Results)-Correct,results=>Results}
            end;
        _->#{status=>unavailable,reason=>calibrate_on_validation_before_test}
    end.
correct(<<"unknown">>,#{status:=unknown})->true;
correct(E,#{status:=matched,speaker:=E,seen_in_training:=false})->true;
correct(_,_) ->false.
true_or_error(true,_)->ok;
true_or_error(false,R)->throw(R).
