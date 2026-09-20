%% BIP-39 (English, empty passphrase) + AEX-10 node wallets.
%% No network, keystore mutation, logger calls, or node-global secret access.
%% Successful generation/import returns a map for compatibility with secrets.
-module(damage_ae_wallet).
-license("Apache-2.0").

-export([generate/0, from_mnemonic/1, validate_keypair/1,
         export_seedphrase/1, export_private_key/1]).
-ifdef(TEST).
-export([entropy_to_mnemonic/1, mnemonic_to_seed/2, slip10/2,
         validate_wordlist/1]).
-endif.

-define(PATH, [44, 457, 0, 0, 0]).
-define(PATH_TEXT, <<"m/44'/457'/0'/0'/0'">>).
-define(HARDENED, 16#80000000).
-define(MAX_MNEMONIC_BYTES, 512).
-define(WORDLIST_SHA256,
        <<16#2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda:256>>).

-spec generate() -> map() | {error, atom()}.
generate() ->
    protected(fun() ->
        %% Never use rand, timestamps, UUIDs, or deterministic fallbacks here.
        from_valid_mnemonic(entropy_to_mnemonic(crypto:strong_rand_bytes(16)))
    end).

-spec from_mnemonic(binary() | list()) -> map() | {error, atom()}.
from_mnemonic(Input) ->
    protected(fun() -> from_valid_mnemonic(checked_mnemonic(Input)) end).

from_valid_mnemonic(Mnemonic) ->
    Seed = mnemonic_to_seed(Mnemonic, <<>>),
    {SigningSeed, _ChainCode} = slip10(Seed, ?PATH),
    #{public := Public, secret := Private} = enacl:sign_seed_keypair(SigningSeed),
    #{public_key => binary_to_list(aeser_api_encoder:encode(account_pubkey, Public)),
      private_key => Private, mnemonic => Mnemonic,
      wallet_scheme => aex10_bip39, derivation_path => ?PATH_TEXT,
      account_index => 0, address_index => 0}.

%% Validate the seed, not just the public-key suffix of a NaCl secret key.
-spec validate_keypair(term()) -> ok | {error, atom()}.
validate_keypair(KeyPair) ->
    protected(fun() -> check_signing_key(KeyPair), ok end).

check_signing_key(#{public_key := Address0,
                    private_key := <<Seed:32/binary, _EmbeddedPublic:32/binary>> = Private}) ->
    #{public := Public, secret := Regenerated} = enacl:sign_seed_keypair(Seed),
    Address = address_binary(Address0),
    case Private =:= Regenerated andalso
         Address =:= aeser_api_encoder:encode(account_pubkey, Public) of
        true -> Address;
        false -> reject(invalid_node_keypair)
    end;
check_signing_key(_) ->
    reject(invalid_node_keypair).

-spec export_seedphrase(term()) -> {ok, map()} | {error, term()}.
export_seedphrase(KeyPair) ->
    protected(fun() ->
        Address = check_signing_key(KeyPair),
        Input = recovery_phrase(KeyPair),
        check_metadata(KeyPair),
        Mnemonic = checked_mnemonic(Input),
        %% Conflicting aliases must never select one phrase silently.
        case maps:find(seed_phrase, KeyPair) of
            {ok, Alias} ->
                case checked_mnemonic(Alias) =:= Mnemonic of
                    true -> ok;
                    false -> reject(conflicting_mnemonic_fields)
                end;
            error -> ok
        end,
        Restored = from_valid_mnemonic(Mnemonic),
        case address_binary(maps:get(public_key, Restored)) =:= Address andalso
             maps:get(private_key, Restored) =:= maps:get(private_key, KeyPair) of
            true ->
                {ok, #{address => Address, format => superhero_seed_phrase,
                       seed_phrase => Mnemonic, wallet_scheme => aex10_bip39,
                       derivation_path => ?PATH_TEXT, account_index => 0,
                       address_index => 0}};
            false -> reject(mnemonic_keypair_mismatch)
        end
    end).

recovery_phrase(#{mnemonic := Mnemonic}) -> Mnemonic;
recovery_phrase(#{seed_phrase := Mnemonic}) -> Mnemonic;
recovery_phrase(_) ->
    reject({node_wallet_not_mnemonic_backed, use_private_key_export}).

check_metadata(#{wallet_scheme := aex10_bip39, derivation_path := ?PATH_TEXT,
                 account_index := 0, address_index := 0} = KeyPair) ->
    %% Accept the earlier generated schema, but never silently ignore an
    %% explicitly stored nonempty BIP-39 passphrase or another language.
    case {maps:get(bip39_passphrase, KeyPair, <<>>),
          maps:get(mnemonic_language, KeyPair, english)} of
        {<<>>, english} -> ok;
        _ -> reject(unsupported_wallet_metadata)
    end;
check_metadata(_) -> reject(unsupported_wallet_metadata).

-spec export_private_key(term()) -> {ok, map()} | {error, atom()}.
export_private_key(KeyPair) ->
    protected(fun() ->
        Address = check_signing_key(KeyPair),
        Private = maps:get(private_key, KeyPair),
        <<Seed:32/binary, _Public:32/binary>> = Private,
        %% Some older aeser_api_encoder versions lack account_seckey. Do not
        %% fabricate a different encoding or silently call it compatible.
        Encoded = try aeser_api_encoder:encode(account_seckey, Seed) of
            <<"sk_", _/binary>> = Value -> Value;
            _ -> reject(account_seckey_encoding_unavailable)
        catch
            _:_ -> reject(account_seckey_encoding_unavailable)
        end,
        {ok, #{address => Address, format => superhero_private_key,
               private_key => Encoded,
               legacy_private_key_hex => string:lowercase(binary:encode_hex(Private))}}
    end).

address_binary(Address) when is_binary(Address), byte_size(Address) =< 100 -> Address;
address_binary(Address) when is_list(Address), length(Address) =< 100 ->
    try list_to_binary(Address) catch _:_ -> reject(invalid_node_keypair) end;
address_binary(_) -> reject(invalid_node_keypair).

%% Only constant, non-sensitive errors leave this module. Exception reasons and
%% stack traces can contain mnemonic/key arguments and must not be returned.
protected(Fun) ->
    try Fun() catch
        throw:{wallet_error, Reason} -> {error, Reason};
        _:_ -> {error, wallet_crypto_failed}
    end.
reject(Reason) -> throw({wallet_error, Reason}).

%% BIP-39 -------------------------------------------------------------

checked_mnemonic(Input) ->
    Mnemonic = normalize_mnemonic(Input),
    Words = binary:split(Mnemonic, <<" ">>, [global]),
    Count = length(Words),
    case lists:member(Count, [12, 15, 18, 21, 24]) of
        true -> ok;
        false -> reject(invalid_mnemonic_word_count)
    end,
    Dictionary = tuple_to_list(wordlist()),
    Index = maps:from_list(lists:zip(Dictionary, lists:seq(0, 2047))),
    Bits = << <<(word_index(Word, Index)):11>> || Word <- Words >>,
    EntropyBytes = Count * 4 div 3,
    ChecksumBits = Count div 3,
    <<Entropy:EntropyBytes/binary, Actual:ChecksumBits>> = Bits,
    <<Expected:ChecksumBits, _/bitstring>> = crypto:hash(sha256, Entropy),
    case Actual =:= Expected of
        true -> Mnemonic;
        false -> reject(invalid_mnemonic_checksum)
    end.

word_index(Word, Index) ->
    case maps:find(Word, Index) of
        {ok, N} -> N;
        error -> reject(unknown_mnemonic_word)
    end.

normalize_mnemonic(Input) ->
    Bin0 = input_binary(Input),
    Bin = try unicode:characters_to_nfkd_binary(Bin0) of
        Value when is_binary(Value), byte_size(Value) =< ?MAX_MNEMONIC_BYTES -> Value;
        _ -> reject(invalid_mnemonic)
    catch _:_ -> reject(invalid_mnemonic) end,
    %% English-only. NFKD is applied before splitting; do not autocorrect words
    %% or silently append a checksum word to a mistyped recovery phrase.
    case string:lexemes(Bin, " \t\r\n") of
        [] -> reject(empty_mnemonic);
        Words -> iolist_to_binary(lists:join(<<" ">>, Words))
    end.

input_binary(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_MNEMONIC_BYTES -> Bin;
input_binary(List) when is_list(List), length(List) =< ?MAX_MNEMONIC_BYTES ->
    case lists:all(fun erlang:is_integer/1, List) of
        true ->
            try unicode:characters_to_binary(List) of
                Bin when is_binary(Bin), byte_size(Bin) =< ?MAX_MNEMONIC_BYTES -> Bin;
                _ -> reject(invalid_mnemonic)
            catch _:_ -> reject(invalid_mnemonic) end;
        false when length(List) =< 24 ->
            Words = [word_binary(Word) || Word <- List],
            input_binary(iolist_to_binary(lists:join(<<" ">>, Words)));
        false -> reject(invalid_mnemonic)
    end;
input_binary(_) -> reject(invalid_mnemonic).

word_binary(Word) when is_binary(Word), byte_size(Word) =< 32 -> Word;
word_binary(Word) when is_list(Word), length(Word) =< 32 ->
    try unicode:characters_to_binary(Word) of
        Bin when is_binary(Bin), byte_size(Bin) =< 32 -> Bin;
        _ -> reject(invalid_mnemonic)
    catch _:_ -> reject(invalid_mnemonic) end;
word_binary(_) -> reject(invalid_mnemonic).

entropy_to_mnemonic(Entropy) when is_binary(Entropy),
    (byte_size(Entropy) =:= 16 orelse byte_size(Entropy) =:= 20 orelse
     byte_size(Entropy) =:= 24 orelse byte_size(Entropy) =:= 28 orelse
     byte_size(Entropy) =:= 32) ->
    ChecksumBits = bit_size(Entropy) div 32,
    <<Checksum:ChecksumBits, _/bitstring>> = crypto:hash(sha256, Entropy),
    Bits = <<Entropy/binary, Checksum:ChecksumBits>>,
    Dictionary = wordlist(),
    Words = [element(N + 1, Dictionary) || <<N:11>> <= Bits],
    iolist_to_binary(lists:join(<<" ">>, Words));
entropy_to_mnemonic(_) -> reject(invalid_entropy_size).

%% This primitive is test-exported for official vectors with passphrases.
%% The production wallet entrypoints above always pass the empty binary.
mnemonic_to_seed(Mnemonic, Passphrase) ->
    NormalMnemonic = unicode:characters_to_nfkd_binary(Mnemonic),
    NormalPassphrase = unicode:characters_to_nfkd_binary(Passphrase),
    crypto:pbkdf2_hmac(sha512, NormalMnemonic,
                       <<"mnemonic", NormalPassphrase/binary>>, 2048, 64).

wordlist() ->
    Priv = case code:priv_dir(damage) of
        Dir when is_list(Dir) -> Dir;
        _ -> reject(wordlist_unavailable)
    end,
    case file:read_file(filename:join([Priv, "bip39", "english.txt"])) of
        {ok, Data} -> validate_wordlist(Data);
        {error, _} -> reject(wordlist_unavailable)
    end.

validate_wordlist(Data) ->
    case crypto:hash(sha256, Data) of
        ?WORDLIST_SHA256 ->
            %% The pinned digest covers ordering, all 2048 entries and LF bytes.
            list_to_tuple([W || W <- binary:split(Data, <<"\n">>, [global]), W =/= <<>>]);
        _ -> reject(invalid_wordlist)
    end.

%% SLIP-0010 Ed25519 -------------------------------------------------

slip10(Seed, Path) when is_binary(Seed), byte_size(Seed) >= 16,
                        byte_size(Seed) =< 64, is_list(Path) ->
    Master = split_hmac(crypto:mac(hmac, sha512, <<"ed25519 seed">>, Seed)),
    lists:foldl(fun hardened_child/2, Master, Path).

hardened_child(Index, {Key, Chain}) when is_integer(Index),
    Index >= 0, Index < ?HARDENED ->
    ChildNumber = Index bor ?HARDENED,
    split_hmac(crypto:mac(hmac, sha512, Chain,
                          <<0, Key/binary, ChildNumber:32/unsigned-big>>));
hardened_child(_, _) -> reject(invalid_derivation_index).

split_hmac(<<Key:32/binary, Chain:32/binary>>) -> {Key, Chain}.
