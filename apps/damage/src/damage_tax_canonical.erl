%%% Deterministic JSON serialization of tax evidence. No floats in commitments.
-module(damage_tax_canonical).
-export([encode/1, sha256_hex/1, commitment/1]).

-spec encode(term()) -> binary().
encode(V) -> iolist_to_binary(json(V)).

-spec sha256_hex(iodata()) -> binary().
sha256_hex(Bytes) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(
        crypto:hash(sha256, iolist_to_binary(Bytes)))))).

-spec commitment(term()) -> binary().
commitment(Term) -> sha256_hex(encode(Term)).

json(M) when is_map(M) ->
    Pairs = lists:sort([{key(K), V} || {K, V} <- maps:to_list(M)]),
    assert_unique_keys(Pairs),
    [<<"{">>, join([[json(K), <<":">>, json(V)] || {K, V} <- Pairs]), <<"}">>];
json(L) when is_list(L) -> [<<"[">>, join([json(V) || V <- L]), <<"]">>];
json(B) when is_binary(B) -> jsx:encode(B);
json(I) when is_integer(I) -> integer_to_binary(I);
json(true) -> <<"true">>;
json(false) -> <<"false">>;
json(null) -> <<"null">>;
json(A) when is_atom(A) -> jsx:encode(atom_to_binary(A, utf8));
json(F) when is_float(F) -> error({floats_forbidden_in_tax_evidence, F});
json(Other) -> error({unsupported_tax_evidence_type, Other}).

key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(Other) -> error({invalid_tax_evidence_key, Other}).

assert_unique_keys([{K, _}, {K, _} | _]) -> error({duplicate_json_key, K});
assert_unique_keys([_ | Rest]) -> assert_unique_keys(Rest);
assert_unique_keys([]) -> ok.

join([]) -> [];
join([H]) -> H;
join([H | T]) -> [H, <<",">>, join(T)].
