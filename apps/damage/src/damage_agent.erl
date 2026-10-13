-module(damage_agent).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    create_agent/1,
    fund_agent/2,
    create_job/2,
    execute_job/2,
    pause_agent/1,
    revoke_agent/1,
    write_receipt/2
]).

-record(agent_job, {
    agent_id,
    job_id,
    requester,
    feature_data,
    feature_hash,
    input_hash,
    estimated_cost = 0,
    reservation_id,
    session_id,
    context = #{}
}).

create_agent(#{
    requester := Requester,
    agent_id := AgentId,
    controller := Controller,
    policy_contract := PolicyContract,
    treasury_contract := TreasuryContract,
    metadata_hash := MetadataHash,
    capability_hash := CapabilityHash
}) ->
    {ok, AgentRegistryCt} = agent_registry_ct(Requester),
    damage_ae:contract_call(
        damage,
        AgentRegistryCt,
        "register_agent",
        [
            AgentId,
            Controller,
            PolicyContract,
            TreasuryContract,
            MetadataHash,
            CapabilityHash
        ]
    ).

fund_agent(AgentId, Amount) when is_binary(AgentId); is_list(AgentId) ->
    {error, {missing_requester, {fund_agent, AgentId, Amount}}};
fund_agent(#{requester := Requester, agent_id := AgentId}, Amount) ->
    {ok, AgentTreasuryCt} = agent_treasury_ct(Requester),
    damage_ae:contract_call(
        damage,
        AgentTreasuryCt,
        "allocate_budget",
        [AgentId, Amount]
    ).

create_job(AgentId, #{requester := Requester, feature_data := FeatureData} = Job0) ->
    FeatureHash = damage_utils:sha256_hex(FeatureData),
    JobId = maps:get(job_id, Job0, damage_utils:uuid()),
    InputHash = damage_utils:sha256_hex(term_to_binary(Job0)),
    {ok, #agent_job{
        agent_id = AgentId,
        job_id = JobId,
        requester = Requester,
        feature_data = FeatureData,
        feature_hash = FeatureHash,
        input_hash = InputHash,
        context = maps:get(context, Job0, #{})
    }}.

execute_job(AgentId, Job0) ->
    {ok, Job1} = create_job(AgentId, Job0),
    case authorize(Job1) of
        ok ->
            case reserve(Job1) of
                {ok, Job2} ->
                    run_reserved_job(Job2);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

pause_agent(#{requester := Requester, agent_id := AgentId}) ->
    {ok, AgentRegistryCt} = agent_registry_ct(Requester),
    damage_ae:contract_call(
        damage,
        AgentRegistryCt,
        "pause_agent",
        [AgentId]
    );
pause_agent(AgentId) ->
    {error, {missing_requester, {pause_agent, AgentId}}}.

revoke_agent(#{requester := Requester, agent_id := AgentId}) ->
    {ok, AgentRegistryCt} = agent_registry_ct(Requester),
    damage_ae:contract_call(
        damage,
        AgentRegistryCt,
        "revoke_agent",
        [AgentId]
    );
revoke_agent(AgentId) ->
    {error, {missing_requester, {revoke_agent, AgentId}}}.

authorize(#agent_job{
    agent_id = AgentId,
    requester = Requester,
    estimated_cost = Cost,
    context = Context
}) ->
    Method = maps:get(method, Context, <<"bdd_execute">>),
    {ok, AgentPolicyCt} = agent_policy_ct(Requester),
    case
        damage_ae:contract_call(
            damage,
            AgentPolicyCt,
            "authorize_method",
            [AgentId, Method, Cost]
        )
    of
        #{<<"return_type">> := <<"ok">>, <<"return_value">> := true} ->
            ok;
        Other ->
            {error, {unauthorized, Other}}
    end.

reserve(
    #agent_job{
        job_id = JobId,
        agent_id = AgentId,
        requester = Requester,
        estimated_cost = Cost
    } = Job
) ->
    {ok, AgentTreasuryCt} = agent_treasury_ct(Requester),
    case
        damage_ae:contract_call(
            damage,
            AgentTreasuryCt,
            "reserve",
            [JobId, AgentId, Cost]
        )
    of
        #{<<"return_type">> := <<"ok">>} ->
            {ok, Job#agent_job{reservation_id = JobId}};
        Other ->
            {error, {reserve_failed, Other}}
    end.

run_reserved_job(#agent_job{} = Job) ->
    Start = erlang:system_time(second),
    Config = damage_run_config:agent_run(Job),
    DryRunConfig = [{dry_run, true} | Config],
    DryRunResult = damage:execute_data(
        DryRunConfig, Job#agent_job.context, Job#agent_job.feature_data
    ),
    EstimatedCost = estimate_cost(DryRunResult),
    Job2 = Job#agent_job{estimated_cost = EstimatedCost},
    case damage:execute_data(Config, Job2#agent_job.context, Job2#agent_job.feature_data) of
        Result ->
            End = erlang:system_time(second),
            finalize_execution(Job2, Result, Start, End)
    end.

estimate_cost(_DryRunResult) ->
    1.

finalize_execution(Job, Result, Start, End) ->
    Status = map_result_status(Result),
    ReportHash = report_hash(Result),
    OutputHash = damage_utils:sha256_hex(term_to_binary(Result)),
    Receipt = #{
        receipt_id => damage_utils:uuid(),
        agent_id => Job#agent_job.agent_id,
        job_id => Job#agent_job.job_id,
        requester => Job#agent_job.requester,
        executor => damage_accounts:node_account(),
        feature_hash => Job#agent_job.feature_hash,
        report_hash => ReportHash,
        input_hash => Job#agent_job.input_hash,
        output_hash => OutputHash,
        cost => Job#agent_job.estimated_cost,
        status => Status,
        started_at => Start,
        ended_at => End
    },
    ok = settle(Job#agent_job.requester, Job#agent_job.job_id, Job#agent_job.estimated_cost),
    ok = write_receipt(Receipt, Result),
    {ok, #{receipt => Receipt, result => Result}}.

settle(Requester, JobId, Cost) ->
    {ok, AgentTreasuryCt} = agent_treasury_ct(Requester),
    case
        damage_ae:contract_call(
            damage,
            AgentTreasuryCt,
            "settle",
            [JobId, Cost]
        )
    of
        #{<<"return_type">> := <<"ok">>} ->
            ok;
        Other ->
            {error, {settle_failed, Other}}
    end.

write_receipt(Receipt, _Result) ->
    Requester = maps:get(requester, Receipt),
    {ok, ExecutionLedgerCt} = agent_execution_ledger_ct(Requester),
    case
        damage_ae:contract_call(
            damage,
            ExecutionLedgerCt,
            "write_receipt",
            [
                maps:get(receipt_id, Receipt),
                maps:get(agent_id, Receipt),
                maps:get(job_id, Receipt),
                maps:get(requester, Receipt),
                maps:get(executor, Receipt),
                maps:get(feature_hash, Receipt),
                maps:get(report_hash, Receipt),
                maps:get(input_hash, Receipt),
                maps:get(output_hash, Receipt),
                maps:get(cost, Receipt),
                maps:get(status, Receipt),
                maps:get(started_at, Receipt),
                maps:get(ended_at, Receipt)
            ]
        )
    of
        #{<<"return_type">> := <<"ok">>} ->
            ok;
        Other ->
            {error, {write_receipt_failed, Other}}
    end.

map_result_status({parse_error, _, _}) -> error;
map_result_status({error, _}) -> error;
map_result_status(_Other) -> passed.

report_hash(Result) ->
    damage_utils:sha256_hex(term_to_binary(Result)).

agent_registry_ct(Requester) ->
    user_contract_ct(Requester, <<"agent_registry">>).

agent_policy_ct(Requester) ->
    user_contract_ct(Requester, <<"agent_policy">>).

agent_treasury_ct(Requester) ->
    user_contract_ct(Requester, <<"agent_treasury">>).

agent_execution_ledger_ct(Requester) ->
    user_contract_ct(Requester, <<"agent_execution_ledger">>).

user_contract_ct(Requester0, Name) ->
    Requester = to_bin(Requester0),
    case damage_node_registry:get_registry_ct_from_node_registry(Requester) of
        {ok, RegistryCt} ->
            KeyPair = identity_server:get_account(Requester),
            account_registry:get_contract(KeyPair, RegistryCt, Name);
        Error ->
            Error
    end.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> list_to_binary(io_lib:format("~p", [V])).
