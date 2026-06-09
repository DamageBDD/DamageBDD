%% ecai_ipfs_ingest.erl
-module(ecai_ipfs_ingest).
-export([ingest_cid/3, ingest_manifest/2]).

%% Ingest a single IPFS CID as chunk documents
ingest_cid(BaseDir, Cid0, Title0) ->
    Cid = to_bin(Cid0),
    Title = to_bin(Title0),
    {ok, Bin} = damage_ipfs:get(Cid),

    {ok, DocTab} = ecai_disk_docstore:open(BaseDir),
    Idx0 = ecai_disk_indexer:new(BaseDir),

    %% chunk the raw doc (org/md/html/json - doesn’t matter)
    Chunks = chunk(Bin, 1100, 140),

    Idx1 =
        lists:foldl(
            fun({_I, Chunk}, AccIdx) ->
                {ok, DocInt} = ecai_disk_docstore:next_id(DocTab),
                Rec = #{
                    cid => Cid,
                    title => Title,
                    heading => <<>>,
                    text => Chunk,
                    ts => erlang:system_time(second),
                    type => <<"ipfs">>,
                    tags => []
                },
                ecai_disk_indexer:add_doc(AccIdx, DocInt, Rec)
            end,
            Idx0,
            lists:zip(lists:seq(1, length(Chunks)), Chunks)
        ),

    _ = ecai_disk_indexer:close(Idx1),
    ok = ecai_disk_docstore:close(DocTab),
    ok.

%% Ingest a manifest CID containing JSON like:
%% { "name": "...", "docs": [ { "cid": "...", "title": "..." }, ... ] }
ingest_manifest(BaseDir, ManifestCid0) ->
    ManifestCid = to_bin(ManifestCid0),
    {ok, Bin} = damage_ipfs:get(ManifestCid),
    M = jsx:decode(Bin, [return_maps]),
    Docs = maps:get(<<"docs">>, M, []),
    lists:foreach(
        fun(D) ->
            Cid = maps:get(<<"cid">>, D),
            Title = maps:get(<<"title">>, D, <<"">>),
            ingest_cid(BaseDir, Cid, Title)
        end,
        Docs
    ),
    ok.

chunk(Bin, Size, Overlap) when is_binary(Bin) ->
    chunk_loop(Bin, Size, Overlap, []).

chunk_loop(Bin, Size, _Overlap, Acc) when byte_size(Bin) =< Size ->
    lists:reverse([Bin | Acc]);
chunk_loop(Bin, Size, Overlap, Acc) ->
    <<Part:Size/binary, Rest/binary>> = Bin,
    %% step back Overlap into next window
    case Rest of
        <<_:Overlap/binary, Next/binary>> ->
            chunk_loop(Next, Size, Overlap, [Part | Acc]);
        _ ->
            lists:reverse([Part, Rest | Acc])
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
