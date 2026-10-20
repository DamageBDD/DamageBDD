-module(damage_theme_ecai_palette_tests).
-include_lib("eunit/include/eunit.hrl").

ecai_palette_aliases_test() ->
    lists:foreach(fun(Theme) ->
        Css = damage_theme_manifest:css(<<"ecai">>, Theme),
        Colors = maps:get(<<"tokens">>, Theme),
        ?assertNotEqual(nomatch, binary:match(Css,
            <<"--paper:", (maps:get(<<"surface">>, Colors))/binary, ";">>)),
        ?assertNotEqual(nomatch, binary:match(Css,
            <<"--canvas:", (maps:get(<<"background">>, Colors))/binary, ";">>)),
        lists:foreach(fun(Name) ->
            ?assertNotEqual(nomatch, binary:match(Css, <<"--", Name/binary, ":">>))
        end, [<<"surface-2">>, <<"on-accent">>, <<"link">>, <<"ecai-color-scheme">>]),
        ?assertEqual(nomatch, binary:match(Css, <<"url(">>))
    end, damage_theme_manifest:builtin()).

dark_and_light_control_text_test() ->
    [Dark, Light | _] = damage_theme_manifest:builtin(),
    DarkCss = damage_theme_manifest:css(<<"ecai">>, Dark),
    LightCss = damage_theme_manifest:css(<<"ecai">>, Light),
    ?assertNotEqual(nomatch, binary:match(DarkCss, <<"--on-accent:#000000;">>)),
    ?assertNotEqual(nomatch, binary:match(LightCss, <<"--on-accent:#ffffff;">>)),
    ?assertNotEqual(nomatch, binary:match(DarkCss, <<"--ecai-color-scheme:dark;">>)),
    ?assertNotEqual(nomatch, binary:match(LightCss, <<"--ecai-color-scheme:light;">>)).

non_ecai_palette_unchanged_test() ->
    [Theme | _] = damage_theme_manifest:builtin(),
    lists:foreach(fun(App) ->
        Css = damage_theme_manifest:css(App, Theme),
        ?assertEqual(nomatch, binary:match(Css, <<"--paper:">>)),
        ?assertEqual(nomatch, binary:match(Css, <<"--ecai-color-scheme:">>))
    end, [<<"damage">>, <<"nosternity">>]).
