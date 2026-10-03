%% Private indexing facade: same ecai_terms pipeline, encrypted records AND
%% postings, no plaintext public indexes or ingest journals. Append-only v1.
-module(ecai_private_index).
-export([index/4, search/4, fetch/3, search_authorized/4, normalize_record/1]).

-define(MAX_RECORDS, 256).
-define(MAX_BATCH_BYTES, 8388608).
-define(MAX_RECORD_BYTES, 1048576).
-define(MAX_QUERY_BYTES, 16384).
-define(MAX_SCAN_BYTES, 268435456).

-spec index(binary(), binary(), binary(), [map()]) -> {ok, map()} | {error, atom()}.
index(Corpus, Principal, BatchId, Records) ->
    ecai_private_policy:run(fun() ->
        Config = ecai_private_policy:resolve(Corpus, Principal, write),
        ecai_private_policy:guard(ecai_private_store:valid_batch_id(BatchId)),
        ecai_private_policy:guard(is_list(Records)),
        ecai_private_policy:guard(length(Records) > 0 andalso
                                  length(Records) =< ?MAX_RECORDS),
        ecai_private_policy:guard(erlang:external_size(Records) =< ?MAX_BATCH_BYTES),
        Normal = [normalize_record(R) || R <- Records],
        {Docs, Postings} = build_segment(Normal),
        Segment = #{schema => <<"ecai-private-segment/v1">>,
                    terms_version => ecai_terms:version(),
                    documents => Docs, postings => Postings},
        #{public_key := Pub} = ecai_private_keys:load(Config),
        Context = ecai_private_crypto:context(Config, Pub, BatchId),
        ok = ecai_private_store:append(Config#{principal => Principal}, Pub,
                                       BatchId, Segment, Context),
        {ok, #{corpus => Corpus, batch_id => BatchId,
               indexed => length(Normal), private => true}}
    end).

-spec search(binary(), binary(), binary() | map(), pos_integer()) ->
    {ok, map()} | {error, atom()}.
search(Corpus, Principal, Query, Limit) ->
    ecai_private_policy:run(fun() ->
        Config = ecai_private_policy:resolve(Corpus, Principal, read),
        search_authorized(Config, Principal, Query, Limit)
    end).

%% Internal trusted-worker API used by the LLM bridge. Re-authorises at entry
%% and immediately before returning plaintext; never accept Config over HTTP.
search_authorized(Config0, Principal, Query, Limit) ->
    Corpus = maps:get(corpus, Config0),
    Config = ecai_private_policy:resolve(Corpus, Principal, read),
    ecai_private_policy:guard(is_integer(Limit) andalso Limit >= 1 andalso Limit =< 50),
    Terms = query_terms(Query),
    Pair = ecai_private_keys:load(Config),
    #{public_key := Pub, private_key := Priv} = Pair,
    Segments = ecai_private_store:segments(Config, Pub),
    {Sources, _Bytes} = lists:foldl(fun({Id, Path}, {Acc, Bytes}) ->
        Size = filelib:file_size(Path),
        ecai_private_policy:guard(Size > 0 andalso Bytes + Size =< ?MAX_SCAN_BYTES),
        Context = ecai_private_crypto:context(Config, Pub, Id),
        Segment = checked_segment(ecai_private_store:read(Path, Priv, Context)),
        Matches = segment_matches(Id, Segment, Terms),
        {take_best(Acc ++ Matches, Limit), Bytes + Size}
    end, {[], 0}, Segments),
    _ = ecai_private_policy:resolve(Corpus, Principal, read),
    {ok, #{corpus => Corpus, private => true,
           sources => Sources, count => length(Sources)}}.

%% Fetch/decrypt one result by its opaque batch:ordinal reference. An ID from
%% another corpus does not bypass scope binding or corpus authorization.
-spec fetch(binary(), binary(), binary()) -> {ok, map()} | {error, atom()}.
fetch(Corpus, Principal, Reference) ->
    ecai_private_policy:run(fun() ->
        Config = ecai_private_policy:resolve(Corpus, Principal, read),
        {Id, Ordinal} = parse_reference(Reference),
        #{public_key := Pub, private_key := Priv} = ecai_private_keys:load(Config),
        Segments = ecai_private_store:segments(Config, Pub),
        Path = case lists:keyfind(Id, 1, Segments) of
            {Id, P} -> P;
            false -> ecai_private_policy:fail(not_found)
        end,
        Segment = checked_segment(ecai_private_store:read(
            Path, Priv, ecai_private_crypto:context(Config, Pub, Id))),
        Doc = case maps:find(Ordinal, maps:get(documents, Segment)) of
            {ok, D} -> D;
            error -> ecai_private_policy:fail(not_found)
        end,
        _ = ecai_private_policy:resolve(Corpus, Principal, read),
        {ok, Doc#{id => Reference}}
    end).

build_segment(Records) ->
    lists:foldl(fun({N, Record}, {Docs, Posts}) ->
        Terms = ecai_terms:terms_from_record(Record),
        ecai_private_policy:guard(length(Terms) =< 16384),
        ecai_private_policy:guard(lists:all(fun(T) -> byte_size(T) =< 8192 end, Terms)),
        Updated = lists:foldl(fun(Term, Acc) ->
            maps:update_with(Term, fun(Ids) -> [N | Ids] end, [N], Acc)
        end, Posts, Terms),
        {Docs#{N => Record}, Updated}
    end, {#{}, #{}}, lists:zip(lists:seq(1, length(Records)), Records)).

query_terms(Query) when is_binary(Query), byte_size(Query) =< ?MAX_QUERY_BYTES ->
    query_terms(#{text => Query});
query_terms(Query) when is_map(Query) ->
    ecai_private_policy:guard(erlang:external_size(Query) =< ?MAX_QUERY_BYTES),
    Terms = ecai_terms:terms_from_query(Query, false),
    ecai_private_policy:guard(Terms =/= [] andalso length(Terms) =< 256),
    Terms;
query_terms(_) -> ecai_private_policy:fail(invalid_query).

checked_segment(#{schema := <<"ecai-private-segment/v1">>, terms_version := Version,
                  documents := Docs, postings := Posts} = S)
  when is_map(Docs), map_size(Docs) > 0, map_size(Docs) =< ?MAX_RECORDS,
       is_map(Posts) ->
    case Version =:= ecai_terms:version() of
        true -> validate_segment_payload(Docs, Posts), S;
        false -> ecai_private_policy:fail(private_terms_version_mismatch)
    end;
checked_segment(_) -> ecai_private_policy:fail(invalid_private_segment).

validate_segment_payload(Docs, Posts) ->
    try
        Count = map_size(Docs),
        true = lists:sort(maps:keys(Docs)) =:= lists:seq(1, Count),
        maps:foreach(fun(_N, Doc) ->
            true = normalize_record(Doc) =:= Doc
        end, Docs),
        maps:foreach(fun(Term, Ids) ->
            true = is_binary(Term) andalso byte_size(Term) > 0 andalso
                   byte_size(Term) =< 8192,
            true = is_list(Ids) andalso length(Ids) =< Count,
            true = lists:all(fun(N) -> is_integer(N) andalso
                                      N > 0 andalso N =< Count end, Ids)
        end, Posts)
    catch _:_ -> ecai_private_policy:fail(invalid_private_segment) end.

segment_matches(Id, #{documents := Docs, postings := Posts}, Terms) ->
    Scores = lists:foldl(fun(Term, Acc0) ->
        lists:foldl(fun(N, Acc) ->
            maps:update_with(N, fun(S) -> S + 1 end, 1, Acc)
        end, Acc0, lists:usort(maps:get(Term, Posts, [])))
    end, #{}, Terms),
    [begin
        Doc = maps:get(N, Docs),
        Reference = <<Id/binary, ":", (integer_to_binary(N))/binary>>,
        Doc#{id => Reference, score => Score}
     end || {N, Score} <- maps:to_list(Scores)].

take_best(Sources, Limit) ->
    lists:sublist(lists:sort(fun(A, B) ->
        {-maps:get(score, A), maps:get(id, A)} <
        {-maps:get(score, B), maps:get(id, B)}
    end, Sources), Limit).

parse_reference(Ref) when is_binary(Ref), byte_size(Ref) =< 40 ->
    case binary:split(Ref, <<":">>, [global]) of
        [Id, Number] ->
            ecai_private_policy:guard(ecai_private_store:valid_batch_id(Id)),
            N = binary_to_integer(Number),
            ecai_private_policy:guard(N > 0 andalso N =< ?MAX_RECORDS),
            {Id, N};
        _ -> ecai_private_policy:fail(invalid_reference)
    end;
parse_reference(_) -> ecai_private_policy:fail(invalid_reference).

%% Closed schema, with atom/binary-key compatibility. Never intern request
%% keys and never persist private-key, password, function or endpoint fields.
%% Unknown fields are rejected rather than silently losing source data.
normalize_record(Record) when is_map(Record) ->
    ecai_private_policy:guard(erlang:external_size(Record) =< ?MAX_RECORD_BYTES),
    Fields = [cid, title, heading, text, tags, type, ts, name, category, city,
              phone, abstract, language, wikidata_id, source_key, source_version,
              chunk_ordinal, chunk_byte_start, chunk_byte_end, chunker,
              event_schema, event_operation, event_pipeline, chunk_content_sha256,
              index_fields_sha256, chunk_id, event_id],
    Keys = Fields ++ [atom_to_binary(K, utf8) || K <- Fields],
    ecai_private_policy:guard(lists:all(fun(K) -> lists:member(K, Keys) end,
                                      maps:keys(Record))),
    maps:fold(fun(Key, Value, Acc) ->
        Canonical = case is_atom(Key) of
            true -> Key;
            false -> hd([F || F <- Fields, atom_to_binary(F, utf8) =:= Key])
        end,
        %% Ambiguous duplicate spellings are an error, not last-key-wins.
        ecai_private_policy:guard(not maps:is_key(Canonical, Acc)),
        Acc#{Canonical => normalize_value(Canonical, Value)}
    end, #{}, Record);
normalize_record(_) -> ecai_private_policy:fail(invalid_record).

normalize_value(tags, Tags) when is_list(Tags), length(Tags) =< 256 ->
    [text(T) || T <- Tags];
normalize_value(Key, N) when is_integer(N), N >= 0,
    (Key =:= ts orelse Key =:= chunk_ordinal orelse
     Key =:= chunk_byte_start orelse Key =:= chunk_byte_end) -> N;
%% These existing ingest fields are opaque binary commitments, not UTF-8.
normalize_value(Key, B) when is_binary(B), byte_size(B) =< 256,
    (Key =:= chunk_content_sha256 orelse Key =:= index_fields_sha256 orelse
     Key =:= chunk_id orelse Key =:= event_id) -> B;
normalize_value(_, Value) -> text(Value).

text(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> Bin;
        _ -> ecai_private_policy:fail(invalid_utf8)
    end;
text(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        B when is_binary(B) -> B;
        _ -> ecai_private_policy:fail(invalid_utf8)
    end;
text(A) when is_atom(A), A =/= undefined, A =/= null -> atom_to_binary(A, utf8);
text(_) -> ecai_private_policy:fail(invalid_record_value).
