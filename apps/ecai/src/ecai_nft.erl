-module(ecai_nft).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai.hrl").

-export([
    mint_knowledge/2,
    mint_alphanumerics_with_ordinals/0,
    deploy_knowledge_nft_contract/0,
    encode/1
]).
-export([
    mint_index_job/3,
    mint_knowledge_image_collection/2,
    mint_knowledge_image_collection/3,
    mint_tshirt_order_nft_json/1,
    mint_index_jobs_from_chunks/4
]).
-export([
    test/0,
    test_mint_tshirt_order/0
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
    {ok, [
        #{
            <<"Hash">> :=
                IpfsHash,
            <<"Name">> :=
                _Name,
            <<"Size">> := _Size
        }
    ]} = damage_ipfs:add({data, EncodedKnowledge, ecai:point_to_filename_hash(Point)}),

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
    Payload = iolist_to_binary(
        vrlp:encode([
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
        ])
    ),

    %% Optional on-chain metadata (small map). Not required for indexing.
    %% Keep it tiny: hex strings only, plus ipfs.
    %% The contract expects KnowledgeNFTs.metadata as a scalar (string),
    %% not a map. So we JSON-encode a tiny map and pass it as a Sophia string.
    %% KnowledgeNFTs.metadata is a VARIANT with constructors:
    %%   MetadataIdentifier | MetadataMap
    %% Use MetadataMap and provide a map(string,string).
    MetaDataMap = #{
        "v" => "3",
        "ipfs" => binary_to_list(IpfsHash),
        "bh" => binary_to_list(binary:encode_hex(FactKey)),
        "s" => binary_to_list(binary:encode_hex(SKey)),
        "p" => binary_to_list(binary:encode_hex(PKey)),
        "o" => binary_to_list(binary:encode_hex(OKey)),
        "c" => binary_to_list(binary:encode_hex(CKey)),
        "k" => binary_to_list(binary:encode_hex(KKey))
    },
    MetaVariant = {"MetadataMap", MetaDataMap},
    MdOpt = {"Some", MetaVariant},

    ?LOG_INFO(
        "Minting knowledge ~p",
        [
            [
                AeAccount,
                TokenId,
                binary_to_list(FactKey),
                binary_to_list(SKey),
                binary_to_list(PKey),
                binary_to_list(OKey),
                binary_to_list(CKey),
                binary_to_list(KKey),
                MdOpt,
                Payload
            ]
        ]
    ),
    damage_ae:contract_call(
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
        ContractPath, ["ECAI Knowledge Fragment", "ecai", "10"]
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

    Payload = iolist_to_binary(
        vrlp:encode([
            {dataset, DatasetId},
            {chunk_id, ChunkId},
            {path, Path},
            {start, Start},
            {lines, Count},
            {price, Price}
        ])
    ),

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
%% -------------------------------------------------------------------
%% Mint a real tshirt order NFT from JSON order details.
%%
%% Input: OrderJson (binary) containing keys like:
%%  {
%%    "order_id":"ORD-2026-000002",
%%    "sku":"DBDD-ECAI-GENESIS-TEE",
%%    "variant_id":"BLACK-XL",
%%    "size":"XL",
%%    "color":"black",
%%    "quantity":1,
%%    "currency":"AUD",
%%    "paid_amount_cents":6500,
%%    "status":"paid",
%%    "collection_manifest_cid":"Qm....",   (optional but recommended)
%%    "customer":{...},                    (PII)
%%    "shipping":{...},                    (PII)
%%    "fulfillment":{...}                  (optional)
%%  }
%%
%% Output: {ok, #{token_id => ..., order_manifest_cid => ..., shipping_sha256 => ... , mint_result => ...}}
%%         {error, Reason}
%% -------------------------------------------------------------------

%% -------------------------------------------------------------------
%% Mint a tshirt order NFT from fields (NO JSON parsing here).
%% The only privacy-sensitive output stored in the public manifest is
%% ShippingCommitment (a keyed HMAC commitment).
%% -------------------------------------------------------------------

-spec mint_tshirt_order_nft_fields(
    %% KeyPair
    map(),
    %% OrderId
    binary(),
    %% Sku
    binary(),
    %% OrderPublicNoPii (already stripped of customer/shipping)
    map(),
    %% ShippingCommitment (privacy-preserving)
    binary()
) -> {ok, map()} | {error, term()}.
mint_tshirt_order_nft_fields(KeyPair, OrderId, Sku, OrderPublicNoPii, ShippingCommitment) when
    is_map(KeyPair),
    is_binary(OrderId),
    is_binary(Sku),
    is_map(OrderPublicNoPii),
    is_binary(ShippingCommitment)
->
    %% Ensure type and add ONLY the privacy-preserving shipping commitment
    Order1 = maps:put(<<"type">>, <<"merch:tshirt_order">>, OrderPublicNoPii),
    OrderPublic = maps:put(<<"shipping_commitment">>, ShippingCommitment, Order1),

    %% Store manifest JSON in IPFS
    PublicJson = jsx:encode(OrderPublic),
    {ok, [#{<<"Hash">> := OrderManifestCid} | _]} =
        damage_ipfs:add({data, PublicJson, <<"tshirt_order.json">>}),
    MintData = #{
        subject => OrderId,
        predicate => <<"is materialised as">>,
        object => OrderManifestCid,
        context => <<"merch:orders">>
    },
    ?LOG_DEBUG("Minting tshirts ~p", [MintData]),

    %% Mint KnowledgeNFT linking OrderId -> manifest CID
    MintResult =
        ecai_nft:mint_knowledge(KeyPair, MintData),

    {ok, #{
        order_id => OrderId,
        sku => Sku,
        order_manifest_cid => OrderManifestCid,
        shipping_commitment => ShippingCommitment,
        mint_result => MintResult
    }}.
%% -------------------------------------------------------------------
%% Parse order JSON, strip PII, compute privacy-preserving shipping commitment.
%% Returns:
%%  {ok, #{order_id := OrderId, sku := Sku, public := OrderPublicNoPii, shipping_commitment := ShipCommit}}
%% -------------------------------------------------------------------

-spec parse_tshirt_order_json(binary()) -> {ok, map()} | {error, term()}.
parse_tshirt_order_json(OrderJson) when is_binary(OrderJson) ->
    try
        Order0 = jsx:decode(OrderJson, [return_maps]),

        OrderId = require_bin(Order0, <<"order_id">>),
        Sku = require_bin(Order0, <<"sku">>),

        %% Shipping map can be required for real fulfillment;
        %% if you want “optional shipping” change require_map -> maps:get default.
        Shipping = require_map(Order0, <<"shipping">>),

        %% Extract shipping fields (binary)
        Line1 = require_bin(Shipping, <<"line1">>),
        Line2 = opt_bin(Shipping, <<"line2">>, <<>>),
        City = require_bin(Shipping, <<"city">>),
        State = require_bin(Shipping, <<"state">>),
        Postcode = require_bin(Shipping, <<"postcode">>),
        Country = require_bin(Shipping, <<"country">>),

        %% Privacy-preserving shipping commitment (keyed HMAC bound to OrderId)
        ShipCommit =
            shipping_commitment(OrderId, Line1, Line2, City, State, Postcode, Country),

        %% Strip PII: remove "customer" and "shipping" completely
        Order1 = maps:remove(<<"customer">>, Order0),
        OrderPublicNoPii = maps:remove(<<"shipping">>, Order1),

        {ok, #{
            order_id => OrderId,
            sku => Sku,
            public => OrderPublicNoPii,
            shipping_commitment => ShipCommit
        }}
    catch
        throw:{missing_field, Field} ->
            {error, {missing_field, Field}};
        throw:{missing_map, Field} ->
            {error, {missing_map, Field}};
        error:Reason:Stack ->
            {error, #{reason => Reason, stack => Stack}}
    end.
-spec mint_tshirt_order_nft_json(binary()) -> {ok, map()} | {error, term()}.
mint_tshirt_order_nft_json(OrderJson) when is_binary(OrderJson) ->
    KeyPair = secrets:node_keypair(),
    mint_tshirt_order_nft_json(KeyPair, OrderJson).

-spec mint_tshirt_order_nft_json(map(), binary()) -> {ok, map()} | {error, term()}.
mint_tshirt_order_nft_json(KeyPair, OrderJson) when
    is_map(KeyPair), is_binary(OrderJson)
->
    case parse_tshirt_order_json(OrderJson) of
        {ok, #{
            order_id := OrderId,
            sku := Sku,
            public := PublicNoPii,
            shipping_commitment := ShipCommit
        }} ->
            mint_tshirt_order_nft_fields(KeyPair, OrderId, Sku, PublicNoPii, ShipCommit);
        {error, _} = Err ->
            Err
    end.
%% Commitment = HMAC_SHA256(Key, OrderId || 0x00 || CanonicalShippingJson)
%% Returned as <<"hsc_v1_", Hex/binary>>

-spec shipping_commitment(binary(), binary(), binary(), binary(), binary(), binary(), binary()) ->
    binary().
shipping_commitment(OrderId, Line1, Line2, City, State, Postcode, Country) when
    is_binary(OrderId)
->
    Key = shipping_commitment_key(),
    shipping_commitment(Key, OrderId, Line1, Line2, City, State, Postcode, Country).

-spec shipping_commitment(
    binary(), binary(), binary(), binary(), binary(), binary(), binary(), binary()
) -> binary().
shipping_commitment(Key0, OrderId, Line1, Line2, City, State, Postcode, Country) when
    is_binary(Key0), is_binary(OrderId)
->
    Key = normalize_key(Key0),

    ShippingMap = #{
        <<"line1">> => to_bin(Line1),
        <<"line2">> => to_bin(Line2),
        <<"city">> => to_bin(City),
        <<"state">> => to_bin(State),
        <<"postcode">> => to_bin(Postcode),
        <<"country">> => to_bin(Country)
    },

    CanonJson = canonical_json_from_map(ShippingMap),

    Mac = crypto:mac(hmac, sha256, Key, <<OrderId/binary, 0, CanonJson/binary>>),
    Hex = binary:encode_hex(Mac),
    <<"hsc_v1_", Hex/binary>>.

shipping_commitment_key() ->
    case application:get_env(ecai, shipping_commitment_key) of
        {ok, K} when is_binary(K), byte_size(K) > 0 -> K;
        _ ->
            KP = secrets:node_keypair(),
            maps:get(private_key, KP)
    end.

normalize_key(K) when is_binary(K) ->
    case byte_size(K) of
        32 -> K;
        _ -> crypto:hash(sha256, K)
    end.

canonical_json_from_map(Map) when is_map(Map) ->
    Canon = canonicalize_term(Map),
    jsx:encode(Canon).

canonicalize_term(M) when is_map(M) ->
    Keys = lists:sort(maps:keys(M)),
    [{K, canonicalize_term(maps:get(K, M))} || K <- Keys];
canonicalize_term(L) when is_list(L) ->
    [canonicalize_term(X) || X <- L];
canonicalize_term(V) ->
    V.
require_bin(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        V when is_binary(V), V =/= <<>> -> V;
        V when is_list(V) ->
            B = list_to_binary(V),
            case B of
                <<>> -> throw({missing_field, Key});
                _ -> B
            end;
        undefined ->
            throw({missing_field, Key});
        _ ->
            throw({missing_field, Key})
    end.

opt_bin(Map, Key, Default) ->
    case maps:get(Key, Map, undefined) of
        V when is_binary(V) -> V;
        V when is_list(V) -> list_to_binary(V);
        undefined -> Default;
        _ -> Default
    end.

require_map(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        V when is_map(V) -> V;
        undefined -> throw({missing_map, Key});
        _ -> throw({missing_map, Key})
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

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
%% -------------------------------------------------------------------
%% Test helper: mint a dummy tshirt order NFT.
%% Uses fake data, but exercises the full pipeline:
%%  - JSON parsing
%%  - PII stripping
%%  - shipping_commitment
%%  - IPFS manifest
%%  - KnowledgeNFT mint
%% -------------------------------------------------------------------

-spec test_mint_tshirt_order() -> {ok, map()} | {error, term()}.
test_mint_tshirt_order() ->
    OrderJson = jsx:encode(#{
        <<"order_id">> => <<"TEST-ORDER-0001">>,
        <<"sku">> => <<"DBDD-ECAI-GENESIS-TEE">>,
        <<"variant_id">> => <<"BLACK-M">>,
        <<"size">> => <<"M">>,
        <<"color">> => <<"black">>,
        <<"quantity">> => 1,
        <<"currency">> => <<"AUD">>,
        <<"paid_amount_cents">> => 6500,
        <<"status">> => <<"test">>,
        <<"collection_manifest_cid">> => <<"QmTestCollectionCid">>,

        %% PII (will NOT be stored publicly)
        <<"customer">> => #{
            <<"name">> => <<"Test User">>,
            <<"email">> => <<"test@example.com">>
        },
        <<"shipping">> => #{
            <<"line1">> => <<"123 Test St">>,
            <<"line2">> => <<"">>,
            <<"city">> => <<"Sydney">>,
            <<"state">> => <<"NSW">>,
            <<"postcode">> => <<"2000">>,
            <<"country">> => <<"AU">>
        },

        <<"fulfillment">> => #{
            <<"provider">> => <<"test-provider">>,
            <<"expected_ship_days">> => 0
        }
    }),

    %% Uses node keypair internally
    mint_tshirt_order_nft_json(OrderJson).
