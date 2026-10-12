-module(ecai_ollama_api_keys_tests).
-include_lib("eunit/include/eunit.hrl").

api_key_lifecycle_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Path) -> ?_test(api_key_lifecycle(Path)) end}.

api_key_lifecycle(_Path) ->
    Owner = <<"acct-test@example.invalid">>,
    Other = <<"other@example.invalid">>,
    Params = #{<<"label">> => <<"CI client">>,
               <<"expires_in_days">> => 90,
               <<"scopes">> => [<<"models">>, <<"chat">>]},
    {ok, Created} = ecai_ollama_api_keys:create(Owner, Params),
    Secret = maps:get(secret, Created),
    Key = maps:get(key, Created),
    Id = maps:get(<<"id">>, Key),
    ?assertMatch(<<"ecai_ollama_", _/binary>>, Secret),
    ?assertEqual(<<"CI client">>, maps:get(<<"label">>, Key)),
    ?assertEqual([<<"chat">>, <<"models">>], maps:get(<<"scopes">>, Key)),
    ?assertEqual(<<"active">>, maps:get(<<"status">>, Key)),

    {ok, Auth} = ecai_ollama_api_keys:authenticate(Secret),
    ?assertEqual(Owner, maps:get(owner, Auth)),
    ?assert(ecai_ollama_api_keys:has_scope(Auth, <<"chat">>)),
    ?assertNot(ecai_ollama_api_keys:has_scope(Auth, <<"generate">>)),

    {ok, Listed} = ecai_ollama_api_keys:list(Owner),
    [ListedKey] = Listed,
    ?assertNot(maps:is_key(<<"secret">>, ListedKey)),
    ?assertNot(maps:is_key(secret_hash, ListedKey)),
    ?assertMatch(<<"ecai_ollama_", _/binary>>, maps:get(<<"hint">>, ListedKey)),
    ?assertEqual({error, key_not_found}, ecai_ollama_api_keys:revoke(Other, Id)),

    {ok, Rotated} = ecai_ollama_api_keys:rotate(Owner, Id),
    NewSecret = maps:get(secret, Rotated),
    ?assertNotEqual(Secret, NewSecret),
    ?assertEqual({error, key_revoked}, ecai_ollama_api_keys:authenticate(Secret)),
    {ok, NewAuth} = ecai_ollama_api_keys:authenticate(NewSecret),
    ?assertEqual(Owner, maps:get(owner, NewAuth)),
    NewId = maps:get(id, NewAuth),
    {ok, Revoked} = ecai_ollama_api_keys:revoke(Owner, NewId),
    ?assertEqual(<<"revoked">>, maps:get(<<"status">>, Revoked)),
    ?assertEqual({error, key_revoked}, ecai_ollama_api_keys:authenticate(NewSecret)).

validation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Path) -> ?_test(validation(Path)) end}.

validation(_Path) ->
    Owner = <<"validation@example.invalid">>,
    ?assertEqual({error, invalid_label},
        ecai_ollama_api_keys:create(Owner, #{<<"label">> => <<>>,
            <<"scopes">> => [<<"chat">>]})),
    ?assertEqual({error, invalid_scopes},
        ecai_ollama_api_keys:create(Owner, #{<<"label">> => <<"bad">>,
            <<"scopes">> => [<<"admin">>]})),
    ?assertEqual({error, invalid_expiry},
        ecai_ollama_api_keys:create(Owner, #{<<"label">> => <<"bad">>,
            <<"scopes">> => [<<"chat">>], <<"expires_in_days">> => -1})),
    ?assertEqual({error, invalid_key}, ecai_ollama_api_keys:authenticate(<<"not-a-key">>)).

setup() ->
    cleanup(undefined),
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Path = filename:join("/tmp", "ecai-ollama-api-keys-" ++ Suffix ++ ".dets"),
    {ok, _Pid} = ecai_ollama_api_keys:start_link(#{path => Path}),
    Path.

cleanup(Path) ->
    case whereis(ecai_ollama_api_keys) of
        undefined -> ok;
        Pid ->
            try gen_server:stop(Pid)
            catch _:_ -> ok
            end
    end,
    case Path of
        P when is_list(P) ->
            _ = file:delete(P),
            _ = file:delete(P ++ ".DAT"),
            _ = file:delete(P ++ ".TMP"),
            ok;
        _ -> ok
    end.
