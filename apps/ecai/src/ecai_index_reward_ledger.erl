%% Pure permissioned indexing reward ledger. No RPCs, network or filesystem I/O.
%% Every mutation is persisted by ecai_index_rewards BEFORE its returned effect.
%% Actor arguments are TRUSTED operator identities, not HTTP authentication.
-module(ecai_index_reward_ledger).
-export([new/0, change/4, recover/2, campaign/2, payout/3, summary/1,
         digest/1, invoice_description/3, validate/2]).

new() -> #{schema => 1, campaigns => #{}, hashes => #{}, work_claims => #{}, events => [], sequence => 0}.

change(Command, State, Config, Now) ->
    try
        validate_context(State, Config),
        mutate(Command, State, Config, Now)
    of
        {Reply, Next, Effect} ->
            invariant(Next),
            {ok, Reply, Next, Effect}
    catch
        throw:{rewards, Why} -> {error, Why};
        error:{badkey, Key} -> {error, {missing_field, Key}};
        error:badarg -> {error, invalid_input}
    end.

mutate({create, Owner, Key, Contract}, S, Config, Now) ->
    check(not maps:get(quarantined, S, false), ledger_quarantined),
    check(lists:member(Owner, maps:get(creators, Config, [])), creator_not_allowed),
    check(is_binary(Key) andalso byte_size(Key) > 0 andalso byte_size(Key) =< 128, invalid_key),
    Root = hash_value(maps:get(plan_root, Contract)),
    Units = maps:get(unit_ids, Contract),
    check(is_list(Units) andalso length(Units) > 0 andalso length(Units) =< 256, invalid_unit_count),
    lists:foreach(fun hash_value/1, Units),
    check(length(lists:usort(Units)) =:= length(Units), duplicate_units),
    Budget = amount(maps:get(budget_msat, Contract)),
    Index = amount(maps:get(index_msat, Contract)),
    Verify = amount(maps:get(verify_msat, Contract)),
    Fee = amount(maps:get(fee_cap_msat, Contract)),
    check(Budget > 0 andalso Budget =< maps:get(max_budget_msat, Config, 10000000), budget_limit),
    check((Index + Verify > 0 orelse maps:is_key(unit_prices, Contract)) andalso
          Fee =< maps:get(max_fee_msat, Config, 1000), invalid_pricing),
    BaseTerms = #{plan_root => Root, unit_ids => Units, budget_msat => Budget,
                  index_msat => Index, verify_msat => Verify, fee_cap_msat => Fee},
    Terms = priced_terms(Contract, BaseTerms),
    Id = digest({reward_campaign_v1, Owner, Key}),
    Existing = maps:get(campaigns, S),
    case maps:find(Id, Existing) of
        {ok, #{terms := Terms, owner := Owner} = C} -> {public(C), S, none};
        {ok, _} -> fail(campaign_key_conflict);
        error ->
            check(map_size(Existing) < 32, campaign_capacity),
            OwnerNode = participant(Owner, Config),
            Treasury = node_id(maps:get(treasury_node, Config)),
            _ = currency(maps:get(network, Config, <<"regtest">>)),
            check(OwnerNode =/= Treasury, self_payment_disallowed),
            C = #{id => Id, owner => Owner, owner_node => OwnerNode, terms => Terms,
                  treasury_node => node_id(maps:get(treasury_node, Config)),
                  network => maps:get(network, Config, <<"regtest">>), state => awaiting_funding,
                  funded_msat => 0, reserved_msat => 0, spent_msat => 0,
                  funding_label => <<"ecai-index:v1:", Id/binary, ":fund">>,
                  funding => none, units => maps:from_list([{U, #{state => ready}} || U <- Units]),
                  payouts => #{}, refunds => 0, created_at => Now},
            save(C, S, Owner, campaign_created, Now, none)
    end;
mutate({funding_invoice, Owner, Id}, S, _Config, Now) ->
    C = owned(Owner, Id, S),
    check(maps:get(state, C) =:= awaiting_funding, funding_not_open),
    case maps:get(funding, C) of
        #{bolt11 := _} -> {public(C), S, none};
        _ ->
            F = #{status => requested},
            save(C#{funding => F}, S, Owner, funding_requested, Now,
                 {fund, Id, maps:get(funding_label, C), maps:get(budget_msat, maps:get(terms, C))})
    end;
mutate({funding_seen, Id, Invoice}, S, _Config, Now) ->
    C = get_campaign(Id, S),
    check(maps:get(label, Invoice) =:= maps:get(funding_label, C), funding_label_mismatch),
    Expected = maps:get(budget_msat, maps:get(terms, C)),
    check(amount(maps:get(amount_msat, Invoice)) =:= Expected, funding_amount_mismatch),
    Hash = hash_value(maps:get(payment_hash, Invoice)),
    use_hash(Hash, {Id, funding}, S),
    Old = maps:get(funding, C),
    check(not is_map(Old) orelse maps:get(payment_hash, Old, Hash) =:= Hash, funding_hash_changed),
    Funding = maps:with([bolt11, payment_hash, amount_msat, amount_received_msat,
                         status, label, paid_at, expires_at], Invoice),
    Paid = maps:get(status, Invoice) =:= <<"paid">>,
    C1 = case {maps:get(funded_msat, C), Paid} of
        {0, true} ->
            Received = amount(maps:get(amount_received_msat, Invoice)),
            check(Received >= Expected, funding_underpaid),
            C#{funding => Funding, funded_msat => Received, state => funded};
        {0, false} -> C#{funding => Funding};
        {_, _} -> C %% Crediting a settled invoice is exactly-once in THIS ledger.
    end,
    save(C1, put_hash(Hash, {Id, funding}, S), <<"cln">>, funding_observed, Now, none);
mutate({allocate, Owner, Id, Unit, Indexer, Verifier}, S, Config, Now) ->
    check(not maps:get(quarantined, S, false), ledger_quarantined),
    C = owned(Owner, Id, S),
    check(maps:get(state, C) =:= funded, campaign_not_funded),
    U = get_unit(Unit, C),
    check(maps:get(state, U) =:= ready, unit_already_allocated),
    IndexNode = participant(Indexer, Config), VerifyNode = participant(Verifier, Config),
    check(Indexer =/= Verifier andalso IndexNode =/= VerifyNode, independent_verifier_required),
    Terms = unit_terms(Unit, C),
    check(IndexNode =/= maps:get(treasury_node, C) andalso
          (VerifyNode =/= maps:get(treasury_node, C) orelse reward(verify, Terms) =:= 0), self_payment_disallowed),
    Claim = {Owner, maps:get(plan_root, Terms), Unit},
    Claims = maps:get(work_claims, S, #{}),
    check(maps:get(Claim, Claims, Id) =:= Id, unit_reserved_or_paid_elsewhere),
    Hold = role_hold(index, Terms) + role_hold(verify, Terms),
    check(Hold =< available(C), budget_exhausted),
    U1 = #{state => allocated, unit_id => Unit, indexer => Indexer, verifier => Verifier,
           indexer_node => IndexNode, verifier_node => VerifyNode, hold_msat => Hold},
    C1 = put_unit(Unit, U1, C#{reserved_msat => maps:get(reserved_msat, C) + Hold}),
    save(C1, S#{work_claims => Claims#{Claim => Id}}, Owner, unit_allocated, Now, none);
mutate({submit, Actor, Id, Unit, Artifact, Evidence}, S, _Config, Now) ->
    C = get_campaign(Id, S), U = get_unit(Unit, C),
    check(maps:get(indexer, U) =:= Actor, wrong_indexer),
    hash_value(Artifact), hash_value(Evidence),
    case maps:get(state, U) of
        allocated ->
            U1 = U#{state => submitted, artifact_sha256 => Artifact, evidence_sha256 => Evidence},
            save(put_unit(Unit, U1, C), S, Actor, artifact_submitted, Now, none);
        _ ->
            check(maps:get(artifact_sha256, U, none) =:= Artifact andalso
                  maps:get(evidence_sha256, U, none) =:= Evidence, immutable_result_conflict),
            {public(C), S, none}
    end;
mutate({attest, Actor, Id, Unit, Artifact, Verdict, Report}, S, _Config, Now) ->
    C = get_campaign(Id, S), U = get_unit(Unit, C),
    check(maps:get(verifier, U) =:= Actor, wrong_verifier),
    check(maps:get(artifact_sha256, U) =:= Artifact, artifact_mismatch),
    check(Verdict =:= accept orelse Verdict =:= reject, invalid_verdict),
    hash_value(Report),
    V = #{verdict => Verdict, report_sha256 => Report, actor => Actor, artifact_sha256 => Artifact},
    case maps:get(state, U) of
        submitted -> save(put_unit(Unit, U#{state => attested, attestation => V}, C),
                          S, Actor, verification_submitted, Now, none);
        _ -> check(maps:get(attestation, U, none) =:= V, immutable_attestation_conflict),
             {public(C), S, none}
    end;
mutate({accept_work, Owner, Id, Unit, Artifact, Decision}, S, _Config, Now) ->
    C = owned(Owner, Id, S), U = get_unit(Unit, C),
    check(maps:get(state, U) =:= attested, work_not_attested),
    check(maps:get(artifact_sha256, U) =:= Artifact, artifact_mismatch),
    check(Decision =:= maps:get(verdict, maps:get(attestation, U)), verdict_mismatch),
    Roles = case Decision of accept -> [index, verify]; reject -> [verify] end,
    Terms = unit_terms(Unit, C),
    Payouts = lists:foldl(fun(Role, Acc) ->
        case reward(Role, Terms) of
            0 -> Acc;
            N ->
                P = new_payout(C, Unit, Role, U, N, maps:get(fee_cap_msat, Terms)),
                Acc#{maps:get(id, P) => P}
        end
    end, maps:get(payouts, C), Roles),
    Held = lists:sum([role_hold(Role, Terms) || Role <- Roles]),
    C1 = C#{payouts => Payouts, reserved_msat => maps:get(reserved_msat, C) - maps:get(hold_msat, U) + Held},
    Status = case Decision of accept -> accepted; reject -> rejected end,
    save(put_unit(Unit, U#{state => Status, hold_msat => 0}, C1), S, Owner, work_decided, Now, none);
mutate({cancel_unit, Owner, Id, Unit}, S, _Config, Now) ->
    C = owned(Owner, Id, S), U = get_unit(Unit, C),
    check(lists:member(maps:get(state, U), [ready, allocated]), submitted_work_cannot_be_cancelled),
    C1 = C#{reserved_msat => maps:get(reserved_msat, C) - maps:get(hold_msat, U, 0)},
    Claim = {Owner, maps:get(plan_root, maps:get(terms, C)), Unit},
    Claims = maps:get(work_claims, S, #{}),
    UpdatedClaims = case maps:get(Claim, Claims, none) of
        Id -> maps:remove(Claim, Claims); _ -> Claims
    end,
    save(put_unit(Unit, U#{state => cancelled, hold_msat => 0}, C1), S#{work_claims => UpdatedClaims}, Owner, unit_cancelled, Now, none);
mutate({close, Owner, Id}, S, _Config, Now) ->
    C = owned(Owner, Id, S),
    check(maps:get(state, C) =:= funded, campaign_not_funded),
    check(lists:all(fun(U) -> lists:member(maps:get(state, U), [ready, accepted, rejected, cancelled]) end,
                    maps:values(maps:get(units, C))), outstanding_work),
    save(C#{state => closed}, S, Owner, campaign_closed, Now, none);
mutate({refund, Owner, Id}, S, _Config, Now) ->
    C = owned(Owner, Id, S),
    check(maps:get(state, C) =:= closed, close_before_refund),
    Fee = maps:get(fee_cap_msat, maps:get(terms, C)),
    N = available(C) - Fee,
    check(N > 0 andalso maps:get(refunds, C) < 16, no_refundable_balance),
    Ordinal = maps:get(refunds, C) + 1,
    Unit = digest({refund, Id, Ordinal}),
    P = #{id => digest({Id, Unit, refund}), unit_id => Unit, role => refund,
          actor => Owner, payee => maps:get(owner_node, C), amount_msat => N,
          fee_cap_msat => Fee, artifact_sha256 => maps:get(plan_root, maps:get(terms, C)),
          state => awaiting_invoice, attempts => 0},
    Ps = maps:get(payouts, C),
    C1 = C#{payouts => Ps#{maps:get(id, P) => P}, refunds => Ordinal,
            reserved_msat => maps:get(reserved_msat, C) + N + Fee},
    save(C1, S, Owner, refund_reserved, Now, none);
mutate({invoice, Actor, Id, Pid, Bolt11, Decoded}, S, _Config, Now) ->
    C = get_campaign(Id, S), P = get_payout(Pid, C),
    check(maps:get(actor, P) =:= Actor, wrong_payee),
    check(is_binary(Bolt11) andalso byte_size(Bolt11) > 0 andalso byte_size(Bolt11) =< 8192, invalid_invoice),
    check(lists:member(maps:get(state, P), [awaiting_invoice, invoice_ready, retryable]), payout_locked),
    %% Never replace an invoice after ANY payment attempt. Reconcile that hash.
    check(maps:get(attempts, P) =:= 0 orelse maps:get(bolt11, P, none) =:= Bolt11, attempted_invoice_is_immutable),
    check(maps:get(valid, Decoded, false) =:= true andalso
          maps:get(type, Decoded, none) =:= <<"bolt11 invoice">>, invalid_bolt11),
    check(maps:get(currency, Decoded) =:= currency(maps:get(network, C)), wrong_invoice_network),
    check(maps:get(payee, Decoded) =:= maps:get(payee, P), invoice_payee_mismatch),
    check(amount(maps:get(amount_msat, Decoded)) =:= maps:get(amount_msat, P), invoice_amount_mismatch),
    check(maps:get(description, Decoded, none) =:= invoice_description(Id, Pid, maps:get(artifact_sha256, P)), invoice_description_mismatch),
    Created = amount(maps:get(created_at, Decoded)), Expiry = amount(maps:get(expiry, Decoded)),
    check(Created + Expiry > Now + 60, invoice_expired),
    Hash = hash_value(maps:get(payment_hash, Decoded)),
    use_hash(Hash, {Id, Pid}, S),
    P1 = P#{state => invoice_ready, bolt11 => Bolt11, payment_hash => Hash, expires_at => Created + Expiry},
    save(put_payout(Pid, P1, C), put_hash(Hash, {Id, Pid}, S), Actor, invoice_bound, Now, none);
mutate({pay, Owner, Id, Pid}, S, Config, Now) ->
    check(maps:get(payments_enabled, Config, false) =:= true, payments_disabled),
    check(not maps:get(quarantined, S, false), ledger_quarantined),
    C = owned(Owner, Id, S), P = get_payout(Pid, C),
    check(lists:member(maps:get(state, P), [invoice_ready, retryable]), payout_not_ready),
    check(maps:get(expires_at, P) > Now + 30, invoice_expired),
    check(maps:get(attempts, P) < 8, payment_attempt_limit),
    P1 = P#{state => paying, attempts => maps:get(attempts, P) + 1, intent_at => Now},
    save(put_payout(Pid, P1, C), S, Owner, payment_intent, Now, {pay, Id, Pid, P1});
mutate({reconcile, Owner, Id, Pid}, S, _Config, _Now) ->
    C = owned(Owner, Id, S), P = get_payout(Pid, C),
    check(lists:member(maps:get(state, P), [paying, uncertain, retryable]), nothing_to_reconcile),
    {public(C), S, {reconcile, Id, Pid, P}};
mutate({payment_seen, Id, Pid, Outcome}, S, _Config, Now) ->
    C = get_campaign(Id, S), P = get_payout(Pid, C),
    case maps:get(state, P) of
        paid -> {public(C), S, none};
        _ ->
            check(lists:member(maps:get(state, P), [paying, uncertain, retryable]), unexpected_payment_result),
            {P1, C1} = settle(P, C, Outcome),
            S1 = case maps:get(diagnostic, P1, none) of
                invalid_settlement_proof -> S#{quarantined => true};
                _ -> S
            end,
            save(put_payout(Pid, P1, C1), S1, <<"cln">>, payment_observed, Now, none)
    end;
mutate(_, _, _, _) -> fail(unsupported_command).

settle(P, C, #{status := complete, payment_hash := H, amount_msat := N,
               amount_sent_msat := Sent, preimage := Preimage}) ->
    Hold = maps:get(amount_msat, P) + maps:get(fee_cap_msat, P),
    Valid = H =:= maps:get(payment_hash, P) andalso N =:= maps:get(amount_msat, P)
        andalso is_integer(Sent) andalso Sent >= N andalso Sent =< Hold
        andalso preimage_matches(Preimage, H),
    case Valid of
        true ->
            Receipt = #{payment_hash => H, amount_msat => N, amount_sent_msat => Sent,
                        fee_msat => Sent - N, proof_checked => true},
            {P#{state => paid, receipt => Receipt},
             C#{spent_msat => maps:get(spent_msat, C) + Sent,
                reserved_msat => maps:get(reserved_msat, C) - Hold}};
        false -> {P#{state => uncertain, diagnostic => invalid_settlement_proof}, C}
    end;
settle(P, C, #{status := failed, payment_hash := H, definitive := true, attempt := Attempt}) ->
    check(H =:= maps:get(payment_hash, P) andalso Attempt =:= maps:get(attempts, P), settlement_hash_mismatch),
    {P#{state => retryable}, C};
settle(P, C, _) -> {P#{state => uncertain}, C}.

%% No money-moving effect on startup. A prior RPC may still be settling in CLN.
recover(S, Now) ->
    Cs = maps:map(fun(_Id, C) ->
        Ps = maps:map(fun(_Pid, P) ->
            case maps:get(state, P) of paying -> P#{state => uncertain, recovery_at => Now}; _ -> P end
        end, maps:get(payouts, C)),
        C#{payouts => Ps}
    end, maps:get(campaigns, S)),
    S#{campaigns => Cs}.

new_payout(C, Unit, Role, U, N, Fee) ->
    {Actor, Node} = case Role of
        index -> {maps:get(indexer, U), maps:get(indexer_node, U)};
        verify -> {maps:get(verifier, U), maps:get(verifier_node, U)}
    end,
    #{id => digest({maps:get(id, C), Unit, Role}), unit_id => Unit, role => Role,
      actor => Actor, payee => Node, amount_msat => N, fee_cap_msat => Fee,
      artifact_sha256 => maps:get(artifact_sha256, U), state => awaiting_invoice, attempts => 0}.

invoice_description(Id, Pid, Hash) ->
    <<"ecai-index:v1:", Id/binary, ":", Pid/binary, ":", Hash/binary>>.

%% v1 campaigns keep their fixed prices. Dashboard contracts freeze a complete
%% price table, and all reservations/earnings read the SAME per-segment prices.
priced_terms(Contract, Base) ->
    case maps:find(unit_prices, Contract) of
        error -> Base;
        {ok, Prices} ->
            Ids = maps:get(unit_ids, Base),
            check(is_map(Prices) andalso lists:sort(maps:keys(Prices)) =:= lists:sort(Ids), invalid_unit_prices),
            Clean = maps:map(fun(_Id, P) ->
                I = amount(maps:get(index_msat, P)), V = amount(maps:get(verify_msat, P)),
                check(I + V > 0, invalid_pricing), #{index_msat => I, verify_msat => V}
            end, Prices),
            Held = lists:sum([role_hold(index, maps:merge(Base, P)) +
                             role_hold(verify, maps:merge(Base, P)) || P <- maps:values(Clean)]),
            check(Held =< maps:get(budget_msat, Base), quoted_budget_exceeded),
            Base#{unit_prices => Clean, allocation_policy => <<"source-bytes-largest-remainder/v1">>,
                  participation_contract => hash_value(maps:get(participation_contract, Contract))}
    end.
unit_terms(Unit, C) ->
    T = maps:get(terms, C),
    case maps:find(unit_prices, T) of
        {ok, Prices} -> maps:merge(T, maps:get(Unit, Prices));
        error -> T
    end.

reward(index, T) -> maps:get(index_msat, T);
reward(verify, T) -> maps:get(verify_msat, T).
role_hold(Role, T) -> case reward(Role, T) of 0 -> 0; N -> N + maps:get(fee_cap_msat, T) end.
available(C) -> maps:get(funded_msat, C) - maps:get(reserved_msat, C) - maps:get(spent_msat, C).
participant(A, Config) ->
    check(is_binary(A) andalso byte_size(A) > 0, invalid_actor),
    case maps:find(A, maps:get(participants, Config, #{})) of
        {ok, Node} -> node_id(Node);
        error -> fail(participant_not_registered)
    end.
node_id(N) ->
    check(is_binary(N) andalso byte_size(N) =:= 66, invalid_node_id),
    check(binary:part(N, 0, 2) =:= <<"02">> orelse binary:part(N, 0, 2) =:= <<"03">>, invalid_node_id),
    check(hex(N), invalid_node_id), N.
hash_value(B) -> check(is_binary(B) andalso byte_size(B) =:= 64 andalso hex(B), invalid_hash), B.
hex(B) -> lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, binary_to_list(B)).
amount(N) when is_integer(N), N >= 0, N =< 2100000000000000000 -> N;
amount(_) -> fail(invalid_msat_amount).
currency(<<"bitcoin">>) -> <<"bc">>;
currency(<<"regtest">>) -> <<"bcrt">>;
currency(<<"testnet">>) -> <<"tb">>;
currency(_) -> fail(unsupported_network).
preimage_matches(B, H) when is_binary(B), byte_size(B) =:= 64 ->
    try ecai_index_job_codec:id_hex(crypto:hash(sha256, binary:decode_hex(B))) =:= H catch _:_ -> false end;
preimage_matches(_, _) -> false.

digest(Term) -> ecai_index_job_codec:id_hex(crypto:hash(sha256, ecai_index_job_codec:canonical_binary(Term))).
%% Accounting reservations by participant; never represented as an exclusive
%% CLN channel balance. Shared node liquidity remains an independent resource.
node_allocations(C) ->
    Active = [{Id, U} || {Id, U} <- maps:to_list(maps:get(units, C)), maps:get(hold_msat, U, 0) > 0],
    A = lists:foldl(fun({Id, U}, Acc) ->
        Terms = unit_terms(Id, C),
        lists:foldl(fun({Role, ActorKey, NodeKey}, A0) ->
            N = reward(Role, Terms),
            case N of
                0 -> A0;
                _ -> allocation_add(maps:get(ActorKey, U), maps:get(NodeKey, U),
                    #{reserved_msat => role_hold(Role, Terms), allocated_reward_msat => N}, A0)
            end
        end, Acc, [{index, indexer, indexer_node}, {verify, verifier, verifier_node}])
    end, #{}, Active),
    Rows = lists:foldl(fun(P, Acc) ->
        N = maps:get(amount_msat, P),
        Delta = case maps:get(state, P) of
            paid -> #{paid_reward_msat => N, fees_paid_msat => maps:get(fee_msat, maps:get(receipt, P))};
            _ -> #{reserved_msat => N + maps:get(fee_cap_msat, P), earned_unpaid_msat => N}
        end,
        allocation_add(maps:get(actor, P), maps:get(payee, P), Delta, Acc)
    end, A, maps:values(maps:get(payouts, C))),
    maps:values(Rows).
allocation_add(Actor, Node, Delta, Rows) ->
    Key = {Actor, Node}, Base = maps:get(Key, Rows, #{actor => Actor, lightning_node => Node,
        reserved_msat => 0, allocated_reward_msat => 0, earned_unpaid_msat => 0,
        paid_reward_msat => 0, fees_paid_msat => 0}),
    Row = maps:fold(fun(K, N, R) -> R#{K => maps:get(K, R) + N} end, Base, Delta),
    Rows#{Key => Row}.
get_campaign(Id, S) -> case maps:find(Id, maps:get(campaigns, S)) of {ok, C} -> C; error -> fail(campaign_not_found) end.
get_unit(Id, C) -> case maps:find(Id, maps:get(units, C)) of {ok, U} -> U; error -> fail(unit_not_found) end.
get_payout(Id, C) -> case maps:find(Id, maps:get(payouts, C)) of {ok, P} -> P; error -> fail(payout_not_found) end.
owned(Owner, Id, S) -> C = get_campaign(Id, S), check(maps:get(owner, C) =:= Owner, owner_required), C.
put_unit(Id, U, C) -> Us = maps:get(units, C), C#{units => Us#{Id => U}}.
put_payout(Id, P, C) -> Ps = maps:get(payouts, C), C#{payouts => Ps#{Id => P}}.
use_hash(H, Key, S) -> check(maps:get(H, maps:get(hashes, S), Key) =:= Key, payment_hash_already_used).
put_hash(H, Key, S) -> Hs = maps:get(hashes, S), S#{hashes => Hs#{H => Key}}.

save(C, S, Actor, Action, Now, Effect) ->
    Seq = maps:get(sequence, S) + 1, Cs = maps:get(campaigns, S),
    Old = maps:get(maps:get(id, C), Cs, #{}),
    Event = #{sequence => Seq, campaign => maps:get(id, C), actor => Actor, action => Action, at => Now,
              units_changed => changed_ids(units, Old, C), payouts_changed => changed_ids(payouts, Old, C),
              funded_msat => maps:get(funded_msat, C), reserved_msat => maps:get(reserved_msat, C),
              spent_msat => maps:get(spent_msat, C)},
    Next = S#{campaigns => Cs#{maps:get(id, C) => C}, sequence => Seq,
              events => [Event | maps:get(events, S)]},
    {public(C), Next, Effect}.
public(C) ->
    Ps = [maps:without([bolt11], P) || P <- maps:values(maps:get(payouts, C))],
    C#{payouts => Ps, available_msat => available(C), node_allocations => node_allocations(C)}.
campaign(Id, S) -> try {ok, public(get_campaign(Id, S))} catch throw:{rewards, R} -> {error, R} end.
payout(Id, Pid, S) -> try {ok, get_payout(Pid, get_campaign(Id, S))} catch throw:{rewards, R} -> {error, R} end.
summary(S) -> #{campaigns => [public(C) || C <- maps:values(maps:get(campaigns, S))],
                sequence => maps:get(sequence, S), quarantined => maps:get(quarantined, S, false)}.
invariant(S) ->
    maps:foreach(fun(_, C) ->
        HeldUnits = lists:sum([maps:get(hold_msat, U, 0) || U <- maps:values(maps:get(units, C))]),
        HeldPays = lists:sum([maps:get(amount_msat, P) + maps:get(fee_cap_msat, P)
                              || P <- maps:values(maps:get(payouts, C)), maps:get(state, P) =/= paid]),
        Spent = lists:sum([maps:get(amount_sent_msat, maps:get(receipt, P))
                           || P <- maps:values(maps:get(payouts, C)), maps:get(state, P) =:= paid]),
        check(maps:get(reserved_msat, C) =:= HeldUnits + HeldPays andalso
              maps:get(spent_msat, C) =:= Spent andalso available(C) >= 0, budget_invariant_broken)
    end, maps:get(campaigns, S)).
changed_ids(Key, Old, New) ->
    Before = maps:get(Key, Old, #{}),
    [Id || {Id, Value} <- maps:to_list(maps:get(Key, New, #{})), maps:get(Id, Before, none) =/= Value].

validate(S, Config) ->
    try validate_context(S, Config), invariant(S), ok
    catch _:_ -> {error, ledger_or_treasury_mismatch} end.
validate_context(S, Config) ->
    maps:foreach(fun(_, C) ->
        check(maps:get(treasury_node, C) =:= maps:get(treasury_node, Config) andalso
              maps:get(network, C) =:= maps:get(network, Config, <<"regtest">>),
              ledger_treasury_mismatch)
    end, maps:get(campaigns, S)).

check(true, _) -> ok;
check(false, R) -> fail(R).
fail(R) -> throw({rewards, R}).
