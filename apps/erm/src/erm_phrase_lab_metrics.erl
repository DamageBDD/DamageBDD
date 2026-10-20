%% No feedback from generated audio enters threshold selection. Scores are
%% distances, not probabilities. Empty/insufficient evaluation is never a pass.
-module(erm_phrase_lab_metrics).
-export([summary/3, recommend/3]).
prediction(#{result:=#{reason:=Reason,action:=A,distance:=D,margin:=M}},Radius,Margin)
    when Reason=/=1,Reason=/=4,D=<Radius,M>=Margin -> A;
prediction(_,_,_) -> undefined.
summary(Rows,Radius,Margin) ->
    Content=[{maps:get(expected,R),prediction(R,Radius,Margin)}||R<-Rows],
    Gated=[{maps:get(expected,R),case maps:get(speaker_ok,R) of true->prediction(R,Radius,Margin);false->undefined end}||R<-Rows],
    #{samples=>length(Rows),content=>count(Content),with_speaker_gate=>count(Gated),
      max_distance=>Radius,min_margin=>Margin,coverage=>coverage(Rows)}.
count(Pairs) ->
    Pos=length([ok||{E,_}<-Pairs,E=/=unknown]),Neg=length(Pairs)-Pos,
    Miss=length([ok||{E,undefined}<-Pairs,E=/=unknown]),
    Wrong=length([ok||{E,P}<-Pairs,E=/=unknown,P=/=undefined,P=/=E]),
    False=length([ok||{unknown,P}<-Pairs,P=/=undefined]),
    #{commands=>Pos,negatives=>Neg,misses=>Miss,wrong_commands=>Wrong,false_activations=>False,
      command_error_rate=>ratio(Miss+Wrong,Pos),false_activation_rate=>ratio(False,Neg)}.
ratio(_,0)->not_evaluated;
ratio(N,D)->N/D.
coverage(Rows)->lists:foldl(fun(#{expected:=A},M)->maps:update_with(A,fun(N)->N+1 end,1,M)end,#{},Rows).
recommend(Rows,Actions,Current) ->
    Coverage=coverage(Rows),
    Enough=Actions=/=[] andalso maps:get(unknown,Coverage,0)>=5 andalso
        lists:all(fun(A)->maps:get(A,Coverage,0)>=2 end,Actions),
    case Enough of
        false -> #{status=>insufficient_human_validation,coverage=>Coverage,
            required=>#{per_enrolled_action=>2,unknown_phrases=>5}};
        true ->
            Radius=maps:get(max_distance,Current),Margin=maps:get(min_margin,Current),
            Candidates=[summary(Rows,R,M)||R<-lists:usort([Radius,0.10,0.15,0.20,0.25,0.30,0.35,0.45,0.60]),
                M<-lists:usort([Margin,0.02,0.04,0.08,0.12,0.20])],
            Ranked=lists:sort([{rank(C,Radius,Margin),C}||C<-Candidates]),
            {_,Best}=hd(Ranked),
            #{status=>proposal_only,proposed=>Best,baseline=>summary(Rows,Radius,Margin),
              promotion=>manual_after_fresh_test_and_human_listening,
              note=>no_guarantee_for_unseen_noise_negations_or_replays}
    end.
rank(C,Radius,Margin)->
    %% Content safety also matters even when a negative failed speaker matching.
    M=maps:get(content,C),
    {maps:get(false_activations,M)+maps:get(wrong_commands,M),maps:get(misses,M),
     abs(maps:get(max_distance,C)-Radius)+abs(maps:get(min_margin,C)-Margin),
     maps:get(max_distance,C),-maps:get(min_margin,C)}.
