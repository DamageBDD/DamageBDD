%%% Pure model tests use unsigned fixtures deliberately. Never feed these to UI/relays.
-module(erm_lens_core_tests).
-include_lib("eunit/include/eunit.hrl").

pub(N) -> erm_lens_nostr:hex(<<N:256>>).
event(Id, Pub, Kind, Time, Content, Tags) ->
    #{
        <<"id">> => pub(Id),
        <<"pubkey">> => pub(Pub),
        <<"kind">> => Kind,
        <<"created_at">> => Time,
        <<"content">> => Content,
        <<"tags">> => Tags,
        <<"sig">> => binary:copy(<<"0">>, 128)
    }.
photo(Id, Author, Time) ->
    event(
        Id,
        Author,
        20,
        Time,
        <<"Caption">>,
        [[<<"imeta">>, <<"url https://example.com/photo.jpg">>, <<"m image/jpeg">>]]
    ).
like(Id, Actor, Post) ->
    event(
        Id,
        Actor,
        7,
        1000,
        <<"+">>,
        [[<<"e">>, maps:get(<<"id">>, Post)], [<<"p">>, maps:get(<<"pubkey">>, Post)]]
    ).
model(Events) ->
    lists:foldl(
        fun(E, S) -> erm_lens_model:insert(E, 1000, S) end,
        erm_lens_model:new(#{}),
        Events
    ).
rank(Events) -> erm_lens_model:rank(model(Events), popular, 1000).

canonical_test() ->
    E = event(1, 2, 1, 123, <<"A\n\"B\"\\/">>, []),
    Expected = iolist_to_binary(["[0,\"", pub(2), "\",123,1,[],\"A\\n\\\"B\\\"\\\\/\"]"]),
    ?assertEqual(Expected, erm_lens_nostr:canonical(E)).
canonical_unicode_test() ->
    E = event(1, 2, 1, 123, <<"café"/utf8>>, []),
    ?assertNotEqual(nomatch, binary:match(erm_lens_nostr:canonical(E), <<"café"/utf8>>)).
canonical_order_test() ->
    E = photo(1, 2, 1000),
    ?assertEqual(
        erm_lens_nostr:id(E), erm_lens_nostr:id(maps:from_list(lists:reverse(maps:to_list(E))))
    ).
invalid_id_fails_before_verifier_test() ->
    ?assertEqual({error, bad_event_id}, erm_lens_nostr:verify(photo(1, 2, 1000))).
invalid_schema_test() ->
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(#{})),
    E = photo(1, 2, 1000),
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(E#{<<"tags">> := [[not_binary]]})).
picture_event_test() ->
    {ok, E} = erm_lens_nostr:picture(
        pub(1),
        <<"https://example.com/a.jpg">>,
        <<"image/jpeg">>,
        <<"Alt">>,
        <<"Caption">>,
        <<"Title">>
    ),
    ?assertEqual(20, maps:get(<<"kind">>, E)),
    ?assertEqual([<<"Title">>], erm_lens_nostr:tags(E, <<"title">>)).
image_fallback_test() ->
    E = event(1, 2, 1, 1000, <<"https://example.com/a.png?size=large">>, []),
    ?assertMatch({ok, #{images := [_]}}, erm_lens_nostr:post(E)).
non_image_and_warning_hidden_test() ->
    ?assertEqual(skip, erm_lens_nostr:post(event(1, 2, 1, 1000, <<"text only">>, []))),
    E = photo(2, 2, 1000),
    ?assertEqual(
        skip,
        erm_lens_nostr:post(E#{<<"tags">> := [[<<"content-warning">>] | maps:get(<<"tags">>, E)]})
    ).
reply_not_discovery_test() ->
    E = event(1, 2, 1, 1000, <<"https://example.com/a.jpg">>, [[<<"e">>, pub(3)]]),
    ?assertEqual(skip, erm_lens_nostr:post(E)).
local_filter_test() ->
    E = photo(1, 2, 1000),
    ?assert(erm_lens_nostr:matches(E, #{<<"kinds">> => [20], <<"since">> => 999})),
    ?assertNot(erm_lens_nostr:matches(E, #{<<"kinds">> => [1]})).
event_deduplication_test() ->
    E = photo(1, 2, 1000),
    ?assertEqual(1, erm_lens_model:size(model([E, E, E]))).
unique_reactors_test() ->
    E = photo(1, 2, 1000),
    [P] = rank([E, like(10, 3, E), like(11, 3, E), like(12, 4, E)]),
    ?assertEqual(2, maps:get(likes, P)).
self_reaction_excluded_test() ->
    E = photo(1, 2, 1000),
    [P] = rank([E, like(10, 2, E)]),
    ?assertEqual(0, maps:get(likes, P)).
emoji_not_positive_like_test() ->
    E = photo(1, 2, 1000),
    R = like(10, 3, E),
    [P] = rank([E, R#{<<"content">> := <<":fire:">>}]),
    ?assertEqual(0, maps:get(likes, P)).
wrong_author_target_excluded_test() ->
    E = photo(1, 2, 1000),
    R = like(10, 3, E),
    [P] = rank([E, R#{<<"tags">> := [[<<"e">>, pub(1)], [<<"p">>, pub(999)]]}]),
    ?assertEqual(0, maps:get(likes, P)).
comment_root_author_not_parent_test() ->
    E = photo(1, 2, 1000),
    C = event(
        10,
        3,
        1111,
        1000,
        <<"Reply">>,
        [
            [<<"E">>, pub(1)],
            [<<"K">>, <<"20">>],
            [<<"P">>, pub(2)],
            [<<"e">>, pub(20)],
            [<<"k">>, <<"1111">>],
            [<<"p">>, pub(4)]
        ]
    ),
    [P] = rank([E, C]),
    ?assertEqual(1, maps:get(comments, P)).
kind6_not_photo_repost_test() ->
    E = photo(1, 2, 1000),
    R = event(10, 3, 6, 1000, <<>>, [[<<"e">>, pub(1)]]),
    [P] = rank([E, R]),
    ?assertEqual(0, maps:get(reposts, P)).
kind16_photo_repost_test() ->
    E = photo(1, 2, 1000),
    R = event(10, 3, 16, 1000, <<>>, [[<<"e">>, pub(1)], [<<"k">>, <<"20">>]]),
    [P] = rank([E, R]),
    ?assertEqual(1, maps:get(reposts, P)).
author_only_deletion_test() ->
    E = photo(1, 2, 1000),
    Bad = event(10, 3, 5, 1000, <<>>, [[<<"e">>, pub(1)]]),
    Good = Bad#{<<"pubkey">> := pub(2)},
    ?assertEqual(1, length(rank([E, Bad]))),
    ?assertEqual([], rank([E, Good])).
future_event_excluded_test() ->
    ?assertEqual(0, erm_lens_model:size(model([photo(1, 2, 1061)]))).
bounded_store_test() ->
    S = lists:foldl(
        fun(E, A) -> erm_lens_model:insert(E, 1000, A) end,
        erm_lens_model:new(#{max_events => 2}),
        [photo(N, 2, 990 + N) || N <- lists:seq(1, 5)]
    ),
    ?assertEqual(2, erm_lens_model:size(S)).
deterministic_ranking_test() ->
    Es = [photo(1, 2, 1000), photo(2, 3, 1000)],
    ?assertEqual(rank(Es), rank(lists:reverse(Es))).
local_follow_and_mute_test() ->
    E = photo(1, 2, 1000),
    S = model([E]),
    ?assertEqual([], erm_lens_model:rank(S, following, 1000)),
    S1 = erm_lens_model:follow(pub(2), S),
    ?assertEqual(1, length(erm_lens_model:rank(S1, following, 1000))),
    ?assertEqual([], erm_lens_model:rank(erm_lens_model:mute(pub(2), S1), popular, 1000)).
exact_amount_test() ->
    ?assertEqual({ok, 123000001}, erm_lens_wallet:amount(<<"1.23000001">>, 8)),
    ?assertEqual(<<"1.23000001">>, erm_lens_wallet:format_amount(123000001, 8)),
    ?assertEqual({ok, 42}, erm_lens_wallet:amount(<<"42">>, 0)).
invalid_amount_test() ->
    [
        ?assertEqual({error, invalid_amount}, erm_lens_wallet:amount(B, 8))
     || B <- [<<"0">>, <<"-1">>, <<"+1">>, <<"1e3">>, <<"01">>, <<" 1">>, <<"1.000000001">>]
    ],
    ?assertEqual({error, invalid_amount}, erm_lens_wallet:amount(1.2, 8)).
wallet_disabled_test() ->
    ?assertEqual({error, aeternity_wallet_adapter_not_configured}, erm_lens_wallet:status(#{})).
