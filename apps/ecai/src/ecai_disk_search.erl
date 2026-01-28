%%--------------------------------------------------------------------
%% ecai_disk_search.erl
%% Query postings via hot cache + disk segments
%%--------------------------------------------------------------------
-module(ecai_disk_search).
-export([term_postings/3]).

term_postings(BaseDir, HotTab, Term) ->
    case ecai_hot_terms:get(HotTab, Term) of
        {ok, Docs} ->
            Docs;
        not_found ->
            Segs = ecai_disk_manifest:list_segments(BaseDir),
            Docs = merge(Segs, Term, []),
            case length(Docs) >= 30 of
                true -> ecai_hot_terms:put(HotTab, Term, Docs);
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
