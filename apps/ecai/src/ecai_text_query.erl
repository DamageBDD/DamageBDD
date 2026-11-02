%% Bounded AND / final-token-prefix retrieval over EXISTING exact postings.
%% This is query policy, not a new term pipeline or a proof/index format.
-module(ecai_text_query).
-export([plan/2, run/3, run_groups/4, intersect/1, merge_groups/2, top/2, ets_terms/3, ets_docs/3, merge_meta/2]).

-define(FIELDS, [{<<"name">>, 3}, {<<"title">>, 3}, {<<"heading">>, 2},
                 {<<"text">>, 1}, {<<"abstract">>, 1}, {<<"city">>, 2},
                 {<<"cat">>, 2}, {<<"tag">>, 1}, {<<"phone">>, 4},
                 {<<"type">>, 1}, {<<"language">>, 1}, {<<"wikidata">>, 2}]).
-define(PREFIX_FIELDS, [<<"name">>, <<"title">>, <<"heading">>,
                        <<"text">>, <<"abstract">>, <<"city">>]).

-spec plan(binary(), bool_prefix | exact) -> {ok, map()} | {error, atom()}.
plan(Q, Mode) when is_binary(Q), byte_size(Q) > 0, byte_size(Q) =< 4096,
                   (Mode =:= bool_prefix orelse Mode =:= exact) ->
    try
        Chars = unicode:characters_to_list(Q),
        true = is_list(Chars),
        Tokens = ecai_tokenizer:tokens(Q),
        case length(Tokens) of
            0 -> {error, invalid_query};
            N when N > 16 -> {error, too_many_query_terms};
            N ->
                Last = lists:last(Tokens),
                %% Reuse the canonical tokenizer's delimiter set. A trailing
                %% space/punctuation completes the last word; never trim Q.
                EndsInWord = ecai_tokenizer:tokens([lists:last(Chars)]) =/= [],
                Prefix = Mode =:= bool_prefix andalso EndsInWord andalso
                    length(unicode:characters_to_list(Last)) >= 2,
                Groups = case Prefix of
                    true -> [{T, exact} || T <- lists:usort(lists:sublist(Tokens, N-1))]
                            ++ [{Last, prefix}];
                    false -> [{T, exact} || T <- lists:usort(Tokens)]
                end,
                {ok, #{matching => Mode, groups => Groups, last_token_prefix => Prefix}}
        end
    catch _:_ -> {error, invalid_query} end;
plan(_, Mode) when Mode =/= bool_prefix, Mode =/= exact -> {error, invalid_matching};
plan(_, _) -> {error, invalid_query}.

%% Lookup(Term,MaxDocs) and Expand(Prefix,MaxTerms) both return {Items,Truncated}.
%% Completed words are ANDed before top-k. Alternatives within a field/token
%% are ORed. Prefix queries never emit all shorter prefixes of the typed word.
-spec run(map(), function(), function()) -> {map(), map()}.
run(Plan, Lookup, Expand) ->
    {Matches, Meta} = run_groups(Plan, Lookup, Expand, undefined),
    {intersect(Matches), Meta}.

%% Disk callers carry the same budget across segments, union each token's
%% matches, then intersect. Only one segment dictionary needs to be resident.
run_groups(Plan, Lookup, Expand, Previous) ->
    State = case Previous of
        undefined -> #{postings_read => 0, expanded_terms => 0,
                       reasons => [], limits => limits()};
        _ -> Previous
    end,
    {Matches, Final} = groups(maps:get(groups, Plan), [], State, Lookup, Expand),
    Meta = maps:with([postings_read, expanded_terms, reasons, limits], Final),
    {Matches, Meta#{truncated => maps:get(reasons, Final) =/= [],
                   matching => maps:get(matching, Plan),
                   last_token_prefix => maps:get(last_token_prefix, Plan)}}.

groups([], Acc, S, _, _) -> {lists:reverse(Acc), S};
groups([{Token, Kind} | Rest], Acc0, S0, Lookup, Expand) ->
    {Exact, S1} = lists:foldl(fun({Field, Weight}, {Acc, S}) ->
        lookup(<<Field/binary, ":", Token/binary>>, 100 + Weight, Acc, S, Lookup)
    end, {#{}, S0}, ?FIELDS),
    {Matches, S2} = case Kind of
        exact -> {Exact, S1};
        prefix -> lists:foldl(fun({Field, Weight}, {Acc, S}) ->
            case lists:member(Field, ?PREFIX_FIELDS) of
                false -> {Acc, S};
                true ->
                    Prefix = <<Field/binary, ":", Token/binary>>,
                    Cap = maps:get(max_expansions_per_field, maps:get(limits, S)),
                    {Terms, Cut} = Expand(Prefix, Cap),
                    S3 = flag(Cut, expansion_limit, S#{expanded_terms :=
                        maps:get(expanded_terms, S) + length(Terms)}),
                    lists:foldl(fun(T, {A, St}) ->
                        %% The complete token already had its stronger score.
                        case T =:= Prefix of
                            true -> {A, St};
                            false -> lookup(T, 50 + Weight, A, St, Lookup)
                        end
                    end, {Acc, S3}, Terms)
            end
        end, {Exact, S1}, ?FIELDS)
    end,
    groups(Rest, [Matches|Acc0], S2, Lookup, Expand).

intersect([]) -> #{};
intersect(Matches) ->
    [Smallest|Rest] = lists:sort(fun(A,B) -> map_size(A) =< map_size(B) end, Matches),
    lists:foldl(fun(M, Previous) ->
        maps:fold(fun(Id, Score, Acc) ->
            case maps:find(Id,M) of
                {ok,More} -> Acc#{Id => Score + More};
                error -> Acc
            end
        end, #{}, Previous)
    end, Smallest, Rest).

merge_groups([], B) -> B;
merge_groups(A, B) ->
    lists:zipwith(fun(M, N) ->
        maps:fold(fun(Id,Score,Acc) ->
            Acc#{Id => erlang:max(Score,maps:get(Id,Acc,0))}
        end, M, N)
    end, A, B).

lookup(Term, Weight, Acc, S, Lookup) ->
    Limits = maps:get(limits, S),
    Left = maps:get(max_postings, Limits) - maps:get(postings_read, S),
    case Left =< 0 of
        true -> {Acc, flag(true, postings_budget, S)};
        false ->
            Cap = erlang:min(Left, maps:get(max_postings_per_term, Limits)),
            {Docs, Cut} = Lookup(Term, Cap),
            S1 = flag(Cut, postings_limit, S#{postings_read :=
                maps:get(postings_read, S) + length(Docs)}),
            {lists:foldl(fun(Id, A) ->
                A#{Id => erlang:max(Weight, maps:get(Id, A, 0))}
            end, Acc, Docs), S1}
    end.

flag(false, _, S) -> S;
flag(true, Reason, S) -> S#{reasons := lists:usort([Reason | maps:get(reasons, S)])}.

limits() ->
    %% Operator config is a proplist. No HTTP request can raise these bounds.
    Config = application:get_env(ecai, knowledge_search_limits, []),
    maps:from_list([{K, bounded_limit(K, Default, Config)} || {K, Default} <- [
        {max_expansions_per_field, 128}, {max_postings_per_term, 10000},
        {max_postings, 50000}] ]).
bounded_limit(K, Default, Config) when is_list(Config) ->
    case proplists:get_value(K, Config, Default) of
        V when is_integer(V), V > 0, V =< Default -> V;
        _ -> Default
    end;
bounded_limit(_, Default, _) -> Default.

top(Scores, K) ->
    lists:sublist(lists:sort(fun({I,A}, {J,B}) -> {-A,I} < {-B,J} end,
                              maps:to_list(Scores)), K).

%% Live and loaded snapshots already have ordered {{Term,DocInt},true} keys.
%% Seek directly to the prefix, and skip all IDs for each distinct term.
%% <<>> sorts AFTER every integer, so it is an upper sentinel for DocInt.
ets_terms(Tab, Prefix, Cap) ->
    ets_terms(Tab, ets:next(Tab, {Prefix, 0}), Prefix, Cap, []).
ets_terms(_Tab, '$end_of_table', _Prefix, _Cap, Acc) -> {lists:reverse(Acc), false};
ets_terms(Tab, {Term, _}, Prefix, Cap, Acc) ->
    case has_prefix(Term, Prefix) of
        false -> {lists:reverse(Acc), false};
        true when Cap =:= 0 -> {lists:reverse(Acc), true};
        true -> ets_terms(Tab, ets:next(Tab, {Term, <<>>}), Prefix, Cap-1, [Term|Acc])
    end.

ets_docs(Tab, Term, Cap) ->
    ets_docs(Tab, ets:next(Tab, {Term, 0}), Term, Cap, []).
ets_docs(_Tab, {Term, _Id}, Term, 0, Acc) -> {lists:reverse(Acc), true};
ets_docs(Tab, {Term, Id} = Key, Term, Cap, Acc) ->
    ets_docs(Tab, ets:next(Tab, Key), Term, Cap-1, [Id|Acc]);
ets_docs(_Tab, _Key, _Term, _Cap, Acc) -> {lists:reverse(Acc), false}.

has_prefix(Bin, Prefix) ->
    N = byte_size(Prefix),
    byte_size(Bin) >= N andalso binary:part(Bin, 0, N) =:= Prefix.

merge_meta(A, B) ->
    Base = maps:merge(A, B),
    Base#{truncated => maps:get(truncated,A,false) orelse maps:get(truncated,B,false),
       reasons => lists:usort(maps:get(reasons,A,[]) ++ maps:get(reasons,B,[])),
       postings_read => maps:get(postings_read,A,0) + maps:get(postings_read,B,0),
       expanded_terms => maps:get(expanded_terms,A,0) + maps:get(expanded_terms,B,0)}.
