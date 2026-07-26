%%--------------------------------------------------------------------
%% Operator-friendly search facade for the Wikimedia visibility index.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_search).

-export([search/1, search/2, search/3, status/0]).

-define(DEFAULT_LIMIT, 20).
-define(MAX_LIMIT, 200).

-spec search(binary() | list() | map()) -> {ok, map()} | {error, term()}.
search(Query) ->
    search(Query, #{}).

-spec search(binary() | list() | map(), map() | pos_integer()) ->
    {ok, map()} | {error, term()}.
search(Query, Limit) when is_integer(Limit) ->
    search(Query, #{limit => Limit});
search(Query, Opts) when is_map(Opts) ->
    try ecai_search_server:get_ctx() of
        undefined -> {error, search_index_not_ready};
        Ctx -> search(Ctx, Query, Opts)
    catch
        Class:Reason -> {error, {search_context_failed, Class, Reason}}
    end;
search(_Query, _Opts) ->
    {error, badarg}.

-spec search(term(), binary() | list() | map(), map()) ->
    {ok, map()} | {error, term()}.
search(Ctx, Query0, Opts) when is_map(Opts) ->
    try
        Query = normalize_query(Query0),
        NormalizedOpts = normalize_options(Opts),
        Limit = bounded_limit(maps:get(limit, NormalizedOpts, ?DEFAULT_LIMIT)),
        FetchLimit = erlang:min(?MAX_LIMIT * 5, erlang:max(Limit * 5, Limit)),
        SearchMap = search_map(Query, NormalizedOpts),
        {Results0, Proofs} = ecai_search:search(Ctx, SearchMap, FetchLimit),
        FilteredResults = [
            Result
         || Result <- Results0,
            matches_filters(Result, NormalizedOpts)
        ],
        MatchedEntityCount = distinct_entity_count(FilteredResults),
        EntityResults = deduplicate_entities(
            FilteredResults,
            maps:get(dedupe_entities, NormalizedOpts, true)
        ),
        Results = lists:sublist(EntityResults, Limit),
        {ok, #{
            query => Query,
            count => length(Results),
            matched_documents => length(FilteredResults),
            matched_entities => MatchedEntityCount,
            results => Results,
            proofs => Proofs,
            filters => maps:with(
                [
                    language,
                    min_pageviews,
                    wikidata_only,
                    max_visibility_rank,
                    dedupe_entities
                ],
                NormalizedOpts
            )
        }}
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace -> {error, {wikimedia_search_failed, Class, Reason, Stacktrace}}
    end;
search(_Ctx, _Query, _Opts) ->
    {error, badarg}.

-spec status() -> map().
status() ->
    try ecai_search_server:get_ctx() of
        undefined -> #{ready => false, reason => search_index_not_ready};
        Ctx -> #{ready => true, size => ecai_search:size(Ctx)}
    catch
        Class:Reason -> #{ready => false, reason => {Class, Reason}}
    end.

normalize_options(Opts) ->
    #{
        limit => option_value(Opts, [limit], ?DEFAULT_LIMIT),
        prefix => option_value(Opts, [prefix], true),
        language => option_value(Opts, [language], undefined),
        wikidata_id => option_value(Opts, [wikidata_id], undefined),
        min_pageviews => option_value(
            Opts,
            [min_pageviews, minimum_pageviews],
            0
        ),
        max_visibility_rank => option_value(
            Opts,
            [max_visibility_rank, maximum_rank],
            undefined
        ),
        wikidata_only => boolean_option(
            option_value(
                Opts,
                [wikidata_only, has_wikidata],
                false
            )
        ),
        dedupe_entities => boolean_option(
            option_value(
                Opts,
                [dedupe_entities, deduplicate_entities],
                true
            )
        )
    }.

option_value(_Opts, [], Default) ->
    Default;
option_value(Opts, [Key | Rest], Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} ->
            Value;
        error ->
            case maps:find(atom_to_binary(Key, utf8), Opts) of
                {ok, Value} -> Value;
                error -> option_value(Opts, Rest, Default)
            end
    end.

search_map(Query, Opts) ->
    Base = #{
        name => Query,
        title => Query,
        abstract => Query,
        prefix => maps:get(prefix, Opts, true)
    },
    Base1 =
        case maps:get(language, Opts, undefined) of
            undefined -> Base;
            Language -> Base#{language => to_binary(Language)}
        end,
    case maps:get(wikidata_id, Opts, undefined) of
        undefined -> Base1;
        Wikidata -> Base1#{wikidata_id => to_binary(Wikidata)}
    end.

matches_filters(Result, Opts) ->
    Record = maps:get(record, Result, #{}),
    language_matches(Record, maps:get(language, Opts, undefined)) andalso
        minimum_matches(Record, pageviews, maps:get(min_pageviews, Opts, 0)) andalso
        maximum_rank_matches(Record, maps:get(max_visibility_rank, Opts, undefined)) andalso
        wikidata_matches(Record, maps:get(wikidata_only, Opts, false)).

language_matches(_Record, undefined) -> true;
language_matches(Record, Expected0) -> maps:get(language, Record, <<>>) =:= to_binary(Expected0).

minimum_matches(Record, Key, Minimum) when is_integer(Minimum), Minimum >= 0 ->
    numeric_value(maps:get(Key, Record, 0)) >= Minimum;
minimum_matches(_Record, _Key, _Minimum) ->
    true.

maximum_rank_matches(_Record, undefined) ->
    true;
maximum_rank_matches(Record, Maximum) when is_integer(Maximum), Maximum > 0 ->
    Rank = numeric_value(maps:get(visibility_rank, Record, 0)),
    Rank > 0 andalso Rank =< Maximum;
maximum_rank_matches(_Record, _Maximum) ->
    true.

wikidata_matches(_Record, false) -> true;
wikidata_matches(Record, true) -> maps:get(wikidata_id, Record, <<>>) =/= <<>>;
wikidata_matches(_Record, _Other) -> true.

%% Wikimedia stores one document per language while Wikidata identifies the
%% shared entity. By default, search returns one representative document for
%% each non-empty Wikidata ID so multilingual variants do not dominate the
%% result list. Operators can set dedupe_entities=false to return every
%% language-specific document.
deduplicate_entities(Results, false) ->
    Results;
deduplicate_entities(Results, true) ->
    {_NextPosition, Groups} = lists:foldl(
        fun(Result, {Position, Acc0}) ->
            Key = entity_key(Result),
            Acc1 =
                case maps:find(Key, Acc0) of
                    error ->
                        Acc0#{Key => {Position, Result}};
                    {ok, {FirstPosition, Current}} ->
                        Preferred = preferred_entity_result(Result, Current),
                        Acc0#{Key => {FirstPosition, Preferred}}
                end,
            {Position + 1, Acc1}
        end,
        {1, #{}},
        Results
    ),
    [
        Result
     || {_Position, Result} <- lists:keysort(1, maps:values(Groups))
    ];
deduplicate_entities(_Results, _Invalid) ->
    erlang:error(badarg).

distinct_entity_count(Results) ->
    maps:size(
        lists:foldl(
            fun(Result, Acc) ->
                Key = entity_key(Result),
                Acc#{Key => true}
            end,
            #{},
            Results
        )
    ).

entity_key(Result) ->
    Record = maps:get(record, Result, #{}),
    case identity_binary(maps:get(wikidata_id, Record, <<>>)) of
        <<>> -> {document, identity_binary(maps:get(doc_id, Result, <<>>))};
        WikidataId -> {wikidata, WikidataId}
    end.

preferred_entity_result(Candidate, Current) ->
    case representative_key(Candidate) < representative_key(Current) of
        true -> Candidate;
        false -> Current
    end.

%% Lower visibility rank is better. Missing ranks sort after ranked records.
%% Ties prefer higher pageviews, then higher text-search score, then stable
%% language and document identifiers.
representative_key(Result) ->
    Record = maps:get(record, Result, #{}),
    Rank0 = numeric_value(maps:get(visibility_rank, Record, 0)),
    Rank =
        case Rank0 > 0 of
            true -> Rank0;
            false -> 16#7FFFFFFFFFFFFFFF
        end,
    Pageviews = numeric_value(maps:get(pageviews, Record, 0)),
    Score = numeric_score(maps:get(score, Result, 0.0)),
    Language = identity_binary(maps:get(language, Record, <<>>)),
    DocId = identity_binary(maps:get(doc_id, Result, <<>>)),
    {Rank, -Pageviews, -Score, Language, DocId}.

numeric_score(Value) when is_integer(Value) -> float(Value);
numeric_score(Value) when is_float(Value) -> Value;
numeric_score(Bin) when is_binary(Bin) ->
    try binary_to_float(Bin) of
        Float -> Float
    catch
        error:badarg -> float(numeric_value(Bin))
    end;
numeric_score(_Other) ->
    0.0.

identity_binary(Bin) when is_binary(Bin) -> Bin;
identity_binary(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end;
identity_binary(Int) when is_integer(Int) -> integer_to_binary(Int);
identity_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
identity_binary(_Other) ->
    <<>>.

boolean_option(true) -> true;
boolean_option(false) -> false;
boolean_option(<<"true">>) -> true;
boolean_option(<<"false">>) -> false;
boolean_option("true") -> true;
boolean_option("false") -> false;
boolean_option(_Other) -> erlang:error(badarg).

normalize_query(Map) when is_map(Map) ->
    case maps:get(query, Map, maps:get(<<"query">>, Map, undefined)) of
        undefined -> erlang:error(badarg);
        Value -> normalize_query(Value)
    end;
normalize_query(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
normalize_query(List) when is_list(List), List =/= [] ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
        _ -> erlang:error(badarg)
    end;
normalize_query(_Other) ->
    erlang:error(badarg).

bounded_limit(Value) when is_integer(Value), Value > 0 -> erlang:min(Value, ?MAX_LIMIT);
bounded_limit(_Value) -> ?DEFAULT_LIMIT.

numeric_value(Value) when is_integer(Value) -> Value;
numeric_value(Value) when is_float(Value) -> trunc(Value);
numeric_value(Bin) when is_binary(Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> 0
    end;
numeric_value(_Other) ->
    0.

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(_Other) -> erlang:error(badarg).
