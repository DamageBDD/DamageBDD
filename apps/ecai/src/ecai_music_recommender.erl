%% Deterministic metadata baseline for ECDJ. This does not claim that a
%% content hash or hash-to-curve mapping encodes musical similarity.
-module(ecai_music_recommender).
-export([default_policy/0, recommend/5, index_record/1, index_terms/1]).

default_policy() -> ecai_dj_package:default().

%% Feedback remains local: id => -2..2, or #{rating => -2..2, plays => N}.
%% recent_ids is newest first. Missing tempo is neutral, not zero-tempo music.
recommend(Tracks, Context, Policy, Feedback, Limit)
  when is_list(Tracks), length(Tracks) =< 10000, is_map(Context),
       is_map(Feedback), map_size(Feedback) =< 10000,
       is_integer(Limit), Limit >= 0, Limit =< 100 ->
    case ecai_dj_package:validate(Policy) of
        {ok, P} ->
            try
                C = context(Context),
                Valid = [track(T) || T <- Tracks],
                true = length(Valid) =:= length(lists:usort([maps:get(id,T) || T <- Valid])),
                Scored = [score(T,C,P,Feedback) || T <- Valid,
                          not excluded(T,P)],
                Sorted = lists:sort(fun(A,B) ->
                    {-maps:get(score,A),maps:get(id,A)} <
                    {-maps:get(score,B),maps:get(id,B)}
                end, Scored),
                {ok, lists:sublist(Sorted,Limit)}
            catch
                throw:R -> {error,R};
                error:_ -> {error,invalid_recommendation_input}
            end;
        Error -> Error
    end;
recommend(_,_,_,_,_) -> {error,invalid_recommendation_input}.

%% Ready for the existing ECAI term/index pipeline without loading a GPU NIF.
index_record(T) ->
    V = track(T),
    #{name => maps:get(title,V), title => maps:get(title,V),
      text => maps:get(artist,V,<<>>), type => <<"music">>,
      tags => maps:get(tags,V,[])}.
index_terms(T) -> ecai_terms:terms_from_record(index_record(T)).

track(T) when is_map(T) ->
    Id = text(maps:get(id,T),256),
    Title = text(maps:get(title,T),1024),
    Artist = text(maps:get(artist,T,<<"Unknown artist">>),1024),
    Tags = tag_list(maps:get(tags,T,[])),
    case maps:find(bpm,T) of
        {ok,B} when is_integer(B), B > 0, B =< 400 -> ok;
        error -> ok;
        _ -> throw(invalid_bpm)
    end,
    T#{id => Id, title => Title, artist => Artist, tags => Tags};
track(_) -> throw(invalid_track).

context(C) ->
    Tags = tag_list(maps:get(tags,C,[])) ++ tag_list(maps:get(preferred_tags,C,[])),
    Mood0 = maps:get(mood,C,<<>>),
    Mood = case Mood0 of <<>> -> <<>>; _ -> hd(tag_list([Mood0])) end,
    Recent0 = maps:get(recent_ids,C,[]),
    true = is_list(Recent0) andalso length(Recent0) =< 1000,
    Recent = [text(B,256) || B <- Recent0],
    Bpm = maps:get(target_bpm,C,0),
    true = is_integer(Bpm) andalso Bpm >= 0 andalso Bpm =< 400,
    %% Time-of-day enters as an explicit coarse tag. The caller supplies local
    %% time; replay never consults the machine clock or infers location.
    Time = maps:get(time_of_day,C,<<>>),
    TimeTags = case Time of
        <<>> -> [];
        _ -> tag_list([Time])
    end,
    #{tags => lists:usort(Tags ++ TimeTags), mood => Mood,
      recent_ids => Recent, target_bpm => Bpm}.

excluded(T,P) -> intersection(maps:get(tags,T),maps:get(excluded_tags,P)) =/= [].

score(T,C,P,F) ->
    Id = maps:get(id,T), Tags = maps:get(tags,T), W = maps:get(weights,P),
    Matched = intersection(Tags,lists:usort(maps:get(preferred_tags,P) ++ maps:get(tags,C))),
    TagScore = length(Matched)*maps:get(tags,W),
    Mood = maps:get(mood,C),
    MoodScore = case lists:member(Mood,Tags) of true -> maps:get(mood,W); false -> 0 end,
    Target = case maps:get(target_bpm,C) of 0 -> maps:get(target_bpm,P); V -> V end,
    BpmScore = case {Target,maps:find(bpm,T)} of
        {0,_} -> 0;
        {_,error} -> 0;
        {_,{ok,B}} -> -abs(B-Target)*maps:get(bpm,W)
    end,
    {Rating,Plays} = feedback(maps:get(Id,F,0)),
    RatingScore = Rating*maps:get(rating,W),
    Recent = maps:get(recent_ids,C),
    RepetitionScore = case lists:member(Id,Recent) of
        true -> -maps:get(repetition,W);
        false -> 0
    end,
    NoveltyScore = case Plays =:= 0 andalso not lists:member(Id,Recent) of
        true -> maps:get(discovery,P);
        false -> 0
    end,
    SeedScore = case lists:member(Id,maps:get(seed_ids,P)) of
        true -> maps:get(seed,W);
        false -> 0
    end,
    Parts = #{tags => TagScore, mood => MoodScore, tempo => BpmScore,
              rating => RatingScore, repetition => RepetitionScore,
              discovery => NoveltyScore, seed => SeedScore},
    Reasons = #{matched_tags => Matched, requested_mood => Mood,
                target_bpm => Target, components => Parts,
                algorithm => <<"ecai-music-metadata/v1">>},
    T#{score => lists:sum(maps:values(Parts)), reasons => Reasons}.

feedback(V) when is_integer(V), V >= -2, V =< 2 -> {V,0};
feedback(M) when is_map(M) ->
    R = maps:get(rating,M,0), N = maps:get(plays,M,0),
    case is_integer(R) andalso R >= -2 andalso R =< 2 andalso
         is_integer(N) andalso N >= 0 andalso N =< 1000000000 of
        true -> {R,N}; false -> throw(invalid_feedback)
    end;
feedback(_) -> throw(invalid_feedback).

text(B, Max) when is_binary(B), byte_size(B) > 0, byte_size(B) =< Max ->
    case unicode:characters_to_binary(B,utf8,utf8) of B -> B; _ -> throw(invalid_text) end;
text(_,_) -> throw(invalid_text).

tag_list(L) when is_list(L), length(L) =< 64 ->
    lists:usort([unicode:characters_to_binary(string:casefold(unicode:characters_to_list(text(B,128)))) || B <- L]);
tag_list(_) -> throw(invalid_tags).

intersection(A,B) -> ordsets:intersection(lists:usort(A),lists:usort(B)).
