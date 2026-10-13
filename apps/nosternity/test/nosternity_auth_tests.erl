-module(nosternity_auth_tests).
-include_lib("eunit/include/eunit.hrl").
-export([sign/2, setup/0, cleanup/1]).

auth_test_() ->
    {timeout, 180, [
        ?_test(with_auth(F))
     || F <- [
            fun signup_and_login/0,
            fun replay_and_binding/0,
            fun wrong_payload/0,
            fun invalid_signature_consumed/0,
            fun strict_nip98/0,
            fun expiry/0,
            fun lightning_flow/0,
            fun lightning_wrong_signature/0,
            fun lightning_expiry/0,
            fun account_persistence_session_loss/0,
            fun preferences_isolation/0,
            fun revoked_session/0,
            fun challenge_and_session_capacity/0,
            fun rate_limit/0,
            fun signup_gate/0,
            fun duplicate_proof_concurrency/0
        ]
    ]}.

setup() ->
    File = filename:join(
        "/tmp",
        "nosternity-auth-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++
            ".dets"
    ),
    Keys = [
        {auth_store_file, File},
        {auth_max_challenges, 1000},
        {auth_max_sessions, 10000},
        {auth_max_accounts, 100000},
        {auth_signup_enabled, true},
        {auth_attempts_per_minute, 120}
    ],
    Saved = [{K, application:get_env(nosternity, K)} || {K, _} <- Keys],
    [application:set_env(nosternity, K, V) || {K, V} <- Keys],
    {ok, Pid} = nosternity_auth:start_link(),
    unlink(Pid),
    {File, Saved}.
cleanup({File, Saved}) ->
    case whereis(nosternity_auth) of
        undefined -> ok;
        P -> gen_server:stop(P)
    end,
    [
        case V of
            undefined -> application:unset_env(nosternity, K);
            {ok, X} -> application:set_env(nosternity, K, X)
        end
     || {K, V} <- Saved
    ],
    file:delete(File).
with_auth(F) ->
    Setup = setup(),
    try
        F()
    after
        cleanup(Setup)
    end.
origin() -> <<"https://nostr.example">>.
binding() -> binary:copy(<<"b">>, 64).
challenge(Intent) ->
    {ok, C} = nosternity_auth:challenge(nostr, Intent, origin(), binding(), peer),
    C.
prove(C, Key) ->
    nosternity_auth:verify_nostr(
        maps:get(challenge_id, C),
        sign(maps:get(event, C), Key),
        maps:get(payload, C),
        origin(),
        binding()
    ).
sign(E0, Key) ->
    {ok, P} = nostrlib_schnorr:new_publickey(<<Key:256>>),
    E = damage_nostr_event:ensure_event_id(E0#{pubkey => nosternity_auth_proof:hex(P)}),
    {ok, Sig} = nostrlib_schnorr:sign(nosternity_auth_proof:unhex(maps:get(id, E)), <<Key:256>>, <<
        0:256
    >>),
    nosternity_filter:wire(E#{sig => nosternity_auth_proof:hex(Sig)}).
signup(Key) ->
    {ok, T, S} = prove(challenge(<<"signup">>), Key),
    {T, S}.
signup_and_login() ->
    ?assertEqual({error, account_not_found}, prove(challenge(<<"login">>), 1)),
    {T, S} = signup(1),
    ?assertEqual(nostr, maps:get(provider, S)),
    ?assertMatch({ok, _}, nosternity_auth:lookup(T)),
    {ok, _, S2} = prove(challenge(<<"login">>), 1),
    ?assertEqual(maps:get(account_id, S), maps:get(account_id, S2)).
replay_and_binding() ->
    C = challenge(<<"signup">>),
    Id = maps:get(challenge_id, C),
    E = sign(maps:get(event, C), 2),
    P = maps:get(payload, C),
    ?assertEqual(
        {error, invalid_challenge},
        nosternity_auth:verify_nostr(Id, E, P, origin(), binary:copy(<<"x">>, 64))
    ),
    ?assertEqual(
        {error, invalid_challenge},
        nosternity_auth:verify_nostr(Id, E, P, <<"https://wrong.example">>, binding())
    ),
    ?assertMatch({ok, _, _}, prove(C, 2)),
    ?assertEqual({error, invalid_challenge}, prove(C, 2)).
wrong_payload() ->
    C = challenge(<<"signup">>),
    ?assertEqual(
        {error, invalid_proof},
        nosternity_auth:verify_nostr(
            maps:get(challenge_id, C),
            sign(maps:get(event, C), 3),
            <<"{}">>,
            origin(),
            binding()
        )
    ),
    ?assertEqual({error, invalid_challenge}, prove(C, 3)).
invalid_signature_consumed() ->
    C = challenge(<<"signup">>),
    E = (sign(maps:get(event, C), 4))#{<<"sig">> => binary:copy(<<"0">>, 128)},
    ?assertEqual(
        {error, invalid_proof},
        nosternity_auth:verify_nostr(
            maps:get(challenge_id, C), E, maps:get(payload, C), origin(), binding()
        )
    ),
    ?assertEqual({error, invalid_challenge}, prove(C, 4)).
strict_nip98() ->
    C = challenge(<<"signup">>),
    E = maps:get(event, C),
    Tags = maps:get(tags, E),
    Bad = [
        E#{kind => 1},
        E#{content => <<"extra">>},
        E#{created_at => erlang:system_time(second) - 61},
        E#{tags => [[<<"u">>, <<"https://wrong.example">>] | tl(Tags)]},
        E#{tags => Tags ++ [hd(Tags)]},
        E#{tags => [hd(Tags), [<<"method">>, <<"GET">>], lists:last(Tags)]}
    ],
    [
        begin
            D = challenge(<<"signup">>),
            ?assertEqual(
                {error, invalid_proof},
                nosternity_auth:verify_nostr(
                    maps:get(challenge_id, D), sign(B, 5), maps:get(payload, D), origin(), binding()
                )
            )
        end
     || B <- Bad
    ].
expiry() ->
    C = challenge(<<"signup">>),
    sys:replace_state(nosternity_auth, fun(S) ->
        S#{
            challenges := maps:map(
                fun(_, V) -> V#{until => erlang:monotonic_time(millisecond) - 1} end,
                maps:get(challenges, S)
            )
        }
    end),
    ?assertEqual({error, invalid_challenge}, prove(C, 6)),
    {T, _} = signup(6),
    sys:replace_state(nosternity_auth, fun(S) ->
        S#{
            sessions := maps:map(
                fun(_, V) -> V#{until => erlang:monotonic_time(millisecond) - 1} end,
                maps:get(sessions, S)
            )
        }
    end),
    ?assertEqual({error, unauthorized}, nosternity_auth:lookup(T)).
ln_challenge() ->
    {ok, C} = nosternity_auth:challenge(lightning, <<"signup">>, origin(), binding(), ln_peer),
    C.
ln_sign(Id) ->
    {<<4, X:32/binary, Y:256>>, Secret} = crypto:generate_key(ecdh, secp256k1),
    Key = nosternity_auth_proof:hex(<<(2 + (Y band 1)), X/binary>>),
    Sig = crypto:sign(ecdsa, sha256, {digest, nosternity_auth_proof:unhex(Id)}, [Secret, secp256k1]),
    {nosternity_auth_proof:hex(Sig), Key}.
lightning_flow() ->
    C = ln_challenge(),
    Id = maps:get(challenge_id, C),
    {Sig, Key} = ln_sign(Id),
    ?assertMatch(<<"lnurl1", _/binary>>, maps:get(lnurl, C)),
    ?assertEqual({ok, pending}, nosternity_auth:poll_lightning(Id, origin(), binding())),
    ?assertEqual(ok, nosternity_auth:verify_lightning(Id, Sig, Key, <<"register">>)),
    ?assertEqual(
        {error, invalid_challenge}, nosternity_auth:verify_lightning(Id, Sig, Key, <<"register">>)
    ),
    ?assertEqual(
        {error, invalid_challenge},
        nosternity_auth:poll_lightning(Id, origin(), binary:copy(<<"x">>, 64))
    ),
    {ok, T, S} = nosternity_auth:poll_lightning(Id, origin(), binding()),
    ?assertEqual(lightning, maps:get(provider, S)),
    ?assertEqual(Key, maps:get(subject, S)),
    ?assertMatch({ok, _}, nosternity_auth:lookup(T)),
    ?assertEqual(
        {error, invalid_challenge}, nosternity_auth:poll_lightning(Id, origin(), binding())
    ).
lightning_wrong_signature() ->
    C = ln_challenge(),
    Id = maps:get(challenge_id, C),
    {Sig, Key} = ln_sign(binary:copy(<<"1">>, 64)),
    ?assertEqual(
        {error, invalid_proof}, nosternity_auth:verify_lightning(Id, Sig, Key, <<"register">>)
    ),
    ?assertEqual(
        {error, invalid_challenge}, nosternity_auth:poll_lightning(Id, origin(), binding())
    ).
lightning_expiry() ->
    C = ln_challenge(),
    Id = maps:get(challenge_id, C),
    {Sig, Key} = ln_sign(Id),
    sys:replace_state(nosternity_auth, fun(S) ->
        S#{
            challenges := maps:map(
                fun(_, V) -> V#{until => erlang:monotonic_time(millisecond) - 1} end,
                maps:get(challenges, S)
            )
        }
    end),
    ?assertEqual(
        {error, invalid_challenge}, nosternity_auth:verify_lightning(Id, Sig, Key, <<"register">>)
    ).
account_persistence_session_loss() ->
    {T, S} = signup(7),
    gen_server:stop(nosternity_auth),
    {ok, P} = nosternity_auth:start_link(),
    unlink(P),
    ?assertEqual({error, unauthorized}, nosternity_auth:lookup(T)),
    {ok, _, S2} = prove(challenge(<<"login">>), 7),
    ?assertEqual(maps:get(account_id, S), maps:get(account_id, S2)).
preferences_isolation() ->
    {T1, _} = signup(8),
    {T2, _} = signup(9),
    {ok, A} = nosternity_auth:account(T1),
    P = maps:get(preferences, A),
    ?assertMatch({ok, _}, nosternity_auth:update(T1, P#{<<"words">> => [<<"spam">>]})),
    {ok, A2} = nosternity_auth:account(T2),
    ?assertEqual([], maps:get(<<"words">>, maps:get(preferences, A2))),
    ?assertEqual(
        {error, invalid_preferences}, nosternity_auth:update(T1, P#{<<"role">> => <<"admin">>})
    ),
    ?assertEqual({error, unauthorized}, nosternity_auth:update(<<"ns1.invalid">>, P)).
revoked_session() ->
    {T, _} = signup(10),
    ok = nosternity_auth:revoke(T),
    ?assertEqual({error, unauthorized}, nosternity_auth:lookup(T)).
challenge_and_session_capacity() ->
    application:set_env(nosternity, auth_max_challenges, 1),
    _C = challenge(<<"signup">>),
    ?assertEqual(
        {error, rate_limited},
        nosternity_auth:challenge(nostr, <<"signup">>, origin(), binding(), another_peer)
    ),
    application:set_env(nosternity, auth_max_challenges, 1000),
    application:set_env(nosternity, auth_max_sessions, 1),
    _ = signup(11),
    ?assertEqual({error, session_capacity}, prove(challenge(<<"signup">>), 12)).
rate_limit() ->
    application:set_env(nosternity, auth_attempts_per_minute, 1),
    ?assertEqual(ok, nosternity_auth:attempt(ip)),
    ?assertEqual({error, rate_limited}, nosternity_auth:attempt(ip)).
signup_gate() ->
    application:set_env(nosternity, auth_signup_enabled, false),
    ?assertEqual({error, signup_unavailable}, prove(challenge(<<"signup">>), 13)).
duplicate_proof_concurrency() ->
    C = challenge(<<"signup">>),
    Parent = self(),
    [spawn(fun() -> Parent ! {done, prove(C, 14)} end) || _ <- lists:seq(1, 2)],
    Rs = [
        receive
            {done, R} -> R
        after 10000 -> timeout
        end
     || _ <- lists:seq(1, 2)
    ],
    ?assertEqual(1, length([ok || {ok, _, _} <- Rs])),
    ?assert(lists:member({error, invalid_challenge}, Rs)).
