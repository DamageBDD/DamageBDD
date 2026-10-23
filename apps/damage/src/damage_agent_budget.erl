%% Fixed-price invocation-admission accounting. All amounts are integer DAMAGE base units.
%% No rate, limit, account or contract comes from an LLM proposal.
-module(damage_agent_budget).
-license("Apache-2.0").
-export([initial/4, enabled/1, backend/1, cost/2, charge/3, view/1,
         receipt/3, validate_binding/2, validate_proof/3]).

-define(MAX_UNITS, 9007199254740991).

initial(Owner, Template, TaskId, RequestId) ->
    Config = maps:get(config, Template),
    case proplists:get_value(accounting, Config, disabled) of
        disabled ->
            case damage_agent_policy:env(accounting_required, true) of
                true -> {error, accounting_required};
                false -> {ok, #{mode => disabled, status => disabled}}
            end;
        Options when is_list(Options) ->
            try
                true = proplists:get_value(mode, Options) =:= aeternity,
                AgentId = proplists:get_value(agent_id, Options),
                true = damage_agent_codec:text(AgentId, 128),
                %% Binding is per authenticated account, not merely a global template.
                Bindings = damage_agent_policy:env(agent_bindings, []),
                true = lists:member(AgentId, proplists:get_value(Owner, Bindings, [])),
                Cap = positive(proplists:get_value(max_cost_units, Options)),
                Planner = tariff(proplists:get_value(planner, Options)),
                Verifier = tariff(proplists:get_value(verifier, Options)),
                ActionRates = proplists:get_value(actions, Options, []),
                ActionIds = [K || {K, _} <- proplists:get_value(actions, Config)],
                true = lists:sort(ActionIds) =:= lists:sort([K || {K, _} <- ActionRates]),
                Rates = maps:from_list([{K, tariff(R)} || {K, R} <- ActionRates]),
                TaskMethod = proplists:get_value(task_method, Options),
                true = damage_agent_codec:text(TaskMethod, 80),
                {ok, Network0} = application:get_env(damage, ae_network_id),
                Network = damage_agent_codec:bin(Network0),
                true = lists:member(Network, [<<"ae_mainnet">>, <<"ae_uat">>]),
                Backend = damage_agent_policy:env(accounting_backend, damage_agent_chain),
                true = is_atom(Backend),
                {module, Backend} = code:ensure_loaded(Backend),
                BackendHash = binary:encode_hex(Backend:module_info(md5)),
                JobId = damage_agent_codec:hash([<<"damage-agent-job-v1">>, Network,
                    Owner, AgentId, TaskId, RequestId]),
                {ok, #{mode => aeternity, status => unprepared, unit => damage_base_units,
                    owner => Owner, agent_id => AgentId, network_id => Network,
                    job_id => JobId, task_id => TaskId,
                    max_cost_units => Cap, spent_units => 0, dispatch_count => 0,
                    task_method => TaskMethod,
                    tariffs => #{planner => Planner, verifier => Verifier, actions => Rates},
                    backend => atom_to_binary(Backend, utf8), backend_md5 => BackendHash}}
            catch _:_ -> {error, invalid_accounting_configuration}
            end;
        _ -> {error, invalid_accounting_configuration}
    end.

positive(N) when is_integer(N), N > 0, N =< ?MAX_UNITS -> N.
nonnegative(N) when is_integer(N), N >= 0, N =< ?MAX_UNITS -> N.
tariff({Units, Method}) ->
    true = damage_agent_codec:text(Method, 80),
    #{units => nonnegative(Units), method => Method}.

enabled(J) -> maps:get(mode, maps:get(budget, J, #{}), disabled) =:= aeternity.

%% No atom is created from checkpoint text; module identity is pinned at submission.
backend(J) ->
    B = maps:get(budget, J),
    M = binary_to_existing_atom(maps:get(backend, B), utf8),
    {module, M} = code:ensure_loaded(M),
    Expected = maps:get(backend_md5, B),
    Expected = binary:encode_hex(M:module_info(md5)),
    M.

cost(Phase, J) ->
    B = maps:get(budget, J), Rates = maps:get(tariffs, B),
    Rate = case Phase of
        planning -> maps:get(planner, Rates);
        verifying -> maps:get(verifier, Rates);
        executing ->
            Plan = maps:get(plan, maps:get(pending, J)),
            maps:get(maps:get(<<"skill">>, Plan), maps:get(actions, Rates))
    end,
    N = maps:get(units, Rate),
    case maps:get(status, B) =:= reserved andalso
         maps:get(spent_units, B) + N =< maps:get(max_cost_units, B) of
        true -> {ok, Rate};
        false -> {error, monetary_budget_exhausted}
    end.

%% Called ONLY after a positive policy check, immediately before worker dispatch.
%% Failed and timed-out invocations have the same fixed tariff as successful ones.
%% This records admission intent, not measured provider usage; a crash between
%% durable intent and actual dispatch requires operator accounting review.
charge(J, Phase, Rate) ->
    {ok, Rate} = cost(Phase, J),
    B = maps:get(budget, J),
    J#{budget => B#{spent_units => maps:get(spent_units, B) + maps:get(units, Rate),
                   dispatch_count => maps:get(dispatch_count, B) + 1}}.

view(J) ->
    B = maps:get(budget, J, #{mode => disabled, status => disabled}),
    V = maps:with([mode, status, unit, agent_id, job_id, network_id, max_cost_units,
        spent_units, dispatch_count, reservation_proof, settlement_proof,
        receipt_proof, receipt_id, contracts, reason], B),
    case maps:get(mode, B) of
        aeternity -> V#{remaining_units => maps:get(max_cost_units, B) - maps:get(spent_units, B)};
        _ -> V
    end.

validate_binding(B, Binding) when is_map(Binding) ->
    try
        true = lists:sort(maps:keys(Binding)) =:=
            lists:sort([contracts, sources, source_hashes, executor, network_id]),
        true = maps:get(network_id, B) =:= maps:get(network_id, Binding),
        Contracts = maps:get(contracts, Binding),
        lists:foreach(fun(K) ->
            <<"ct_", Tail/binary>> = maps:get(K, Contracts), true = byte_size(Tail) > 0,
            true = damage_agent_codec:text(maps:get(K, maps:get(sources, Binding)), 4096),
            H = maps:get(K, maps:get(source_hashes, Binding)),
            true = is_binary(H) andalso byte_size(H) =:= 64
        end, [agent_policy, agent_treasury, agent_execution_ledger]),
        <<"ak_", _/binary>> = maps:get(executor, Binding),
        {ok, maps:merge(B, Binding)}
    catch _:_ -> {error, invalid_contract_binding}
    end;
validate_binding(_, _) -> {error, invalid_contract_binding}.

%% Inclusion is required, not merely submission or a successful dry run.
%% Confirmations beyond inclusion need a deployment-specific finality adapter.
validate_proof(B, Kind, Proof) when is_map(Proof) ->
    try
        CtKey = case Kind of
            reserve -> agent_treasury;
            settle -> agent_treasury;
            receipt -> agent_execution_ledger
        end,
        true = maps:get(contract_id, Proof) =:= maps:get(CtKey, maps:get(contracts, B)),
        true = maps:get(caller_id, Proof) =:= maps:get(owner, B),
        H = maps:get(height, Proof), true = is_integer(H) andalso H > 0,
        N = maps:get(caller_nonce, Proof), true = is_integer(N) andalso N > 0,
        true = maps:get(outcome, Proof) =:= included,
        {ok, maps:with([contract_id, caller_id, caller_nonce, height, outcome,
                       tx_hash, gas_used, gas_price], Proof)}
    catch _:_ -> {error, invalid_chain_proof}
    end;
validate_proof(_, _, _) -> {error, invalid_chain_proof}.

receipt(J, Status, End) ->
    B = maps:get(budget, J),
    %% These are private content hashes, NOT fabricated IPFS CIDs.
    ReportHash = damage_agent_codec:hash(#{artifacts => maps:get(artifacts, J),
        verification => maps:get(verification, J, #{}), audit_head => maps:get(audit_head, J)}),
    #{receipt_id => damage_agent_codec:hash([<<"agent-receipt-v1">>, maps:get(job_id, B)]),
      agent_id => maps:get(agent_id, B), job_id => maps:get(job_id, B),
      requester => maps:get(owner, J), executor => maps:get(executor, B),
      feature_hash => maps:get(hash,maps:get(behaviour_identity,J,
          #{hash => maps:get(policy_hash,J)})),
      report_hash => ReportHash,
      input_hash => damage_agent_codec:hash([maps:get(goal, J), maps:get(policy_hash, J)]),
      output_hash => damage_agent_codec:hash(#{artifacts => maps:get(artifacts, J),
        verification => maps:get(verification, J, #{}), execution_status => Status}),
      cost => maps:get(spent_units, B),
      status => case Status of completed -> <<"passed">>; _ -> <<"error">> end,
      started_at => maps:get(created_at, J), ended_at => End}.
