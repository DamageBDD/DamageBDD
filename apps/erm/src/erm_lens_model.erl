%%% Pure, bounded ranking model. insert/3 accepts VERIFIED events only.
-module(erm_lens_model).
-export([new/1, insert/3, prune/2, rank/3, mute/2, follow/2, ids/1, ids/2, size/1]).

new(C) ->
    #{
        events => #{},
        limit => erm_lens_config:integer(max_events, C, 4000, 1, 20000),
        byte_limit => erm_lens_config:integer(max_store_bytes, C, 67108864, 262144, 268435456),
        bytes => 0,
        window => erm_lens_config:integer(window_seconds, C, 172800, 1, 604800),
        muted => maps:from_keys(maps:get(muted, C, []), true),
        following => maps:from_keys(maps:get(following, C, []), true)
    }.
size(S) -> map_size(maps:get(events, S)).
mute(Pub, S) -> S#{muted := (maps:get(muted, S))#{Pub => true}}.
follow(Pub, S) -> S#{following := (maps:get(following, S))#{Pub => true}}.
ids(S) -> ids(S, erlang:system_time(second)).
ids(S, Now) ->
    %% Never keep querying muted, expired, or author-deleted picture IDs.
    [maps:get(id, P) || P <- rank(S, newest, Now)].

insert(E0, Now, S) ->
    E = erm_lens_nostr:event_fields(E0),
    T = maps:get(<<"created_at">>, E),
    K = maps:get(<<"kind">>, E),
    S0 = prune(Now, S),
    case T >= Now - maps:get(window, S0) andalso T =< Now + 60 andalso
         lists:member(K, [1, 5, 6, 7, 16, 20, 1111]) of
        false -> S0;
        true ->
            Es = (maps:get(events, S0))#{maps:get(<<"id">>, E) => E},
            bound(Es, S0)
    end.

prune(Now, S) ->
    Es = maps:filter(fun(_, E) ->
        T = maps:get(<<"created_at">>, E),
        T >= Now - maps:get(window, S) andalso T =< Now + 60
    end, maps:get(events, S)),
    S#{events := Es, bytes => store_bytes(Es)}.

bound(Es, S) ->
    Bytes = store_bytes(Es),
    Limit = maps:get(limit, S),
    ByteLimit = maps:get(byte_limit, S, 67108864),
    case map_size(Es) =< Limit andalso Bytes =< ByteLimit of
        true -> S#{events := Es, bytes => Bytes};
        false ->
            %% A deterministic byte AND count budget; event-count alone can
            %% still retain hundreds of MiB of signed content/tags.
            Sorted = lists:sort(fun({I, A}, {J, B}) ->
                {-maps:get(<<"created_at">>, A), I} <
                {-maps:get(<<"created_at">>, B), J}
            end, maps:to_list(Es)),
            {Kept, Used} = take_budget(Sorted, Limit, ByteLimit, [], 0),
            S#{events := maps:from_list(Kept), bytes => Used}
    end.

take_budget([], _, _, Acc, Used) -> {Acc, Used};
take_budget(_, 0, _, Acc, Used) -> {Acc, Used};
take_budget([{_, E} = Pair | Rest], Left, Remaining, Acc, Used) ->
    Size = erlang:external_size(E),
    case Size =< Remaining of
        true -> take_budget(Rest, Left - 1, Remaining - Size, [Pair | Acc], Used + Size);
        false -> take_budget(Rest, Left, Remaining, Acc, Used)
    end.

store_bytes(Es) ->
    maps:fold(fun(_, E, Acc) -> Acc + erlang:external_size(E) end, 0, Es).

rank(S, Mode, Now) ->
    Muted = maps:get(muted, S),
    All0 = maps:values(maps:get(events, S)),
    %% NIP-09 deletions affect only events by the same signing key.
    Deleted = maps:from_list([
        {{Id, maps:get(<<"pubkey">>, E)}, true}
     || E <- All0,
        maps:get(<<"kind">>, E) =:= 5,
        Id <- erm_lens_nostr:tags(E, <<"e">>)
    ]),
    All = [
        E
     || E <- All0,
        maps:get(<<"created_at">>, E) >= Now - maps:get(window, S),
        maps:get(<<"created_at">>, E) =< Now + 60,
        not maps:is_key(maps:get(<<"pubkey">>, E), Muted),
        not maps:is_key({maps:get(<<"id">>, E), maps:get(<<"pubkey">>, E)}, Deleted)
    ],
    Posts = [
        P
     || E <- All,
        {ok, P} <- [erm_lens_nostr:post(E)],
        Mode =/= following orelse maps:is_key(maps:get(author, P), maps:get(following, S))
    ],
    ById = maps:from_list([{maps:get(id, P), P} || P <- Posts]),
    Counts = lists:foldl(fun(E, Acc) -> count_event(E, ById, Acc) end, #{}, All),
    Ranked = [score(P, maps:get(maps:get(id, P), Counts, #{}), Now) || P <- Posts],
    lists:sort(fun(A, B) -> sort_key(A, Mode) < sort_key(B, Mode) end, Ranked).

count_event(E, Posts, Acc) ->
    case interaction(E) of
        none ->
            Acc;
        {Type, Target} ->
            case maps:get(Target, Posts, undefined) of
                undefined ->
                    Acc;
                P ->
                    Actor = maps:get(<<"pubkey">>, E),
                    Author = maps:get(author, P),
                    Kind = maps:get(<<"kind">>, maps:get(event, P)),
                    EventKind = maps:get(<<"kind">>, E),
                    AuthorTag =
                        case EventKind of
                            1111 -> <<"P">>;
                            _ -> <<"p">>
                        end,
                    RefAuthor = erm_lens_nostr:last_tag(E, AuthorTag),
                    RefKind = erm_lens_nostr:last_tag(E, <<"K">>),
                    RepostKind = erm_lens_nostr:last_tag(E, <<"k">>),
                    Valid =
                        Actor =/= Author andalso
                            (RefAuthor =:= undefined orelse RefAuthor =:= Author) andalso
                            (maps:get(<<"kind">>, E) =/= 1111 orelse
                                RefKind =:= integer_to_binary(Kind)) andalso
                            (EventKind =/= 6 orelse Kind =:= 1) andalso
                            (EventKind =/= 16 orelse RepostKind =:= integer_to_binary(Kind)),
                    case Valid of
                        false ->
                            Acc;
                        true ->
                            PerPost = maps:get(Target, Acc, #{}),
                            Acc#{Target => PerPost#{{Type, Actor} => true}}
                    end
            end
    end.
interaction(E = #{<<"kind">> := 7, <<"content">> := Content}) when
    Content =:= <<"+">>; Content =:= <<>>
->
    {likes, erm_lens_nostr:last_tag(E, <<"e">>)};
interaction(E = #{<<"kind">> := K}) when K =:= 6; K =:= 16 ->
    {reposts, erm_lens_nostr:last_tag(E, <<"e">>)};
interaction(E = #{<<"kind">> := 1111}) ->
    {comments, erm_lens_nostr:last_tag(E, <<"E">>)};
interaction(E = #{<<"kind">> := 1}) ->
    case [Id || [<<"e">>, Id, _, <<"root">> | _] <- maps:get(<<"tags">>, E)] of
        [Id | _] ->
            {comments, Id};
        [] ->
            case erm_lens_nostr:tags(E, <<"e">>) of
                [Id] -> {comments, Id};
                _ -> none
            end
    end;
interaction(_) ->
    none.
score(P, Actors, Now) ->
    L = length([ok || {likes, _} <- maps:keys(Actors)]),
    C = length([ok || {comments, _} <- maps:keys(Actors)]),
    R = length([ok || {reposts, _} <- maps:keys(Actors)]),
    Hours = max(0, Now - maps:get(created_at, P)) / 3600,
    Score = (1.0 + math:log(1 + L + 3 * C + 2 * R)) / math:pow(Hours + 2, 1.3),
    P#{likes => L, comments => C, reposts => R, score => Score}.
sort_key(P, popular) -> {-maps:get(score, P), -maps:get(created_at, P), maps:get(id, P)};
sort_key(P, _) -> {-maps:get(created_at, P), maps:get(id, P)}.
