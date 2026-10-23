%% Canonical encoding for local audit chains. No dynamic atom creation.
-module(damage_agent_codec).
-license("Apache-2.0").
-export([bin/1, canonical/1, hash/1, text/2, json_value/2]).

bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I).

%% This is a versioned project encoding, not a claim of RFC 8785 compliance.
canonical(M) when is_map(M) ->
    Pairs = lists:sort([{bin(K), V} || {K, V} <- maps:to_list(M)]),
    iolist_to_binary(["{", join([[jsx:encode(K), ":", canonical(V)] || {K,V} <- Pairs]), "}"]);
canonical(L) when is_list(L) ->
    iolist_to_binary(["[", join([canonical(V) || V <- L]), "]"]);
canonical(A) when is_atom(A), A =/= true, A =/= false, A =/= null ->
    jsx:encode(bin(A));
canonical(V) -> jsx:encode(V).

join([]) -> [];
join([H|T]) -> [H | [[",", X] || X <- T]].
hash(T) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, canonical(T)))).

text(B, Max) when is_binary(B), byte_size(B) > 0, byte_size(B) =< Max ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        B -> binary:match(B, <<0>>) =:= nomatch;
        _ -> false
    end;
text(_, _) -> false.

%% Bound nesting and reject PIDs, references, tuples, funs and arbitrary atoms.
json_value(_, Depth) when Depth > 12 -> false;
json_value(M, D) when is_map(M), map_size(M) =< 128 ->
    lists:all(fun({K,V}) -> is_binary(K) andalso json_value(V,D+1) end, maps:to_list(M));
json_value(L, D) when is_list(L), length(L) =< 256 ->
    lists:all(fun(V) -> json_value(V,D+1) end, L);
json_value(B, _) when is_binary(B) -> byte_size(B) =< 131072 andalso
    unicode:characters_to_binary(B,utf8,utf8) =:= B;
json_value(I, _) when is_integer(I) -> abs(I) =< 9007199254740991;
json_value(V, _) -> V =:= true orelse V =:= false orelse V =:= null.
