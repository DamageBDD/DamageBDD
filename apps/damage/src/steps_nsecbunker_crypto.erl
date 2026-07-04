%%--------------------------------------------------------------------
%% DamageBDD steps for Phase 2B crypto backend executable testing.
%% These steps test the backend contract directly through the same JSON
%% stdin/stdout shape used by damage_nsecbunker_vault.
%%--------------------------------------------------------------------
-module(steps_nsecbunker_crypto).

-include_lib("kernel/include/logger.hrl").

-export([step/6, step_dry/6]).

-define(NS, nsecbunker_crypto).

-define(S_BACKEND_CMD, ["the Phase 2B crypto backend command is", Cmd]).
-define(S_VAULT_PATH, ["the Phase 2B test vault path is", Path]).
-define(S_RESET_VAULT, ["the Phase 2B test vault is reset"]).
-define(S_VAULT_PASSPHRASE, ["the Phase 2B test vault passphrase is", Passphrase]).
-define(S_PLAIN_NIP44, ["Phase 2B plain NIP44 loopback is enabled"]).
-define(S_HEALTH, ["I ask the crypto backend for health"]).
-define(S_GENERATE, ["I ask the crypto backend to generate identity"]).
-define(S_GET_PUBLIC, ["I ask the crypto backend for the public key"]).
-define(S_NPUB, ["I ask the crypto backend for npub"]).
-define(S_SIGN_KIND, ["I ask the crypto backend to sign a kind", Kind, "event"]).
-define(S_ENCRYPT, ["I ask the crypto backend to encrypt a Phase 2B plaintext response"]).
-define(S_DECRYPT, ["I ask the crypto backend to decrypt the Phase 2B ciphertext response"]).
-define(S_OK, ["the crypto backend response MUST be ok"]).
-define(S_FIELD_PRESENT, ["the crypto backend result field", Field, "MUST be present"]).
-define(S_RESULT_FIELD_EQUALS, ["the crypto backend result field", Field, "MUST equal", Expected]).
-define(S_EVENT_HAS_SIG, ["the signed event MUST contain id and sig"]).
-define(S_NO_SECRET, ["the crypto backend response MUST NOT contain secret material"]).
-define(S_PUBKEY_64, ["the returned public key MUST be 64 lowercase hex characters"]).
-define(S_CIPHERTEXT_ROUNDTRIPS, ["the decrypted plaintext MUST equal the encrypted plaintext"]).

-define(S_PHASE2C_REAL_NIP44, ["Phase 2C real NIP44 mode is expected"]).
-define(S_PRODUCTION_MODE, ["Phase 2C production mode is enabled"]).
-define(S_BIP340_SIGN_VECTOR0, ["I ask the crypto backend to sign BIP340 vector", "0"]).
-define(S_BIP340_VERIFY_VECTOR0, ["I ask the crypto backend to verify BIP340 vector", "0"]).
-define(S_NPUB_VECTOR, ["I ask the crypto backend to encode the secp256k1 generator npub vector"]).
-define(S_EVENT_ID_VECTOR, ["I ask the crypto backend to calculate the NIP01 event id vector"]).
-define(S_NIP44_ENCRYPT_VECTOR0, ["I ask the crypto backend to encrypt NIP44 vector", "0"]).
-define(S_NIP44_DECRYPT_VECTOR0, ["I ask the crypto backend to decrypt NIP44 vector", "0"]).
-define(S_REAL_NIP44_ENCRYPT, ["I ask the crypto backend to encrypt a Phase 2C real NIP44 message"]).
-define(S_REAL_NIP44_DECRYPT, [
    "I ask the crypto backend to decrypt the Phase 2C real NIP44 message"
]).
-define(S_WRONG_PASSPHRASE, ["I ask the crypto backend to open the vault with the wrong passphrase"]).
-define(S_PLAIN_STATUS, ["I ask the crypto backend whether plain NIP44 is allowed"]).

-spec step(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().
-spec step_dry(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, _Keyword, _Line, ?S_BACKEND_CMD, _Args) ->
    put_ns(Context, (ns(Context))#{cmd => strip(Cmd)});
step(_Config, Context, _Keyword, _Line, ?S_VAULT_PATH, _Args) ->
    Path0 = strip(Path),
    ok = filelib:ensure_dir(binary_to_list(<<Path0/binary, ".dummy">>)),
    put_ns(Context, (ns(Context))#{vault_path => Path0});
step(_Config, Context, _Keyword, _Line, ?S_RESET_VAULT, _Args) ->
    Path0 = vault_path(Context),
    _ = file:delete(binary_to_list(Path0)),
    Context;
step(_Config, Context, _Keyword, _Line, ?S_VAULT_PASSPHRASE, _Args) ->
    put_ns(Context, (ns(Context))#{passphrase => strip(Passphrase)});
step(_Config, Context, _Keyword, _Line, ?S_PLAIN_NIP44, _Args) ->
    put_ns(Context, (ns(Context))#{plain_nip44 => true});
step(_Config, Context, _Keyword, _Line, ?S_HEALTH, _Args) ->
    call_and_store(Context, #{op => <<"health">>});
step(_Config, Context, _Keyword, _Line, ?S_GENERATE, _Args) ->
    call_and_store(Context, #{op => <<"generate_identity">>, vault_path => vault_path(Context)});
step(_Config, Context, _Keyword, _Line, ?S_GET_PUBLIC, _Args) ->
    call_and_store(Context, #{op => <<"get_public_key">>, vault_path => vault_path(Context)});
step(_Config, Context, _Keyword, _Line, ?S_NPUB, _Args) ->
    Pubkey = result_field(Context, <<"pubkey_hex">>),
    call_and_store(Context, #{
        op => <<"npub">>, vault_path => vault_path(Context), pubkey_hex => Pubkey
    });
step(_Config, Context, _Keyword, _Line, ?S_SIGN_KIND, _Args) ->
    KindInt = to_int(Kind),
    Event = #{
        kind => KindInt,
        created_at => 1778000000,
        tags => [],
        content => <<"phase2b crypto backend test">>
    },
    call_and_store(Context, #{
        op => <<"sign_event">>, vault_path => vault_path(Context), event => Event
    });
step(_Config, Context, _Keyword, _Line, ?S_ENCRYPT, _Args) ->
    Plain = <<"{\"id\":\"bdd-phase2b\",\"result\":\"pong\",\"error\":\"\"}">>,
    C1 = put_ns(Context, (ns(Context))#{roundtrip_plaintext => Plain}),
    call_and_store(C1, #{
        op => <<"nip44_encrypt">>,
        vault_path => vault_path(C1),
        client_pubkey => fake_client(),
        plaintext => Plain
    });
step(_Config, Context, _Keyword, _Line, ?S_DECRYPT, _Args) ->
    Ciphertext = result_field(Context, <<"ciphertext">>),
    call_and_store(Context, #{
        op => <<"nip44_decrypt">>,
        vault_path => vault_path(Context),
        client_pubkey => fake_client(),
        ciphertext => Ciphertext
    });
step(_Config, Context, _Keyword, _Line, ?S_OK, _Args) ->
    Resp = response(Context),
    case maps:get(<<"ok">>, Resp, maps:get(ok, Resp, false)) of
        true -> Context;
        false -> error({crypto_backend_not_ok, Resp})
    end;
step(_Config, Context, _Keyword, _Line, ?S_FIELD_PRESENT, _Args) ->
    _ = result_field(Context, strip(Field)),
    Context;
step(_Config, Context, _Keyword, _Line, ?S_RESULT_FIELD_EQUALS, _Args) ->
    Actual = result_field(Context, strip(Field)),
    Expected0 = expected_value(strip(Expected)),
    case Actual =:= Expected0 of
        true -> Context;
        false -> error({crypto_backend_field_mismatch, Field, Expected0, Actual})
    end;
step(_Config, Context, _Keyword, _Line, ?S_EVENT_HAS_SIG, _Args) ->
    Event = result_field(Context, <<"event">>),
    _ = get_any(<<"id">>, id, Event),
    Sig = get_any(<<"sig">>, sig, Event),
    true = is_binary(Sig) andalso byte_size(Sig) =:= 128,
    Context;
step(_Config, Context, _Keyword, _Line, ?S_NO_SECRET, _Args) ->
    %% Structural check: the backend name contains "nsecbunker", so do not
    %% blindly grep for "nsec" across the whole JSON blob.
    case secret_leak(response(Context)) of
        false -> Context;
        Leak -> error({crypto_backend_secret_material_leaked, Leak})
    end;
step(_Config, Context, _Keyword, _Line, ?S_PUBKEY_64, _Args) ->
    Pubkey = result_field(Context, <<"pubkey_hex">>),
    case re:run(Pubkey, <<"^[0-9a-f]{64}$">>, [{capture, none}]) of
        match -> Context;
        nomatch -> error({invalid_pubkey_hex, Pubkey})
    end;
step(_Config, Context, _Keyword, _Line, ?S_CIPHERTEXT_ROUNDTRIPS, _Args) ->
    Plain0 = maps:get(roundtrip_plaintext, ns(Context)),
    Plain1 = result_field(Context, <<"plaintext">>),
    case Plain0 =:= Plain1 of
        true -> Context;
        false -> error({nip44_plain_roundtrip_failed, Plain0, Plain1})
    end;
step(_Config, Context, _Keyword, _Line, ?S_PHASE2C_REAL_NIP44, _Args) ->
    put_ns(Context, (ns(Context))#{plain_nip44 => false, phase2c_real_nip44 => true});
step(_Config, Context, _Keyword, _Line, ?S_PRODUCTION_MODE, _Args) ->
    put_ns(Context, (ns(Context))#{production_mode => true});
step(_Config, Context, _Keyword, _Line, ?S_BIP340_SIGN_VECTOR0, _Args) ->
    call_and_store(Context, #{
        op => <<"schnorr_sign_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000003">>,
        message_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>,
        aux_rand_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>
    });
step(_Config, Context, _Keyword, _Line, ?S_BIP340_VERIFY_VECTOR0, _Args) ->
    call_and_store(Context, #{
        op => <<"schnorr_verify">>,
        pubkey_hex => <<"F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9">>,
        message_hex => <<"0000000000000000000000000000000000000000000000000000000000000000">>,
        signature_hex =>
            <<"E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0">>
    });
step(_Config, Context, _Keyword, _Line, ?S_NPUB_VECTOR, _Args) ->
    call_and_store(Context, #{
        op => <<"npub">>,
        pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>
    });
step(_Config, Context, _Keyword, _Line, ?S_EVENT_ID_VECTOR, _Args) ->
    call_and_store(Context, #{
        op => <<"event_id">>,
        pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
        event => #{created_at => 0, kind => 1, tags => [], content => <<"hello">>}
    });
step(_Config, Context, _Keyword, _Line, ?S_NIP44_ENCRYPT_VECTOR0, _Args) ->
    call_and_store(Context, #{
        op => <<"nip44_encrypt_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000001">>,
        peer_pubkey_hex => <<"c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5">>,
        nonce_hex => <<"0000000000000000000000000000000000000000000000000000000000000001">>,
        plaintext => <<"a">>
    });
step(_Config, Context, _Keyword, _Line, ?S_NIP44_DECRYPT_VECTOR0, _Args) ->
    call_and_store(Context, #{
        op => <<"nip44_decrypt_vector">>,
        secret_key_hex => <<"0000000000000000000000000000000000000000000000000000000000000002">>,
        peer_pubkey_hex => <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>,
        payload =>
            <<"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb">>
    });
step(_Config, Context, _Keyword, _Line, ?S_REAL_NIP44_ENCRYPT, _Args) ->
    Plain = <<"phase2c real nip44">>,
    C1 = put_ns(Context, (ns(Context))#{roundtrip_plaintext => Plain}),
    call_and_store(C1, #{
        op => <<"nip44_encrypt">>,
        vault_path => vault_path(C1),
        client_pubkey => valid_client(),
        plaintext => Plain
    });
step(_Config, Context, _Keyword, _Line, ?S_REAL_NIP44_DECRYPT, _Args) ->
    Ciphertext = result_field(Context, <<"ciphertext">>),
    call_and_store(Context, #{
        op => <<"nip44_decrypt">>,
        vault_path => vault_path(Context),
        client_pubkey => valid_client(),
        ciphertext => Ciphertext
    });
step(_Config, Context, _Keyword, _Line, ?S_WRONG_PASSPHRASE, _Args) ->
    C1 = put_ns(Context, (ns(Context))#{passphrase => <<"wrong-passphrase">>}),
    call_and_store(C1, #{op => <<"get_public_key">>, vault_path => vault_path(C1)});
step(_Config, Context, _Keyword, _Line, ?S_PLAIN_STATUS, _Args) ->
    call_and_store(Context, #{op => <<"plain_mode_status">>}).

call_and_store(Context, Req) ->
    Resp = call_backend(Context, Req),
    put_ns(Context, (ns(Context))#{last_response => Resp}).

call_backend(Context, Req) ->
    Cmd = binary_to_list(maps:get(cmd, ns(Context))),
    Env = env(Context),
    Port = open_port({spawn_executable, Cmd}, [
        binary, use_stdio, exit_status, stderr_to_stdout, {env, Env}
    ]),
    Json = jsx:encode(Req),
    true = port_command(Port, <<Json/binary, "\n">>),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, _Status}} ->
            case jsx:decode(Acc, [return_maps]) of
                Map when is_map(Map) -> Map
            end
    after 10000 ->
        _ = erlang:port_close(Port),
        error(crypto_backend_timeout)
    end.

env(Context) ->
    Base = [
        {"DAMAGE_NSECBUNKER_VAULT_PATH", binary_to_list(vault_path(Context))},
        {"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
            binary_to_list(maps:get(passphrase, ns(Context), <<"phase2b-bdd-passphrase">>))}
    ],
    WithPlain =
        case maps:get(plain_nip44, ns(Context), false) of
            true ->
                [
                    {"DAMAGE_NSECBUNKER_TEST_MODE", "1"},
                    {"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"}
                    | Base
                ];
            false ->
                Base
        end,
    case maps:get(production_mode, ns(Context), false) of
        true ->
            [
                {"DAMAGE_NSECBUNKER_PRODUCTION", "1"},
                {"DAMAGE_NSECBUNKER_TEST_MODE", "1"},
                {"DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44", "1"}
                | WithPlain
            ];
        false ->
            WithPlain
    end.

response(Context) -> maps:get(last_response, ns(Context), #{}).

result(Context) ->
    Resp = response(Context),
    maps:get(<<"result">>, Resp, maps:get(result, Resp, #{})).

result_field(Context, Field0) ->
    Field = strip(Field0),
    Result = result(Context),
    Resp = response(Context),
    case get_any(Field, binary_to_atom_safe(Field), Result) of
        undefined ->
            case get_any(Field, binary_to_atom_safe(Field), Resp) of
                undefined -> error({missing_crypto_backend_result_field, Field, Result, Resp});
                TopValue -> TopValue
            end;
        Value ->
            Value
    end.

get_any(BinKey, AtomKey, Map) when is_map(Map) ->
    maps:get(BinKey, Map, maps:get(AtomKey, Map, undefined)).

ns(Context) -> maps:get(?NS, Context, #{}).
put_ns(Context, NS) -> maps:put(?NS, NS, Context).

vault_path(Context) ->
    maps:get(vault_path, ns(Context), <<"/tmp/damage-nsecbunker-phase2b-bdd.vault">>).

fake_client() -> <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>.
valid_client() -> <<"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798">>.

strip(V) when is_binary(V) -> strip_quotes(string:trim(V));
strip(V) when is_list(V) -> strip(unicode:characters_to_binary(V));
strip(V) when is_atom(V) -> atom_to_binary(V, utf8);
strip(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

strip_quotes(Bin) when is_binary(Bin) ->
    Chars = binary_to_list(Bin),
    case Chars of
        [$" | Rest] ->
            case lists:reverse(Rest) of
                [$" | RevMiddle] -> unicode:characters_to_binary(lists:reverse(RevMiddle));
                _ -> Bin
            end;
        _ ->
            Bin
    end.

binary_to_atom_safe(Bin) ->
    try
        binary_to_existing_atom(Bin, utf8)
    catch
        _:_ -> Bin
    end.

expected_value(<<"true">>) -> true;
expected_value(<<"false">>) -> false;
expected_value(Other) -> Other.

to_int(B) when is_binary(B) -> binary_to_integer(strip(B));
to_int(L) when is_list(L) -> to_int(unicode:characters_to_binary(L));
to_int(I) when is_integer(I) -> I.

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
