%% Shared evaluation encodings. Only data is hashed; hashes do not prove truth.
-module(ecai_eval_util).
-export([json/1, decode/1, hash/1, hex/1, id/0, now_ms/0, day/0,
         bin/1, require/2, keys/2, text/2, integer/3, enum/2, public/1]).

%% Stable key ordering; manifest_bytes are exported verbatim for portable hashing.
%% This is ECAI eval JSON v1, not a claim of RFC 8785 compliance.
json(M) when is_map(M) ->
    Pairs = lists:sort([{bin(K), V} || {K, V} <- maps:to_list(M)]),
    iolist_to_binary([<<"{">>, lists:join(<<",">>,
        [[json(K), <<":">>, json(V)] || {K, V} <- Pairs]), <<"}">>]);
json(L) when is_list(L) ->
    iolist_to_binary([<<"[">>, lists:join(<<",">>, [json(V) || V <- L]), <<"]">>]);
json(true) -> <<"true">>;
json(false) -> <<"false">>;
json(null) -> <<"null">>;
json(undefined) -> <<"null">>;
json(A) when is_atom(A) -> json(atom_to_binary(A, utf8));
json(V) when is_binary(V); is_number(V) -> iolist_to_binary(json:encode(V)).

decode(B) when is_binary(B) -> json:decode(B).
hash(T) -> hex(crypto:hash(sha256, [<<"ecai-eval/v1", 0>>, json(T)])).
hex(B) -> << <<(digit(N bsr 4)), (digit(N band 15))>> || <<N>> <= B >>.
digit(N) when N < 10 -> $0 + N;
digit(N) -> $a + N - 10.
id() -> hex(crypto:strong_rand_bytes(16)).
now_ms() -> erlang:system_time(millisecond).
day() -> erlang:system_time(second) div 86400.
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I).
require(true, _) -> ok;
require(false, Why) -> throw({eval_error, Why}).
keys(M, Allowed) when is_map(M) ->
    require(lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(M)), unexpected_fields);
keys(_, _) -> throw({eval_error, object_required}).
text(B, Max) ->
    require(is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< Max,
            invalid_text),
    require(is_list(unicode:characters_to_list(B)), invalid_utf8),
    require(binary:match(B, <<0>>) =:= nomatch, contains_nul), B.
integer(N, Min, Max) ->
    require(is_integer(N) andalso N >= Min andalso N =< Max, invalid_integer), N.
enum(V, Values) -> require(lists:member(V, Values), invalid_enum), V.
public(T) -> decode(json(T)).
