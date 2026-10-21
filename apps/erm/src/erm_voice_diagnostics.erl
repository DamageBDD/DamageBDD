%% Bounded display measurements for one human capture. No acceptance decisions,
%% speaker embeddings, reconstruction models, PCM or filesystem paths escape.
-module(erm_voice_diagnostics).
-export([capture/2]).

capture(U,C) when is_map(U),is_map(C)->
    try describe(U,C)
    catch _:_ -> #{id=>maps:get(id,C,undefined),kind=>maps:get(kind,C,unknown),
        outcome=>maps:get(outcome,C,unknown),stages=>[],scores=>[],references=>[],
        envelope=>[],mfcc=>[],summary=><<"Capture diagnostics unavailable; see the trace.">>}
    end.

describe(U,C)->
    Check=maps:get(check,C,maps:get(check,U,#{})),
    Snap=maps:get(snapshot,C,#{}),Limits=maps:get(thresholds,Check,maps:get(thresholds,Snap,#{})),
    Q=maps:get(quality,U,#{}),Ms=maps:get(ms,U,0),
    Kind=maps:get(kind,C,unknown),Outcome=maps:get(outcome,C,unknown),
    Sample=maps:get(sample,U,#{}),Frames=maps:get(frames,Sample,0),
    Result=maps:get(result,U,#{}),Reason=maps:get(reason,Check,unknown),
    Consistency=maps:get(consistency,Check,#{}),
    AudioTests=[{Ms,maps:get(min_speaker_ms,Limits,undefined),minimum},
        {maps:get(rms_dbfs,Q,undefined),maps:get(min_rms_dbfs,Limits,undefined),minimum},
        {maps:get(clipped_fraction,Q,undefined),maps:get(max_clipped_fraction,Limits,undefined),maximum}],
    AudioState=checks(AudioTests),
    AudioText=fmt("~B ms · RMS ~ts dBFS · clipping ~ts%",[Ms,
        number(maps:get(rms_dbfs,Q,undefined)),percent(maps:get(clipped_fraction,Q,undefined))]),
    Dim=maps:get(embedding_dimension,Check,0),ExpectedDim=maps:get(expected_embedding_dimension,Check,0),
    FeatureState=case {Kind=:=voice_enrol orelse Frames>0,Dim>0,Dim=:=ExpectedDim,Reason} of
        {true,true,true,R} when R=/=invalid_embedding->pass;
        _->fail
    end,
    SpeakerState=speaker_state(Check),
    SpeakerText=speaker_text(Check,Kind),
    {PhraseState,PhraseText}=phrase_stage(Kind,Result),
    {StoreState,StoreText}=store_stage(Outcome),
    Stages=[stage(audio,<<"Audio quality">>,AudioState,AudioText),
        stage(features,<<"Analysis">>,FeatureState,
            fmt("~B MFCC frames · embedding ~B / ~B dimensions",[Frames,Dim,ExpectedDim])),
        stage(speaker,case Kind of voice_enrol-> <<"Voice consistency">>;_-> <<"Speaker identity">> end,
            SpeakerState,SpeakerText),
        stage(phrase,<<"Phrase content">>,PhraseState,PhraseText),
        stage(storage,<<"Take outcome">>,StoreState,StoreText)],
    Scores=speaker_scores(Check,Kind)++audio_scores(Ms,Q,Limits)++phrase_scores(Kind,Result,Snap),
    ReferenceScores=maps:get(scores,Consistency,[]),
    References=[#{index=>I,score=>float(V)} || {I,V}<-lists:zip(lists:seq(1,min(10,length(ReferenceScores))),
        lists:sublist(ReferenceScores,10)),is_number(V),V>= -1.001,V=<1.001],
    Summary=case Reason of
        enrolment_inconsistent->case maps:get(failed_check,Consistency,undefined) of
            candidate_score-> <<"Rejected at voice consistency: new take versus preceding mean. Accepted samples are unchanged.">>;
            profile_consistency-> <<"Rejected because the proposed mean would make an accepted sample fail. Accepted samples are unchanged.">>;
            _-> <<"Voice samples were inconsistent. Accepted samples are unchanged.">>
        end;
        _->StoreText
    end,
    #{id=>maps:get(id,C,maps:get(id,U,undefined)),kind=>Kind,outcome=>Outcome,
        stages=>Stages,scores=>Scores,references=>References,
        reference_note=><<"Pairwise comparisons only. Acceptance uses the preceding mean and proposed profile minimum.">>,
        envelope=>envelope(maps:get(synthesis,U,<<>>)),
        envelope_note=><<"Captured-segment RMS envelope, 25 ms windows. Not the raw waveform.">>,
        mfcc=>feature_preview(Sample),duration_ms=>Ms,feature_frames=>Frames,
        context=>public_context(maps:get(capture_context,Snap,#{})),summary=>Summary}.

stage(Id,Label,State,Value)->#{id=>Id,label=>Label,status=>State,value=>Value}.
checks(Tests)->
    case lists:any(fun({A,B,_})->not is_number(A) orelse not is_number(B) end,Tests) of
        true->pending;
        false->case lists:all(fun({A,B,minimum})->A>=B;({A,B,maximum})->A=<B end,Tests) of
            true->pass;false->fail end
    end.
speaker_state(#{consistency:=#{failed_check:=_}})->fail;
speaker_state(#{consistency:=_})->pass;
speaker_state(#{speaker_score:=V,thresholds:=#{speaker_threshold:=T}}) when is_number(V),is_number(T)->
    %% A later corpus/storage rejection must not erase a completed identity
    %% comparison. The backend supplies a score only after its prerequisites.
    case V>=T of true->pass;false->fail end;
speaker_state(_)->na.
speaker_text(#{consistency:=#{candidate_score:=undefined}},_)->
    <<"First reference sample; no prior identity comparison.">>;
speaker_text(#{consistency:=#{candidate_score:=V,threshold:=T}=D},_)->
    Base=fmt("Candidate vs preceding mean ~.3f; required ~.3f",[float(V),float(T)]),
    case maps:get(profile_min_score,D,undefined) of
        M when is_number(M)-> <<Base/binary,(fmt(" · proposed profile minimum ~.3f",[float(M)]))/binary>>;
        _->Base
    end;
speaker_text(#{speaker_score:=V,thresholds:=#{speaker_threshold:=T}},_)->
    fmt("Saved-profile cosine ~.3f; required ~.3f",[float(V),float(T)]);
speaker_text(_,voice_enrol)-> <<"Not evaluated: audio or embedding checks did not pass.">>;
speaker_text(_,_)-> <<"Not evaluated: prerequisite checks did not pass.">>.

phrase_stage(voice_enrol,_)->{na,<<"Speaker enrolment does not recognise a command.">>};
phrase_stage(_,#{reason:=matched,action:=A})->{pass,fmt("Content matched ~p; identity remains a separate gate.",[A])};
phrase_stage(_,#{reason:=no_eligible_templates})->{fail,<<"No eligible templates: empty bank or fewer than two duration-compatible takes.">>};
phrase_stage(_,#{reason:=too_far,action:=A})->{fail,fmt("Closest ~p exceeds the distance limit.",[A])};
phrase_stage(_,#{reason:=ambiguous,action:=A})->{fail,fmt("Closest ~p is too close to a competing command.",[A])};
phrase_stage(_,#{reason:=no_features})->{fail,<<"No phrase features captured.">>};
phrase_stage(_,_)->{pending,<<"No phrase result available.">>}.
store_stage(voice_sample_accepted)->{pass,<<"Accepted into this unsaved voice draft.">>};
store_stage(voice_sample_rejected)->{fail,<<"Rejected; accepted voice samples are unchanged.">>};
store_stage(human_sample_saved)->{pass,<<"Human take saved. Train phrase commits command templates.">>};
store_stage(human_sample_rejected)->{fail,<<"Human take rejected; no training sample saved.">>};
store_stage(voice_verified)->{na,<<"Verification only; this take was not saved.">>};
store_stage(_)->{pending,<<"Capture outcome is pending.">>}.

speaker_scores(#{consistency:=D},_)->
    T=maps:get(threshold,D,undefined),
    bar(<<"Candidate / preceding mean">>,maps:get(candidate_score,D,undefined),-1,1,T,minimum)++
    bar(<<"Proposed profile minimum">>,maps:get(profile_min_score,D,undefined),-1,1,T,minimum);
speaker_scores(#{speaker_score:=V,thresholds:=#{speaker_threshold:=T}},_)->
    bar(<<"Saved-profile similarity">>,V,-1,1,T,minimum);
speaker_scores(_,_)->[].
audio_scores(Ms,Q,L)->
    bar(<<"Speech duration (ms)">>,Ms,0,8000,maps:get(min_speaker_ms,L,undefined),minimum)++
    bar(<<"RMS (dBFS)">>,maps:get(rms_dbfs,Q,undefined),-80,0,maps:get(min_rms_dbfs,L,undefined),minimum)++
    bar(<<"Clipped samples (%)">>,times100(maps:get(clipped_fraction,Q,undefined)),0,10,
        times100(maps:get(max_clipped_fraction,L,undefined)),maximum).
phrase_scores(voice_enrol,_,_)->[];
phrase_scores(_,#{reason:=R,distance:=D,margin:=M},S) when R=:=matched;R=:=too_far;R=:=ambiguous->
    Radius=maps:get(max_distance,S,undefined),MinMargin=maps:get(min_margin,S,undefined),
    bar(<<"Phrase distance (lower is better)">>,D,0,max(1,2*numeric(Radius)),Radius,maximum)++
    case M<1000 of true->bar(<<"Competing-command margin">>,M,0,max(1,2*numeric(MinMargin)),MinMargin,minimum);false->[] end;
phrase_scores(_,_,_)->[].
bar(Label,V,Lo,Hi,T,Direction) when is_number(V),is_number(T)->
    [#{label=>Label,value=>float(V),min=>float(Lo),max=>float(Hi),threshold=>float(T),
        pass=>case Direction of minimum->V>=T;maximum->V=<T end,direction=>Direction}];
bar(_,_,_,_,_,_)->[].
numeric(V) when is_number(V)->V;
numeric(_)->0.
times100(V) when is_number(V)->100*V;
times100(_)->undefined.
number(V) when is_number(V)->fmt("~.1f",[float(V)]);
number(_)-> <<"unavailable">>.
percent(V)->number(times100(V)).

%% Each LPC frame is 19 float32 values: RMS, pitch, voicing, 16 coefficients.
%% Only its RMS envelope is exposed; reconstruction parameters remain private.
envelope(<<"ELS1",Samples:32,N:16,B/binary>>) when Samples>=400,Samples=<128000,
    N>0,N=<800,byte_size(B)=:=N*76->
    Values=[R || <<R:32/float-big,_:72/binary>> <= B],
    case length(Values)=:=N andalso lists:all(fun(V)->V>=0 andalso V=<1 end,Values) of
        true->downsample(Values,64);false->[] end;
envelope(_)->[].
feature_preview(#{frames:=N,features:=B}) when N>0,N=<160,is_binary(B),byte_size(B)=:=N*13*4->
    Values=[V || <<V:32/float-big>> <= B],
    case length(Values)=:=N*13 andalso lists:all(fun(V)->abs(V)=<64 end,Values) of
        true->Rows=rows(Values,[]),
            case N=<48 of true->Rows;false->
                [mean_rows(lists:sublist(Rows,(I*N div 48)+1,((I+1)*N div 48)-(I*N div 48))) || I<-lists:seq(0,47)] end;
        false->[]
    end;
feature_preview(_)->[].
rows([],Acc)->lists:reverse(Acc);
rows(Vs,Acc)->{Row,Rest}=lists:split(13,Vs),rows(Rest,[Row|Acc]).
mean_rows(Rows)->[lists:sum([lists:nth(I,R)||R<-Rows])/length(Rows)||I<-lists:seq(1,13)].
downsample(Vs,Limit) when length(Vs)=<Limit->Vs;
downsample(Vs,Limit)->N=length(Vs),
    [begin Part=lists:sublist(Vs,(I*N div Limit)+1,((I+1)*N div Limit)-(I*N div Limit)),
        lists:sum(Part)/length(Part) end || I<-lists:seq(0,Limit-1)].
public_context(M) when is_map(M)->maps:with([device,speaker_model,speaker_dimension,
    input_gain_db,vad_threshold,silence_ms,min_speech_ms,max_segment_ms],M);
public_context(_)->#{}.
fmt(F,A)->unicode:characters_to_binary(io_lib:format(F,A)).
