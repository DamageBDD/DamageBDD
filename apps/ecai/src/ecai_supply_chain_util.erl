%% Stable, domain-separated evidence encoding. Digests are not signatures.
-module(ecai_supply_chain_util).
-export([json/1, hash/2, hex/1, require/2, keys/2, integer/3, id/2]).

json(M) when is_map(M) ->
    Pairs = lists:sort([{key(K), V} || {K, V} <- maps:to_list(M)]),
    iolist_to_binary([<<"{">>, lists:join(<<",">>,
        [[json(K), <<":">>, json(V)] || {K, V} <- Pairs]), <<"}">>]);
json(L) when is_list(L) ->
    iolist_to_binary([<<"[">>, lists:join(<<",">>, [json(V) || V <- L]), <<"]">>]);
json(true) -> <<"true">>;
json(false) -> <<"false">>;
json(null) -> <<"null">>;
json(A) when is_atom(A) -> json(atom_to_binary(A, utf8));
json(V) when is_binary(V); is_number(V) -> iolist_to_binary(json:encode(V)).
key(B) when is_binary(B) -> B;
key(A) when is_atom(A) -> atom_to_binary(A, utf8).
hash(Domain, Value) -> hex(crypto:hash(sha256, [Domain, <<0>>, json(Value)])).
hex(B) -> << <<(digit(N bsr 4)), (digit(N band 15))>> || <<N>> <= B >>.
digit(N) when N < 10 -> $0 + N;
digit(N) -> $a + N - 10.
require(true, _) -> ok;
require(false, Why) -> throw({supply_chain, Why}).
keys(M, Allowed) when is_map(M) ->
    require(lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(M)), unexpected_fields);
keys(_, _) -> throw({supply_chain, json_object_required}).
integer(N, Min, Max) ->
    require(is_integer(N) andalso N >= Min andalso N =< Max, invalid_integer), N.
id(Prefix, N) -> <<Prefix/binary, (integer_to_binary(N))/binary>>.
