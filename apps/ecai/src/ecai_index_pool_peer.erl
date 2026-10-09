%% Private-cluster participant. Erlang distribution is a TRUSTED administrative
%% transport, not an Internet worker API. Never share its cookie with strangers.
-module(ecai_index_pool_peer).
-import(ecai_index_pool_util, [need/1, ensure/2, guarded/1, hash/1, field/2, object/1]).
-export([offer/2, pipeline/0, enqueue/6, job/2, invoice/3, retry/2]).

pipeline() ->
    Modules = [ecai_search, ecai_index_job_codec, ecai_index_job_wikipedia,
        ecai_index_job_yelp, ecai_wikipedia_loader, ecai_yelp_loader,
        ecai_index_shards, ecai_index_pool_proof],
    Items = [begin {module, M} = code:ensure_loaded(M),
        {M, ecai_index_job_codec:id_hex(M:module_info(md5))} end || M <- Modules],
    hash(Items).

authorize(Coordinator) ->
    ensure(Coordinator =:= node() orelse
        (application:get_env(ecai, index_pool_participant_enabled, false) =:= true andalso
         lists:member(Coordinator, application:get_env(ecai, index_pool_coordinators, []))), participation_not_enabled).
identity() ->
    Account = application:get_env(ecai, index_pool_account, undefined),
    ensure(ecai_node_admin:is_node_admin(Account), participant_account_not_node_admin),
    Info = object(damage_cln:getinfo()),
    #{account => Account, lightning_node => field(id, Info), network => field(network, Info),
      node_name => atom_to_binary(node(), utf8), pipeline_sha256 => pipeline()}.
offer(Coordinator, Nonce) -> guarded(fun() ->
    authorize(Coordinator), ensure(is_binary(Nonce) andalso byte_size(Nonce) =:= 64, invalid_challenge),
    I = identity(),
    Binding = I#{coordinator => atom_to_binary(Coordinator, utf8), nonce => Nonce},
    Message = <<"ecai-index-pool:v1:", (hash(Binding))/binary>>,
    Signed = object(damage_cln:sign_index_pool_message(Message)),
    Binding#{message => Message, signature => field(zbase, Signed),
             max_inflight => 1, consent => <<"permissioned-indexing/v1">>}
end).

enqueue(Coordinator, Expected, Spec0, SourceIdentity, Key, Role) -> guarded(fun() ->
    authorize(Coordinator),
    ensure(Role =:= index orelse Role =:= verify, invalid_role),
    case Coordinator =:= node() andalso Role =:= verify of
        true -> ok;
        false -> ensure(maps:get(reward_msat, Expected, 0) >=
            application:get_env(ecai, index_pool_min_reward_msat, 1000), reward_below_participant_minimum)
    end,
    %% Only unpaid verification can use the coordinator without worker opt-in.
    case Coordinator =:= node() andalso Role =:= verify of
        true -> ensure(maps:get(pipeline_sha256, Expected) =:= pipeline(), pipeline_changed);
        false ->
            I = identity(),
            ensure(maps:with([account, lightning_node, pipeline_sha256, network], I) =:=
                   maps:with([account, lightning_node, pipeline_sha256, network], Expected), participant_identity_changed)
    end,
    Spec = need(ecai_index_job_codec:normalize_spec(Spec0)),
    ensure(lists:member(maps:get(kind, Spec), [wikipedia_jsonl, yelp_ndjson]) andalso
           maps:get(mode, maps:get(target, Spec)) =:= shard_search, unsupported_pool_work),
    Paths = maps:get(paths, maps:get(source, Spec)),
    ensure(length(Paths) > 0 andalso length(Paths) =< 16, too_many_source_files),
    lists:foreach(fun ecai_index_pool_util:shared_path/1, Paths),
    _ = ecai_index_pool_util:shared_path(maps:get(base_dir, maps:get(target, Spec))),
    ensure(maps:get(finalize, Spec) =:= #{auto_mint => false, build_nft_manifest => false,
                                        publish_ipfs => false}, external_publication_not_permitted),
    ok = need(ecai_index_source:verify_paths(Paths, SourceIdentity)),
    Job = need(ecai_index_jobs_srv:enqueue(Spec, #{idempotency_key => Key})),
    #{node => node(), job_id => maps:get(<<"id">>, Job), spec_sha256 => maps:get(<<"spec_hash">>, Job)}
end).
job(Coordinator, Id) -> guarded(fun() -> authorize(Coordinator), need(ecai_index_jobs_srv:get(Id)) end).
retry(Coordinator, Id) -> guarded(fun() -> authorize(Coordinator), need(ecai_index_jobs_srv:retry(Id)) end).

invoice(Coordinator, CampaignId, Payout) -> guarded(fun() ->
    authorize(Coordinator), I = identity(),
    ensure(maps:get(actor, Payout) =:= maps:get(account, I) andalso
           maps:get(payee, Payout) =:= maps:get(lightning_node, I), payout_identity_changed),
    Id = maps:get(id, Payout),
    Label = <<"ecai-pool:v1:", CampaignId/binary, ":", Id/binary>>,
    Desc = ecai_index_reward_ledger:invoice_description(CampaignId, Id, maps:get(artifact_sha256, Payout)),
    Amount = maps:get(amount_msat, Payout),
    ensure(is_integer(Amount) andalso Amount > 0, invalid_invoice_amount),
    Existing = invoices(Label),
    case Existing of
        [] -> _ = object(damage_cln:create_invoice(Amount, Desc, 86400, Label));
        [_] -> ok;
        _ -> throw({pool, ambiguous_recipient_invoice})
    end,
    case invoices(Label) of
        [Inv] ->
            ensure(ecai_index_pool_util:msat(field(amount_msat, Inv)) =:= Amount, invoice_label_conflict),
            field(bolt11, Inv);
        _ -> throw({pool, recipient_invoice_unavailable})
    end
end).
invoices(Label) ->
    M = object(damage_cln:list_invoices_by_label(Label)), L = field(invoices, M),
    ensure(is_list(L), invalid_cln_response), [I || I <- L, field(label, I) =:= Label].
