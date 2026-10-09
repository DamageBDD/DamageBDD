%% One bounded coordination step. Network effects already have immutable
%% placement/queue keys or durable reward-ledger intents before transmission.
-module(ecai_index_pool_runner).
-import(ecai_index_pool_util, [need/1, ensure/2, guarded/1, hash/1, text/1]).
-export([step/1, execution_entry/3]).

step(J) -> guarded(fun() ->
    Owner = maps:get(owner, J), Id = maps:get(id, J),
    ensure(ecai_node_admin:is_node_admin(Owner), creator_no_longer_node_admin),
    case maps:get(stage, J) of
        draft ->
            Contract = maps:get(contract, J),
            ok = need(ecai_index_rewards:register_participant(Owner, Owner, maps:get(refund_node, Contract))),
            _ = need(ecai_index_rewards:pool_create(Owner, maps:get(key, J), maps:get(terms, J))),
            _ = accepted_effect(ecai_index_rewards:funding_invoice(Owner, Id)),
            #{stage => awaiting_funding, last_error => null};
        awaiting_funding ->
            C = campaign(J),
            case maps:get(state, C) of
                funded -> #{stage => funded, last_error => null};
                _ -> _ = accepted_effect(ecai_index_rewards:refresh_funding(Owner, Id)), #{}
            end;
        _ ->
            ensure(ecai_index_pool:authorized(Id, compute, maps:get(quote_hash, J)), job_paused),
            C = campaign(J),
            ensure(maps:get(state, C) =:= funded, campaign_not_funded),
            case payment_step(J, C) of
                none -> compute_step(J, C);
                done -> #{last_error => null}
            end
    end
end).
campaign(J) ->
    C = need(ecai_index_rewards:campaign(maps:get(id, J))),
    ensure(maps:get(terms, C) =:= maps:get(terms, J), reward_contract_changed), C.
accepted_effect({ok, _}) -> ok;
accepted_effect({error, cln_operation_in_flight}) -> ok;
accepted_effect({error, R}) -> throw({pool, R}).

payment_step(J, C) ->
    Cfg = application:get_env(ecai, index_rewards_config, #{}),
    case maps:get(auto_pay, J, false) andalso maps:get(payments_enabled, Cfg, false) of
        false -> none;
        true ->
            Pays = lists:sort(fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end,
                [P || P <- maps:get(payouts, C), maps:get(state, P) =/= paid, maps:get(role, P) =/= refund]),
            case Pays of
                [] -> none;
                [P | _] ->
                    Id = maps:get(id, J), Owner = maps:get(owner, J), Pid = maps:get(id, P),
                    case maps:get(state, P) of
                        awaiting_invoice ->
                            Participant = payee(J, P),
                            Node = member_node(Participant),
                            Bolt = need(ecai_index_pool:rpc(Node, invoice, [node(), Id, P])),
                            _ = need(ecai_index_rewards:submit_invoice(maps:get(actor, P), Id, Pid, Bolt));
                        invoice_ready ->
                            ensure(ecai_index_pool:authorized(Id, pay, maps:get(quote_hash, J)), payment_grant_revoked),
                            _ = accepted_effect(ecai_index_rewards:pay(Owner, Id, Pid, <<"pay indexing reward">>));
                        paying -> _ = accepted_effect(ecai_index_rewards:reconcile(Owner, Id, Pid));
                        uncertain -> _ = accepted_effect(ecai_index_rewards:reconcile(Owner, Id, Pid));
                        retryable -> throw({pool, payment_requires_operator_retry})
                    end,
                    case maps:get(state, P) of paying -> none; uncertain -> none; _ -> done end
            end
    end.
payee(J, P) ->
    Assignment = maps:get(maps:get(unit_id, P), maps:get(assignments, maps:get(contract, J))),
    Member = case maps:get(role, P) of index -> maps:get(indexer, Assignment); verify -> maps:get(verifier, Assignment) end,
    ensure(maps:get(account, Member) =:= maps:get(actor, P) andalso
        maps:get(lightning_node, Member) =:= maps:get(payee, P), payout_participant_changed), Member.
member_node(#{unpaid_local_verifier := true, node_name := Name}) ->
    ensure(Name =:= atom_to_binary(node(), utf8), coordinator_identity_changed), node();
member_node(P) -> ecai_index_pool_util:node_named(maps:get(node_name, P)).

compute_step(J, C) ->
    Units = maps:get(units, J), R = maps:get(results, J),
    Pending = [U || U <- Units, not lists:member(maps:get(phase, maps:get(maps:get(id, U), R, #{}), new), [accepted, rejected])],
    case Pending of
        [] -> finish(J, C);
        _ ->
            %% Rotate polling so a long source never starves the other peers.
            Eligible = [U0 || U0 <- Pending, eligible(J, U0)],
            ensure(Eligible =/= [], no_schedulable_segment),
            Pos = maps:get(cursor, J, 0) rem length(Eligible), U = lists:nth(Pos + 1, Eligible),
            Id = maps:get(id, U), Old = maps:get(Id, R, #{phase => new}),
            Next = unit_step(J, U, Old, C),
            #{results => R#{Id => Next}, cursor => Pos + 1, stage => indexing, last_error => null}
    end.
eligible(J, U) ->
    Results = maps:get(results, J), Unit = maps:get(id, U),
    case maps:get(phase, maps:get(Unit, Results, #{}), new) of
        new ->
            Busy = [{Id, R} || {Id, R} <- maps:to_list(Results),
                lists:member(maps:get(phase, R), [indexing, verifying])],
            Target = maps:get(node_name, maps:get(indexer, assignment(J, Unit))),
            Limit = application:get_env(ecai, index_pool_max_inflight, 2),
            length(Busy) < Limit andalso not lists:any(fun({Id, R}) ->
                Role = case maps:get(phase, R) of indexing -> indexer; verifying -> verifier end,
                maps:get(node_name, maps:get(Role, assignment(J, Id))) =:= Target
            end, Busy);
        _ -> true
    end.
unit_step(J, U, #{phase := new} = R, C) ->
    Id = maps:get(id, J), Owner = maps:get(owner, J), Unit = maps:get(id, U),
    A = assignment(J, Unit), Indexer = maps:get(indexer, A), Verifier = maps:get(verifier, A),
    LU = maps:get(Unit, maps:get(units, C)),
    case maps:get(state, LU) of
        ready -> _ = need(ecai_index_rewards:allocate(Owner, Id, Unit, maps:get(account, Indexer), maps:get(account, Verifier)));
        cancelled -> throw({pool, segment_cancelled});
        _ -> ensure(maps:get(indexer, LU) =:= maps:get(account, Indexer) andalso
                    maps:get(verifier, LU) =:= maps:get(account, Verifier), assignment_changed)
    end,
    Receipt = enqueue(J, U, index, Indexer),
    R#{phase => indexing, index_receipt => Receipt};
unit_step(J, U, #{phase := indexing, index_receipt := Receipt} = R, _C) ->
    case completed(J, U, index, Receipt) of
        {waiting, Progress} -> R#{progress => Progress};
        {done, Proof} ->
            Id = maps:get(id, J), Unit = maps:get(id, U), A = assignment(J, Unit),
            Evidence = hash(#{unit_id => Unit, receipt => Receipt, proof => Proof}),
            _ = need(ecai_index_rewards:submit(maps:get(account, maps:get(indexer, A)), Id, Unit,
                     maps:get(snapshot_sha256, Proof), Evidence)),
            VerifyReceipt = enqueue(J, U, verify, maps:get(verifier, A)),
            R#{phase => verifying, index_proof => Proof, evidence_sha256 => Evidence, verify_receipt => VerifyReceipt}
    end;
unit_step(J, U, #{phase := verifying, verify_receipt := Receipt, index_proof := IndexProof} = R, C) ->
    case completed(J, U, verify, Receipt) of
        {waiting, Progress} -> R#{progress => Progress};
        {done, VerifyProof} ->
            Unit = maps:get(id, U), Id = maps:get(id, J), A = assignment(J, Unit),
            %% Re-read index bytes after the verifier completes (not just its
            %% older reported digest). A changed artifact cannot earn payment.
            {done, CurrentIndex} = completed(J, U, index, maps:get(index_receipt, R)),
            ensure(CurrentIndex =:= IndexProof, index_changed_during_verification),
            Decision = case ecai_index_pool_proof:compare(IndexProof, VerifyProof) of true -> accept; false -> reject end,
            Report = hash(#{policy => <<"full-independent-rebuild/v1">>, unit => Unit,
                index => IndexProof, verification => VerifyProof, verdict => Decision}),
            Artifact = maps:get(snapshot_sha256, IndexProof),
            _ = need(ecai_index_rewards:attest(maps:get(account, maps:get(verifier, A)), Id, Unit, Artifact, Decision, Report)),
            ensure(ecai_index_pool:authorized(Id, compute, maps:get(quote_hash, J)), job_paused),
            OldState = maps:get(state, maps:get(Unit, maps:get(units, C))),
            case lists:member(OldState, [accepted, rejected]) of
                true -> ok;
                false -> _ = need(ecai_index_rewards:accept_work(maps:get(owner, J), Id, Unit, Artifact, Decision))
            end,
            Phase = case Decision of accept -> accepted; reject -> rejected end,
            R#{phase => Phase, verification_proof => VerifyProof, report_sha256 => Report,
                verified_at => erlang:system_time(second), progress => #{}}
    end.
assignment(J, Unit) -> maps:get(Unit, maps:get(assignments, maps:get(contract, J))).
enqueue(J, U, Role, Participant) ->
    ensure(ecai_index_pool:authorized(maps:get(id, J), compute, maps:get(quote_hash, J)), job_paused),
    E = execution_entry(J, U, Role), Unit = maps:get(id, U),
    Key = <<"ecai-pool:", (maps:get(id, J))/binary, ":", Unit/binary, ":", (atom_to_binary(Role, utf8))/binary>>,
    Price = maps:get(Unit, maps:get(unit_prices, maps:get(terms, J))),
    Amount = case Role of index -> maps:get(index_msat, Price); verify -> maps:get(verify_msat, Price) end,
    need(ecai_index_pool:rpc(member_node(Participant), enqueue,
        [node(), Participant#{reward_msat => Amount}, maps:get(spec, E), maps:get(source_identity, E), Key, Role])).
execution_entry(J, U, Role) ->
    [E] = [Entry || Entry <- maps:get(entries, maps:get(plan, J)), maps:get(ordinal, Entry) =:= maps:get(ordinal, U)],
    Base = ecai_index_pool_util:shared_path(filename:join([ecai_index_pool_util:shared_root(),
        "pool-execution", binary_to_list(maps:get(id, J)), binary_to_list(maps:get(id, U)), atom_to_list(Role)])),
    S0 = maps:get(spec, E), T0 = maps:get(target, S0),
    S = need(ecai_index_job_codec:normalize_spec(S0#{target => T0#{base_dir => text(Base)}})),
    Sha = ecai_index_job_codec:id_hex(need(ecai_index_job_codec:spec_hash(S))),
    E#{spec => S, spec_sha256 => Sha}.
completed(J, U, Role, Receipt) ->
    E = execution_entry(J, U, Role),
    ensure(maps:get(spec_sha256, Receipt) =:= maps:get(spec_sha256, E), receipt_spec_changed),
    Job = need(ecai_index_pool:rpc(maps:get(node, Receipt), job, [node(), maps:get(job_id, Receipt)])),
    ensure(maps:get(<<"spec_hash">>, Job) =:= maps:get(spec_sha256, E), worker_job_changed),
    case maps:get(<<"state">>, Job) of
        <<"completed">> ->
            Result = maps:get(<<"result">>, Job), Sha = maps:get(<<"search_snapshot_sha256">>, Result),
            Base = maps:get(base_dir, maps:get(target, maps:get(spec, E))),
            Expected = filename:join([binary_to_list(Base), "shard-snapshots", binary_to_list(maps:get(job_id, Receipt)), binary_to_list(Sha) ++ ".etf"]),
            ensure(text(Expected) =:= maps:get(<<"search_snapshot_path">>, Result), snapshot_location_changed),
            ok = need(ecai_index_source:verify_paths(maps:get(paths, maps:get(source, maps:get(spec, E))), maps:get(source_identity, E))),
            {done, need(ecai_index_pool_proof:snapshot(Expected, Sha))};
        State when State =:= <<"failed">>; State =:= <<"canceled">>; State =:= <<"paused">> ->
            throw({pool, {worker_job_stopped, maps:get(node, Receipt), maps:get(job_id, Receipt), State}});
        _ -> {waiting, maps:get(<<"progress">>, Job, #{})}
    end.
finish(J, C) ->
    Results = maps:get(results, J),
    Rejected = length([R || R <- maps:values(Results), maps:get(phase, R) =:= rejected]),
    case Rejected of
        0 ->
            case maps:is_key(manifest, J) of
                false ->
                    Plan = maps:get(plan, J), Us = maps:get(units, J),
                    Es = [execution_entry(J, U, index) || U <- Us],
                    Rs = maps:from_list([{maps:get(ordinal, U), maps:get(index_receipt, maps:get(maps:get(id, U), Results))} || U <- Us]),
                    Out = ecai_index_pool_util:shared_path(filename:join([ecai_index_pool_util:shared_root(), "pool-merged", binary_to_list(maps:get(id, J)) ++ ".etf"])),
                    M = need(ecai_index_shards:merge_plan(Plan#{entries => Es, receipts => Rs}, Out)),
                    #{manifest => #{path => text(Out), index_root => maps:get(index_root, M)}, stage => indexed};
                true -> final_stage(J, C, complete)
            end;
        _ -> final_stage(J, C, rejected_segments)
    end.
final_stage(J, C, Stage) ->
    Unpaid = [P || P <- maps:get(payouts, C), maps:get(state, P) =/= paid],
    Cfg = application:get_env(ecai, index_rewards_config, #{}),
    Auto = maps:get(auto_pay, J, false) andalso maps:get(payments_enabled, Cfg, false),
    Done = Unpaid =:= [] orelse not Auto,
    Display = case {Stage, Unpaid} of {complete, [_|_]} -> indexed_awaiting_payment; _ -> Stage end,
    #{stage => Display, finished => Done, completed_at => erlang:system_time(second)}.
