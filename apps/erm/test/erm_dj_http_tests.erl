-module(erm_dj_http_tests).
-include_lib("eunit/include/eunit.hrl").

trusted_url_test() ->
    ?assertEqual({ok, <<"https://ektoplazm.com/audio/song.mp3">>},
                 erm_dj_http:validate_url(<<"https://ektoplazm.com/audio/song.mp3">>)).

url_rejections_test() ->
    URLs = [<<"http://ektoplazm.com/files/a.zip">>,
            <<"https://ektoplazm.com.evil.example/files/a.zip">>,
            <<"https://ektoplazm.com@evil.example/a">>,
            <<"https://x@ektoplazm.com/a">>,
            <<"https://127.0.0.1/a">>,
            <<"https://ektoplazm.com:8443/a">>,
            <<"https://ektoplazm.com/a#frag">>,
            <<"https://ektoplazm.com/a\r\nheader">>,
            <<"https://ektoplazm.com/\\evil">>],
    lists:foreach(fun(U) -> ?assertEqual({error, untrusted_url}, erm_dj_http:validate_url(U)) end, URLs).

invalid_budget_test() ->
    ?assertEqual({error, invalid_limits}, erm_dj_http:get(<<"https://ektoplazm.com">>, #{max_bytes => 268435457})),
    ?assertEqual({error, invalid_limits}, erm_dj_http:get(<<"https://ektoplazm.com">>, #{timeout => infinity})),
    ?assertEqual({error, invalid_options}, erm_dj_http:get(<<"https://ektoplazm.com">>, [] )).
