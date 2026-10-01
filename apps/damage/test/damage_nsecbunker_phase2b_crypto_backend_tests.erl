-module(damage_nsecbunker_phase2b_crypto_backend_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

crypto_backend_smoke_test_() ->
    %% Each case creates its own identity. Sharing one setup across the list
    %% attempts to generate over the vault left by the preceding case.
    %% Keep nonzero backend exits fatal; isolate the fixture instead.
    {foreach, fun setup/0, fun cleanup/1, [
        fun(State) -> {timeout, 60, ?_test(health(State))} end,
        fun(State) -> {timeout, 60, ?_test(generate_identity(State))} end,
        fun(State) -> {timeout, 60, ?_test(get_public_key(State))} end,
        fun(State) -> {timeout, 60, ?_test(sign_event(State))} end,
        fun(State) -> {timeout, 60, ?_test(plain_nip44_roundtrip(State))} end
    ]}.

%% EUnit owns the disposable vault. Only the executable path is overridable.
%% Never consume an operator's VAULT_PATH, TEST_VAULT or vault passphrase.
setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    Cmd = crypto_backend_command(),
    Scratch = new_scratch_dir(),
    try
        ok = file:change_mode(Scratch, 8#700),
        Pass = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(32))),
        #{cmd => Cmd, vault => filename:join(Scratch, "test.vault"),
            pass => Pass, scratch_dir => Scratch}
    catch
        Class:Reason:Stack ->
            remove_scratch_tree(Scratch),
            erlang:raise(Class, Reason, Stack)
    end.

cleanup(#{scratch_dir := Scratch}) ->
    remove_scratch_tree(Scratch).

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
    Generated = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Generated)),
    assert_no_secret(Generated),
    Resp = call(State, #{op => <<"get_public_key">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Resp)),
    Pubkey = result_field(Resp, <<"pubkey_hex">>),
    ?assertMatch({match, _}, re:run(Pubkey, <<"^[0-9a-f]{64}$">>)),
    %% call/2 opens a new process: this also verifies reopening the SAME
    %% vault with the SAME password, rather than generating another identity.
    ?assertEqual(result_field(Generated, <<"pubkey_hex">>), Pubkey),
    assert_no_secret(Resp).

sign_event(State) ->
    Generated = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Generated)),
    assert_no_secret(Generated),
    Event = #{kind => 1, created_at => 1778000000, tags => [], content => <<"phase2b eunit">>},
    Resp = call(State, #{op => <<"sign_event">>, vault_path => vault(State), event => Event}),
    ?assertEqual(true, ok_field(Resp)),
    Signed = result_field(Resp, <<"event">>),
    ?assert(byte_size(field(Signed, <<"id">>)) =:= 64),
    ?assert(byte_size(field(Signed, <<"sig">>)) =:= 128),
    ?assertEqual(1, field(Signed, <<"kind">>)),
    assert_no_secret(Resp).

plain_nip44_roundtrip(State) ->
    Generated = call(State, #{op => <<"generate_identity">>, vault_path => vault(State)}),
    ?assertEqual(true, ok_field(Generated)),
    assert_no_secret(Generated),
    Plain = <<"{\"id\":\"eunit\",\"result\":\"pong\",\"error\":\"\"}">>,
    Enc = call(
        State,
        #{
            op => <<"nip44_encrypt">>,
            vault_path => vault(State),
            client_pubkey => fake_client(),
            plaintext => Plain
        },
        true
    ),
    ?assertEqual(true, ok_field(Enc)),
    Cipher = result_field(Enc, <<"ciphertext">>),
    Dec = call(
        State,
        #{
            op => <<"nip44_decrypt">>,
            vault_path => vault(State),
            client_pubkey => fake_client(),
            ciphertext => Cipher
        },
        true
    ),
    ?assertEqual(true, ok_field(Dec)),
    ?assertEqual(Plain, result_field(Dec, <<"plaintext">>)),
    assert_no_secret(Dec).

call(State, Req) ->
    call(State, Req, false).

call(#{cmd := Cmd, vault := Vault, pass := Pass}, Req, PlainNip44) ->
    %% Port-only overrides: do not mutate Rebar/EUnit's OS environment.
    %% Remove the test escape hatch on ordinary calls, even when inherited.
    Env = [
        {"DAMAGE_NSECBUNKER_VAULT_PATH", Vault},
        {"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", Pass},
        {"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44",
            case PlainNip44 of true -> "1"; false -> false end}
    ],
    Port = open_port({spawn_executable, Cmd}, [
        binary, use_stdio, exit_status, stderr_to_stdout, {env, Env}
    ]),
    Json = jsx:encode(Req),
    true = port_command(Port, <<Json/binary, "\n">>),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> jsx:decode(Acc, [return_maps]);
        {Port, {exit_status, Status}} -> error({crypto_backend_exit, Status})
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
    try
        binary_to_existing_atom(Bin, utf8)
    catch
        _:_ -> Bin
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
        true ->
            {secret_key, lists:reverse([K | Path]), <<"[REDACTED]">>};
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

crypto_backend_command() ->
    case os:getenv("DAMAGE_NSECBUNKER_CRYPTO_CMD") of
        false -> find_built_backend(filename:absname("."));
        "" -> error({invalid_crypto_backend_command, empty});
        Cmd -> checked_executable(filename:absname(Cmd))
    end.

%% Rebar runs from the project root. Walking ancestors also supports callers
%% launched from apps/damage or a build directory. Do not invoke a shell.
find_built_backend(Dir) ->
    Cmd = filename:join([Dir, "priv", "crypto", "damage-nsecbunker-crypto-c",
        "damage-nsecbunker-crypto-c"]),
    case filelib:is_file(Cmd) of
        true -> checked_executable(Cmd);
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> error({crypto_backend_not_built,
                    "Run rebar3 compile or set DAMAGE_NSECBUNKER_CRYPTO_CMD"});
                false -> find_built_backend(Parent)
            end
    end.

checked_executable(Cmd) ->
    case file:read_file_info(Cmd) of
        {ok, #file_info{type = regular, mode = Mode}} when (Mode band 8#111) =/= 0 ->
            Cmd;
        {ok, _} -> error({crypto_backend_not_executable, Cmd});
        {error, Reason} -> error({crypto_backend_unavailable, Cmd, Reason})
    end.

new_scratch_dir() ->
    Root = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end,
    new_scratch_dir(filename:absname(Root), 16).

new_scratch_dir(Root, 0) ->
    error({crypto_test_tmpdir_failed, Root, collision_limit});
new_scratch_dir(Root, Attempts) ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Dir = filename:join(Root, "damage-nsecbunker-eunit-" ++ Suffix),
    case file:make_dir(Dir) of
        ok -> Dir;
        {error, eexist} -> new_scratch_dir(Root, Attempts - 1);
        {error, Reason} -> error({crypto_test_tmpdir_failed, Root, Reason})
    end.

%% Called only on a directory exclusively created by this fixture. Inspect
%% links themselves, so cleanup never follows a symlink out of that directory.
remove_scratch_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            lists:foreach(fun(Name) ->
                ok = remove_scratch_tree(filename:join(Path, Name))
            end, Names),
            file:del_dir(Path);
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok;
        {error, Reason} -> error({crypto_test_cleanup_failed, Reason})
    end.

%% Fixture regression: independent vault locations even in successive VMs.
scratch_directories_are_distinct_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    A = new_scratch_dir(),
    try
        B = new_scratch_dir(),
        try
            ?assertNotEqual(A, B),
            ?assert(filelib:is_dir(A)),
            ?assert(filelib:is_dir(B))
        after
            ok = remove_scratch_tree(B)
        end
    after
        ok = remove_scratch_tree(A)
    end.

cleanup_does_not_follow_symlinks_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Outside = new_scratch_dir(),
    try
        Keep = filename:join(Outside, "keep"),
        ok = file:write_file(Keep, <<"not owned by cleaned fixture">>),
        Scratch = new_scratch_dir(),
        try
            ok = file:make_symlink(Outside, filename:join(Scratch, "link")),
            ok = remove_scratch_tree(Scratch),
            ?assertEqual({ok, <<"not owned by cleaned fixture">>}, file:read_file(Keep))
        after
            ok = remove_scratch_tree(Scratch)
        end
    after
        ok = remove_scratch_tree(Outside)
    end.

default_backend_is_found_from_child_directory_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Scratch = new_scratch_dir(),
    try
        Cmd = filename:join([Scratch, "priv", "crypto", "damage-nsecbunker-crypto-c",
            "damage-nsecbunker-crypto-c"]),
        Child = filename:join([Scratch, "apps", "damage"]),
        ok = filelib:ensure_dir(Cmd),
        ok = filelib:ensure_dir(filename:join(Child, "unused")),
        ok = file:write_file(Cmd, <<"#!/bin/sh\nexit 0\n">>),
        ok = file:change_mode(Cmd, 8#700),
        ?assertEqual(Cmd, find_built_backend(Child))
    after
        ok = remove_scratch_tree(Scratch)
    end.

non_executable_backend_is_rejected_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Scratch = new_scratch_dir(),
    try
        Cmd = filename:join(Scratch, "not-executable"),
        ok = file:write_file(Cmd, <<"fixture">>),
        ok = file:change_mode(Cmd, 8#600),
        ?assertError({crypto_backend_not_executable, Cmd}, checked_executable(Cmd)),
        Missing = filename:join(Scratch, "missing"),
        ?assertError({crypto_backend_unavailable, Missing, enoent}, checked_executable(Missing))
    after
        ok = remove_scratch_tree(Scratch)
    end.
