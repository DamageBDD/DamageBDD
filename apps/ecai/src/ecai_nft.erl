-module(ecai_nft).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai.hrl").

-export([
    test/0,
    mint_knowledge/2,
    mint_alphanumerics_with_ordinals/0,
    deploy_knowledge_nft_contract/0,
    encode/1
]).
-export([
    mint_index_job/3,
    mint_knowledge_image_collection/2,
    mint_knowledge_image_collection/3,
    mint_tshirt_nfts/0,
    mint_index_jobs_from_chunks/4
]).
%% Pull the contract id from Opts or application env
-spec ct_id(map()) -> binary().
ct_id(Opts) ->
    case maps:get(ct, Opts, undefined) of
        <<"ct_", _/binary>> = Ct ->
            Ct;
        _ ->
            case application:get_env(ecai, knowledge_registry_ct) of
                {ok, <<"ct_", _/binary>> = C} -> C;
                _ -> ?KNOWLEDGE_NFT_CONTRACT
            end
    end.
mint_knowledge(
    #{public_key := AeAccount, private_key := _PrivateKey} = KeyPair,
    #{subject := Subject, predicate := Predicate, object := Object, context := Context} = Knowledge
) ->
    EncodedKnowledge = encode(Knowledge),

    %% Canonical identity key for this fact/blob (bytes32)
    FactKey = crypto:hash(sha256, EncodedKnowledge),

    %% Derived token_id: uint64(big-endian) from first 8 bytes of FactKey
    <<Id64:64/unsigned-big, _/binary>> = FactKey,
    TokenId0 = Id64,
    TokenId =
        case TokenId0 of
            0 -> 1;
            _ -> TokenId0
        end,

    %% Curve point (kept for ECAI clients; not required by chain)
    Point = ecai:hash_to_curve(binary_to_list(EncodedKnowledge)),

    %% Store blob in IPFS (filename hashed from point like you already do)
    {ok, [#{<<"Hash">> :=
                IpfsHash,
            <<"Name">> :=
                _Name,
            <<"Size">> := _Size}]} = damage_ipfs:add({data, EncodedKnowledge, ecai:point_to_filename_hash(Point)}),

    %% Compact bytes32 keys for indexing in middleware topics
    %% NOTE: these are NOT the curve points; they are 32-byte stable keys.
    SKey = crypto:hash(sha256, encode_atom(Subject)),
    PKey = crypto:hash(sha256, encode_atom(Predicate)),
    OKey = crypto:hash(sha256, encode_atom(Object)),
    CKey = crypto:hash(sha256, encode_atom(Context)),
    KKey = crypto:hash(sha256, <<"knowledge">>),

    %% Payload bytes (>32) for event payload:
    %% Put everything you want indexers to decode without contract calls.
    %% VRLP is fine since you already use it.
    Payload = vrlp:encode([
        {ipfs, IpfsHash},
        {fact_key, FactKey},
        {token_id, TokenId},
        {point, term_to_binary(Point)},
        {s, SKey},
        {p, PKey},
        {o, OKey},
        {c, CKey},
        {k, KKey}
        %% optionally include raw strings too (costs bytes, but off-chain only):
        %% , {subject, Subject}, {predicate, Predicate}, {object, Object}, {context, Context}
    ]),

    %% Optional on-chain metadata (small map). Not required for indexing.
    %% Keep it tiny: hex strings only, plus ipfs.
    MetaData = #{
        "v" => <<"3">>,
        "ipfs" => IpfsHash,
        "bh" => binary:encode_hex(FactKey),
        "s" => binary:encode_hex(SKey),
        "p" => binary:encode_hex(PKey),
        "o" => binary:encode_hex(OKey),
        "c" => binary:encode_hex(CKey),
        "k" => binary:encode_hex(KKey)
    },
     MdOpt = {"Some", MetaData},

    damage_ae:contract_call_dry(
        KeyPair,
        ct_id(#{}),
        contract_path("knowledge_nft"),
        "mint_derived",
        [AeAccount, TokenId, FactKey, SKey, PKey, OKey, CKey, KKey, MdOpt, Payload]
    ).

encode_atom(X) when is_binary(X) ->
    %% stable encoding for atom text
    vrlp:encode([X]);
encode_atom(X) when is_list(X) ->
    vrlp:encode([list_to_binary(X)]);
encode_atom(X) ->
    vrlp:encode([iolist_to_binary(X)]).

encode(#{subject := Subject, predicate := Predicate, object := Object, context := Context}) ->
    Timestamp = erlang:system_time(seconds),
    vrlp:encode([Subject, Predicate, Object, Context, Timestamp]).
%%% -----------------------------
%%% SPOC builders with ordinals
%%% -----------------------------

%% Public API
mint_alphanumerics_with_ordinals() ->
    NodeKeyPair = secrets:node_keypair(),
    Letters = lists:seq($a, $z),
    Digits = lists:seq($0, $9),
    ok = mint_letters(NodeKeyPair, Letters),
    ok = mint_digits(NodeKeyPair, Digits),
    ok.

%%% Letters

mint_letters(KeyPair, Letters) ->
    lists:foreach(
        fun(Char) ->
            %% 1) a is instance of letter (latin alphabet)
            mint_knowledge(KeyPair, spoc_letter_instance(Char)),
            %% 2) a has ordinal position 1 in latin alphabet
            mint_knowledge(KeyPair, spoc_letter_ordinal(Char))
        end,
        Letters
    ),
    ok.

spoc_letter_instance(Char) when Char >= $a, Char =< $z ->
    #{
        subject => <<Char>>,
        predicate => "is instance of",
        object => "letter",
        context => "latin alphabet"
    }.

spoc_letter_ordinal(Char) when Char >= $a, Char =< $z ->
    #{
        subject => <<Char>>,
        predicate => "has ordinal position",
        %% Store as string so your encode/VRLP stays uniform:
        object => integer_to_binary(letter_index(Char)),
        context => "latin alphabet"
    }.

letter_index(Char) ->
    %% a=1, ..., z=26
    (Char - $a) + 1.

%%% Digits

mint_digits(KeyPair, Digits) ->
    lists:foreach(
        fun(Char) ->
            %% 1) 7 is instance of digit (arabic numerals)
            mint_knowledge(KeyPair, spoc_digit_instance(Char)),
            %% 2) 7 has ordinal position 8 in arabic numerals (0-based display sets)
            mint_knowledge(KeyPair, spoc_digit_ordinal(Char)),
            %% Optional: “represents integer seven”
            mint_knowledge(KeyPair, spoc_digit_semantics(Char))
        end,
        Digits
    ),
    ok.

spoc_digit_instance(Char) when Char >= $0, Char =< $9 ->
    #{
        subject => <<Char>>,
        predicate => "is instance of",
        object => "digit",
        context => "arabic numerals"
    }.

spoc_digit_ordinal(Char) when Char >= $0, Char =< $9 ->
    #{
        subject => <<Char>>,
        predicate => "has ordinal position",
        %% Common to say 0..9 are the “first ten digits”; we’ll use 0-based index:
        object => integer_to_binary(digit_index(Char)),
        context => "arabic numerals (0-based)"
    }.

spoc_digit_semantics(Char) when Char >= $0, Char =< $9 ->
    #{
        subject => <<Char>>,
        predicate => "represents",
        object => integer_to_binary(Char - $0),
        context => "natural numbers"
    }.

digit_index(Char) ->
    %% '0'->0, ..., '9'->9
    Char - $0.
contract_path(Contract0) ->
    PrivDir = code:priv_dir(ecai),
    %% Strip "contracts/" prefix if present
    Contract1 =
        case string:prefix(Contract0, "contracts/") of
            nomatch -> Contract0;
            Name -> Name
        end,
    %% Ensure it ends with ".aes"
    Contract2 =
        case filename:extension(Contract1) of
            ".aes" -> Contract1;
            _ -> Contract1 ++ ".aes"
        end,
    filename:join([PrivDir, "contracts", Contract2]).

deploy_knowledge_nft_contract() ->
    ContractPath = contract_path("knowledge_nft"),
    ?LOG_INFO("Contract ~p", [ContractPath]),
    #{"contract_id" := ContractId} = damage_ae:contract_deploy(
        ContractPath, ["Wikipedia Search Index Fragment 1", "ecai", "10"]
    ),

    ContractId.

-spec mint_index_job(KeyPair :: map(), ChunkMeta :: map(), Price :: integer()) ->
    {ok, TokenId :: integer()} | {error, term()}.
mint_index_job(
    #{public_key := AeAccount} = KeyPair,
    #{
        dataset := DatasetId,
        chunk_id := ChunkId,
        path := Path,
        start_line := Start,
        line_count := Count
    } = _Chunk,
    Price
) ->
    %% Canonical job identity
    JobBin = term_to_binary({DatasetId, ChunkId, Start, Count}),
    JobKey = crypto:hash(sha256, JobBin),

    %% Deterministic token_id (same scheme as knowledge)
    <<Id64:64/unsigned-big, _/binary>> = JobKey,
    TokenId =
        case Id64 of
            0 -> 1;
            _ -> Id64
        end,

    DatasetKey = crypto:hash(sha256, DatasetId),
    ChunkKey = crypto:hash(sha256, ChunkId),
    KindKey = crypto:hash(sha256, <<"ecai:index:v1">>),

    Payload = vrlp:encode([
        {dataset, DatasetId},
        {chunk_id, ChunkId},
        {path, Path},
        {start, Start},
        {lines, Count},
        {price, Price}
    ]),

    Meta = #{
        <<"type">> => <<"ecai_index_job">>,
        <<"dataset">> => binary:encode_hex(DatasetKey),
        <<"chunk">> => binary:encode_hex(ChunkKey),
        <<"price">> => integer_to_binary(Price)
    },

    damage_ae:contract_call_dry(
        KeyPair,
        ct_id(#{}),
        contract_path("knowledge_nft"),
        "mint_index_job",
        [AeAccount, TokenId, JobKey, DatasetKey, ChunkKey, KindKey, Meta, Payload]
    ).

mint_index_jobs_from_chunks(KeyPair, DatasetId, Chunks, Price) ->
    lists:foreach(
        fun(Chunk) ->
            ok = mint_index_job(
                KeyPair,
                Chunk#{dataset => DatasetId},
                Price
            )
        end,
        Chunks
    ).
%added QmVuUKm7WnFfuxvxZUYByqFdpjtZKNrEUKchCg2ChMCgHj photo_2026-01-12_20-52-25.jpg
%added QmSCL3jutYJyZQAYH2gbbmYiqrP2gxztwjtBd6ZwGwbyWy photo_2026-01-12_20-52-29.jpg
%added QmbiC96Wpvp1pv1Mun1tfvRVAZeZjHXRkdSnuzBmsDLpfx photo_2026-01-12_20-52-33.jpg
%added Qme7stsuVhF5gkmcwsyyWLEzb64idJcz51fZaGVE2rqStW photo_2026-01-12_20-52-36.jpg
% QmZdQG1NUP1Z7wowoS2EJLrjhhUhvVV22BkQQDd4kBubir merch_genesis.md
mint_tshirt_nfts() ->
    KeyPair = secrets:node_keypair(),

    StoryCid = <<"QmZdQG1NUP1Z7wowoS2EJLrjhhUhvVV22BkQQDd4kBubir">>,

    mint_knowledge_image_collection(
        KeyPair, #{
            title => <<"DamageBDD × ECAI — Genesis Merch">>,
            description => <<"First DamageBDD merch, minted as a KnowledgeNFT collection.">>,
            context => <<"merch">>,
            images => [
                <<"QmVuUKm7WnFfuxvxZUYByqFdpjtZKNrEUKchCg2ChMCgHj">>,
                <<"QmSCL3jutYJyZQAYH2gbbmYiqrP2gxztwjtBd6ZwGwbyWy">>,
                <<"QmbiC96Wpvp1pv1Mun1tfvRVAZeZjHXRkdSnuzBmsDLpfx">>,
                <<"Qme7stsuVhF5gkmcwsyyWLEzb64idJcz51fZaGVE2rqStW">>
            ],
            links => [
                #{rel => <<"story">>, type => <<"text/markdown">>, ipfs => StoryCid}
            ]
        }
    ).

%% ------------------------------------------------------------------
%% Knowledge NFT – Image Collection
%% ------------------------------------------------------------------

%% Build manifest, add to IPFS, mint KnowledgeNFT
mint_knowledge_image_collection(
    KeyPair,
    #{
        title := Title,
        images := Images
    } = Meta
) when is_list(Images) ->
    Description = maps:get(description, Meta, <<>>),
    Context = maps:get(context, Meta, <<"knowledge">>),
    Links = maps:get(links, Meta, []),


    Manifest = #{
        <<"type">> => <<"knowledge:image_collection">>,
        <<"title">> => Title,
        <<"description">> => Description,
        <<"context">> => Context,
        <<"images">> => Images,
        <<"links">> => Links,
        <<"created_at">> => erlang:system_time(second)
    },

    ManifestJson = jsx:encode(Manifest),
    {ok, [#{<<"Hash">> := ManifestCid}]} = damage_ipfs:add(
        {data, ManifestJson, <<"manifest.json">>}
    ),

    mint_knowledge_image_collection(KeyPair, ManifestCid, Manifest).

%% Mint directly from an existing manifest CID
mint_knowledge_image_collection(KeyPair, ManifestCid, Manifest) ->
    %% Mint using the existing knowledge mint pipeline.
    %% We store the manifest CID as the "object" of a normal SPOC fact.
    %%
    %% This keeps indexing consistent with the rest of ECAI knowledge
    %% while letting the manifest describe a multi-image collection.
    Title = maps:get(<<"title">>, Manifest, <<"knowledge:image_collection">>),
    Context = maps:get(<<"context">>, Manifest, <<"knowledge">>),
    mint_knowledge(KeyPair, #{
        subject => Title,
        predicate => <<"is materialised as">>,
        object => ManifestCid,
        context => Context
    }).


%% Example execution
test() ->
    NodeKeyPair = secrets:node_keypair(),
    mint_letters(NodeKeyPair, "abcdefghijklmnopqrstuvwxyz"),
    mint_digits(NodeKeyPair, "1234567890").
