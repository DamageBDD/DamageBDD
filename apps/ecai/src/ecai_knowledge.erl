%% Unified, bounded retrieval over public indexes and caller-owned funded jobs.
%% All filesystem paths are operator configuration; clients supply logical IDs.
%% Reads never enqueue jobs, fetch remote URLs, pay invoices or submit NFTs.
-module(ecai_knowledge).
-export([search/1, search/2, source/2, context/3, status/1, disk_indexes/0]).

search(Query) -> search(Query, #{}).
search(Query, Opts) when is_binary(Query), byte_size(Query) > 0,
    byte_size(Query) =< 4096, is_map(Opts) ->
    K = limit(maps:get(limit, Opts, 10)),
    Principal = maps:get(principal, Opts, undefined),
    Calls = [
        {<<"shared">>, fun() -> shared(Query, K) end},
        {<<"wikimedia">>, fun() -> wiki(Query, K) end}
    ] ++ [{maps:get(id,D), fun() -> disk(D,Query,K) end} || D <- disk_indexes()] ++
        [{pool_id(M), fun() -> pool_search(M, Query, K) end} || M <- pool_views(Principal)],
    %% Each backend executes in a monitored request worker: timeouts kill the
    %% caller and release its ETS tables / DETS opens. They do not cancel jobs.
    {Groups, States} = lists:unzip([backend(Id, F) || {Id, F} <- Calls]),
    Hits = fuse(Groups, K),
    {ok, #{results => Hits, count => length(Hits), backends => States,
           ranking => reciprocal_rank_fusion, consistency => published_or_live_preview,
           partial => lists:any(fun(S) -> maps:get(state,S) =/= ready end, States)}};
search(_, _) -> {error, invalid_query}.

context(Principal, Query, K) ->
    case search(Query, #{principal => Principal, limit => K}) of
        {ok, #{results := Hits}} ->
            [(maps:get(record,H))#{source_ref => maps:get(source_ref,H),
                retrieval_live => maps:get(live,H,false), retrieval_index => maps:get(index,H)} || H <- Hits];
        _ -> []
    end.

%% Ref is the object returned with a search hit. SHA-256 pins the returned
%% version when a live document ID is replaced between search and retrieval.
source(#{index := Id, doc_id := DocId} = Ref, Principal) when is_binary(Id) ->
    Result = try source_lookup(Id, DocId, Ref, Principal)
        catch Class:Why -> {error, {source_lookup_failed, Class, Why}} end,
    case {Result, maps:get(sha256,Ref,undefined)} of
        {{ok, Source}, Expected} when is_binary(Expected) ->
            case maps:get(sha256,Source,undefined) =:= Expected of
                true -> {ok, Source};
                false -> {error, source_version_changed}
            end;
        _ -> Result
    end;
source(_, _) -> {error, invalid_source_reference}.

source_lookup(<<"wikimedia">>, DocId, _Ref, _Principal) ->
    ecai_wikimedia_search_server:source(DocId);
source_lookup(<<"shared">>, DocId, _Ref, _Principal) ->
    Ctx = gen_server:call(ecai_search_server, get_ctx, 2000),
    ecai_search:source(Ctx, DocId);
source_lookup(<<"pool:", _/binary>> = Id, DocId, Ref, Principal) ->
    case [M || M <- pool_views(Principal), pool_id(M) =:= Id] of
        [M] -> ecai_index_shards:source(maps:get(path,M), maps:get(shard_ordinal,Ref), DocId);
        _ -> {error, source_not_found}
    end;
source_lookup(Id, DocId, _Ref, _Principal) ->
    case [D || D <- disk_indexes(), maps:get(id,D) =:= Id] of
        [D] -> ecai_source_retrieval:disk(maps:get(dir,D), DocId);
        _ -> {error, source_not_found}
    end.

status(Principal) ->
    #{public_disk_indexes => [maps:without([dir],D) || D <- disk_indexes()],
      owned_funded_indexes => [maps:without([path], M) || M <- pool_views(Principal)],
      shared_running => is_pid(whereis(ecai_search_server)),
      wikimedia_running => is_pid(whereis(ecai_wikimedia_search_server)),
      cloud_dispatch => pending, mint_submission => pending}.

disk_indexes() ->
    Default = [#{id => <<"public-ipfs">>, dir => ecai_paths:ipfs_index_dir()}],
    Values = application:get_env(ecai, knowledge_disk_indexes, Default),
    [#{id => Id, dir => ecai_paths:normalize(Dir)} || #{id := Id, dir := Dir} <- Values,
        is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 128,
        Id =/= <<"shared">>, Id =/= <<"wikimedia">>,
        not (byte_size(Id) >= 5 andalso binary:part(Id,0,5) =:= <<"pool:">>)].

shared(Query,K) ->
    Ctx = gen_server:call(ecai_search_server, get_ctx, 2000),
    {Hits,_} = ecai_search:search(Ctx, query_map(Query), K, #{include_proofs => false}),
    decorate(Hits, <<"shared">>, true, false).
wiki(Query,K) ->
    {ok, Response} = gen_server:call(ecai_wikimedia_search_server,
        {search, Query, #{limit => K, include_proofs => false}}, 5000),
    decorate(maps:get(results,Response), <<"wikimedia">>,
             maps:get(live,Response,false), maps:get(final,Response,false)).
disk(#{id := Id, dir := Dir}, Query, K) ->
    Records = ecai_ollama_rag:retrieve_sources_lexical(Dir, Query, K),
    [hit(#{doc_id => maps:get(docint,R), record => R}, Id, true, false) || R <- Records].
pool_search(M, Query, K) ->
    {ok, Response} = ecai_index_shards:search(maps:get(path,M),query_map(Query),K,#{include_proofs => false}),
    decorate(maps:get(results,Response),pool_id(M),maps:get(live,M,true),maps:get(final,M,false)).
pool_views(Principal) ->
    try ecai_index_pool:knowledge_manifests(Principal) of
        Ms when is_list(Ms) -> Ms
    catch _:_ -> [] end.
pool_id(M) -> <<"pool:", (maps:get(pool_id,M))/binary>>.
query_map(Q) -> #{name => Q, title => Q, heading => Q, text => Q, abstract => Q,
                  category => Q, city => Q, tags => [Q], phone => Q, prefix => false}.

decorate(Hits, Id, Live, Final) -> [hit(H,Id,Live,Final) || H <- Hits].
hit(H, Id, Live, Final) ->
    Raw = maps:get(record,H,#{}),
    Record = maps:map(fun(Key,V) ->
        case (Key =:= text orelse Key =:= abstract) andalso is_binary(V) of
            true -> clip(V,2048);
            false -> V
        end
    end, ecai_source_retrieval:summary(Raw)),
    Desc = ecai_source_retrieval:describe(Raw),
    Ref = maps:merge(maps:with([sha256],Desc),maps:with([shard_ordinal],H)),
    H#{record => Record, index => Id, live => Live, final => Final,
       source_ref => Ref#{index => Id, doc_id => maps:get(doc_id,H)}}.

backend(Id, Fun) ->
    Ref = make_ref(), Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try {ok, Fun()} catch _:_ -> {error, unavailable} end,
        Parent ! {Ref, Result}
    end),
    Timeout = application:get_env(ecai, knowledge_backend_timeout_ms, 5000),
    receive
        {Ref, {ok, Hits}} -> erlang:demonitor(Mon,[flush]),
            {Hits, #{id => Id, state => ready, returned => length(Hits)}};
        {Ref, {error, Why}} -> erlang:demonitor(Mon,[flush]),
            {[], #{id => Id, state => unavailable, reason => Why}};
        {'DOWN', Mon, process, Pid, _} ->
            {[], #{id => Id, state => unavailable}}
    after Timeout ->
        exit(Pid,kill),
        receive {'DOWN',Mon,process,Pid,_} -> ok end,
        receive {Ref,_Late} -> ok after 0 -> ok end,
        {[],#{id => Id,state => timeout}}
    end.

%% Scores from independent corpora have incompatible IDF scales. Fuse ranks,
%% keep deterministic ties and return the source locator from one real hit.
fuse(Groups,K) ->
    Combined = lists:foldl(fun(Group,Acc0) ->
        lists:foldl(fun({H,Rank},Acc) ->
            Key = hit_key(H), Weight = 1.0/(60+Rank),
            case maps:find(Key,Acc) of
                {ok,{OldScore,Old}} -> Acc#{Key => {OldScore+Weight,Old}};
                error -> Acc#{Key => {Weight,H}}
            end
        end,Acc0,lists:zip(Group,lists:seq(1,length(Group))))
    end,#{},Groups),
    Sorted = lists:sort(fun({A,{SA,_}},{B,{SB,_}}) -> {-SA,A} < {-SB,B} end,maps:to_list(Combined)),
    [H#{fusion_score => Score} || {_,{Score,H}} <- lists:sublist(Sorted,K)].
hit_key(H) ->
    R = maps:get(record,H),
    case maps:get(url,R,maps:get(link,R,<<>>)) of
        Url when is_binary(Url), byte_size(Url)>0 -> {url,Url,maps:get(sha256,maps:get(source_ref,H),undefined)};
        _ -> {maps:get(index,H),maps:get(shard_ordinal,H,undefined),maps:get(doc_id,H)}
    end.
limit(N) when is_integer(N), N>0, N=<100 -> N;
limit(_) -> 10.
clip(B,N) when byte_size(B)=<N -> B;
clip(B,N) ->
    Part = binary:part(B,0,N),
    case unicode:characters_to_binary(Part) of
        V when is_binary(V) -> V;
        {incomplete,V,_} -> V;
        {error,V,_} -> V
    end.
