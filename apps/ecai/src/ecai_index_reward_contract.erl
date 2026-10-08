%% Bind payment contracts to real work plans. Operator API only. These helpers
%% verify integrity, NOT correctness/completeness of an index. A trusted,
%% independent verifier must execute the agreed verification procedure.
-module(ecai_index_reward_contract).
-export([shards/3, upstream/3, shard_result/2]).

%% Returns {ok, Contract, Units}; select a bounded campaign of <=256 units.
shards(File, Ordinals, Pricing) -> guarded(fun() ->
    {ok, Plan} = need(ecai_index_shards:read_plan(File)),
    Root = maps:get(group_id, Plan),
    %% group_id uses the ORIGINAL source/spec/limits, not mutable job receipts.
    Computed = digest(#{spec => maps:get(original_spec, Plan),
        source_identity => maps:get(source_identity, Plan), limits => maps:get(limits, Plan)}),
    require(Root =:= Computed, shard_plan_identity_changed),
    Units = [begin
        E = entry(N, Plan),
        {ok, S} = need(ecai_index_job_codec:spec_hash(maps:get(spec, E))),
        require(ecai_index_job_codec:id_hex(S) =:= maps:get(spec_sha256, E), shard_spec_changed),
        #{id => unit_id(Root, E), ordinal => N, spec_sha256 => maps:get(spec_sha256, E),
          bytes => maps:get(bytes, E), lines => maps:get(lines, E)}
    end || N <- Ordinals],
    contract(Root, Units, Pricing)
end).
upstream(Root, UnitIds, Pricing) -> guarded(fun() ->
    {ok, Plan} = need(ecai_wikimedia_work:read_plan(Root)),
    Units = [begin
        [U] = [R || R <- maps:get(units, Plan), maps:get(id, R) =:= Id], U
    end || Id <- UnitIds],
    contract(Root, Units, Pricing)
end).
contract(Root, Units, Pricing) ->
    Ids = [maps:get(id, U) || U <- Units],
    require(length(Ids) > 0 andalso length(Ids) =< 256 andalso length(lists:usort(Ids)) =:= length(Ids), invalid_unit_selection),
    Terms = maps:with([budget_msat, index_msat, verify_msat, fee_cap_msat], Pricing),
    {ok, Terms#{plan_root => Root, unit_ids => Ids}, Units}.

%% On the trusted coordinator/shared artifact store: check child job, admitted
%% input and snapshot SHA before recording a submission. This is NOT attestation.
shard_result(File, Ordinal) -> guarded(fun() ->
    {ok, Plan} = need(ecai_index_shards:read_plan(File)), E = entry(Ordinal, Plan),
    {ok, _Contract, [U]} = need(shards(File, [Ordinal], #{})),
    Placement = maps:get(Ordinal, maps:get(receipts, Plan)),
    {ok, J} = need(ecai_index_dispatch:get(Placement)),
    require(maps:get(<<"state">>, J) =:= <<"completed">> andalso
        maps:get(<<"spec_hash">>, J) =:= maps:get(spec_sha256, E), shard_not_complete_or_changed),
    Paths = maps:get(paths, maps:get(source, maps:get(spec, E))),
    ok = need_ok(ecai_index_source:verify_paths(Paths, maps:get(source_identity, E))),
    Result = maps:get(<<"result">>, J), Path = maps:get(<<"search_snapshot_path">>, Result),
    Sha = maps:get(<<"search_snapshot_sha256">>, Result),
    {ok, #{files := [#{sha256 := Actual}]}} = need(ecai_index_source:describe_paths([Path])),
    require(Sha =:= Actual, artifact_changed),
    Evidence = #{unit_id => maps:get(id, U), job_id => maps:get(<<"id">>, J),
        snapshot_sha256 => Sha, spec_sha256 => maps:get(spec_sha256, E),
        source_identity => maps:get(source_identity, E)},
    {ok, Evidence#{artifact_sha256 => Sha, evidence_sha256 => digest(Evidence)}}
end).
entry(N, P) ->
    case [E || E <- maps:get(entries, P), maps:get(ordinal, E) =:= N] of
        [E] -> E; _ -> fail(unknown_shard)
    end.
unit_id(Root, E) -> digest({index_shard_v1, Root, maps:get(ordinal, E),
    maps:get(spec_sha256, E), maps:get(source_identity, E)}).
digest(T) -> ecai_index_reward_ledger:digest(T).
need({ok, _} = O) -> O;
need({ok, _, _} = O) -> O;
need({error, R}) -> fail(R).
need_ok(ok) -> ok;
need_ok({error, R}) -> fail(R).
require(true, _) -> ok;
require(false, R) -> fail(R).
fail(R) -> throw({reward_contract, R}).
guarded(F) -> try F() catch throw:{reward_contract, R} -> {error, R}; C:R -> {error, {C,R}} end.
