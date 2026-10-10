%% Pure origin/policy regressions; no wallet or network connection.
-module(damage_browser_auth_origin_tests).
-include_lib("eunit/include/eunit.hrl").

per_listener_origins_test() ->
    with_env(damage, browser_auth, [{origin, "https://damage.example"}], fun() ->
        with_env(ecai, browser_auth_origin, "https://ecai.example", fun() ->
            ?assertEqual(<<"https://damage.example">>, damage_browser_auth_http:configured_origin()),
            ?assertEqual(<<"https://damage.example">>, damage_browser_auth_http:configured_origin(damage)),
            ?assertEqual(<<"https://ecai.example">>, damage_browser_auth_http:configured_origin(ecai))
        end)
    end).

nosternity_origin_test() ->
    with_env(nosternity, browser_auth_origin, "https://nostr.example", fun() ->
        ?assertEqual(<<"https://nostr.example">>, damage_browser_auth_http:configured_origin(nosternity))
    end),
    Old = application:get_env(nosternity, browser_auth_origin),
    application:unset_env(nosternity, browser_auth_origin),
    try ?assertError(nosternity_browser_auth_origin_missing, damage_browser_auth_http:configured_origin(nosternity))
    after restore(nosternity, browser_auth_origin, Old) end.

missing_ecai_origin_fails_closed_test() ->
    Old = application:get_env(ecai, browser_auth_origin),
    application:unset_env(ecai, browser_auth_origin),
    try ?assertError(ecai_browser_auth_origin_missing, damage_browser_auth_http:configured_origin(ecai))
    after restore(ecai, browser_auth_origin, Old) end.

origin_header_checks_test_() ->
    Expected = <<"https://ecai.example">>,
    [?_assertEqual(Result, damage_browser_auth_http:request_origin_allowed(
        Expected, Method, Origin, Header, FetchSite)) || {Method, Origin, Header, FetchSite, Result} <- [
        {<<"POST">>, Expected, <<"1">>, <<"same-origin">>, true},
        {<<"POST">>, <<"https://damage.example">>, <<"1">>, <<"same-site">>, false},
        {<<"POST">>, <<"https://evil.example">>, <<"1">>, <<"same-origin">>, false},
        {<<"POST">>, undefined, <<"1">>, undefined, false},
        {<<"POST">>, Expected, undefined, undefined, false},
        {<<"POST">>, Expected, <<"1">>, <<"cross-site">>, false},
        {<<"GET">>, undefined, <<"1">>, <<"same-origin">>, true},
        {<<"GET">>, <<"null">>, <<"1">>, undefined, false}
    ]].

wallet_ecai_scope_test_() ->
    [?_assert(damage_wallet_policy:allowed(<<"GET">>, <<"/ecai/auth/session">>, wallet)),
     ?_assertNot(damage_wallet_policy:allowed(<<"POST">>, <<"/ecai/auth/session">>, wallet))] ++
    [?_assertNot(damage_wallet_policy:allowed(Method, Path, wallet)) ||
        Method <- [<<"GET">>, <<"POST">>],
        Path <- [<<"/ecai/admin/code/status">>, <<"/ecai/admin/index-pool/nodes">>,
                 <<"/ecai/admin/index-pool/jobs">>, <<"/ecai/ekef">>, <<"/ecai/index-jobs">>]].

with_env(App, Key, Value, Fun) ->
    Old = application:get_env(App, Key), application:set_env(App, Key, Value),
    try Fun() after restore(App, Key, Old) end.
restore(App, Key, undefined) -> application:unset_env(App, Key);
restore(App, Key, {ok, V}) -> application:set_env(App, Key, V).
