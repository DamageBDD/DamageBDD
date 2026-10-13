-module(ecai_sbrm_ipfs_financial_ingest).

-author("Steven Joseph <steven@stevenjoseph.in>").

-export([
    ingest_ipfs_json/1
]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% Public API
%%====================================================================

%% Entry point:
%%   IPFSHash :: binary() | string()
%%
%% Reads JSON from IPFS, decodes it, chunks it, indexes it via ECAI
%%
ingest_ipfs_json(IPFSHash) ->
    case damage_ipfs:cat(IPFSHash) of
        {ok, Bin} ->
            ingest_binary(Bin);
        Bin when is_binary(Bin) ->
            ingest_binary(Bin);
        Error ->
            ?LOG_ERROR("ipfs cat failed for ~p: ~p", [IPFSHash, Error]),
            {error, ipfs_fetch_failed}
    end.

%%====================================================================
%% Internal
%%====================================================================

ingest_binary(Bin) ->
    case decode_json(Bin) of
        {ok, JsonMap} ->
            ecai_sbrm_financial_statement_ingestor:ingest_report(JsonMap);
        {error, Reason} ->
            ?LOG_ERROR("json decode failed: ~p", [Reason]),
            {error, invalid_json}
    end.

decode_json(Bin) ->
    %% You can swap jsx ↔ jiffy here without touching logic
    try
        {ok, jsx:decode(Bin, [return_maps])}
    catch
        _:Err ->
            {error, Err}
    end.
