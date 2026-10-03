-module(erm_voice_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erm_playlist.hrl").

opts() -> #{settle_ms => 1000, command_window_ms => 8000,
            rearm_silence_ms => 6000, command_dedupe_ms => 6000,
            max_command_bytes => 512}.
feed(Text, Time, S) -> erm_voice_boundary:feed(Text, ["bob"], Time, S, opts()).
tick(Time, S) -> erm_voice_boundary:tick(Time, S, opts()).

wake_test_() ->
    [?_assertEqual(Expected, erm_voice_boundary:wake(Text, ["bob"])) ||
        {Text, Expected} <- [
            {"BOB, next song!", {wake, <<"next song!">>}},
            {"Hey Bob, pause.", {wake, <<"pause.">>}},
            {"okay bob stop", {wake, <<"stop">>}},
            {"Bobby next", nomatch},
            {"bobcat", nomatch},
            {"bob_name", nomatch},
            {"I was talking to Bob", nomatch},
            {"play a Bob Dylan song", nomatch},
            {[16#FF22,16#FF2F,16#FF22], {wake, <<>>}},
            {[$b,$o,$b,16#0301], nomatch}
        ]].
longer_alias_test() ->
    ?assertEqual({wake, <<"next">>},
                 erm_voice_boundary:wake("bob junior next", ["bob", "bob junior"])).

settling_revision_test() ->
    S1 = feed("bob play", 0, erm_voice_boundary:new()),
    {none, S2} = tick(500, S1),
    S3 = feed("bob play wonderwall", 700, S2),
    {none, S4} = tick(1200, S3),
    ?assertMatch({{command, <<"play wonderwall">>}, _}, tick(1700, S4)).
wake_separate_record_test() ->
    S1 = feed("bob", 0, erm_voice_boundary:new()),
    {none, S2} = tick(1500, S1),
    S3 = feed("next song", 1600, S2),
    ?assertMatch({{command, <<"next song">>}, _}, tick(2600, S3)).
rolling_redraw_exactly_once_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = lists:foldl(fun(T, S) ->
        S0 = feed("bob next", T, S),
        {none, SNext} = tick(T, S0), SNext
    end, S2, lists:seq(1100, 15000, 100)),
    ?assertEqual(locked, maps:get(phase, S3)).
context_closed_after_command_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = feed("pause", 1200, S2),
    ?assertMatch({none, _}, tick(2400, S3)).
no_prewake_context_test() ->
    S1 = feed("talk about work", 0, erm_voice_boundary:new()),
    S2 = feed("bob next", 200, S1),
    ?assertMatch({{command, <<"next">>}, _}, tick(1200, S2)).
expired_wake_test() ->
    S1 = feed("bob", 0, erm_voice_boundary:new()),
    {none, S2} = tick(8000, S1),
    S3 = feed("next", 8100, S2),
    ?assertMatch({none, _}, tick(10000, S3)).
expired_partial_never_executes_test() ->
    S1 = feed("bob", 0, erm_voice_boundary:new()),
    S2 = feed("play", 7500, S1),
    ?assertMatch({none, _}, tick(8500, S2)).
new_wake_after_silence_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    {none, S3} = tick(7000, S2),
    S4 = feed("bob next", 7100, S3),
    ?assertMatch({{command, <<"next">>}, _}, tick(8100, S4)).
unrelated_fragment_cancels_test() ->
    S1 = feed("bob play wonderwall", 0, erm_voice_boundary:new()),
    S2 = feed("the weather is nice", 500, S1),
    ?assertMatch({none, _}, tick(2000, S2)).
overlapping_fragment_test() ->
    S1 = feed("bob play wonderwall", 0, erm_voice_boundary:new()),
    S2 = feed("wonderwall by oasis", 500, S1),
    ?assertMatch({{command, <<"play wonderwall by oasis">>}, _}, tick(1500, S2)).
long_command_rejected_test() ->
    S = feed(<<"bob ", (binary:copy(<<"a">>, 600))/binary>>, 0, erm_voice_boundary:new()),
    ?assertMatch({none, _}, tick(1500, S)).

fast_intents_test_() ->
    [?_assertEqual({ok, #{action => A}}, erm_voice_intent:parse(T)) ||
        {T, A} <- [{"play", play}, {"start", play}, {"resume", play},
                   {"PAUSE!", pause}, {"stop music", stop}, {"next song", next},
                   {"previous track", previous}, {"show player", show_player}]].
volume_validation_test() ->
    ?assertEqual({ok, #{action => volume, value => 35}}, erm_voice_intent:parse("set volume to 35")),
    ?assertMatch({error, _}, erm_voice_intent:parse("volume 101")).
negated_command_test() ->
    ?assertEqual({error, negated_command}, erm_voice_intent:parse("don't play")),
    ?assertMatch({ok, #{action := play_song}}, erm_voice_intent:parse("play don't stop me now")).
model_allowlist_test() ->
    ?assertMatch({error, _}, erm_voice_intent:validate(
        #{<<"action">> => <<"os:cmd">>, <<"query">> => <<"rm -rf /">>, <<"value">> => 0}, #{})),
    ?assertMatch({error, _}, erm_voice_intent:validate(
        #{<<"action">> => <<"volume">>, <<"query">> => <<>>, <<"value">> => -1}, #{})),
    ?assertMatch({error, _}, erm_voice_intent:validate(
        #{<<"action">> => <<"next">>, <<"query">> => <<>>, <<"value">> => 0,
          <<"code">> => <<"anything">>}, #{})).
custom_action_test() ->
    O = #{actions => [{<<"lights_on">>, "Turn on lights", {test_lights, on}}]},
    ?assertMatch({ok, #{action := custom, name := <<"lights_on">>}},
        erm_voice_intent:validate(#{<<"action">> => <<"lights_on">>,
                                   <<"query">> => <<"office">>, <<"value">> => 0}, O)),
    ?assertMatch({ok, _}, erm_voice:options(O)),
    ?assertMatch({error, _}, erm_voice:options(#{actions => [{<<"stop">>, "override", {m,f}}]})).

song_selection_test() ->
    T1 = #track{id = 1, path = "/music/Wonderwall.flac", artist = "Oasis"},
    T2 = #track{id = 2, path = "/covers/Wonderwall.mp3", artist = "Ryan Adams"},
    Tracks = [{0, T1}, {1, T2}],
    ?assertEqual({ok, T1}, erm_voice_media:select_song("wonderwall by oasis", Tracks)),
    ?assertMatch({error, {ambiguous_song, _}}, erm_voice_media:select_song("wonderwall", Tracks)),
    ?assertEqual({error, song_not_found}, erm_voice_media:select_song("made up title", Tracks)),
    ?assertEqual({error, song_not_found}, erm_voice_media:select_song("", Tracks)).

legacy_revision_cannot_change_action_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = feed("bob pause", 1200, S2),
    ?assertMatch({none, _}, tick(2200, S3)).
late_revision_not_second_action_test() ->
    S1 = feed("bob play wonderwall", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = feed("bob play wonderwall by oasis", 1400, S2),
    ?assertMatch({none, _}, tick(2500, S3)).
split_multiword_wake_test() ->
    S1 = erm_voice_boundary:feed("hey thread", ["thread ripper"], 0,
                                erm_voice_boundary:new(), opts()),
    S2 = erm_voice_boundary:feed("ripper next", ["thread ripper"], 600, S1, opts()),
    ?assertMatch({{command, <<"next">>}, _}, tick(1700, S2)).
expired_multiword_prefix_test() ->
    S1 = erm_voice_boundary:feed("thread", ["thread ripper"], 0,
                                erm_voice_boundary:new(), opts()),
    S2 = erm_voice_boundary:feed("ripper next", ["thread ripper"], 2000, S1, opts()),
    ?assertMatch({none, _}, tick(3100, S2)).

legacy_wake_only_requires_rearm_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = feed("bob", 1400, S2),
    S4 = feed("pause", 1800, S3),
    ?assertMatch({none, _}, tick(2900, S4)).

structured(Id, Text, Final, Time, S) ->
    feed(#{utterance_id => Id, text => Text, final => Final}, Time, S).

partial_waits_for_final_test() ->
    S1 = structured(<<"u1">>, <<"Bob play">>, false, 0, erm_voice_boundary:new()),
    {none, S2} = tick(2000, S1),
    S3 = structured(<<"u1">>, <<"Bob play Wonderwall">>, true, 2100, S2),
    ?assertMatch({{command, <<"play Wonderwall">>}, _}, tick(2101, S3)).

same_command_new_utterance_test() ->
    S1 = structured(<<"u1">>, <<"bob next">>, true, 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1, S1),
    S3 = structured(<<"u2">>, <<"bob next">>, true, 100, S2),
    ?assertMatch({{command, <<"next">>}, _}, tick(101, S3)).

late_final_redraw_ignored_test() ->
    S1 = structured(<<"u1">>, <<"bob next">>, true, 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1, S1),
    S3 = structured(<<"u1">>, <<"bob pause">>, true, 100, S2),
    ?assertMatch({none, _}, tick(1500, S3)).

final_is_immutable_before_tick_test() ->
    S1 = structured(<<"u1">>, <<"bob next">>, true, 0, erm_voice_boundary:new()),
    S2 = structured(<<"u1">>, <<"bob stop">>, true, 1, S1),
    ?assertMatch({{command, <<"next">>}, _}, tick(2, S2)).

abandoned_utterance_cannot_return_test() ->
    S1 = structured(<<"u1">>, <<"bob play">>, false, 0, erm_voice_boundary:new()),
    S2 = structured(<<"u2">>, <<"bob pause">>, false, 100, S1),
    S3 = structured(<<"u1">>, <<"bob play music">>, true, 200, S2),
    ?assertMatch({none, _}, tick(1500, S3)).

unrelated_text_does_not_unlock_test() ->
    S1 = feed("bob next", 0, erm_voice_boundary:new()),
    {{command, _}, S2} = tick(1000, S1),
    S3 = feed("background conversation", 1200, S2),
    S4 = feed("bob pause", 1400, S3),
    ?assertMatch({none, _}, tick(2500, S4)).

late_final_cannot_extend_deadline_test() ->
    S1 = structured(<<"u1">>, <<"bob">>, false, 0, erm_voice_boundary:new()),
    S2 = structured(<<"u1">>, <<"bob next">>, true, 8001, S1),
    ?assertMatch({none, _}, tick(8002, S2)).

strict_mode_rejects_unfinalized_text_test() ->
    O = (opts())#{require_final => true},
    S = erm_voice_boundary:feed("bob next", ["bob"], 0, erm_voice_boundary:new(), O),
    ?assertMatch({none, _}, erm_voice_boundary:tick(1500, S, O)).

punctuation_preserved_test() ->
    ?assertEqual({wake, <<"ask Is -5 < 0?">>},
                 erm_voice_boundary:wake("Bob, ask Is -5 < 0?", ["bob"])),
    ?assertEqual({ok, #{action => ask, query => <<"Is -5 < 0?">>}},
                 erm_voice_intent:parse("ask Is -5 < 0?")),
    ?assertEqual({ok, #{action => play_song, query => <<"Don't Stop Me Now">>}},
                 erm_voice_intent:parse("play Don't Stop Me Now")).

invalid_volume_never_reaches_model_test_() ->
    [?_assertMatch({error, _}, erm_voice_intent:plan(T, #{})) || T <-
        ["volume -5", "set volume to +5", "volume 3.5", "volume 1/2", "volume 101"]].

require_final_configuration_test() ->
    ?assertMatch({ok, _}, erm_voice:options(#{require_final => true})),
    ?assertMatch({error, _}, erm_voice:options(#{require_final => invalid})).
