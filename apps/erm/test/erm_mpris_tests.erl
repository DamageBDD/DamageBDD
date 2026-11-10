-module(erm_mpris_tests).
-include_lib("eunit/include/eunit.hrl").

% Pure injection tests: never touch the user's running MPV or D-Bus session.
autoload_prevents_double_loading_test() ->
    Exists = fun(P) -> P =:= "/etc/mpv/scripts/mpris.so" end,
    ?assertEqual(
        {autoload, "/etc/mpv/scripts/mpris.so"},
        erm_mpris:select_plugin(
            "/opt/custom/mpris.so", ["/etc/mpv/scripts/mpris.so"],
            ["/usr/lib/mpv-mpris/mpris.so"], Exists
        )
    ),
    ?assertEqual(
        ["--load-scripts=yes", "--audio-client-name=ERM"],
        erm_mpris:args_for({autoload, "/etc/mpv/scripts/mpris.so"})
    ).

manual_plugin_when_no_autoload_test() ->
    Exists = fun(P) -> P =:= "/usr/lib/mpv-mpris/mpris.so" end,
    P = erm_mpris:select_plugin(
        false, ["/etc/mpv/scripts/mpris.so"],
        ["/usr/lib/mpv-mpris/mpris.so"], Exists
    ),
    ?assertEqual({manual, "/usr/lib/mpv-mpris/mpris.so"}, P),
    ?assertEqual(
        ["--load-scripts=yes", "--audio-client-name=ERM",
         "--script=/usr/lib/mpv-mpris/mpris.so"],
        erm_mpris:args_for(P)
    ).

explicit_plugin_test() ->
    P = "/opt/erm/mpris.so",
    Exists = fun(Path) -> Path =:= P end,
    ?assertEqual({manual, P}, erm_mpris:select_plugin(
        P, [], ["/usr/lib/mpv-mpris/mpris.so"], Exists
    )).

bad_override_does_not_load_wrong_plugin_test() ->
    Exists = fun(_Path) -> false end,
    ?assertEqual(
        {unavailable, {override_not_absolute, "relative/mpris.so"}},
        erm_mpris:select_plugin("relative/mpris.so", [], [], Exists)
    ),
    ?assertEqual([], erm_mpris:args_for({unavailable, not_installed})).

missing_plugin_keeps_audio_backend_available_test() ->
    Exists = fun(_Path) -> false end,
    Selection = erm_mpris:select_plugin(false, [], [], Exists),
    ?assertEqual({unavailable, mpv_mpris_not_installed}, Selection),
    ?assertEqual([], erm_mpris:args_for(Selection)).
