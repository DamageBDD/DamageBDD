-module(ecai).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    start/0,
    test/0,
    hash_to_curve/1,
    store_knowledge/1,
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

init() ->
    PrivDir = code:priv_dir(ecai),
    NifPath = filename:join([PrivDir, "ecai"]),
    ok = erlang:load_nif(NifPath, 0).
%% Generate a valid point on the elliptic curve

hash_to_curve(_Arg) -> erlang:nif_error(nif_library_not_loaded).

curve_add(_X1, _Y1, _X2, _Y2) -> erlang:nif_error(nif_library_not_loaded).

store_knowledge(Knowledge) ->
    {X, Y} = ecai:hash_to_curve(Knowledge),

    damage_ae:contract_call("contracts/knowledge.aes", "insert_point", [X, Y]).

%% Example execution
test() ->
    [store_knowledge(Char) || Char <- "abcdefghijklmnopqrstuvwxyz1234567890"],
    store_knowledge("test").
