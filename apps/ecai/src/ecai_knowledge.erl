%% Unified, bounded retrieval over public indexes and caller-owned funded jobs.
%% All filesystem paths are operator configuration; clients supply logical IDs.
%% Reads never enqueue jobs, fetch remote URLs, pay invoices or submit NFTs.
-module(ecai_knowledge).
-export([search/1, search/2, source/2, context/3, status/1, disk_indexes/0, index_catalog/1, validate_indexes/1]).

search(Query) -> search(Query, #{}).
search(Query, Opts) when is_binary(Query), byte_size(Query) > 0,
    byte_size(Query) =< 4096, is_map(Opts) ->
    Mode = maps:get(matching, Opts, bool_prefix),
    Valid = case Mode of
        legacy -> ok;
        _ -> case ecai_text_query:plan(Query, Mode) of
            {ok, _} -> ok;
            Error -> Error
        end
    end,
    case Valid of
        ok -> do_search(Query, Opts, Mode);
        Error0 -> Error0
    end;
search(_, _) -> {error, invalid_query}.

%% Resolve the caller-visible logical IDs BEFORE creating any query workers.
%% Omission/all is compatible with existing callers; [] deliberately does no work.
do_search(Query, Opts, Mode) ->
    case validate_indexes(maps:get(indexes, Opts, all)) of
        {ok, Selection} ->
            Principal = maps:get(principal, Opts, undefined),
            case search_indexes(Principal, Selection) of
                {ok, Indexes, DiscoveryStates} ->
                    K = limit(maps:get(limit, Opts, 10)),
                    {Groups, QueryStates} = lists:unzip([
                        backend(maps:get(id, I), fun() -> query_index(I, Query, K, Mode) end)
                        || I <- Indexes
                    ]),
                    States = QueryStates ++ DiscoveryStates,
                    Hits = fuse(Groups, K),
                    {ok, #{results => Hits, count => length(Hits), backends => States,
                           matching => Mode,
                           selection => #{mode => selection_mode(Selection),
                               indexes => [maps:get(id, I) || I <- Indexes]},
                           ranking => reciprocal_rank_fusion,
                           consistency => published_or_live_preview,
                           partial => lists:any(fun(S) -> maps:get(state, S) =/= ready end, States)}};
                Error -> Error
            end;
        Error -> Error
    end.

-spec validate_indexes(term()) -> {ok, all | [binary()]} | {error, invalid_index_selection}.
validate_indexes(all) -> {ok, all};
validate_indexes(Ids) when is_list(Ids), length(Ids) =< 128 ->
    case lists:all(fun(Id) -> is_binary(Id) andalso byte_size(Id) > 0 andalso
        byte_size(Id) =< 128 end, Ids) of
        true -> {ok, lists:usort(Ids)};
        false -> {error, invalid_index_selection}
    end;
validate_indexes(_) -> {error, invalid_index_selection}.

selection_mode(all) -> all;
selection_mode(_) -> selected.

public_indexes() ->
    unique_indexes([
        #{id => <<"shared">>, kind => shared},
        #{id => <<"wikimedia">>, kind => wikimedia}
    ] ++ [D#{kind => disk} || D <- disk_indexes()]).

unique_indexes(Indexes) ->
    %% Duplicate configured IDs must never cause a backend to run twice.
    {_Seen, Rev} = lists:foldl(fun(I, {Seen, Acc}) ->
        Id = maps:get(id, I),
        case maps:is_key(Id, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Id => true}, [I | Acc]}
        end
    end, {#{}, []}, Indexes),
    lists:reverse(Rev).

search_indexes(_Principal, []) -> {ok, [], []};
search_indexes(Principal, all) ->
    Public = public_indexes(),
    case funded_indexes(Principal) of
        {ok, Funded} -> {ok, Public ++ Funded, []};
        {error, _} ->
            %% All includes owned funded indexes. A discovery failure must not
            %% pretend that a public-only response searched everything.
            {ok, Public, [#{id => <<"pool:*">>, state => unavailable,
                phase => discovery, reason => funded_indexes_unavailable}]}
    end;
search_indexes(Principal, Ids) ->
    Public = public_indexes(),
    Known = maps:from_list([{maps:get(id, I), true} || I <- Public]),
    case lists:all(fun(Id) -> maps:is_key(Id, Known) orelse is_pool_id(Id) end, Ids) of
        false -> {error, invalid_index_selection};
        true ->
            %% Public-only selection does not even query the funded registry.
            FundedResult = case lists:any(fun is_pool_id/1, Ids) of
                true -> funded_indexes(Principal);
                false -> {ok, []}
            end,
            case FundedResult of
                {ok, Funded} ->
                    Allowed = maps:from_list([{maps:get(id, I), I} || I <- Public ++ Funded]),
                    case lists:all(fun(Id) -> maps:is_key(Id, Allowed) end, Ids) of
                        true -> {ok, [maps:get(Id, Allowed) || Id <- Ids], []};
                        %% Deliberately identical for unknown and unauthorized IDs.
                        false -> {error, invalid_index_selection}
                    end;
                Error -> Error
            end
    end.

is_pool_id(<<"pool:", _/binary>>) -> true;
is_pool_id(_) -> false.

funded_indexes(Principal) when is_binary(Principal), byte_size(Principal) > 0 ->
    try ecai_index_pool:knowledge_manifests(Principal) of
        Ms when is_list(Ms) ->
            {ok, unique_indexes([#{id => pool_id(M), kind => funded, manifest => M} || M <- Ms])};
        _ -> {error, funded_indexes_unavailable}
    catch _:_ -> {error, funded_indexes_unavailable} end;
funded_indexes(_) -> {ok, []}.

query_index(#{kind := shared}, Q, K, Mode) -> shared(Q, K, Mode);
query_index(#{kind := wikimedia}, Q, K, Mode) -> wiki(Q, K, Mode);
query_index(#{kind := disk} = D, Q, K, Mode) -> disk(D, Q, K, Mode);
query_index(#{kind := funded, manifest := M}, Q, K, Mode) -> pool_search(M, Q, K, Mode).

%% Discovery is read-only and advisory: no query, snapshot load, IPFS fetch,
%% indexing job or payment. Whitelist response fields; never return local paths.
index_catalog(Principal) ->
    {ok, Indexes, DiscoveryStates} = search_indexes(Principal, all),
    #{indexes => [catalog_entry(I) || I <- Indexes], default_selection => all,
      partial => DiscoveryStates =/= [], backends => DiscoveryStates}.

catalog_entry(#{id := Id, kind := Kind} = I) ->
    {Label, Description, Scope} = case Kind of
        shared -> {<<"Shared live index">>, <<"Records in the shared in-memory index">>, public};
        wikimedia -> {<<"Wikimedia">>, <<"Indexed Wikimedia articles">>, public};
        disk -> {Id, <<"Published disk segments">>, public};
        funded -> {Id, <<"Your accepted funded shards">>, owner}
    end,
    #{id => Id, label => Label, description => Description, kind => Kind,
      scope => Scope, state => catalog_state(I)}.

catalog_state(#{kind := shared}) -> process_state(ecai_search_server);
catalog_state(#{kind := wikimedia}) -> process_state(ecai_wikimedia_search_server);
catalog_state(#{kind := disk, dir := Dir}) ->
    try
        ok = ecai_private_store:assert_public(Dir),
        file_state(filename:join([Dir, "docstore", "ecai_docstore.dets"]))
    catch _:_ -> unavailable end;
catalog_state(#{kind := funded, manifest := M}) ->
    file_state(maps:get(path, M, undefined)).
process_state(Name) ->
    case is_pid(whereis(Name)) of true -> ready; false -> unavailable end.
file_state(Path) when is_binary(Path); is_list(Path) ->
    case filelib:is_regular(Path) of true -> ready; false -> not_ready end;
file_state(_) -> not_ready.

context(Principal, Query, K) ->
    case search(Query, #{principal => Principal, limit => K, matching => legacy}) of
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

shared(Query,K,Mode) ->
    Ctx = gen_server:call(ecai_search_server, get_ctx, 2000),
    {Hits,Meta} = case Mode of
        legacy ->
            {Hs,_} = ecai_search:search(Ctx, query_map(Query,legacy), K, #{include_proofs => false}),
            {Hs,#{truncated => false}};
        _ -> ecai_search:text_search(Ctx,Query,K,Mode)
    end,
    {decorate(Hits, <<"shared">>, true, false), Meta}.
wiki(Query,K,Mode) ->
    {ok, Response} = gen_server:call(ecai_wikimedia_search_server,
        {search, Query, #{limit => K, include_proofs => false, matching => Mode}}, 5000),
    {decorate(maps:get(results,Response), <<"wikimedia">>,
             maps:get(live,Response,false), maps:get(final,Response,false)),
     maps:get(search_meta,Response,#{truncated => false})}.
disk(#{id := Id, dir := Dir}, Query, K, legacy) ->
    Records = ecai_ollama_rag:retrieve_sources_lexical(Dir, Query, K),
    {[hit(#{doc_id => maps:get(docint,R), record => R}, Id, true, false) || R <- Records],
     #{truncated => false}};
disk(#{id := Id, dir := Dir}, Query, K, Mode) ->
    {Hits,Meta} = ecai_disk_search:text_search(Dir,Query,K,Mode),
    {decorate(Hits,Id,true,false),Meta}.
pool_search(M, Query, K, Mode) ->
    {ok, Response} = ecai_index_shards:search(maps:get(path,M),query_map(Query,Mode),K,#{include_proofs => false}),
    {decorate(maps:get(results,Response),pool_id(M),maps:get(live,M,true),maps:get(final,M,false)),
     maps:get(search_meta,Response,#{truncated => false})}.

pool_views(Principal) ->
    try ecai_index_pool:knowledge_manifests(Principal) of
        Ms when is_list(Ms) -> Ms
    catch _:_ -> [] end.
pool_id(M) -> <<"pool:", (maps:get(pool_id,M))/binary>>.
query_map(Q,Mode) when Mode =:= bool_prefix; Mode =:= exact ->
    #{knowledge_query => Q, matching => Mode};
query_map(Q,legacy) -> #{name => Q, title => Q, heading => Q, text => Q, abstract => Q,
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
        {Ref, {ok, {Hits, Meta}}} -> erlang:demonitor(Mon,[flush]),
            Status = case maps:get(truncated,Meta,false) of true -> limited; false -> ready end,
            {Hits, #{id => Id, state => Status, returned => length(Hits), search => Meta}};
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
