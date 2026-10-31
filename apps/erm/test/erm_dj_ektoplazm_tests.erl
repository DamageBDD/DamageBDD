-module(erm_dj_ektoplazm_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    {ok, B} = file:read_file(filename:join([filename:dirname(?FILE), "fixtures", "ektoplazm_release.html"])), B.
url() -> <<"https://ektoplazm.com/free-music/example-release">>.

actual_markup_test() ->
    {ok, R} = erm_dj_ektoplazm:parse_release(fixture(), url()),
    ?assertEqual(<<"Example Release">>, maps:get(title, R)),
    ?assertEqual(<<"Example Artist">>, maps:get(artist, R)),
    ?assertEqual([<<"downtempo">>, <<"psy dub">>], maps:get(tags, R)),
    ?assertMatch(#{id := <<"CC-BY-NC-SA-4.0">>, nc := true, sa := true, nd := false}, maps:get(license, R)),
    [First, Second] = maps:get(tracks, R),
    ?assertEqual(<<"First & Light">>, maps:get(title, First)),
    ?assertEqual(<<"Second Track">>, maps:get(title, Second)),
    ?assertEqual(<<"https://ektoplazm.com/audio/example-first.mp3">>, maps:get(media_url, First)),
    ?assertEqual(2, length(maps:get(downloads, R))),
    ?assertEqual(64, byte_size(maps:get(html_sha256, maps:get(license_evidence, R)))).

footer_licence_cannot_authorise_release_test() ->
    HTML = binary:replace(fixture(), <<"Released under a">>, <<"An unrelated link to a">>),
    ?assertEqual({error, missing_release_license}, erm_dj_ektoplazm:parse_release(HTML, url())).

ambiguous_licence_test() ->
    HTML = binary:replace(fixture(), <<"for noncommercial usage.">>,
          <<"or <a href='https://creativecommons.org/licenses/by/4.0/'>another licence</a>.">>),
    ?assertEqual({error, ambiguous_release_license}, erm_dj_ektoplazm:parse_release(HTML, url())).

unsupported_licence_test() ->
    HTML = binary:replace(fixture(), <<"by-nc-sa/4.0/">>, <<"by-nc-sa/4.0/au/">>, [global]),
    ?assertEqual({error, unsupported_release_license}, erm_dj_ektoplazm:parse_release(HTML, url())).

untrusted_media_ignored_test() ->
    HTML = binary:replace(fixture(), <<"https:\\/\\/ektoplazm.com\\/audio\\/example-second.mp3">>,
                                 <<"https:\\/\\/evil.example\\/audio\\/example-second.mp3">>),
    {ok, R} = erm_dj_ektoplazm:parse_release(HTML, url()),
    ?assertEqual(1, length(maps:get(tracks, R))).

release_url_required_test() ->
    ?assertEqual({error, invalid_release_url},
                 erm_dj_ektoplazm:parse_release(fixture(), <<"https://ektoplazm.com/free-music">>)).

malformed_and_large_test() ->
    ?assertMatch({error, _}, erm_dj_ektoplazm:parse_release(<<"<div class='post'><div class='entry'>">>, url())),
    ?assertEqual({error, invalid_html}, erm_dj_ektoplazm:parse_release(binary:copy(<<"x">>, 2097153), url())).

discovery_filters_test() ->
    {ok, URLs} = erm_dj_ektoplazm:parse_discovery(
        <<"<a href='https://ektoplazm.com/free-music/example-release'>yes</a>",
          "<a href='https://ektoplazm.com/free-music/example-release'>duplicate</a>",
          "<a href='https://ektoplazm.com/free-music/example-release#comments'>comments</a>",
          "<a href='https://evil.example/free-music/no'>evil</a>",
          "<a href='https://ektoplazm.com/free-music/page/2'>page</a>">>),
    ?assertEqual([url()], URLs).
