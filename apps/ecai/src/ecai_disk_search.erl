%%--------------------------------------------------------------------
%% ecai_disk_search.erl
%% Query postings via hot cache + disk segments
%%--------------------------------------------------------------------
-module(ecai_disk_search).
-export([term_postings/3, text_search/4]).

term_postings(BaseDir, HotTab, Term) ->
    ok = ecai_private_store:assert_public(BaseDir),
    Segs = ecai_disk_manifest:list_segments(BaseDir),
    CacheKey = {filename:absname(BaseDir), crypto:hash(sha256, term_to_binary(Segs)), Term},
    case ecai_hot_terms:get(HotTab, CacheKey) of
        {ok, Docs} ->
            Docs;
        not_found ->
            Docs = merge(Segs, Term, []),
            case length(Docs) >= 30 of
                true -> ecai_hot_terms:put(HotTab, CacheKey, Docs);
                false -> ok
            end,
            Docs
    end.

merge([], _T, Acc) ->
    lists:usort(Acc);
merge([P | Rest], T, Acc) ->
    {ok, Seg} = ecai_disk_segment:open(P),
    Docs = ecai_disk_segment:get_postings(Seg, T),
    ok = ecai_disk_segment:close(Seg),
    merge(Rest, T, Docs ++ Acc).

%% One manifest view, one segment dictionary resident at a time. Preserve
%% cross-segment AND semantics by unioning postings per query token first.
text_search(BaseDir, Query, K, Mode) ->
    ok = ecai_private_store:assert_public(BaseDir),
    case filelib:is_regular(filename:join([BaseDir, "docstore", "ecai_docstore.dets"])) of
        false -> erlang:error(index_not_ready);
        true ->
            {ok, Plan} = ecai_text_query:plan(Query, Mode),
            Paths = ecai_disk_manifest:list_segments(BaseDir),
            {Matches, Meta0} = search_segments(lists:sublist(Paths,128), Plan, [], undefined),
            Meta = case length(Paths) > 128 of
                true -> ecai_text_query:merge_meta(Meta0,
                    #{truncated => true, reasons => [segment_limit]});
                false -> Meta0
            end,
            Scores = ecai_text_query:intersect(Matches),
            {ok, DocTab} = ecai_disk_docstore:open(BaseDir),
            try
                Hits = [#{doc_id => Id, score => Score, record => R#{docint => Id}}
                    || {Id, Score} <- ecai_text_query:top(Scores, K),
                       {ok, R} <- [ecai_disk_docstore:get(DocTab, Id)]],
                {Hits, Meta}
            after ecai_disk_docstore:close(DocTab) end
    end.

search_segments([], _Plan, Acc, undefined) -> {Acc,#{truncated => false}};
search_segments([], _Plan, Acc, Meta) -> {Acc,Meta};
search_segments([Path|Rest], Plan, Acc, Meta0) ->
    Exhausted = case Meta0 of
        undefined -> false;
        _ -> maps:get(postings_read,Meta0) >= maps:get(max_postings,maps:get(limits,Meta0))
    end,
    case Exhausted of
        true -> {Acc,ecai_text_query:merge_meta(Meta0,
                    #{truncated => true,reasons => [postings_budget]})};
        false ->
            {ok,Seg} = ecai_disk_segment:open(Path),
            {GroupMatches, Meta} = try
                ecai_text_query:run_groups(Plan,
                    fun(T,Cap) -> ecai_disk_segment:get_postings(Seg,T,Cap) end,
                    fun(P,Cap) -> ecai_disk_segment:prefix_terms(Seg,P,Cap) end,Meta0)
            after ecai_disk_segment:close(Seg) end,
            search_segments(Rest, Plan, ecai_text_query:merge_groups(Acc,GroupMatches), Meta)
    end.
