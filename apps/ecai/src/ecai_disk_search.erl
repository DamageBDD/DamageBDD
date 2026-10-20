%%--------------------------------------------------------------------
%% ecai_disk_search.erl
%% Query postings via hot cache + disk segments
%%--------------------------------------------------------------------
-module(ecai_disk_search).
-export([term_postings/3]).

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
