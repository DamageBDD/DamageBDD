%% Explicit human enrolment only. Repeated sentences measure within-speaker
%% variation; two further takes validate the frozen reference and threshold.
%% No rejected ambient commands, test takes or playback train this profile.
-module(erm_voice_calibration).
-export([new/1, progress/1, add/4, payload/1, profile/3, threshold/2, validate/1]).

new(N) when is_integer(N), N>=3, N=<10 ->
    #{repeats=>max(3,(N+1) div 2),training=>[],validation=>[],seen=>[],
      discarded=>0,fit=>undefined}.

progress(C=#{repeats:=R,training:=T,validation:=V,discarded:=D}) ->
    Group=next_group(C),
    {Stage,Index,Count}=case Group of
        3->{validation,length(V)+1,2};
        4->{ready,2,2};
        _->{repeats,length([ok || #{group:=G}<-T,G=:=Group])+1,R}
    end,
    #{collected=>length(T)+length(V),target=>2*R+2,stage=>Stage,
      sentence=>min(3,Group),repeat_index=>Index,repeat_target=>Count,
      discarded=>D,prompt=>prompt(min(3,Group)),calibration=>maps:get(fit,C)}.

prompt(1)-> <<"I am speaking naturally at my usual volume.">>;
prompt(2)-> <<"Please play some music while I work today.">>;
prompt(3)-> <<"The microphone can hear me clearly from here.">>.

next_group(#{repeats:=R,training:=T,validation:=V}) ->
    case [G || G<-[1,2],length([ok || #{group:=X}<-T,X=:=G])<R] of
        [G|_]->G;
        [] when length(V)<2->3;
        []->4
    end.

add(V,FP,C=#{seen:=Seen},Configured) ->
    case {lists:member(FP,Seen),length(Seen)>=64,next_group(C)} of
        {true,_,_}->{C,check(false,duplicate_sample,C)};
        {_,true,_}->{C,check(false,enrolment_attempt_limit,C)};
        {_,_,4}->{C,check(false,enrolment_complete,C)};
        {_,_,3}->validation(V,FP,C#{seen=>[FP|Seen]});
        {_,_,G}->training(#{embedding=>V,fingerprint=>FP,group=>G},C#{seen=>[FP|Seen]},Configured)
    end.

training(Row,C=#{repeats:=R,training:=T},Configured) ->
    Added=C#{training=>T++[Row]},
    case length(T)+1=:=2*R of
        false->{Added,check(true,repeat_collected,Added)};
        true->
            %% A maximum mutually consistent majority avoids anchoring on the
            %% first take. Equal competing clusters are never selected by order.
            case core(T++[Row],threshold_floor(Configured)) of
                {ok,Keep} when length(Keep)=:=2*R->
                    {_,Fit}=fit(Keep,Configured),Next=Added#{fit=>Fit},
                    {Next,check(true,repeat_reference_ready,Next)};
                {ok,Keep}->
                    Next=Added#{training=>Keep,discarded=>maps:get(discarded,C)+2*R-length(Keep)},
                    Retained=lists:member(Row,Keep),
                    {Next,check(Retained,enrolment_outlier_removed,Next)};
                error->
                    Next=Added#{training=>[],fit=>undefined,discarded=>maps:get(discarded,C)+2*R},
                    {Next,check(false,enrolment_batch_inconsistent,Next)}
            end
    end.

validation(V,FP,C=#{training:=T,validation:=Held,fit:=Fit}) ->
    {ok,Mean}=centroid([maps:get(embedding,X)||X<-T]),
    Score=erm_native_voice:score(V,Mean),
    case Score>=maps:get(threshold,Fit) of
        true->
            Next=C#{validation=>Held++[#{embedding=>V,fingerprint=>FP,group=>3}]},
            {Next,(check(true,repeat_validation_passed,Next))#{speaker_score=>Score}};
        false->{C,(check(false,validation_speaker_mismatch,C))#{speaker_score=>Score}}
    end.

check(Accepted,Reason,C) ->
    P=progress(C),Fit=maps:get(fit,C),
    Consistency=case Fit of
        undefined->#{method=>repeated_sentences,stage=>maps:get(stage,P),threshold=>undefined};
        _->Fit#{method=>repeated_sentences,stage=>maps:get(stage,P)}
    end,
    #{accepted=>Accepted,reason=>Reason,consistency=>Consistency,
      collected=>maps:get(collected,P),target=>maps:get(target,P),discarded=>maps:get(discarded,P)}.

payload(C)->maps:with([repeats,training,validation],C).

%% Recompute at the backend boundary. Never trust the UI's threshold or mean.
profile(#{repeats:=R,training:=T,validation:=V}=P,Configured,Dim) ->
    try
        true=map_size(P)=:=3 andalso is_integer(R) andalso R>=3 andalso R=<5,
        true=is_list(T) andalso length(T)=:=2*R andalso is_list(V) andalso length(V)=:=2,
        Rows=T++V,
        lists:foreach(fun(#{embedding:=E,fingerprint:=FP,group:=G}=Row)->
            true=map_size(Row)=:=3 andalso is_list(E) andalso length(E)=:=Dim,
            true=is_binary(FP) andalso byte_size(FP)=:=32 andalso lists:member(G,[1,2,3]),
            true=lists:all(fun(X)->is_number(X) andalso abs(X)=<1.001 end,E),
            {ok,N}=erm_native_voice:normalise(E),
            true=abs(erm_native_voice:score(N,E)-1.0)<0.00001
        end,Rows),
        true=length(lists:usort([maps:get(fingerprint,X)||X<-Rows]))=:=length(Rows),
        [R,R]=[length([ok||#{group:=G}<-T,G=:=I])||I<-[1,2]],
        true=lists:all(fun(#{group:=G})->G=:=3 end,V),
        {ok,Keep}=core(T,threshold_floor(Configured)),true=length(Keep)=:=length(T),
        {Mean,Fit}=fit(T,Configured),
        Scores=[erm_native_voice:score(maps:get(embedding,X),Mean)||X<-V],
        true=lists:min(Scores)>=maps:get(threshold,Fit),
        Calibration=Fit#{validation_min=>lists:min(Scores),validation_count=>2},
        ok=validate(Calibration),{ok,Mean,Calibration}
    catch _:_->{error,invalid_or_unvalidated_voice_calibration} end;
profile(_,_,_)->{error,invalid_or_unvalidated_voice_calibration}.

fit(Rows,Configured) ->
    Es=[maps:get(embedding,X)||X<-Rows],{ok,Mean}=centroid(Es),
    Loo=[begin {ok,M}=centroid(lists:delete(E,Es)),
        erm_native_voice:score(E,M) end||E<-Es],
    Cross=[begin G=maps:get(group,Row),
        {ok,M}=centroid([maps:get(embedding,X)||X<-Rows,maps:get(group,X)=/=G]),
        erm_native_voice:score(maps:get(embedding,Row),M) end||Row<-Rows],
    Low=min(lists:min(Loo),lists:min(Cross)),
    T=max(threshold_floor(Configured),min(Configured,Low-0.04)),
    {Mean,#{method=>repeated_sentences,threshold=>T,configured_threshold=>Configured,
        floor=>threshold_floor(Configured),loo_min=>lists:min(Loo),cross_sentence_min=>lists:min(Cross),
        training_count=>length(Rows),negative_samples=>0}}.

threshold_floor(Configured)->min(Configured,max(0.50,Configured-0.20)).

threshold(undefined,Configured)->Configured;
threshold(Calibration,Configured)->
    case validate(Calibration) of
        ok->max(threshold_floor(Configured),min(Configured,maps:get(threshold,Calibration)));
        _->Configured
    end.

validate(#{method:=repeated_sentences,threshold:=T,configured_threshold:=Configured,
           floor:=F,loo_min:=L,cross_sentence_min:=C,training_count:=N,
           negative_samples:=0,validation_min:=V,validation_count:=2}=M) ->
    case map_size(M)=:=10 andalso is_integer(N) andalso N>=6 andalso N=<10 andalso
         lists:all(fun(X)->is_number(X) andalso X>= -1.001 andalso X=<1.001 end,[T,Configured,F,L,C,V])
         andalso Configured>=0.01 andalso Configured=<0.99 andalso
         abs(F-threshold_floor(Configured))<0.000001 andalso T>=F andalso T=<Configured andalso V>=T of
        true->ok;false->{error,invalid_voice_calibration}
    end;
validate(_)->{error,invalid_voice_calibration}.

centroid([First|_]=Es)->
    Sum=lists:foldl(fun(E,A)->lists:zipwith(fun(X,Y)->X+Y end,E,A) end,
        lists:duplicate(length(First),0.0),Es),
    erm_native_voice:normalise(Sum).

core(Rows,Minimum)->
    case coherent(Rows,Minimum) of true->{ok,Rows};false->majority_core(Rows,Minimum) end.
majority_core(Rows,Minimum) ->
    Indexed=lists:zip(lists:seq(0,length(Rows)-1),Rows),
    Sets=[[Row||{I,Row}<-Indexed,Mask band (1 bsl I)=/=0]
          ||Mask<-lists:seq(1,(1 bsl length(Rows))-1)],
    Eligible=[S||S<-Sets,length(S)>=max(3,(3*length(Rows)+3) div 4),coherent(S,Minimum)],
    case Eligible of
        []->error;
        _->Size=lists:max([length(S)||S<-Eligible]),
            case [S||S<-Eligible,length(S)=:=Size] of [Best]->{ok,Best};_->error end
    end.
coherent([],_) -> true;
coherent([#{embedding:=E}|Tail],Minimum) ->
    lists:all(fun(#{embedding:=V})->erm_native_voice:score(E,V)>=Minimum end,Tail)
        andalso coherent(Tail,Minimum).
