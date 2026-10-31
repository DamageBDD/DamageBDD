-module(erm_dj_widget_tests).
-include_lib("eunit/include/eunit.hrl").

context_is_explicit_and_bounded_test() ->
    ?assertEqual({ok,#{tags=>[<<"ambient">>,<<"downtempo">>],mood=><<"calm">>}},
        erm_dj_widget:parse_context(<<" ambient, downtempo, ambient, ">>,<<" calm ">>)),
    ?assertEqual({ok,#{tags=>[],mood=><<>>}},erm_dj_widget:parse_context(<<>>,<<>>)),
    ?assertEqual({error,invalid_context},
        erm_dj_widget:parse_context(binary:copy(<<"a">>,2049),<<>>)),
    ?assertEqual({error,invalid_context},erm_dj_widget:parse_context(<<255>>,<<>>)).

attribution_is_visible_test() ->
    T=#{artist=><<"Example artist">>,title=><<"Example recording">>,
        license=>#{id=><<"CC-BY-NC-SA-3.0">>,
                   url=><<"https://creativecommons.org/licenses/by-nc-sa/3.0/">>},
        source_url=><<"https://ektoplazm.com/free-music/example">>},
    Text=erm_dj_widget:track_summary(T),
    [?assertNotEqual(nomatch,binary:match(Text,Value)) || Value<-
        [<<"Example artist">>,<<"Example recording">>,<<"CC-BY-NC-SA-3.0">>,
         <<"https://creativecommons.org/licenses/by-nc-sa/3.0/">>,
         <<"https://ektoplazm.com/free-music/example">>]].

headless_start_is_clean_test() ->
    %% This isolated suite deliberately does not load or start GTK.
    ?assertEqual(undefined,whereis(gtkgs)),
    ?assertEqual({error,gtk_unavailable},erm_dj_widget:start()),
    ?assertEqual(#{running=>false},erm_dj_widget:status()),
    ?assertEqual(ok,erm_dj_widget:close()).
