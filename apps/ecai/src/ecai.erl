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
    hash_to_curve_point/1,
    hash_binary_to_curve_point/1,
    hash_raw_binary_to_curve_point/1,
    hash_to_curve/1,
    hash_to_curve/2,
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
        Err ->
            ?LOG_INFO("ECAI NIF Not Loaded ~p", [Err])
    end.
%% Generate a valid point on the elliptic curve

hash_to_curve(_Arg) -> erlang:nif_error(nif_library_not_loaded).

curve_add(_X1, _Y1, _X2, _Y2) -> erlang:nif_error(nif_library_not_loaded).

%% Backward-compatible curve mapping.
%%
%% Historically, callers that passed binary data were first SHA256 hashed,
%% hex encoded, then mapped to a curve point. Keep that behaviour because the
%% resulting point feeds deterministic NFT token IDs/fact keys. Changing this
%% function would remap existing knowledge artifacts.
hash_to_curve_point(Data) when is_binary(Data) ->
    hash_binary_to_curve_point(Data);
hash_to_curve_point(Data) when is_list(Data) ->
    case hash_to_curve(Data) of
        {XBin, YBin, Counter} ->
            #{
                x_bin => XBin,
                y_bin => YBin,
                x => binary:decode_unsigned(XBin, little),
                y => binary:decode_unsigned(YBin, little),
                counter => Counter
            };
        {error, _Reason} = Error ->
            Error
    end.

%% Explicit hash-first mapping for binary payloads.
hash_binary_to_curve_point(Data) when is_binary(Data) ->
    hash_to_curve_point(binary_to_list(binary:encode_hex(crypto:hash(sha256, Data)))).

%% Explicit raw binary/list mapping for new callers that intentionally want
%% raw payload bytes to feed the NIF.
hash_raw_binary_to_curve_point(Data) when is_binary(Data) ->
    hash_to_curve_point(binary_to_list(Data)).
-spec point_to_filename_hash(
    {integer(), integer()}
    | {binary(), binary()}
    | {integer(), integer(), non_neg_integer()}
    | {binary(), binary(), non_neg_integer()}
) -> binary().

point_to_filename_hash({X, Y}) when is_integer(X), is_integer(Y) ->
    point_to_filename_hash_ints({X, Y, 0});
point_to_filename_hash({XBin, YBin}) when is_binary(XBin), is_binary(YBin) ->
    point_to_filename_hash_bins({XBin, YBin, 0});
point_to_filename_hash({X, Y, Counter}) when
    is_integer(X), is_integer(Y), is_integer(Counter), Counter >= 0
->
    point_to_filename_hash_ints({X, Y, Counter});
point_to_filename_hash({XBin, YBin, Counter}) when
    is_binary(XBin), is_binary(YBin), is_integer(Counter), Counter >= 0
->
    point_to_filename_hash_bins({XBin, YBin, Counter}).

point_to_filename_hash_ints({X, Y, Counter}) ->
    Bin = term_to_binary({X, Y, Counter}),
    Hash = crypto:hash(sha256, Bin),
    Slug = base32:encode(binary:part(Hash, 0, 20)),
    <<"ecai_", Slug/binary>>.

point_to_filename_hash_bins({XBin, YBin, Counter}) ->
    X = binary:decode_unsigned(XBin, little),
    Y = binary:decode_unsigned(YBin, little),
    point_to_filename_hash_ints({X, Y, Counter}).

test() ->
    {XBin, YBin, Counter} = ecai:hash_to_curve("hello"),
    X = binary:decode_unsigned(XBin, little),
    Y = binary:decode_unsigned(YBin, little),
    io:format("X = ~p~nY = ~p~nCounter = ~p~n", [X, Y, Counter]).
