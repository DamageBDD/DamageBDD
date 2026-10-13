%%%-------------------------------------------------------------------
%%% ecai_log_decode.erl — expand ECAI[XXXX] refs back into full log lines
%%%-------------------------------------------------------------------
-module(ecai_log_decode).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([expand/3]).

%% Public:
%%   expand(Hash, FullPath, DataBin) -> DataBinExpanded
%%
%% Hash: report root hash (string/binary used by damage_ipfs:cat path join)
%% FullPath: e.g. "reports/<run>/stdout.txt"
%% DataBin: raw file contents
expand(Hash, FullPath, DataBin) when is_binary(DataBin) ->
    case maybe_has_refs(DataBin) of
        false ->
            DataBin;
        true ->
            Dict = load_sidecar_dict(Hash, FullPath),
            replace_refs(DataBin, Dict)
    end.

maybe_has_refs(Bin) ->
    %% cheap check before regex work
    binary:match(Bin, <<"ECAI[">>) =/= nomatch.

%% Sidecar dictionary location:
%%   same directory as the report file:
%%     reports/<run>/ecai_map.term
%%
%% Format: binary_to_term(Map) where Map :: #{ <<"ECAI[...]>">> => <<"full text">> }
load_sidecar_dict(Hash, FullPath) ->
    Dir = filename:dirname(FullPath),
    MapPath = filename:join([Dir, "ecai_map.term"]),
    case safe_cat(Hash, MapPath) of
        {ok, Bin} ->
            try binary_to_term(Bin) of
                M when is_map(M) -> M;
                _ -> #{}
            catch
                _:_ -> #{}
            end;
        _ ->
            #{}
    end.

safe_cat(Hash, Path) ->
    %% reuse your existing damage_reports:cat logic style (damage_ipfs:cat)
    %% Path is relative inside the hash root.
    try damage_ipfs:cat(filename:join([Hash, Path])) of
        {ok, Bin} when is_binary(Bin) -> {ok, Bin};
        _ -> error
    catch
        _:_ -> error
    end.

replace_refs(DataBin, Dict) when map_size(Dict) =:= 0 ->
    %% If no dict, leave as-is (no hallucinated expansion)
    DataBin;
replace_refs(DataBin, Dict) ->
    %% Find all refs like ECAI[0123ABCD] (your short base16 token)
    case re:run(DataBin, <<"ECAI\\[[0-9A-F]+\\]">>, [global]) of
        nomatch ->
            DataBin;
        {match, Matches} ->
            Refs = lists:usort([binary:part(DataBin, S, L) || [{S, L}] <- Matches]),
            lists:foldl(
                fun(Ref, Acc) ->
                    case maps:get(Ref, Dict, undefined) of
                        undefined -> Acc;
                        FullText -> binary:replace(Acc, Ref, FullText, [global])
                    end
                end,
                DataBin,
                Refs
            )
    end.
