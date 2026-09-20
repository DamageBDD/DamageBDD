%% All phrases/keys here are public test vectors or disposable generated data.
%% Run in a fresh test VM, never a running/funded Damage node.
-module(damage_ae_wallet_tests).
-include_lib("eunit/include/eunit.hrl").

wallet_test_() ->
    {setup, fun setup/0, fun(_) -> ok end,
     [fun bip39_reference_vector/0,
      fun slip10_reference_vectors/0,
      fun independent_aex10_addresses/0,
      fun all_bip39_entropy_sizes/0,
      fun generated_wallets_are_distinct_and_restorable/0,
      fun generated_key_can_sign/0,
      fun accepts_documented_input_shapes/0,
      fun rejects_invalid_mnemonics/0,
      fun rejects_valid_but_unrelated_phrase/0,
      fun rejects_forged_signing_seed/0,
      fun rejects_mismatched_address/0,
      fun rejects_unsupported_metadata/0,
      fun rejects_conflicting_phrase_aliases/0,
      fun validates_legacy_keypair_without_inventing_phrase/0,
      fun rejects_invalid_keypair_shapes/0,
      fun validates_wordlist_integrity/0,
      fun nfkd_passphrase_reference_behavior/0,
      fun rejects_invalid_derivation_indices/0,
      fun private_key_encoder_compatibility/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    {module, enacl} = code:ensure_loaded(enacl),
    {module, aeser_api_encoder} = code:ensure_loaded(aeser_api_encoder),
    {module, damage_ae_wallet} = code:ensure_loaded(damage_ae_wallet),
    ok.

bip39_reference_vector() ->
    %% BIP-39 / trezor/python-mnemonic: zero entropy + passphrase TREZOR.
    Mnemonic = zero_mnemonic(),
    ?assertEqual(Mnemonic, damage_ae_wallet:entropy_to_mnemonic(<<0:128>>)),
    Expected = unhex(<<
        "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553",
        "1f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
    >>),
    ?assertEqual(Expected, damage_ae_wallet:mnemonic_to_seed(Mnemonic, <<"TREZOR">>)).

slip10_reference_vectors() ->
    %% Published SLIP-0010 Ed25519 test vector 1, not computed by this module.
    Seed = unhex(<<"000102030405060708090a0b0c0d0e0f">>),
    Vectors = [
      {[],
       <<"2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7">>,
       <<"90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb">>},
      {[0],
       <<"68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3">>,
       <<"8b59aa11380b624e81507a27fedda59fea6d0b779a778918a2fd3590e16e9c69">>},
      {[0, 1, 2, 2, 1000000000],
       <<"8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793">>,
       <<"68789923a0cac2cd5a29172a475fe9e0fb14cd6adb5ad98a3fa70333e7afa230">>}
    ],
    lists:foreach(fun({Path, Key, Chain}) ->
        ?assertEqual({unhex(Key), unhex(Chain)}, damage_ae_wallet:slip10(Seed, Path))
    end, Vectors).

independent_aex10_addresses() ->
    %% Expected bytes generated with Python's hashlib/cryptography and checked
    %% independently with Node crypto. Neither uses Damage's Erlang derivation.
    lists:foreach(fun(F) ->
        Mnemonic = maps:get(<<"mnemonic">>, F),
        KeyPair = secrets:keypair_from_mnemonic(Mnemonic),
        ?assert(is_map(KeyPair)),
        ?assertEqual(maps:get(<<"address">>, F), list_to_binary(maps:get(public_key, KeyPair))),
        ExpectedPrivate = <<(unhex(maps:get(<<"signing_seed_hex">>, F)))/binary,
                            (unhex(maps:get(<<"public_key_hex">>, F)))/binary>>,
        ?assertEqual(ExpectedPrivate, maps:get(private_key, KeyPair)),
        ?assertEqual(unhex(maps:get(<<"bip39_seed_hex">>, F)),
                     damage_ae_wallet:mnemonic_to_seed(Mnemonic, <<>>)),
        ?assertEqual(Mnemonic, damage_ae_wallet:entropy_to_mnemonic(
                                      unhex(maps:get(<<"entropy_hex">>, F)))),
        ?assertEqual(ok, damage_ae_wallet:validate_keypair(KeyPair)),
        {ok, Export} = damage_ae_wallet:export_seedphrase(KeyPair),
        ?assertEqual(Mnemonic, maps:get(seed_phrase, Export)),
        ?assertEqual(maps:get(<<"address">>, F), maps:get(address, Export))
    end, fixtures()).

all_bip39_entropy_sizes() ->
    lists:foreach(fun({Bytes, Count}) ->
        Mnemonic = damage_ae_wallet:entropy_to_mnemonic(binary:copy(<<0>>, Bytes)),
        ?assertEqual(Count, length(binary:split(Mnemonic, <<" ">>, [global]))),
        KP = secrets:keypair_from_mnemonic(Mnemonic),
        ?assert(is_map(KP)),
        ?assertMatch({ok, _}, damage_ae_wallet:export_seedphrase(KP))
    end, [{16, 12}, {20, 15}, {24, 18}, {28, 21}, {32, 24}]).

generated_wallets_are_distinct_and_restorable() ->
    %% This checks accidental deterministic reuse, not statistical RNG quality.
    Wallets = [secrets:make_keypair() || _ <- lists:seq(1, 16)],
    lists:foreach(fun(KP) ->
        ?assert(is_map(KP)),
        Mnemonic = maps:get(mnemonic, KP),
        ?assertEqual(12, length(binary:split(Mnemonic, <<" ">>, [global]))),
        ?assertEqual(64, byte_size(maps:get(private_key, KP))),
        ?assertEqual(KP, secrets:keypair_from_mnemonic(Mnemonic)),
        ?assertEqual(ok, damage_ae_wallet:validate_keypair(KP))
    end, Wallets),
    ?assertEqual(16, length(lists:usort([maps:get(mnemonic, KP) || KP <- Wallets]))),
    ?assertEqual(16, length(lists:usort([maps:get(public_key, KP) || KP <- Wallets]))).

generated_key_can_sign() ->
    KP = secrets:make_keypair(),
    Private = maps:get(private_key, KP),
    <<_Seed:32/binary, Public:32/binary>> = Private,
    Message = <<"DamageBDD disposable wallet generation verification">>,
    Signature = enacl:sign_detached(Message, Private),
    ?assertEqual(true, enacl:sign_verify_detached(Signature, Message, Public)),
    ?assertEqual(false, enacl:sign_verify_detached(Signature, <<"different">>, Public)).

accepts_documented_input_shapes() ->
    M = zero_mnemonic(),
    Expected = secrets:keypair_from_mnemonic(M),
    Words = binary:split(M, <<" ">>, [global]),
    ?assertEqual(Expected, secrets:keypair_from_mnemonic(binary_to_list(M))),
    ?assertEqual(Expected, secrets:keypair_from_mnemonic(Words)),
    ?assertEqual(Expected, secrets:keypair_from_mnemonic([binary_to_list(W) || W <- Words])),
    Messy = iolist_to_binary([<<" \n\t">>, lists:join(<<"  \t">>, Words), <<"\r\n">>]),
    ?assertEqual(Expected, secrets:keypair_from_mnemonic(Messy)).

rejects_invalid_mnemonics() ->
    ?assertEqual({error, empty_mnemonic}, secrets:keypair_from_mnemonic(<<" \t\n">>)),
    ?assertEqual({error, invalid_mnemonic_word_count}, secrets:keypair_from_mnemonic(<<"abandon">>)),
    BadChecksum = iolist_to_binary(lists:join(<<" ">>, lists:duplicate(12, <<"abandon">>))),
    ?assertEqual({error, invalid_mnemonic_checksum}, secrets:keypair_from_mnemonic(BadChecksum)),
    Unknown = <<"notaword abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about">>,
    ?assertEqual({error, unknown_mnemonic_word}, secrets:keypair_from_mnemonic(Unknown)),
    lists:foreach(fun(Input) ->
        ?assertEqual({error, invalid_mnemonic}, secrets:keypair_from_mnemonic(Input))
    end, [undefined, #{}, 42, <<255>>, [<<"abandon">>, invalid], binary:copy(<<"x">>, 513)]).

rejects_valid_but_unrelated_phrase() ->
    [First, Second | _] = fixtures(),
    KP = secrets:keypair_from_mnemonic(maps:get(<<"mnemonic">>, First)),
    ?assertEqual({error, mnemonic_keypair_mismatch}, damage_ae_wallet:export_seedphrase(
                  KP#{mnemonic => maps:get(<<"mnemonic">>, Second)})).

rejects_forged_signing_seed() ->
    KP = secrets:keypair_from_mnemonic(zero_mnemonic()),
    <<First, Rest/binary>> = maps:get(private_key, KP),
    Forged = KP#{private_key => <<(First bxor 1), Rest/binary>>},
    %% The embedded public-key suffix still matches the advertised address.
    ?assertEqual({error, invalid_node_keypair}, damage_ae_wallet:validate_keypair(Forged)),
    ?assertEqual({error, invalid_node_keypair}, damage_ae_wallet:export_seedphrase(Forged)).

rejects_mismatched_address() ->
    KP = secrets:keypair_from_mnemonic(zero_mnemonic()),
    Other = secrets:make_keypair(),
    ?assertEqual({error, invalid_node_keypair}, damage_ae_wallet:export_seedphrase(
                  KP#{public_key => maps:get(public_key, Other)})).

rejects_unsupported_metadata() ->
    KP = secrets:keypair_from_mnemonic(zero_mnemonic()),
    Bad = [maps:remove(wallet_scheme, KP),
           KP#{wallet_scheme => unknown_scheme}, KP#{account_index => 1},
           KP#{address_index => 1}, KP#{derivation_path => <<"m/44'/457'/1'/0'/0'">>},
           KP#{bip39_passphrase => <<"nonempty">>}, KP#{mnemonic_language => other}],
    lists:foreach(fun(K) ->
        ?assertEqual({error, unsupported_wallet_metadata}, damage_ae_wallet:export_seedphrase(K))
    end, Bad).

rejects_conflicting_phrase_aliases() ->
    KP = secrets:keypair_from_mnemonic(zero_mnemonic()),
    [_First, Second | _] = fixtures(),
    ?assertEqual({error, conflicting_mnemonic_fields}, damage_ae_wallet:export_seedphrase(
                  KP#{seed_phrase => maps:get(<<"mnemonic">>, Second)})),
    Alias = (maps:remove(mnemonic, KP))#{seed_phrase => zero_mnemonic()},
    ?assertMatch({ok, _}, damage_ae_wallet:export_seedphrase(Alias)).

validates_legacy_keypair_without_inventing_phrase() ->
    #{public := Pub, secret := Priv} = enacl:sign_keypair(),
    KP = #{public_key => aeser_api_encoder:encode(account_pubkey, Pub), private_key => Priv},
    ?assertEqual(ok, damage_ae_wallet:validate_keypair(KP)),
    ?assertEqual({error, {node_wallet_not_mnemonic_backed, use_private_key_export}},
                 damage_ae_wallet:export_seedphrase(KP)).

rejects_invalid_keypair_shapes() ->
    lists:foreach(fun(Value) ->
        ?assertEqual({error, invalid_node_keypair}, damage_ae_wallet:validate_keypair(Value)),
        ?assertEqual({error, invalid_node_keypair}, damage_ae_wallet:export_seedphrase(Value))
    end, [undefined, #{}, #{public_key => <<"ak_invalid">>, private_key => <<0:256>>}]).

validates_wordlist_integrity() ->
    Path = filename:join([code:priv_dir(damage), "bip39", "english.txt"]),
    {ok, Data} = file:read_file(Path),
    Dictionary = damage_ae_wallet:validate_wordlist(Data),
    ?assertEqual(2048, tuple_size(Dictionary)),
    ?assertEqual(<<"abandon">>, element(1, Dictionary)),
    ?assertEqual(<<"zoo">>, element(2048, Dictionary)),
    ?assertThrow({wallet_error, invalid_wordlist},
                 damage_ae_wallet:validate_wordlist(<<Data/binary, "\n">>)).

nfkd_passphrase_reference_behavior() ->
    %% Composed/decomposed e-acute must give identical BIP-39 seed bytes.
    A = unicode:characters_to_binary([16#00E9]),
    B = unicode:characters_to_binary([$e, 16#0301]),
    ?assertEqual(damage_ae_wallet:mnemonic_to_seed(zero_mnemonic(), A),
                 damage_ae_wallet:mnemonic_to_seed(zero_mnemonic(), B)).

rejects_invalid_derivation_indices() ->
    lists:foreach(fun(Index) ->
        ?assertThrow({wallet_error, invalid_derivation_index},
                     damage_ae_wallet:slip10(<<0:128>>, [Index]))
    end, [-1, 16#80000000, not_an_index]),
    ?assertThrow({wallet_error, invalid_entropy_size},
                 damage_ae_wallet:entropy_to_mnemonic(<<0:120>>)).

private_key_encoder_compatibility() ->
    KP = secrets:keypair_from_mnemonic(zero_mnemonic()),
    <<Seed:32/binary, _/binary>> = maps:get(private_key, KP),
    %% Both branches are contractual: current encoders export sk_; older ones
    %% must return a controlled error, not crash or invent a fallback encoding.
    Probe = try aeser_api_encoder:encode(account_seckey, Seed)
            catch _:_ -> unsupported end,
    case Probe of
        <<"sk_", _/binary>> = Encoded ->
            {ok, Export} = damage_ae_wallet:export_private_key(KP),
            ?assertEqual(Encoded, maps:get(private_key, Export)),
            ?assertEqual(maps:get(private_key, KP), unhex(maps:get(legacy_private_key_hex, Export)));
        _ ->
            ?assertEqual({error, account_seckey_encoding_unavailable},
                         damage_ae_wallet:export_private_key(KP))
    end.

fixtures() ->
    Path = filename:join([filename:dirname(?FILE), "fixtures", "wallet_vectors.json"]),
    {ok, Json} = file:read_file(Path),
    jsx:decode(Json, [return_maps]).
zero_mnemonic() ->
    <<"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about">>.
unhex(Bin) -> binary:decode_hex(string:uppercase(Bin)).
