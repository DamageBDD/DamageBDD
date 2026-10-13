%%%-------------------------------------------------------------------
%%% ecai_tokenizer.erl  — deterministic tokenizer for ECAI indexing
%%% - Uses string:tokens/2 (list-based), but accepts binaries too
%%% - Returns tokens as UTF-8 binaries (ready for your index)
%%% - ASCII lowercase; stable across OTP versions
%%%-------------------------------------------------------------------
-module(ecai_tokenizer).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-export([
    % Value -> [<<Token/binary>>]
    tokens/1,
    % Value, Delims -> [<<Token/binary>>]  (Delims list/binary)
    tokens/2,
    % Value -> <<digits-only/binary>>
    digits_only/1,
    % Value -> <<lowercased/binary>>
    lower_ascii/1,
    % Value -> String() list (for debugging)
    normalize/1
]).

%% ---- Public API ----------------------------------------------------

-spec tokens(term()) -> [binary()].
tokens(Value) ->
    tokens(Value, default_delims()).

-spec tokens(term(), list() | binary()) -> [binary()].
tokens(Value, Delims0) ->
    S0 = normalize(Value),
    S = lower_ascii_list(S0),
    D = normalize_delims(Delims0),
    [unicode:characters_to_binary(T) || T <- string:tokens(S, D), T =/= []].

-spec digits_only(term()) -> binary().
digits_only(Value) ->
    S = normalize(Value),
    list_to_binary([C || C <- S, C >= $0, C =< $9]).

-spec lower_ascii(term()) -> binary().
lower_ascii(Value) ->
    L = lower_ascii_list(normalize(Value)),
    unicode:characters_to_binary(L).

-spec normalize(term()) -> string().
normalize(undefined) -> [];
normalize(B) when is_binary(B) -> unicode:characters_to_list(B);
normalize(L) when is_list(L) -> unicode:characters_to_list(L);
normalize(A) when is_atom(A) -> atom_to_list(A);
normalize(I) when is_integer(I) -> integer_to_list(I);
normalize(F) when is_float(F) -> io_lib:format("~.16g", [F]);
normalize(Other) -> io_lib:format("~ts", [Other]).

%% ---- Internals -----------------------------------------------------

%% Default delimiter set: whitespace + common punctuation
default_delims() ->
    " \t\r\n,.;:!?\"'()[]{}<>/\\|@#%^&*+=`~\v\f".

normalize_delims(D) when is_binary(D) -> unicode:characters_to_list(D);
normalize_delims(D) when is_list(D) -> unicode:characters_to_list(D);
normalize_delims(_) -> default_delims().

lower_ascii_list([]) -> [];
lower_ascii_list([C | Rest]) when C >= $A, C =< $Z -> [C + 32 | lower_ascii_list(Rest)];
lower_ascii_list([C | Rest]) -> [C | lower_ascii_list(Rest)].
