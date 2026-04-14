-module(ecai_disk_indexer).
-export([new/1, add_doc/3, flush/1, close/1]).

-record(st, {
    base_dir,
    docstore_tab,
    seg_no = 0,
    %% #{TermBin => [DocInt...]}
    batch = #{},
    batch_docs = 0,
    %% tune: batch size controls RAM
    max_docs = 50000
}).

new(BaseDir) ->
    ok = filelib:ensure_dir(filename:join(BaseDir, "x")),
    {ok, Tab} = ecai_disk_docstore:open(BaseDir),
    #st{base_dir = BaseDir, docstore_tab = Tab, seg_no = next_seg_no(BaseDir)}.

%% add_doc(State, DocInt, RecMap) -> State1
add_doc(S0 = #st{batch = B0, batch_docs = N0, max_docs = Max}, DocInt, RecMap) ->
    %% IMPORTANT: re-use your existing term formats, not embeddings:
    %% terms_from_record/1 is currently private in ecai_search; move it out or duplicate.

    %% you'll create ecai_terms.erl from your current logic :contentReference[oaicite:4]{index=4}
    Terms = ecai_terms:terms_from_record(RecMap),
    %% Persist chunk metadata on disk (DocInt -> Meta)
    %% Expected fields in RecMap:
    %%   cid (binary or list), title (optional), heading (optional), text (binary or list)
    Meta =
        maps:with(
            [cid, title, heading, text, tags, type, ts],
            RecMap
        ),
    ok = ecai_disk_docstore:put(S0#st.docstore_tab, DocInt, normalize_meta(Meta)),

    B1 = lists:foldl(
        fun(T, Acc) -> maps:update_with(T, fun(L) -> [DocInt | L] end, [DocInt], Acc) end, B0, Terms
    ),
    N1 = N0 + 1,
    S1 = S0#st{batch = B1, batch_docs = N1},
    case N1 >= Max of
        true -> flush(S1);
        false -> S1
    end.

flush(S = #st{base_dir = Dir, seg_no = No, batch = Batch, batch_docs = Docs}) ->
    case Docs of
        0 ->
            S;
        _ ->
            SegName = io_lib:format("seg_~6..0B.ecs", [No]),
            ok = ecai_disk_segment:write(Dir, lists:flatten(SegName), Batch),
            ok = ecai_disk_manifest:append_segment(Dir, filename:join(Dir, lists:flatten(SegName))),
            S#st{seg_no = No + 1, batch = #{}, batch_docs = 0}
    end.

close(S) ->
    flush(S),
    ok = ecai_disk_docstore:close(S#st.docstore_tab),
    ok.

normalize_meta(M) ->
    maps:map(
        fun(_K, V) ->
            case V of
                Bin when is_binary(Bin) -> Bin;
                L when is_list(L) -> list_to_binary(L);
                Other -> Other
            end
        end,
        M
    ).
next_seg_no(BaseDir) ->
    Segs = ecai_disk_manifest:list_segments(BaseDir),
    %% simple: parse highest seg_NNNNNN.ecs
    Ns = [seg_num(S) || S <- Segs],
    case Ns of
        [] -> 1;
        _ -> lists:max(Ns) + 1
    end.

seg_num(Path) ->
    Base = filename:basename(Path),
    %% "seg_000123.ecs"
    case string:tokens(Base, "_.") of
        ["seg", NStr, "ecs"] ->
            list_to_integer(NStr);
        _ ->
            0
    end.
