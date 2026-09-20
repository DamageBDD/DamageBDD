%% Isolated secrets callbacks hosted by real gen_server processes. No gproc
%% registration, HTTP, AE node, production DETS or funded wallet is touched.
-module(secrets_wallet_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-export([init_fixture/2, log/2]).

secrets_wallet_test_() ->
    {setup, fun setup/0, fun(_) -> ok end,
     [fun first_run_export_and_restart/0,
      fun legacy_keystore_is_not_rotated/0,
      fun wrong_password_and_corrupt_file_are_not_replaced/0,
      fun mismatched_backup_is_rejected_on_load/0,
      fun failed_creation_is_reported/0,
      fun creation_refuses_overwrite/0,
      fun export_requires_unlock_and_existing_keystore/0,
      fun export_rejects_replaced_keystore/0,
      fun repeated_encrypt_decrypt_does_not_cache_plaintext/0,
      fun malformed_envelopes_are_rejected/0,
      fun scoped_and_bound_apis_are_still_exported/0,
      fun otp_status_and_unknown_call_logs_are_redacted/0,
      fun code_upgrade_drops_recovery_and_plaintext_cache/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    {module, secrets} = code:ensure_loaded(secrets),
    {module, enacl} = code:ensure_loaded(enacl),
    {module, damage_ae_wallet} = code:ensure_loaded(damage_ae_wallet),
    ok.

first_run_export_and_restart() ->
    with_keystore(fun(Path) ->
        Password = password(),
        Pid = start_fixture(#{}),
        {Signing, Phrase} = try
            ?assertEqual(ok, gen_server:call(Pid, {set_node_password, Password})),
            {ok, Info} = file:read_file_info(Path),
            ?assertEqual(8#600, Info#file_info.mode band 8#777),
            KeyPair = secrets:read_keypair(Path, Password),
            ?assert(is_map(KeyPair)),
            Mnemonic = maps:get(mnemonic, KeyPair),
            {ok, DiskBytes} = file:read_file(Path),
            ?assertEqual(nomatch, binary:match(DiskBytes, Mnemonic)),
            ?assertEqual(nomatch, binary:match(DiskBytes, maps:get(private_key, KeyPair))),
            Reply = gen_server:call(Pid, node_keypair),
            ?assertEqual([private_key, public_key], lists:sort(maps:keys(Reply))),
            ?assertEqual(Reply, gen_server:call(Pid, node_keypair)),
            ?assertEqual(false, maps:is_key(mnemonic, sys:get_state(Pid))),
            {ok, Export} = gen_server:call(Pid, export_node_wallet_seedphrase),
            ?assertEqual(Mnemonic, maps:get(seed_phrase, Export)),
            ?assertEqual(maps:get(public_key, Reply), maps:get(address, Export)),
            ?assertEqual(false, maps:is_key(mnemonic, sys:get_state(Pid))),
            {Reply, Mnemonic}
        after stop_fixture(Pid) end,
        %% A fresh process has no signing-key or mnemonic cache.
        Pid2 = start_fixture(#{node_password => binary_to_list(Password)}),
        try
            ?assertEqual(Signing, gen_server:call(Pid2, node_keypair)),
            {ok, Reloaded} = gen_server:call(Pid2, export_node_wallet_seedphrase),
            ?assertEqual(Phrase, maps:get(seed_phrase, Reloaded)),
            ?assertEqual(ok, gen_server:call(Pid2, clear_cache)),
            ?assertEqual(#{}, sys:get_state(Pid2)),
            ?assertEqual({error, node_locked}, gen_server:call(Pid2, export_node_wallet_seedphrase))
        after stop_fixture(Pid2) end
    end).

legacy_keystore_is_not_rotated() ->
    with_keystore(fun(Path) ->
        #{public := Public, secret := Private} = enacl:sign_keypair(),
        Legacy = #{public_key => binary_to_list(aeser_api_encoder:encode(account_pubkey, Public)),
                   private_key => Private},
        write_fixture(Path, Legacy),
        {ok, Before} = file:read_file(Path),
        ?assertEqual(ok, secrets:ensure_keypair_valid(password())),
        ?assertEqual(Legacy, secrets:keypair(Path, password())),
        ?assertEqual({ok, Before}, file:read_file(Path)),
        Pid = start_fixture(#{node_password => binary_to_list(password())}),
        try
            Reply = gen_server:call(Pid, node_keypair),
            ?assertEqual(Private, maps:get(private_key, Reply)),
            ?assertEqual({error, {node_wallet_not_mnemonic_backed, use_private_key_export}},
                         gen_server:call(Pid, export_node_wallet_seedphrase))
        after stop_fixture(Pid) end,
        ?assertEqual({ok, Before}, file:read_file(Path))
    end).

wrong_password_and_corrupt_file_are_not_replaced() ->
    with_keystore(fun(Path) ->
        ?assert(is_map(secrets:keypair(Path, password()))),
        {ok, Before} = file:read_file(Path),
        ?assertEqual({error, decrypt_keypair}, secrets:keypair(Path, <<"wrong">>)),
        ?assertEqual({error, invalid_password}, secrets:ensure_keypair_valid(<<"wrong">>)),
        ?assertEqual({ok, Before}, file:read_file(Path)),
        ok = file:write_file(Path, <<"corrupt-keystore">>),
        ?assertEqual({error, corrupt_keypair}, secrets:keypair(Path, password())),
        ?assertEqual({ok, <<"corrupt-keystore">>}, file:read_file(Path)),
        write_fixture(Path, #{not_a_keypair => true}),
        ?assertEqual({error, corrupt_keypair}, secrets:ensure_keypair_valid(password()))
    end).

mismatched_backup_is_rejected_on_load() ->
    with_keystore(fun(Path) ->
        A = secrets:make_keypair(), B = secrets:make_keypair(),
        Bad = A#{mnemonic => maps:get(mnemonic, B)},
        write_fixture(Path, Bad),
        {ok, Before} = file:read_file(Path),
        ?assertEqual({error, {invalid_wallet_backup, mnemonic_keypair_mismatch}},
                     secrets:keypair(Path, password())),
        ?assertEqual({ok, Before}, file:read_file(Path))
    end).

failed_creation_is_reported() ->
    with_keystore(fun(Path) ->
        Parent = filename:dirname(Path),
        ok = file:write_file(Parent, <<"not-a-directory">>),
        ?assertMatch({error, {keypair_directory_failed, _}},
                     secrets:create_keypair(Path, password())),
        Pid = start_fixture(#{}),
        try
            ?assertMatch({error, {keypair_read_failed, _}},
                         gen_server:call(Pid, {set_node_password, password()})),
            ?assertEqual(#{}, sys:get_state(Pid))
        after stop_fixture(Pid) end
    end).

creation_refuses_overwrite() ->
    with_keystore(fun(Path) ->
        KP = secrets:keypair(Path, password()),
        {ok, Before} = file:read_file(Path),
        ?assertEqual({error, keypair_already_exists}, secrets:create_keypair(Path, password())),
        ?assertEqual({ok, Before}, file:read_file(Path)),
        ?assertEqual(KP, secrets:keypair(Path, password()))
    end).

export_requires_unlock_and_existing_keystore() ->
    with_keystore(fun(Path) ->
        Pid = start_fixture(#{}),
        try
            ?assertEqual({error, node_locked}, gen_server:call(Pid, export_node_wallet_seedphrase))
        after stop_fixture(Pid) end,
        Pid2 = start_fixture(#{node_password => binary_to_list(password())}),
        try
            ?assertEqual({error, missing_keypair}, gen_server:call(Pid2, export_node_wallet_seedphrase)),
            ?assertEqual(false, filelib:is_file(Path))
        after stop_fixture(Pid2) end
    end).

export_rejects_replaced_keystore() ->
    with_keystore(fun(Path) ->
        ?assert(is_map(secrets:keypair(Path, password()))),
        Pid = start_fixture(#{node_password => binary_to_list(password())}),
        try
            _ = gen_server:call(Pid, node_keypair),
            write_fixture(Path, secrets:make_keypair()),
            ?assertEqual({error, keystore_identity_mismatch},
                         gen_server:call(Pid, export_node_wallet_seedphrase))
        after stop_fixture(Pid) end
    end).

repeated_encrypt_decrypt_does_not_cache_plaintext() ->
    State = #{node_password => binary_to_list(password())},
    Pid = start_fixture(State),
    Plain = #{payload => <<"sensitive-test-payload">>},
    try
        lists:foreach(fun(_) ->
            {ok, Envelope} = gen_server:call(Pid, {encrypt, cache_key, Plain}),
            ?assert(is_binary(Envelope)),
            ?assertEqual(Plain, gen_server:call(Pid, {decrypt, cache_key, Envelope})),
            {ok, Explicit} = gen_server:call(Pid, {encrypt, cache_key, password(), Plain}),
            ?assertEqual(Plain, gen_server:call(Pid, {decrypt, cache_key, password(), Explicit})),
            ?assertEqual(State, sys:get_state(Pid))
        end, lists:seq(1, 3)),
        ?assertEqual(error, gen_server:call(Pid, {decrypt, cache_key, <<"bad-etf">>})),
        ?assertEqual(State, sys:get_state(Pid))
    after stop_fixture(Pid) end.

malformed_envelopes_are_rejected() ->
    KP = secrets:make_keypair(),
    lists:foreach(fun(Envelope) ->
        ?assertEqual(error, secrets:decrypt(KP, Envelope))
    end, [<<"not base64!">>, base64:encode(<<"bad-etf">>),
          base64:encode(term_to_binary({<<>>, <<>>, <<>>}))]),
    %% ETF SMALL_ATOM_UTF8_EXT for a name that is not interned. Safe decoding
    %% must reject it without adding a new atom to this VM.
    Name = <<"damage_wallet_untrusted_", (binary:encode_hex(crypto:strong_rand_bytes(12)))/binary>>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    ETF = <<131, 119, (byte_size(Name)), Name/binary>>,
    ?assertEqual(error, secrets:decrypt(KP, base64:encode(ETF))),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)).

scoped_and_bound_apis_are_still_exported() ->
    lists:foreach(fun({Function, Arity}) ->
        ?assert(erlang:function_exported(secrets, Function, Arity))
    end, [{delete_secret, 1}, {delete_secret, 2}, {encrypt_store, 3},
          {retrieve_decrypt, 2}, {encrypt_bound, 2}, {decrypt_bound, 2}]).

otp_status_and_unknown_call_logs_are_redacted() ->
    Secret = <<"UNIQUE-CREDENTIAL-MUST-NOT-APPEAR">>,
    Status = #{state => #{mnemonic => Secret}, message => {password, Secret},
               reason => {badmatch, Secret}, log => [{in, Secret}], future_field => Secret},
    Redacted = secrets:format_status(Status),
    ?assertEqual(lists:sort(maps:keys(Status)), lists:sort(maps:keys(Redacted))),
    ?assertEqual(nomatch, binary:match(term_to_binary(Redacted), Secret)),
    Pid = start_fixture(#{node_password => binary_to_list(Secret), mnemonic => Secret}),
    Ref = make_ref(),
    Handler = damage_wallet_test_capture,
    ok = logger:add_handler(Handler, ?MODULE,
             #{level => all, config => #{owner => self(), reference => Ref}}),
    try
        ?assertEqual({error, unsupported_call}, gen_server:call(Pid, {Secret, Secret})),
        receive
            {Ref, #{meta := #{pid := Pid}} = Event} ->
                ?assertEqual(nomatch, binary:match(term_to_binary(Event), Secret))
        after 5000 -> error(missing_log_event)
        end,
        ?assertEqual(nomatch, binary:match(term_to_binary(sys:get_status(Pid)), Secret))
    after
        logger:remove_handler(Handler),
        stop_fixture(Pid)
    end.

code_upgrade_drops_recovery_and_plaintext_cache() ->
    State = #{node_password => "test", public_key => <<"ak_test">>, private_key => <<0:512>>,
              mnemonic => <<"words">>, seed_phrase => <<"words">>, cache_key => <<"plaintext">>},
    {ok, Upgraded} = secrets:code_change(old, State, []),
    ?assertEqual([node_password, private_key, public_key], lists:sort(maps:keys(Upgraded))).

%% A real OTP server using secrets callbacks, without calling the production
%% initializer or claiming its gproc registration.
start_fixture(State) ->
    {ok, Pid} = proc_lib:start_link(?MODULE, init_fixture, [self(), State]),
    Pid.
init_fixture(Parent, State) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    gen_server:enter_loop(secrets, [], State).
stop_fixture(Pid) ->
    case is_process_alive(Pid) of true -> gen_server:stop(Pid, normal, 5000); false -> ok end.

%% Minimal logger handler, used only by the diagnostic-redaction test.
log(Event, #{config := #{owner := Owner, reference := Ref}}) ->
    Owner ! {Ref, Event}, ok.

with_keystore(Fun) ->
    %% These tests are intentionally sequential and must run in a fresh VM.
    OldKeystore = application:get_env(damage, keystore),
    OldPassword = os:getenv("DAMAGE_SECRET_KEY"),
    Tmp = case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end,
    Root = filename:join(Tmp, "damage-wallet-test-" ++
                              binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Root),
    ok = file:change_mode(Root, 8#700),
    Path = filename:join([Root, "nested", "damage.key"]),
    try
        application:set_env(damage, keystore, Path),
        os:unsetenv("DAMAGE_SECRET_KEY"),
        Fun(Path)
    after
        case OldKeystore of
            undefined -> application:unset_env(damage, keystore);
            {ok, Value} -> application:set_env(damage, keystore, Value)
        end,
        case OldPassword of
            false -> os:unsetenv("DAMAGE_SECRET_KEY");
            Password -> os:putenv("DAMAGE_SECRET_KEY", Password)
        end,
        file:del_dir_r(Root)
    end.

write_fixture(Path, Term) ->
    ok = filelib:ensure_dir(Path),
    Envelope = secrets:encrypt(password(), term_to_binary(Term)),
    ok = file:write_file(Path, term_to_binary(Envelope)),
    ok = file:change_mode(Path, 8#600).
password() -> <<"disposable-unit-test-keystore-password">>.
