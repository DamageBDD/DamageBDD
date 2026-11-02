%% Deterministic, local-only storage/retrieval benchmark. No cloud / model /
%% IPFS network / Lightning / chain calls. A dedicated NEW output dir is required.
-module(ecai_index_benchmark).
-export([profiles/0, run/2, run/3]).

profiles() ->
    [profile(<<"smoke">>,1,1,16,64,1),
     profile(<<"edge-2g">>,2,2,64,4096,2),
     profile(<<"small-4g">>,2,4,128,4096,4),
     profile(<<"medium-8g">>,4,8,500,4096,8),
     profile(<<"large-16g">>,8,16,1000,4096,16),
     profile(<<"xlarge-32g">>,16,32,2000,4096,32),
     profile(<<"workstation-128g">>,32,128,5000,4096,64)].
profile(Name,Cpu,GiB,Batch,Docs,ShardMiB) ->
    #{name => Name, schedulers => Cpu, memory_gib => GiB, batch_docs => Batch,
      documents => Docs, source_bytes => 2048, flush_interval_ms => 2000,
      query_interval_ms => 200, max_shard_bytes => ShardMiB*1048576}.

run(Profile, OutDir) -> run(Profile,OutDir,#{}).
run(Profile0, OutDir0, Overrides) when is_map(Overrides) ->
    try
        {ok, _} = application:ensure_all_started(crypto),
        Name = to_binary(Profile0),
        [Base] = [P || P <- profiles(), maps:get(name,P) =:= Name],
        %% Resource settings are fixed by profile. Only corpus size may vary.
        true = lists:all(fun(K)->K =:= documents end,maps:keys(Overrides)),
        P = maps:merge(Base,Overrides), N = maps:get(documents,P),
        true = is_integer(N) andalso N>0 andalso N=<100000,
        Out = filename:absname(OutDir0),
        ok = filelib:ensure_dir(filename:join(filename:dirname(Out),"x")),
        ok = file:make_dir(Out), %% Refuse existing directories, never delete one.
        Index = filename:join(Out,"index"),
        ok = filelib:ensure_dir(filename:join(Index,"x")),
        T0 = erlang:monotonic_time(microsecond),
        Parent = self(), Tag = make_ref(),
        {Reader, Monitor} = spawn_monitor(fun() ->
            _ = erlang:monitor(process, Parent),
            probe_loop(Parent,Tag,Index,T0,maps:get(query_interval_ms,P),[],undefined,0,0)
        end),
        try
            {Records,CorpusHash} = build(Index,P),
            T1 = erlang:monotonic_time(microsecond),
            Reader ! {stop,Tag},
            Probe = receive
                {Tag,ProbeResult} -> erlang:demonitor(Monitor,[flush]), ProbeResult;
                {'DOWN',Monitor,process,Reader,DownReason} -> erlang:error({probe_failed,DownReason})
            after 10000 -> erlang:error(probe_timeout) end,
            %% Verify first and last exact source bytes after writer close/reopen.
            VerifyNs = lists:usort([1,N]),
            lists:foreach(fun(I) ->
                {Key,Version,Bytes} = fixture(I,maps:get(source_bytes,P)),
                {ok,#{text := Bytes,complete := true,integrity := verified_sha256}} =
                    ecai_source_retrieval:disk_source(Index,Key,Version)
            end,VerifyNs),
            FinalHits = ecai_ollama_rag:retrieve_sources_lexical(Index,<<"needle1">>,5),
            true = FinalHits =/= [],
            Report = Probe#{schema => <<"ecai-index-benchmark/v1">>, profile => P,
                workload => <<"synthetic-local-source-retention-and-disk-search">>,
                documents => N, records => Records, corpus_sha256 => hex(CorpusHash),
                live_query_observed => is_number(maps:get(first_searchable_ms,Probe)) andalso
                    maps:get(first_searchable_ms,Probe) < (T1-T0)/1000,
                ingest_ms => (T1-T0)/1000, documents_per_second => N*1000000/max(1,T1-T0),
                output_bytes => tree_bytes(Index), roundtrip_samples => length(VerifyNs),
                roundtrip_verified => true, final_query_matches => length(FinalHits),
                otp_release => erlang:system_info(otp_release),
                schedulers_online => erlang:system_info(schedulers_online),
                word_size => erlang:system_info(wordsize),
                machine => erlang:system_info(system_architecture),
                billing_operations => 0, external_network_calls => 0,
                measured_scope => <<"not end-to-end cloud, funded, NFT, or relevance benchmark">>},
            ok = file:write_file(filename:join(Out,"benchmark.json"),
                jsx:encode(ecai_index_job_codec:externalize(Report))),
            {ok,Report}
        after
            exit(Reader,kill), erlang:demonitor(Monitor,[flush])
        end
    catch Class:Why -> {error,{benchmark_failed,Class,Why}} end;
run(_,_,_) -> {error,badarg}.

build(Index,P) ->
    S0 = ecai_disk_indexer:new(Index,#{max_docs => maps:get(batch_docs,P),
        flush_interval_ms => maps:get(flush_interval_ms,P)}),
    try
        {S1,Count,Hash} = lists:foldl(fun(I,{S,C,H}) ->
            {Key,Version,Bytes} = fixture(I,maps:get(source_bytes,P)),
            {ok,Ref} = ecai_source_retrieval:retain(Index,Bytes,Key,Version),
            {ok,Chunks} = ecai_chunker:chunk_utf8(Bytes,1100,140),
            Records = [#{text => maps:get(text,Chunk),title => Key,source_blob => Ref,
                chunk_ordinal => maps:get(ordinal,Chunk)} || Chunk <- Chunks],
            {ecai_disk_indexer:add_records(S,Records), C+length(Records),crypto:hash_update(H,Bytes)}
        end,{S0,0,crypto:hash_init(sha256)},lists:seq(1,maps:get(documents,P))),
        ok = ecai_disk_indexer:close(S1),
        {Count,crypto:hash_final(Hash)}
    catch Class:Why:Stack ->
        _ = ecai_disk_indexer:abort(S0), erlang:raise(Class,Why,Stack)
    end.

fixture(N,Size) ->
    Id = integer_to_binary(N), Key = <<"fixture://",Id/binary>>,
    Head = <<"needle",Id/binary," Deterministic source retention benchmark. ",16#03BB/utf8,"\n">>,
    Unit = <<"alpha beta gamma delta ">>,
    Padding = binary:copy(Unit, Size div byte_size(Unit) + 1),
    Bytes = <<Head/binary,(binary:part(Padding,0,Size-byte_size(Head)))/binary>>,
    {Key,<<"fixture-v1">>,Bytes}.

probe_loop(Parent,Tag,Index,T0,Interval,Latencies,First,Peak,Errors) ->
    receive
        {'DOWN',_,process,Parent,_} -> ok;
        {stop,Tag} ->
            Parent ! {Tag,#{query_samples => length(Latencies),
                query_p50_ms => percentile(Latencies,0.50),query_p95_ms => percentile(Latencies,0.95),
                first_searchable_ms => First, sampled_peak_beam_bytes => Peak,
                query_errors => Errors}}
    after Interval ->
        Start = erlang:monotonic_time(microsecond),
        Result = try ecai_ollama_rag:retrieve_sources_lexical(Index,<<"needle1">>,5)
            catch _:_ -> error end,
        End = erlang:monotonic_time(microsecond),
        First1 = case {First,Result} of
            {undefined,[_|_]} -> (End-T0)/1000;
            _ -> First
        end,
        E = case Result of error -> Errors+1; _ -> Errors end,
        probe_loop(Parent,Tag,Index,T0,Interval,[(End-Start)/1000|Latencies],First1,
            max(Peak,erlang:memory(total)),E)
    end.
percentile([],_) -> undefined;
percentile(Values,P) -> lists:nth(max(1,ceil(length(Values)*P)),lists:sort(Values)).
tree_bytes(Dir) ->
    filelib:fold_files(Dir,".*",true,fun(Path,Acc)->Acc+filelib:file_size(Path) end,0).
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L).
hex(B) -> ecai_index_job_codec:id_hex(B).
