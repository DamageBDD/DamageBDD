%% Offline authorization/lifecycle tests. Signature adapter is mocked deliberately;
%% real Superhero signature interoperability needs the opt-in live integration run.
-module(damage_browser_auth_tests).
-include_lib("eunit/include/eunit.hrl").
-define(ADDRESS, <<"ak_11111111111111111111111111111111273Yts">>).
-define(ORIGIN, <<"https://damage.example">>).
-define(BINDING, <<"0123456789012345678901234567890123456789012345678901234567890123">>).
-define(SIG, (binary:copy(<<"a">>, 128))).

browser_auth_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                ?assertEqual(?ADDRESS, maps:get(address, C)),
                ?assertMatch({_, _}, binary:match(maps:get(message, C), ?ORIGIN)),
                ?assertMatch(
                    {_, _}, binary:match(maps:get(message, C), <<"does not authorise payments">>)
                )
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, A} = challenge(),
                {ok, B} = challenge(),
                ?assertNotEqual(maps:get(challenge_id, A), maps:get(challenge_id, B))
            end)
        end,
        fun(_) ->
            ?_test(
                ?assertEqual(
                    {error, invalid_challenge},
                    damage_browser_auth:challenge(<<"not-an-account">>, ?ORIGIN, ?BINDING, peer)
                )
            )
        end,
        fun(_) ->
            ?_test(
                ?assertEqual(
                    {error, invalid_challenge},
                    damage_browser_auth:challenge(?ADDRESS, ?ORIGIN, <<"short">>, peer)
                )
            )
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                Id = maps:get(challenge_id, C),
                ?assertEqual(
                    {error, invalid_challenge},
                    damage_browser_auth:verify(Id, ?SIG, <<"https://evil.example">>, ?BINDING)
                ),
                ?assertMatch({ok, _, _}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                ?assertEqual(
                    {error, invalid_challenge},
                    damage_browser_auth:verify(
                        maps:get(challenge_id, C), ?SIG, ?ORIGIN, <<"other-browser">>
                    )
                ),
                ?assertMatch({ok, _, _}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, Token, S} = verify(C),
                ?assertEqual(wallet, maps:get(mode, S)),
                ?assertMatch(<<"ds1.", _/binary>>, Token),
                ?assertEqual({ok, S}, damage_browser_auth:lookup(Token)),
                ?assertEqual(false, maps:is_key(private_key, S))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, _, _} = verify(C),
                ?assertEqual({error, invalid_challenge}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                ?assertEqual(
                    {error, invalid_signature},
                    damage_browser_auth:verify(
                        maps:get(challenge_id, C), <<"false">>, ?ORIGIN, ?BINDING
                    )
                ),
                ?assertEqual({error, invalid_challenge}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                meck:expect(vanillae, verify_signature, fun(_, _, _) -> {ok, false} end),
                {ok, C} = challenge(),
                ?assertEqual({error, invalid_signature}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                meck:expect(vanillae, verify_signature, fun(_, _, _) -> error(bad_signature) end),
                {ok, C} = challenge(),
                ?assertEqual({error, invalid_signature}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                sys:replace_state(damage_browser_auth, fun(S) ->
                    Cs = maps:map(
                        fun(_, V) -> V#{until => erlang:monotonic_time(millisecond) - 1} end,
                        maps:get(challenges, S)
                    ),
                    S#{challenges := Cs}
                end),
                ?assertEqual({error, invalid_challenge}, verify(C))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, Token, _} = verify(C),
                ok = damage_browser_auth:revoke(Token),
                ?assertEqual({error, invalid_session}, damage_browser_auth:lookup(Token)),
                ?assertEqual(ok, damage_browser_auth:revoke(Token))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, Token, _} = verify(C),
                sys:replace_state(damage_browser_auth, fun(S) ->
                    Ss = maps:map(
                        fun(_, V) -> V#{until => erlang:monotonic_time(millisecond) - 1} end,
                        maps:get(sessions, S)
                    ),
                    S#{sessions := Ss}
                end),
                ?assertEqual({error, invalid_session}, damage_browser_auth:lookup(Token))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, Token, _} = verify(C),
                Ss = maps:get(sessions, sys:get_state(damage_browser_auth)),
                ?assertEqual(false, maps:is_key(Token, Ss)),
                ?assertEqual(true, maps:is_key(crypto:hash(sha256, Token), Ss))
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, _, S} = damage_browser_auth:issue(
                    ?ADDRESS, custodial, <<"test@example.invalid">>
                ),
                ?assertEqual(custodial, maps:get(mode, S)),
                ?assertEqual(
                    {error, bad_request}, damage_browser_auth:issue(?ADDRESS, wallet, <<>>)
                )
            end)
        end,
        fun(_) ->
            ?_test(begin
                application:set_env(damage, browser_auth, [{attempts_per_minute, 2}]),
                ok = damage_browser_auth:attempt(peer),
                ok = damage_browser_auth:attempt(peer),
                ?assertEqual({error, rate_limited}, damage_browser_auth:attempt(peer)),
                ?assertEqual(ok, damage_browser_auth:attempt(other_peer))
            end)
        end,
        fun(_) ->
            ?_test(begin
                [
                    begin
                        {ok, _} = challenge()
                    end
                 || _ <- lists:seq(1, 4)
                ],
                ?assertEqual({error, rate_limited}, challenge())
            end)
        end,
        fun(_) ->
            ?_test(begin
                application:set_env(damage, browser_auth, [{max_sessions, 1}]),
                {ok, _, _} = damage_browser_auth:issue(
                    ?ADDRESS, custodial, <<"test@example.invalid">>
                ),
                ?assertEqual(
                    {error, session_unavailable},
                    damage_browser_auth:issue(?ADDRESS, custodial, <<"test@example.invalid">>)
                )
            end)
        end,
        fun(_) ->
            ?_test(begin
                {ok, C} = challenge(),
                {ok, Token, _} = verify(C),
                {ok, State} = damage_auth:resolve_oauth(Token, #{
                    private_key => <<"stale-key">>, username => <<"stale-user">>
                }),
                ?assertEqual(wallet, maps:get(auth_mode, State)),
                ?assertNot(maps:is_key(private_key, State)),
                ?assertNot(maps:is_key(username, State)),
                ?assertNot(meck:called(identity_server, get_account, '_'))
            end)
        end,
        fun(_) ->
            ?_test(begin
                gen_server:stop(damage_browser_auth),
                ?assertEqual(
                    {error, auth_unavailable}, damage_browser_auth:lookup(<<"ds1.missing">>)
                )
            end)
        end
    ]}.

challenge() -> damage_browser_auth:challenge(?ADDRESS, ?ORIGIN, ?BINDING, peer).
verify(C) -> damage_browser_auth:verify(maps:get(challenge_id, C), ?SIG, ?ORIGIN, ?BINDING).
setup() ->
    undefined = whereis(damage_browser_auth),
    false = lists:keymember(damage, 1, application:which_applications()),
    Saved = [{K, application:get_env(damage, K)} || K <- [browser_auth, node_admins]],
    application:set_env(damage, browser_auth, []),
    application:set_env(damage, node_admins, []),
    meck:new([aeser_api_encoder, vanillae, identity_server], [non_strict]),
    meck:expect(aeser_api_encoder, decode, fun
        (?ADDRESS) -> {account_pubkey, <<0:256>>};
        (_) -> error(badarg)
    end),
    meck:expect(vanillae, verify_signature, fun(Sig, _Msg, ?ADDRESS) -> {ok, Sig =:= ?SIG} end),
    meck:expect(identity_server, get_account, fun(_) -> error(custodial_lookup_forbidden) end),
    {ok, Pid} = damage_browser_auth:start_link(),
    unlink(Pid),
    Saved.
cleanup(Saved) ->
    case whereis(damage_browser_auth) of
        undefined -> ok;
        P -> gen_server:stop(P)
    end,
    meck:unload([aeser_api_encoder, vanillae, identity_server]),
    [
        case V of
            undefined -> application:unset_env(damage, K);
            {ok, X} -> application:set_env(damage, K, X)
        end
     || {K, V} <- Saved
    ],
    ok.
