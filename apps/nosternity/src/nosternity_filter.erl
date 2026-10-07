%% NIP-01/50 validation and shared stored/live filter semantics.
-module(nosternity_filter).
-export([validate_event/1, valid_filters/1, match/2, search_text/1,
         searchable/1, record/1, wire/1, expired/1, address/1, newer/2,
         max_limit/0, default_limit/0]).

max_limit() -> nosternity_config:get(search_max_limit).
default_limit() -> nosternity_config:get(search_default_limit).

validate_event(Input) ->
    try
        true = is_map(Input),
        %% Select only protocol fields. Do not normalize malformed input into a
        %% different signed event, supply defaults, or create atoms from JSON.
        E = maps:from_list([{K, required(K, Input)} || K <-
            [id, pubkey, created_at, kind, tags, content, sig]]),
        #{id := Id, pubkey := Pub, created_at := Time, kind := Kind,
          tags := Tags, content := Content, sig := Sig} = E,
        true = hex(Id, 64) andalso hex(Pub, 64) andalso hex(Sig, 128),
        true = is_integer(Time) andalso Time >= 0 andalso
            Time =< erlang:system_time(second) + 300,
        true = is_integer(Kind) andalso Kind >= 0 andalso Kind =< 65535,
        true = utf8(Content) andalso byte_size(Content) =< 16384,
        true = is_list(Tags) andalso length(Tags) =< 256,
        true = lists:all(fun(T) -> is_list(T) andalso T =/= [] andalso
            lists:all(fun utf8/1, T) end, Tags),
        true = byte_size(jsx:encode(wire(E))) =< 65000,
        true = lists:all(fun expiration_value/1, Tags),
        damage_nostr_event:verify(E)
    catch _:_ -> {error, invalid_event} end.

required(K, M) ->
    case maps:find(atom_to_binary(K, utf8), M) of
        {ok, V} -> V;
        error -> maps:get(K, M)
    end.
wire(E) -> maps:from_list([{atom_to_binary(K, utf8), maps:get(K, E)} ||
    K <- [id, pubkey, created_at, kind, tags, content, sig]]).
utf8(B) when is_binary(B) -> is_list(unicode:characters_to_list(B));
utf8(_) -> false.
hex(B, N) when is_binary(B), byte_size(B) =:= N ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) end, binary_to_list(B));
hex(_, _) -> false.
expiration_value([<<"expiration">>, V | _]) ->
    try binary_to_integer(V) >= 0 catch _:_ -> false end;
expiration_value([<<"expiration">>]) -> false;
expiration_value(_) -> true.
expired(#{tags := Tags}) ->
    Now = erlang:system_time(second),
    lists:any(fun
        ([<<"expiration">>, V | _]) -> binary_to_integer(V) =< Now;
        (_) -> false
    end, Tags).

valid_filters(Fs) when is_list(Fs), Fs =/= [] ->
    case length(Fs) =< nosternity_config:get(max_filters) andalso
         lists:all(fun valid_filter/1, Fs) of
        true -> {ok, Fs}; false -> {error, invalid_filters}
    end;
valid_filters(_) -> {error, invalid_filters}.
valid_filter(F) when is_map(F) -> maps:fold(fun(K,V,A) -> A andalso field(K,V) end, true,F);
valid_filter(_) -> false.
field(K,V) when K =:= <<"ids">>; K =:= <<"authors">>; K =:= <<"#e">>; K =:= <<"#p">> ->
    values(V, fun(X) -> hex(X,64) end);
field(<<"kinds">>,V) -> values(V, fun(X) -> is_integer(X) andalso X >= 0 andalso X =< 65535 end);
field(K,V) when K =:= <<"since">>; K =:= <<"until">>; K =:= <<"limit">> ->
    is_integer(V) andalso V >= 0;
field(<<"search">>,V) -> utf8(V) andalso byte_size(V) =< 1024;
field(<<$#,C>>,V) when C >= $a, C =< $z; C >= $A, C =< $Z -> values(V, fun utf8/1);
field(_,_) -> false.
values(V,F) -> is_list(V) andalso V =/= [] andalso
    length(V) =< nosternity_config:get(max_filter_values) andalso lists:all(F,V).

%% All fields AND; alternatives within a field OR. Initial limit is ignored
%% here so limit=0 subscriptions still receive new matching events.
match(E,F) -> not expired(E) andalso maps:fold(fun(K,V,A) ->
    A andalso matches(K,V,E) end, true,F).
matches(<<"ids">>,V,E) -> lists:member(maps:get(id,E),V);
matches(<<"authors">>,V,E) -> lists:member(maps:get(pubkey,E),V);
matches(<<"kinds">>,V,E) -> lists:member(maps:get(kind,E),V);
matches(<<"since">>,V,E) -> maps:get(created_at,E) >= V;
matches(<<"until">>,V,E) -> maps:get(created_at,E) =< V;
matches(<<"limit">>,_,_) -> true;
matches(<<"search">>,V,E) ->
    T = ecai_tokenizer:tokens(search_text(V)),
    searchable(E) andalso (T =:= [] orelse lists:any(fun(X) ->
        lists:member(X, lists:sublist(ecai_tokenizer:tokens(maps:get(content,E)),256))
    end,T));
matches(<<$#,C>>,V,E) -> lists:any(fun
    ([K,Value|_]) -> K =:= <<C>> andalso lists:member(Value,V);
    (_) -> false end, maps:get(tags,E)).

%% NIP-50 unsupported key:value extensions are ignored, not tokenized.
search_text(B) -> iolist_to_binary(lists:join(<<" ">>, [W ||
    W <- re:split(B, <<"\\s+">>, [unicode,{return,binary},trim]),
    binary:match(W, <<":">>) =:= nomatch])).

%% Public allowlist: ciphertext, gift wraps, DMs, and signer commands never
%% enter the text index or the LLM context. Add kinds only after schema review.
searchable(#{kind := K}) -> lists:member(K, [0,1,30023]).
record(E) -> #{text => maps:get(content,E), type => <<"nostr">>}.
address(#{kind := K, pubkey := P, tags := Tags}) when K >= 30000, K < 40000 ->
    D = case [V || [<<"d">>,V|_] <- Tags] of [V|_] -> V; [] -> <<>> end,
    <<(integer_to_binary(K))/binary, $:, P/binary, $:, D/binary>>;
address(#{kind := K, pubkey := P}) when K =:= 0; K =:= 3; K >= 10000, K < 20000 ->
    <<(integer_to_binary(K))/binary, $:, P/binary, $:>>;
address(_) -> undefined.
newer(A,B) ->
    {maps:get(created_at,A), maps:get(id,B)} >
    {maps:get(created_at,B), maps:get(id,A)}.
