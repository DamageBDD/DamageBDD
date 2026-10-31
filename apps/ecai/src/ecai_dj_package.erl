%% Portable declarative ECDJ policies. Digests establish integrity, not authorship,
%% music rights, ownership, or entitlement. No executable terms are accepted.
-module(ecai_dj_package).
-export([default/0, validate/1, digest/1, export/1, import/1]).

-define(SCHEMA, <<"ecai-dj-policy/v1">>).
-define(FORMAT, <<"ecai-dj-package/v1">>).
-define(MAX_BYTES, 65536).

default() ->
    #{schema => ?SCHEMA, name => <<"Open discovery">>, version => 1,
      policy_license => <<"LicenseRef-Unspecified">>,
      preferred_tags => [], excluded_tags => [], seed_ids => [],
      target_bpm => 0, discovery => 20,
      weights => #{tags => 100, mood => 80, bpm => 1, rating => 80,
                   repetition => 200, seed => 120}}.

%% Both JSON binary keys and native atom keys are accepted at this boundary.
%% Only this finite key vocabulary is converted; user input never creates atoms.
validate(Input) when is_map(Input), map_size(Input) =< 11 ->
    try
        M = known_map(Input, [schema, name, version, preferred_tags, excluded_tags,
                             seed_ids, target_bpm, discovery, weights, policy_license]),
        D = default(), P = maps:merge(D, M),
        ?SCHEMA = maps:get(schema, P),
        Name = text(name, maps:get(name, P), 128),
        License = text(policy_license, maps:get(policy_license,P),256),
        Version = integer(version, maps:get(version, P), 1, 1000000),
        Preferred = tags(preferred_tags, maps:get(preferred_tags, P)),
        Excluded = tags(excluded_tags, maps:get(excluded_tags, P)),
        Seeds = strings(seed_ids, maps:get(seed_ids, P), 64, 256),
        Bpm = integer(target_bpm, maps:get(target_bpm, P), 0, 400),
        Discovery = integer(discovery, maps:get(discovery, P), 0, 100),
        W0 = known_map(maps:get(weights, P), [tags, mood, bpm, rating, repetition, seed]),
        W = maps:merge(maps:get(weights, D), W0),
        maps:foreach(fun(K,V) -> integer(K,V,0,1000) end, W),
        {ok, P#{name => Name, policy_license => License, version => Version, preferred_tags => Preferred,
                excluded_tags => Excluded, seed_ids => Seeds, target_bpm => Bpm,
                discovery => Discovery, weights => W}}
    catch
        throw:Reason -> {error, Reason};
        error:{badmatch, _} -> {error, unsupported_policy_schema};
        error:_ -> {error, invalid_policy}
    end;
validate(_) -> {error, invalid_policy}.

digest(Input) ->
    case validate(Input) of
        {ok, P} -> {ok, hex(crypto:hash(sha256, canonical(json_policy(P))))};
        Error -> Error
    end.

export(Input) ->
    case validate(Input) of
        {ok, P} ->
            J = json_policy(P),
            Hash = hex(crypto:hash(sha256, canonical(J))),
            {ok, canonical(#{<<"format">> => ?FORMAT, <<"policy">> => J,
                             <<"sha256">> => Hash})};
        Error -> Error
    end.

import(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_BYTES ->
    try
        Envelope = jsx:decode(Bin, [return_maps]),
        %% Three envelope fields exactly; unknown keys cannot hide payloads.
        #{<<"format">> := ?FORMAT, <<"policy">> := Raw,
          <<"sha256">> := Hash} = Envelope,
        3 = map_size(Envelope),
        true = is_binary(Hash) andalso byte_size(Hash) =:= 64,
        case validate(Raw) of
            {ok, P} ->
                {ok, Expected} = digest(P),
                case Hash =:= Expected of
                    true -> {ok, P};
                    false -> {error, digest_mismatch}
                end;
            Error -> Error
        end
    catch _:_ -> {error, invalid_package} end;
import(_) -> {error, package_too_large_or_invalid}.

known_map(M, Allowed) when is_map(M) ->
    lists:foldl(fun({K,V}, Acc) ->
        Matches = [A || A <- Allowed, K =:= A orelse K =:= atom_to_binary(A, utf8)],
        case Matches of
            [A] ->
                case maps:is_key(A, Acc) of
                    true -> throw({duplicate_field, A});
                    false -> Acc#{A => V}
                end;
            [] -> throw(unknown_policy_field)
        end
    end, #{}, maps:to_list(M));
known_map(_,_) -> throw(invalid_policy_map).

text(K, B, Max) when is_binary(B), byte_size(B) > 0, byte_size(B) =< Max ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        B -> B;
        _ -> throw({invalid_text, K})
    end;
text(K,_,_) -> throw({invalid_text, K}).

integer(_, V, Low, High) when is_integer(V), V >= Low, V =< High -> V;
integer(K,_,_,_) -> throw({invalid_integer, K}).

strings(K, L, Count, Size) when is_list(L), length(L) =< Count ->
    lists:usort([text(K,B,Size) || B <- L]);
strings(K,_,_,_) -> throw({invalid_list,K}).

tags(K,L) ->
    lists:usort([text(K,unicode:characters_to_binary(string:casefold(unicode:characters_to_list(B))),128)
                 || B <- strings(K,L,64,128)]).

json_policy(P) ->
    maps:from_list([{atom_to_binary(K,utf8), json_value(V)} || {K,V} <- maps:to_list(P)]).
json_value(M) when is_map(M) -> json_policy(M);
json_value(V) -> V.

%% Object keys sorted lexicographically, integers only, UTF-8 strings encoded
%% by jsx. Export and digest share the same byte representation.
canonical(M) when is_map(M) ->
    iolist_to_binary([${, lists:join($,, [[jsx:encode(K),$:,canonical(V)]
                         || {K,V} <- lists:sort(maps:to_list(M))]), $}]);
canonical(L) when is_list(L) ->
    iolist_to_binary([$[, lists:join($,,[canonical(V) || V <- L]), $]]);
canonical(V) when is_binary(V); is_integer(V) -> jsx:encode(V).

hex(Bin) -> << <<(digit(N bsr 4)), (digit(N band 15))>> || <<N>> <= Bin >>.
digit(N) when N < 10 -> $0+N;
digit(N) -> $a+N-10.
