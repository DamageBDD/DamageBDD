-module(ecai).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai.hrl").

-export([
    start/0,
    test/0
]).

-export([
         point_to_filename_hash/1,
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
    <<"ecai_", Slug/binary>>.


test() ->
    {1650075109,63181} = ecai:hash_to_curve("Hello world!").
