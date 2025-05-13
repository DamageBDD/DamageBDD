-module(ecai).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    start/0,
    test/0,
    mint_knowledge/2,
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
-include("ecai.hrl").

-include_lib("kernel/include/logger.hrl").

-on_load(init/0).

%% Elliptic curve parameters (y^2 = x^3 + ax + b over prime field P)
-define(A, -1).
-define(B, 1).
-define(P, 23).

%% Start the AI
start() ->
    io:format("Elliptical AI initialized. Ready for computation.~n").

init() ->
    PrivDir = code:priv_dir(ecai),
    NifPath = filename:join([PrivDir, "ecai"]),
    ok = erlang:load_nif(NifPath, 0).
%% Generate a valid point on the elliptic curve

hash_to_curve(_Arg) -> erlang:nif_error(nif_library_not_loaded).

curve_add(_X1, _Y1, _X2, _Y2) -> erlang:nif_error(nif_library_not_loaded).

mint_knowledge(
    AeAccount,
    #{
        subject := _Subject,
        predicate := _Predicate,
        object := _Object,
        context := _Context
    } = Knowledge
) ->
    EncodedKnowledge = encode(Knowledge),
    Point = {_X, _Y} = ecai:hash_to_curve(EncodedKnowledge),
    MetaData = #{Point => ecai:hash_to_curve(EncodedKnowledge)},

    damage_ae:contract_call(
        secrets:node_keypair(),
        ?ECAI_KNOWLEDGE_NFT_CONTRACT,
        "contracts/knowledge_nft.aes",
        "mint",
        [AeAccount, MetaData, Knowledge]
    ).

encode(#{subject := Subject, predicate := Predicate, object := Object, context := Context}) ->
    Timestamp = erlang:system_time(seconds),
    vrlp:encode([Subject, Predicate, Object, Context, Timestamp]).
%% Example execution
test() ->
    [
        mint_knowledge(secrets:node_keypair(), Char)
     || Char <- "abcdefghijklmnopqrstuvwxyz1234567890"
    ],
    mint_knowledge(secrets:node_keypair(), "test").
