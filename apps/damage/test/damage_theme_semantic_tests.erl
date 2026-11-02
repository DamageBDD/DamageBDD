%% Pure tests. No node startup, wallet, storage, IPFS or contract calls.
-module(damage_theme_semantic_tests).
-include_lib("eunit/include/eunit.hrl").

semantic_roles_for_all_apps_test_() ->
    [{binary_to_list(<<App/binary, "/", (maps:get(<<"id">>, Theme))/binary>>),
      fun() ->
          Css = damage_theme_manifest:css(App, Theme),
          lists:foreach(fun(Role) ->
              ?assertNotEqual(<<>>, value(Css, <<"theme-", Role/binary>>))
          end, [<<"bg">>, <<"surface">>, <<"surface-alt">>, <<"input">>,
                <<"text">>, <<"muted">>, <<"link">>, <<"border">>, <<"accent">>,
                <<"on-accent">>, <<"focus">>, <<"success">>, <<"danger">>,
                <<"warning">>, <<"info">>, <<"shadow">>, <<"focus-glow">>,
                <<"color-scheme">>]),
          ?assertEqual(nomatch, binary:match(Css, <<"url(">>)),
          ?assertEqual(nomatch, binary:match(Css, <<"@import">>))
      end}
     || Theme <- damage_theme_manifest:builtin(),
        App <- [<<"damage">>, <<"ecai">>, <<"nosternity">>, <<"bop">>, <<"erm">>]].

paired_colors_test_() ->
    [{binary_to_list(maps:get(<<"id">>, Theme)), fun() ->
        Css = damage_theme_manifest:css(<<"damage">>, Theme),
        Backgrounds = [value(Css, <<"theme-bg">>), value(Css, <<"theme-surface">>)],
        lists:foreach(fun(Role) ->
            lists:foreach(fun(BG) ->
                ?assert(ratio(value(Css, Role), BG) >= 4.5)
            end, Backgrounds)
        end, [<<"theme-text">>, <<"theme-muted">>, <<"theme-link">>]),
        ?assert(ratio(value(Css, <<"theme-on-accent">>), value(Css, <<"theme-accent">>)) >= 4.5),
        ?assertEqual(value(Css, <<"theme-surface">>), value(Css, <<"ws-panel">>)),
        ?assertEqual(value(Css, <<"theme-bg">>), value(Css, <<"ws-input">>))
    end} || Theme <- damage_theme_manifest:builtin()].

low_contrast_foreground_is_derived_not_written_into_package_test() ->
    [Theme | _] = damage_theme_manifest:builtin(),
    Colors = maps:get(<<"tokens">>, Theme),
    Custom = Theme#{<<"tokens">> := Colors#{
        <<"text">> := <<"#182535">>, <<"muted">> := <<"#182535">>,
        <<"accent">> := <<"#182535">>}},
    {ok, Package} = damage_theme_manifest:validate(Custom),
    Hash = damage_theme_manifest:package_hash(Package),
    Css = damage_theme_manifest:css(<<"ecai">>, Package),
    ?assertNotEqual(<<"#182535">>, value(Css, <<"theme-text">>)),
    ?assertEqual(<<"#182535">>, maps:get(<<"text">>, maps:get(<<"tokens">>, Package))),
    ?assertEqual(Hash, damage_theme_manifest:package_hash(Package)),
    ?assertEqual(6, map_size(maps:get(<<"tokens">>, Package))).

color_scheme_follows_surface_test() ->
    [Dark, Light, Violet] = damage_theme_manifest:builtin(),
    lists:foreach(fun({Theme, Scheme}) ->
        ?assertEqual(Scheme, value(damage_theme_manifest:css(<<"bop">>, Theme), <<"theme-color-scheme">>))
    end, [{Dark, <<"dark">>}, {Light, <<"light">>}, {Violet, <<"dark">>}]).

value(Css, Name) ->
    {match, [Value]} = re:run(Css, <<"--", Name/binary, ":([^;]+);">>, [{capture, [1], binary}]),
    Value.
ratio(A, B) ->
    LA = luminance(A), LB = luminance(B),
    (max(LA, LB) + 0.05) / (min(LA, LB) + 0.05).
luminance(<<"#", R:2/binary, G:2/binary, B:2/binary>>) ->
    0.2126 * channel(R) + 0.7152 * channel(G) + 0.0722 * channel(B).
channel(Hex) ->
    V = binary_to_integer(Hex, 16) / 255,
    case V =< 0.04045 of true -> V / 12.92; false -> math:pow((V + 0.055) / 1.055, 2.4) end.
