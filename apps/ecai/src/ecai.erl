-module(ecai).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai.hrl").

-export([
    start/0,
    test/0,
    mint_knowledge/2,
    mint_alphanumerics_with_ordinals/0,
    deploy_knowledge_nft_contract/0,
    encode/1
]).
-export([
    hash_to_curve/1,
    curve_add/4
]).
-nifs([
    hash_to_curve/1,
    curve_add/4
]).

-include_lib("kernel/include/logger.hrl").

-on_load(init/0).

%% Elliptic curve parameters (y^2 = x^3 + ax + b over prime field P)
-define(A, -1).
-define(B, 1).
-define(P, 23).

%% Start the AI
start() ->
    io:format("Elliptical AI initialized. Ready for computation.~n").

%% Pull the contract id from Opts or application env
-spec ct_id(map()) -> binary().
ct_id(Opts) ->
    case maps:get(ct, Opts, undefined) of
        <<"ct_", _/binary>> = Ct ->
            Ct;
        _ ->
            case application:get_env(ecai, knowledge_registry_ct) of
                {ok, <<"ct_", _/binary>> = C} -> C;
                _ -> error({missing_contract_id, knowledge_registry_ct})
            end
    end.
init() ->
    PrivDir = code:priv_dir(ecai),
    NifPath = filename:join([PrivDir, "ecai"]),
    case erlang:load_nif(NifPath, 0) of
        ok ->
            ?LOG_INFO("ECAI NIF Loaded");
        _ ->
            ?LOG_INFO("ECAI NIF Not Loaded")
    end.
%% Generate a valid point on the elliptic curve

hash_to_curve(_Arg) -> erlang:nif_error(nif_library_not_loaded).

curve_add(_X1, _Y1, _X2, _Y2) -> erlang:nif_error(nif_library_not_loaded).
-spec point_to_filename_hash({integer(), integer()}) -> binary().
point_to_filename_hash({X, Y}) ->
    Bin = term_to_binary({X, Y}),
    Hash = crypto:hash(sha256, Bin),
    Slug = base32:encode(binary:part(Hash, 0, 20)),
    <<"ecai_", Slug/binary, ".wav">>.

mint_knowledge(
    #{public_key := AeAccount, private_key := _PrivateKey} = KeyPair,
    #{ subject := Subject, predicate := Predicate, object := Object, context := Context } = Knowledge
) ->
    EncodedKnowledge = encode(Knowledge),

    %% Canonical identity key for this fact/blob (bytes32)
    FactKey = crypto:hash(sha256, EncodedKnowledge),

    %% Derived token_id: uint64(big-endian) from first 8 bytes of FactKey
    <<Id64:64/unsigned-big, _/binary>> = FactKey,
    TokenId0 = Id64,
    TokenId  = case TokenId0 of 0 -> 1; _ -> TokenId0 end,

    %% Curve point (kept for ECAI clients; not required by chain)
    Point = ecai:hash_to_curve(EncodedKnowledge),

    %% Store blob in IPFS (filename hashed from point like you already do)
    {ok, IpfsHash} = ipfs:add({data, EncodedKnowledge, point_to_filename_hash(Point)}),

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
        {s, SKey}, {p, PKey}, {o, OKey}, {c, CKey}, {k, KKey}
        %% optionally include raw strings too (costs bytes, but off-chain only):
        %% , {subject, Subject}, {predicate, Predicate}, {object, Object}, {context, Context}
    ]),

    %% Optional on-chain metadata (small map). Not required for indexing.
    %% Keep it tiny: hex strings only, plus ipfs.
    MetaData = #{
        <<"v">>    => <<"3">>,
        <<"ipfs">> => IpfsHash,
        <<"bh">>   => binary:encode_hex(FactKey),
        <<"s">>    => binary:encode_hex(SKey),
        <<"p">>    => binary:encode_hex(PKey),
        <<"o">>    => binary:encode_hex(OKey),
        <<"c">>    => binary:encode_hex(CKey),
        <<"k">>    => binary:encode_hex(KKey)
    },

    damage_ae:contract_call(
        KeyPair,
        ct_id(#{}),
        "contracts/knowledge_nft.aes",
        "mint_derived",
        [AeAccount, TokenId, FactKey, SKey, PKey, OKey, CKey, KKey, MetaData, Payload]
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
    ?LOG_INFO("Contract ~p",[ContractPath]),
    #{"contract_id" := ContractId} = damage_ae:contract_deploy(
        ContractPath, ["Wikipedia Search Index Fragment 1", "ecai", "10" ]
    ),

    ContractId.

%% Example execution
test() ->
    NodeKeyPair = secrets:node_keypair(),
    mint_letters(NodeKeyPair, "abcdefghijklmnopqrstuvwxyz"),
    mint_digits(NodeKeyPair, "1234567890").
