-module(ecai_pqc_nft).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([
    contract_path/0,
    deploy/0,
    deploy/1,
    mint_pqc/5,
    metadata/2,
    owner/2,
    balance/2,
    total_supply/1,
    transfer/4,
    approve/5,
    approve_all/4,
    burn/3,
    envelope_from_chain_metadata/1,
    decrypt_token_payload/2,
    decrypt_token_payload/3,
    test/0
]).

contract_path() ->
    damage_ae:contract_path(ecai, "ecai_pqc_nft.aes").

deploy() ->
    deploy(#{}).

deploy(Opts) ->
    Name = maps:get(name, Opts, <<"ECAI PQC NFT">>),
    Symbol = maps:get(symbol, Opts, <<"EPQC">>),
    damage_ae:contract_deploy(
        contract_path(),
        [to_bin(Name), to_bin(Symbol)]
    ).

mint_pqc(KeyPair, ContractId, ToAccount, PQPublicKey, Opts) ->
    Plaintext = to_bin(maps:get(plaintext, Opts)),
    AADContext = maps:get(aad_context, Opts, none),
    Envelope = secrets_pqc:encrypt(Plaintext, PQPublicKey, AADContext),

    Subject = maps:get(subject, Opts, <<"ecai">>),
    Predicate = maps:get(predicate, Opts, <<"sealed_as">>),
    Object = maps:get(object, Opts, <<"pqc_envelope">>),
    Context = maps:get(context, Opts, <<"ecai:pqc">>),

    MetaMap0 = #{
        "type" => "ecai_pqc",
        "subject" => to_list(Subject),
        "predicate" => to_list(Predicate),
        "object" => to_list(Object),
        "context" => to_list(Context),
        "alg" => atom_to_list(maps:get(alg, Envelope)),
        "kem" => atom_to_list(maps:get(kem, Envelope)),
        "kem_ct" => b64(maps:get(kem_ct, Envelope)),
        "iv" => b64(maps:get(iv, Envelope)),
        "tag" => b64(maps:get(tag, Envelope)),
        "ct" => b64(maps:get(ct, Envelope)),
        "payload_sha256" => to_list(binary:encode_hex(crypto:hash(sha256, Plaintext))),
        "recipient_pqpk_sha256" => to_list(binary:encode_hex(crypto:hash(sha256, PQPublicKey)))
    },

    MetaMap = maybe_put_aad_metadata(MetaMap0, Envelope, AADContext),

    damage_ae:contract_call(
        KeyPair,
        ContractId,
        contract_path(),
        "mint",
        [to_bin(ToAccount), {some, {"MetadataMap", MetaMap}}, {none}]
    ).

metadata(ContractId, TokenId) ->
    damage_ae:contract_call_static(
        ContractId,
        contract_path(),
        "metadata",
        [TokenId]
    ).

owner(ContractId, TokenId) ->
    damage_ae:contract_call_static(
        ContractId,
        contract_path(),
        "owner",
        [TokenId]
    ).

balance(ContractId, Account) ->
    damage_ae:contract_call_static(
        ContractId,
        contract_path(),
        "balance",
        [to_bin(Account)]
    ).

total_supply(ContractId) ->
    damage_ae:contract_call_static(
        ContractId,
        contract_path(),
        "total_supply",
        []
    ).

transfer(KeyPair, ContractId, ToAccount, TokenId) ->
    damage_ae:contract_call(
        KeyPair,
        ContractId,
        contract_path(),
        "transfer",
        [to_bin(ToAccount), TokenId, {none}]
    ).

approve(KeyPair, ContractId, Approved, TokenId, Enabled) ->
    damage_ae:contract_call(
        KeyPair,
        ContractId,
        contract_path(),
        "approve",
        [to_bin(Approved), TokenId, Enabled]
    ).

approve_all(KeyPair, ContractId, Operator, Enabled) ->
    damage_ae:contract_call(
        KeyPair,
        ContractId,
        contract_path(),
        "approve_all",
        [to_bin(Operator), Enabled]
    ).

burn(KeyPair, ContractId, TokenId) ->
    damage_ae:contract_call(
        KeyPair,
        ContractId,
        contract_path(),
        "burn",
        [TokenId]
    ).

%% unwrap {some, {"MetadataMap", MetaMap}} from chain result
envelope_from_chain_metadata({some, {"MetadataMap", MetaMap}}) when is_map(MetaMap) ->
    Envelope0 = #{
        v => 1,
        alg => parse_alg(maps:get("alg", MetaMap)),
        kem => parse_kem(maps:get("kem", MetaMap)),
        kem_ct => base64:decode(to_bin(maps:get("kem_ct", MetaMap))),
        iv => base64:decode(to_bin(maps:get("iv", MetaMap))),
        tag => base64:decode(to_bin(maps:get("tag", MetaMap))),
        ct => base64:decode(to_bin(maps:get("ct", MetaMap)))
    },
    maybe_parse_aad_sha256(Envelope0, MetaMap);
envelope_from_chain_metadata(MetaMap) when is_map(MetaMap) ->
    Envelope0 = #{
        v => 1,
        alg => parse_alg(maps:get("alg", MetaMap)),
        kem => parse_kem(maps:get("kem", MetaMap)),
        kem_ct => base64:decode(to_bin(maps:get("kem_ct", MetaMap))),
        iv => base64:decode(to_bin(maps:get("iv", MetaMap))),
        tag => base64:decode(to_bin(maps:get("tag", MetaMap))),
        ct => base64:decode(to_bin(maps:get("ct", MetaMap)))
    },
    maybe_parse_aad_sha256(Envelope0, MetaMap).

decrypt_token_payload(ChainMetadata, PQPrivateKey) ->
    Envelope = envelope_from_chain_metadata(ChainMetadata),
    secrets_pqc:decrypt(Envelope, PQPrivateKey).

decrypt_token_payload(ChainMetadata, PQPrivateKey, AADContext) ->
    Envelope = envelope_from_chain_metadata(ChainMetadata),
    secrets_pqc:decrypt(Envelope, PQPrivateKey, AADContext).

maybe_put_aad_metadata(MetaMap, Envelope, none) ->
    maybe_put_aad_hash_metadata(MetaMap, Envelope);
maybe_put_aad_metadata(MetaMap, Envelope, undefined) ->
    maybe_put_aad_hash_metadata(MetaMap, Envelope);
maybe_put_aad_metadata(MetaMap, Envelope, AADContext) ->
    MetaMap1 = maybe_put_aad_hash_metadata(MetaMap, Envelope),
    maps:put("aad_context", to_list(jsx:encode(AADContext)), MetaMap1).

maybe_put_aad_hash_metadata(MetaMap, Envelope) ->
    case maps:get(aad_sha256, Envelope, undefined) of
        undefined -> MetaMap;
        AADHash -> maps:put("aad_sha256", to_list(binary:encode_hex(AADHash)), MetaMap)
    end.

maybe_parse_aad_sha256(Envelope, MetaMap) ->
    case maps:get("aad_sha256", MetaMap, undefined) of
        undefined -> Envelope;
        AADHashHex -> maps:put(aad_sha256, hex_to_bin(to_bin(AADHashHex)), Envelope)
    end.

hex_to_bin(Hex0) ->
    Hex = string:lowercase(binary_to_list(to_bin(Hex0))),
    hex_to_bin(Hex, <<>>).

hex_to_bin([], Acc) ->
    Acc;
hex_to_bin([Hi, Lo | Rest], Acc) ->
    Byte = (hex_nibble(Hi) bsl 4) bor hex_nibble(Lo),
    hex_to_bin(Rest, <<Acc/binary, Byte:8>>).

hex_nibble(C) when C >= $0, C =< $9 -> C - $0;
hex_nibble(C) when C >= $a, C =< $f -> 10 + C - $a.

parse_alg(<<"pqc_hybrid_aes_256_gcm">>) -> pqc_hybrid_aes_256_gcm;
parse_alg("pqc_hybrid_aes_256_gcm") -> pqc_hybrid_aes_256_gcm;
parse_alg(pqc_hybrid_aes_256_gcm) -> pqc_hybrid_aes_256_gcm.

parse_kem(<<"ml_kem_768">>) -> ml_kem_768;
parse_kem("ml_kem_768") -> ml_kem_768;
parse_kem(ml_kem_768) -> ml_kem_768.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I).

b64(Bin) when is_binary(Bin) ->
    binary_to_list(base64:encode(Bin)).

test() ->
    KeyPair = secrets:node_keypair(),
    PQ = secrets_pqc:generate_keypair(),
    PQPub = maps:get(public_key, PQ),
    PQPriv = maps:get(private_key, PQ),

    {ok, DeployRes} = deploy(),
    ContractId = maps:get(<<"contract_id">>, DeployRes, maps:get("contract_id", DeployRes)),

    AeAccount = maps:get(public_key, KeyPair),

    {ok, _MintRes} =
        mint_pqc(
            KeyPair,
            ContractId,
            AeAccount,
            PQPub,
            #{
                plaintext => <<"hello ecai pqc">>,
                subject => <<"genesis">>,
                predicate => <<"sealed_as">>,
                object => <<"knowledge">>,
                context => <<"ecai:pqc:test">>
            }
        ),

    {ok, MetaRes} = metadata(ContractId, 1),
    Plaintext = decrypt_token_payload(MetaRes, PQPriv),

    {ok, #{
        contract_id => ContractId,
        token_id => 1,
        plaintext => Plaintext
    }}.
