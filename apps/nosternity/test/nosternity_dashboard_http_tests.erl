-module(nosternity_dashboard_http_tests).
-include_lib("eunit/include/eunit.hrl").
http_roundtrip_test_() -> {timeout, 180, fun roundtrip/0}.

roundtrip() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Setup = nosternity_auth_tests:setup(),
    Dir = filename:join(
        "/tmp",
        "nosternity-dashboard-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    Keys = [search_store_file, ae_event_store_rehydrate, browser_auth_origin],
    Old = [{K, application:get_env(nosternity, K)} || K <- Keys],
    application:set_env(nosternity, search_store_file, filename:join(Dir, "events.dets")),
    application:set_env(nosternity, ae_event_store_rehydrate, false),
    {ok, Relay} = nosternity_relay:start_link(),
    unlink(Relay),
    {ok, Damage} = damage_browser_auth:start_link(),
    unlink(Damage),
    Ref = make_ref(),
    Routes = nosternity_app:routes(),
    {ok, _} = cowboy:start_clear(Ref, #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0}]}, #{
        env => #{dispatch => trails:single_host_compile(Routes)}
    }),
    Port = ranch:get_port(Ref),
    Origin = list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),
    application:set_env(nosternity, browser_auth_origin, Origin),
    try
        exercise(Port, Origin)
    after
        cowboy:stop_listener(Ref),
        gen_server:stop(Relay),
        gen_server:stop(Damage),
        nosternity_auth_tests:cleanup(Setup),
        [
            case V of
                undefined -> application:unset_env(nosternity, K);
                {ok, X} -> application:set_env(nosternity, K, X)
            end
         || {K, V} <- Old
        ],
        file:del_dir_r(Dir)
    end.

exercise(Port, Origin) ->
    {200, H, HTML} = request(Port, <<"GET">>, "/dashboard", [], <<>>),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"Nosternity">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"authTemplate">>)),
    ?assertNotEqual(undefined, proplists:get_value(<<"content-security-policy">>, H)),
    {200, _, _} = request(Port, <<"GET">>, "/dashboard/fragments/auth", [], <<>>),
    {200, _, Voice} = request(Port, <<"GET">>, "/dashboard/fragments/voice-note", [], <<>>),
    ?assertNotEqual(nomatch, binary:match(Voice, <<"Hold to talk">>)),
    ?assertNotEqual(
        nomatch,
        binary:match(proplists:get_value(<<"content-security-policy">>, H), <<"media-src 'self' blob:">>)
    ),
    ?assertEqual(
        <<"microphone=(self), on-device-speech-recognition=(self)">>,
        proplists:get_value(<<"permissions-policy">>, H)
    ),
    {404, _, _} = request(Port, <<"GET">>, "/dashboard/fragments/not_allowed", [], <<>>),
    {200, _, _} = request(Port, <<"GET">>, "/dashboard/assets/dashboard.js", [], <<>>),
    Headers = [
        {<<"origin">>, Origin},
        {<<"x-nosternity-auth">>, <<"1">>},
        {<<"content-type">>, <<"application/json">>}
    ],
    {403, _, _} = request(Port, <<"POST">>, "/api/nosternity/auth/nostr/challenge", [], <<"{}">>),
    {403, _, _} = request(
        Port,
        <<"POST">>,
        "/api/nosternity/auth/nostr/challenge",
        lists:keyreplace(<<"origin">>, 1, Headers, {<<"origin">>, <<"https://evil.example">>}),
        <<"{}">>
    ),
    {200, CH, CB} = request(
        Port,
        <<"POST">>,
        "/api/nosternity/auth/nostr/challenge",
        Headers,
        <<"{\"intent\":\"signup\"}">>
    ),
    Challenge = json(CB),
    Binding = cookie(CH, <<"nosternity_binding">>),
    E = nosternity_auth_tests:sign(maps:get(<<"event">>, Challenge), 21),
    Proof = base64:encode(jsx:encode(E)),
    VerifyHeaders =
        Headers ++ [{<<"cookie">>, Binding}, {<<"authorization">>, <<"Nostr ", Proof/binary>>}],
    {200, SH, SB} = request(
        Port,
        <<"POST">>,
        "/api/nosternity/auth/nostr/verify",
        VerifyHeaders,
        maps:get(<<"payload">>, Challenge)
    ),
    Session = json(SB),
    ?assertEqual(true, maps:get(<<"authenticated">>, Session)),
    ?assertNot(maps:is_key(<<"access_token">>, Session)),
    SC = cookie(SH, <<"nosternity_session">>),
    ?assertNotEqual(
        nomatch, binary:match(proplists:get_value(<<"set-cookie">>, SH), <<"HttpOnly">>)
    ),
    AH = Headers ++ [{<<"cookie">>, SC}],
    {401, _, _} = request(
        Port,
        <<"POST">>,
        "/api/nosternity/auth/nostr/verify",
        VerifyHeaders,
        maps:get(<<"payload">>, Challenge)
    ),
    {200, _, _} = request(Port, <<"GET">>, "/api/nosternity/auth/session", AH, <<>>),
    {401, _, _} = request(Port, <<"GET">>, "/api/nosternity/account", Headers, <<>>),
    Now = erlang:system_time(second),
    Note = nosternity_auth_tests:sign(
        #{kind => 1, content => <<"a useful public note">>, tags => [], created_at => Now}, 21
    ),
    Other = nosternity_auth_tests:sign(
        #{kind => 1, content => <<"another author">>, tags => [], created_at => Now}, 22
    ),
    Spam = nosternity_auth_tests:sign(
        #{kind => 1, content => <<"claim your airdrop">>, tags => [], created_at => Now}, 21
    ),
    {202, _, _} = post(Port, "/api/nosternity/events", AH, Note),
    {400, _, _} = post(Port, "/api/nosternity/events", AH, Other),
    {403, _, _} = post(Port, "/api/nosternity/events", Headers, Note),
    {202, _, _} = post(Port, "/api/nosternity/events", AH, Spam),
    Private = nosternity_auth_tests:sign(
        #{kind => 23194, content => <<"private request">>, tags => [], created_at => Now}, 21
    ),
    {400, _, _} = post(Port, "/api/nosternity/events", AH, Private),
    {200, _, FB} = post(Port, "/api/nosternity/feed", AH, #{scope => <<"account">>}),
    ?assertEqual(1, maps:get(<<"total">>, json(FB))),
    ?assertEqual(1, maps:get(<<"hidden">>, json(FB))),
    {403, _, _} = post(Port, "/api/nosternity/feed", Headers, #{scope => <<"account">>}),
    {200, _, AB} = request(Port, <<"GET">>, "/api/nosternity/account", AH, <<>>),
    Prefs = maps:get(<<"preferences">>, json(AB)),
    {200, _, _} = post(Port, "/api/nosternity/preferences", AH, Prefs#{<<"spam">> => false}),
    {200, _, FB2} = post(Port, "/api/nosternity/feed", AH, #{scope => <<"account">>}),
    ?assertEqual(2, maps:get(<<"total">>, json(FB2))),
    {400, _, _} = post(Port, "/api/nosternity/preferences", AH, Prefs#{<<"admin">> => true}),
    {401, _, _} = post(Port, "/api/nwc/mint", AH, #{}),
    {401, _, _} = post(Port, "/api/nosternity/auth/damage", AH, #{intent => <<"signup">>}),
    {200, _, _} = request(Port, <<"GET">>, "/accounts/auth/options", [], <<>>),
    {403, _, _} = post(
        Port,
        "/accounts/login",
        [{<<"x-damage-auth">>, <<"1">>}, {<<"origin">>, <<"https://evil.example">>}],
        #{}
    ),
    lightning(Port, Headers),
    {200, _, _} = post(Port, "/api/nosternity/auth/logout", AH, #{}),
    {401, _, _} = request(Port, <<"GET">>, "/api/nosternity/auth/session", AH, <<>>),
    {200, _, MB} = request(Port, <<"GET">>, "/api/nosternity/analytics", Headers, <<>>),
    ?assertMatch(#{<<"dashboard">> := #{<<"requests">> := 2}}, json(MB)).

lightning(Port, H) ->
    {200, CH, B} = post(Port, "/api/nosternity/auth/lightning/challenge", H, #{
        intent => <<"signup">>
    }),
    C = json(B),
    Id = maps:get(<<"challenge_id">>, C),
    Binding = cookie(CH, <<"nosternity_binding">>),
    {<<4, X:32/binary, Y:256>>, Priv} = crypto:generate_key(ecdh, secp256k1),
    Key = nosternity_auth_proof:hex(<<(2 + (Y band 1)), X/binary>>),
    Sig = nosternity_auth_proof:hex(
        crypto:sign(ecdsa, sha256, {digest, nosternity_auth_proof:unhex(Id)}, [Priv, secp256k1])
    ),
    URL =
        "/api/nosternity/auth/lightning/callback?tag=login&action=register&k1=" ++
            binary_to_list(Id) ++ "&sig=" ++ binary_to_list(Sig) ++ "&key=" ++ binary_to_list(Key),
    {200, RH, RB} = request(Port, <<"GET">>, URL, [], <<>>),
    ?assertEqual(#{<<"status">> => <<"OK">>}, json(RB)),
    ?assertEqual(undefined, proplists:get_value(<<"set-cookie">>, RH)),
    {401, _, _} = post(Port, "/api/nosternity/auth/lightning/poll", H, #{challenge_id => Id}),
    {200, _, SB} = post(
        Port, "/api/nosternity/auth/lightning/poll", H ++ [{<<"cookie">>, Binding}], #{
            challenge_id => Id
        }
    ),
    ?assertEqual(<<"lightning">>, maps:get(<<"provider">>, json(SB))),
    ?assertEqual(false, maps:get(<<"social_write">>, maps:get(<<"capabilities">>, json(SB)))).

post(P, Path, H, B) -> request(P, <<"POST">>, Path, H, jsx:encode(B)).
request(Port, Method, Path, H, Body) ->
    {ok, C} = gun:open("127.0.0.1", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(C),
    try
        R = gun:request(C, Method, Path, H, Body),
        case gun:await(C, R, 15000) of
            {response, nofin, Code, Headers} ->
                {ok, Bytes} = gun:await_body(C, R, 15000),
                {Code, Headers, Bytes};
            {response, fin, Code, Headers} ->
                {Code, Headers, <<>>}
        end
    after
        gun:close(C)
    end.
json(B) -> jsx:decode(B, [return_maps]).
cookie(H, Name) ->
    [Raw | _] = [
        V
     || {<<"set-cookie">>, V} <- H,
        binary:match(V, <<Name/binary, "=">>) =:= {0, byte_size(Name) + 1}
    ],
    hd(binary:split(Raw, <<";">>, [global])).
