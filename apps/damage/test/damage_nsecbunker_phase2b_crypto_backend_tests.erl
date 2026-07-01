-module(damage_nsecbunker_phase2b_crypto_backend_tests).

-include_lib("eunit/include/eunit.hrl").

crypto_backend_smoke_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        fun(State) ->
            [
                {timeout, 60, ?_test(health(State))},
                {timeout, 60, ?_test(generate_identity(State))},
                {timeout, 60, ?_test(get_public_key(State))},
                {timeout, 60, ?_test(sign_event(State))},
                {timeout, 60, ?_test(plain_nip44_roundtrip(State))}
            ]
        end}.

setup() ->
    Cmd = getenv_required("DAMAGE_NSECBUNKER_CRYPTO_CMD"),
    Vault = getenv_default("DAMAGE_NSECBUNKER_TEST_VAULT", "/tmp/damage-nsecbunker-phase2b-eunit.vault"),
    Pass = getenv_default("DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase2b-eunit-passphrase"),
    _ = file:delete(Vault),
    ok = filelib:ensure_dir(Vault ++ ".dummy"),
    #{cmd => Cmd, vault => Vault, pass => Pass}.

cleanup(#{vault := Vault}) ->
    _ = file:delete(Vault),
    ok.

health(State) ->
    Resp = call(State, #{op => <<"health">>}),
    ?assertEqual(true, ok_field(Resp)),
    ?assertEqual(<<"damage-nsecbunker-crypto-v1">>, result_field(Resp, <<"protocol">>)),
    assert_no_secret(Resp).

generate_identity(State) ->
    Resp = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Resp)),
    Pubkey = result_field(Resp, <<"pubkey_hex">>),
    ?assertMatch({match, _}, re:run(Pubkey, <<"^[0-9a-f]{64}$">>)),
    _ = result_field(Resp, <<"npub">>),
    assert_no_secret(Resp).

get_public_key(State) ->
    _ = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    Resp = call(State, #{op => <<"get_public_key">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Resp)),
    Pubkey = result_field(Resp, <<"pubkey_hex">>),
    ?assertMatch({match, _}, re:run(Pubkey, <<"^[0-9a-f]{64}$">>)),
    assert_no_secret(Resp).

sign_event(State) ->
    _ = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    Event = #{kind => 1, created_at => 1778000000, tags => [], content => <<"phase2b eunit">>},
    Resp = call(State, #{op => <<"sign_event">>, vault_path => vault(State), event => Event}),
    ?assertEqual(true, ok_field(Resp)),
    Signed = result_field(Resp, <<"event">>),
    ?assert(byte_size(field(Signed, <<"id">>)) =:= 64),
    ?assert(byte_size(field(Signed, <<"sig">>)) =:= 128),
    ?assertEqual(1, field(Signed, <<"kind">>)),
    assert_no_secret(Resp).

plain_nip44_roundtrip(State) ->
    _ = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    Plain = <<"{\"id\":\"eunit\",\"result\":\"pong\",\"error\":\"\"}">>,
    Enc = call(State, #{op => <<"nip44_encrypt">>, vault_path => vault(State), client_pubkey => fake_client(), plaintext => Plain}, true),
    ?assertEqual(true, ok_field(Enc)),
    Cipher = result_field(Enc, <<"ciphertext">>),
    Dec = call(State, #{op => <<"nip44_decrypt">>, vault_path => vault(State), client_pubkey => fake_client(), ciphertext => Cipher}, true),
    ?assertEqual(true, ok_field(Dec)),
    ?assertEqual(Plain, result_field(Dec, <<"plaintext">>)),
    assert_no_secret(Dec).

call(State, Req) ->
    call(State, Req, false).

call(#{cmd := Cmd, vault := Vault, pass := Pass}, Req, PlainNip44) ->
    Env0 = [{"DAMAGE_NSECBUNKER_VAULT_PATH", Vault}, {"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", Pass}],
    Env = case PlainNip44 of true -> [{"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"} | Env0]; false -> Env0 end,
    Port = open_port({spawn_executable, Cmd}, [binary, use_stdio, exit_status, stderr_to_stdout, {env, Env}]),
    Json = jsx:encode(Req),
    true = port_command(Port, <<Json/binary, "\n">>),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, _}} -> jsx:decode(Acc, [return_maps])
    after 10000 ->
        _ = erlang:port_close(Port),
        error(crypto_backend_timeout)
    end.

ok_field(Resp) -> maps:get(<<"ok">>, Resp, maps:get(ok, Resp, false)).

result_field(Resp, Field) ->
    Result = maps:get(<<"result">>, Resp, maps:get(result, Resp, #{})),
    field(Result, Field).

field(Map, Field) -> maps:get(Field, Map, maps:get(binary_to_atom_safe(Field), Map, undefined)).

binary_to_atom_safe(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch _:_ -> Bin
    end.

assert_no_secret(Resp) ->
    %% Secret leak detection must be structural. The backend/protocol name
    %% contains "nsecbunker", so a blind substring scan for "nsec" creates
    %% false positives. Reject exact secret-shaped field names and actual
    %% secret-shaped values instead.
    ?assertEqual(false, secret_leak(Resp)).

secret_leak(Term) ->
    secret_leak(Term, []).

secret_leak(Map, Path) when is_map(Map) ->
    secret_leak_pairs(maps:to_list(Map), Path);
secret_leak(List, Path) when is_list(List) ->
    secret_leak_list(List, Path, 0);
secret_leak(Bin, Path) when is_binary(Bin) ->
    case secret_value(Bin) of
        true -> {secret_value, lists:reverse(Path), <<"[REDACTED]">>};
        false -> false
    end;
secret_leak(_Other, _Path) ->
    false.

secret_leak_pairs([], _Path) ->
    false;
secret_leak_pairs([{K, V} | Rest], Path) ->
    case secret_key_name(K) of
        true -> {secret_key, lists:reverse([K | Path]), <<"[REDACTED]">>};
        false ->
            case secret_leak(V, [K | Path]) of
                false -> secret_leak_pairs(Rest, Path);
                Leak -> Leak
            end
    end.

secret_leak_list([], _Path, _N) ->
    false;
secret_leak_list([H | T], Path, N) ->
    case secret_leak(H, [N | Path]) of
        false -> secret_leak_list(T, Path, N + 1);
        Leak -> Leak
    end.

secret_key_name(K) ->
    lists:member(key_bin(K), [
        <<"nsec">>,
        <<"private_key">>,
        <<"private_key_hex">>,
        <<"privkey">>,
        <<"privkey_hex">>,
        <<"secret_key">>,
        <<"secret_key_hex">>,
        <<"mnemonic">>,
        <<"seed">>,
        <<"seed_hex">>,
        <<"sk">>
    ]).

secret_value(Bin) ->
    Patterns = <<"(nsec1[02-9ac-hj-np-z]+|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----)">>,
    case re:run(Bin, Patterns, [caseless, {capture, none}]) of
        match -> true;
        nomatch -> false
    end.

key_bin(K) when is_binary(K) ->
    list_to_binary(string:lowercase(binary_to_list(K)));
key_bin(K) when is_atom(K) ->
    key_bin(atom_to_binary(K, utf8));
key_bin(K) when is_integer(K) ->
    integer_to_binary(K);
key_bin(K) ->
    key_bin(unicode:characters_to_binary(io_lib:format("~p", [K]))).

vault(#{vault := Vault}) -> unicode:characters_to_binary(Vault).

fake_client() -> <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>.

getenv_required(Name) ->
    case os:getenv(Name) of false -> error({missing_required_env, Name}); Value -> Value end.

getenv_default(Name, Default) ->
    case os:getenv(Name) of false -> Default; Value -> Value end.
