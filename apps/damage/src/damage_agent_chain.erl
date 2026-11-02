%% Adapter for the ABI referenced by the uploaded damage_agent.erl.
%% The Sophia implementations were not supplied: do not infer escrow, refunds,
%% atomic authorisation, finality depth or idempotence from these method names.
-module(damage_agent_chain).
-license("Apache-2.0").
-export([prepare/1, reserve/1, authorize/3, settle/2, write_receipt/2, reconcile/2,
         management/2, decode/1, inclusion/3, resolve_contract/2]).

prepare(B) ->
    safe_read(fun() ->
        ok = deployment_ready(B),
        Owner = maps:get(owner, B),
        {ok, _} = signer(Owner),
        Names = [agent_policy, agent_treasury, agent_execution_ledger],
        Contracts = maps:from_list([begin
            {ok, Ct} = resolve_contract(Owner, atom_to_binary(N, utf8)), {N, Ct}
        end || N <- Names]),
        SourceList = [{N, source(N)} || N <- Names],
        Sources = maps:from_list([{N, P} || {N, {ok, P, _H}} <- SourceList]),
        Hashes = maps:from_list([{N, H} || {N, {ok, _P, H}} <- SourceList]),
        true = map_size(Sources) =:= length(Names),
        #{public_key := Executor0} = secrets:node_keypair(),
        Executor = damage_agent_codec:bin(Executor0),
        {ok, #{contracts => Contracts, sources => Sources, source_hashes => Hashes,
               executor => Executor, network_id => maps:get(network_id, B)}}
    end).

reserve(B) ->
    case authorize(B, maps:get(task_method, B), maps:get(max_cost_units, B)) of
        ok -> mutate(B, agent_treasury, "reserve", [maps:get(job_id, B),
                    maps:get(agent_id, B), integer_to_list(maps:get(max_cost_units, B))]);
        {error, _} -> {error, reservation_not_submitted}
    end.

authorize(B, Method, Units) when is_binary(Method), is_integer(Units), Units >= 0 ->
    case safe_read(fun() ->
        ok = deployment_ready(B),
        {ok, KP} = signer(maps:get(owner, B)),
        {Ct, Path} = target(B, agent_policy),
        case decode(damage_ae:contract_call_dry(KP, Ct, Path, "authorize_method",
            [maps:get(agent_id, B), Method, integer_to_list(Units)])) of
            {ok,true,M} ->
                Ct = string_value(field(contract_id,M)),
                Owner = maps:get(owner,B), Owner = string_value(field(caller_id,M)),
                {ok,true,M};
            Other -> Other
        end
    end) of
        {ok, true, _} -> ok;
        _ -> {error, policy_rejected_or_unavailable}
    end.

settle(B, Units) when is_integer(Units), Units >= 0 ->
    case Units =:= maps:get(spent_units, B) andalso Units =< maps:get(max_cost_units, B) of
        true -> mutate(B, agent_treasury, "settle", [maps:get(job_id, B), integer_to_list(Units)]);
        false -> {error, invalid_settlement_amount}
    end.

write_receipt(B, R) ->
    %% Field order is the order in the supplied legacy wrapper, not a new ABI.
    Keys = [receipt_id, agent_id, job_id, requester, executor, feature_hash,
            report_hash, input_hash, output_hash, cost, status, started_at, ended_at],
    Args = [argument(maps:get(K, R)) || K <- Keys],
    mutate(B, agent_execution_ledger, "write_receipt", Args).

%% Deliberately no fictional get_reservation/get_receipt call. A deployment with
%% those read APIs supplies an accounting_backend implementing this callback.
%% NEVER interpret an RPC timeout or an absent middleware event as a refund.
reconcile(_B, _Receipt) -> {error, contract_reconciliation_adapter_required}.

mutate(B, Name, Function, Args) ->
    try
        ok = deployment_ready(B),
        Owner = maps:get(owner, B),
        {ok, KP} = signer(Owner),
        {Ct, Path} = target(B, Name),
        %% Serialises this adapter's writes per signer on this node. Other AE
        %% writers must share a nonce coordinator; this is not a network-wide lock.
        Lock = {{?MODULE, Owner}, self()},
        Result = global:trans(Lock, fun() ->
            %% The five-argument API takes a signer, address AND source path.
            %% The old contract_call(damage,Ct,Function,Args) was the wrong ABI.
            inclusion(damage_ae:contract_call(KP, Ct, Path, Function, Args), Ct, Owner)
        end, [node()], 0),
        case Result of
            aborted -> {error, signer_busy_not_submitted};
            _ -> Result
        end
    catch _:_ -> {error, chain_outcome_unknown}
    end.

%% Keys and return_type values have appeared as atoms, binaries and charlists.
%% Reject conflicting aliases instead of silently choosing one.
decode({ok, M}) when is_map(M) -> decode(M);
decode(M) when is_map(M) ->
    try
        RT = string_value(field(return_type, M)),
        case RT of
            <<"ok">> -> {ok, field(return_value, M), M};
            <<"revert">> -> {error, contract_reverted};
            <<"error">> -> {error, contract_failed};
            _ -> {error, invalid_contract_result}
        end
    catch _:_ -> {error, invalid_contract_result}
    end;
decode(_) -> {error, invalid_contract_result}.

inclusion(Result, Ct, Owner) ->
    case decode(Result) of
        {ok, V, M} when V =:= true; V =:= {} ->
            try
                Ct = string_value(field(contract_id, M)),
                Owner = string_value(field(caller_id, M)),
                H = field(height, M), true = is_integer(H) andalso H > 0,
                N = field(caller_nonce, M), true = is_integer(N) andalso N > 0,
                Proof0 = #{contract_id => Ct, caller_id => Owner, caller_nonce => N,
                           height => H, outcome => included},
                Proof = lists:foldl(fun(K, Acc) ->
                    case optional(K, M) of
                        missing -> Acc;
                        X when K =:= tx_hash -> Acc#{K => string_value(X)};
                        X when is_integer(X), X >= 0 -> Acc#{K => X};
                        _ -> Acc
                    end
                end, Proof0, [tx_hash, gas_used, gas_price]),
                {ok, Proof}
            catch _:_ -> {error, inclusion_not_verified}
            end;
        {ok, false, _} -> {error, contract_returned_false};
        {ok, _, _} -> {error, unexpected_mutation_return};
        E -> E
    end.

field(K, M) ->
    case optional(K, M) of missing -> error(missing_contract_field); V -> V end.
optional(K, M) ->
    Keys = [K, atom_to_binary(K, utf8), atom_to_list(K)],
    case [maps:get(A, M) || A <- Keys, maps:is_key(A, M)] of
        [] -> missing;
        [V] -> V;
        [_ | _] -> error(ambiguous_contract_fields)
    end.
string_value(B) when is_binary(B) -> B;
string_value(L) when is_list(L) -> unicode:characters_to_binary(L);
string_value(A) when is_atom(A) -> atom_to_binary(A, utf8).
argument(I) when is_integer(I) -> integer_to_list(I);
argument(B) when is_binary(B) -> B.

signer(Owner) ->
    %% No implicit node-key fallback for a missing/noncustodial requester key.
    case identity_server:get_account(Owner) of
        #{public_key := P, private_key := K} = KP when is_binary(K), byte_size(K) > 0 ->
            case string_value(P) =:= Owner of
                true -> {ok, KP}; false -> {error, signer_mismatch}
            end;
        #{public_key := P, private_key := K} = KP when is_list(K), K =/= [] ->
            case string_value(P) =:= Owner of
                true -> {ok, KP}; false -> {error, signer_mismatch}
            end;
        _ -> {error, requester_signature_required}
    end.

resolve_contract(Owner, Name) ->
    safe_read(fun() ->
        {ok, Registry} = damage_node_registry:get_registry_ct_from_node_registry(Owner),
        {ok, KP} = signer(Owner),
        contract_address(account_registry:get_contract(KP, Registry, Name))
    end).
contract_address({ok, V}) -> contract_address(V);
contract_address(<<"ct_", Rest/binary>> = Ct) when byte_size(Rest) > 0 -> {ok, Ct};
contract_address("ct_" ++ _ = Ct) -> contract_address(unicode:characters_to_binary(Ct));
contract_address({variant, [0, 1], 1, {V}}) -> contract_address(V);
contract_address({address, B}) when is_binary(B), byte_size(B) =:= 32 ->
    contract_address(aeser_api_encoder:encode(contract_pubkey, B));
contract_address(M) when is_map(M) ->
    case decode(M) of {ok, V, _} -> contract_address(V); _ -> {error, contract_lookup_failed} end;
contract_address(_) -> {error, contract_not_registered}.

deployment_ready(B) ->
    true = damage_agent_policy:env(accounting_contracts_reviewed, false) =:= true,
    {ok, Network0} = application:get_env(damage, ae_network_id),
    true = string_value(Network0) =:= maps:get(network_id, B),
    ok.
source(Name) ->
    Entries = damage_agent_policy:env(accounting_sources, []),
    S = proplists:get_value(Name, Entries),
    Path = proplists:get_value(path, S),
    true = is_list(Path) andalso filename:pathtype(Path) =:= absolute,
    Expected = proplists:get_value(sha256, S),
    true = is_binary(Expected) andalso byte_size(Expected) =:= 64,
    {ok, Bytes} = file:read_file(Path),
    Expected = string:lowercase(binary:encode_hex(crypto:hash(sha256, Bytes))),
    {ok, unicode:characters_to_binary(Path), Expected}.
target(B, Name) ->
    %% Recheck the snapshotted source bytes; a changed source must never silently
    %% change how arguments/results are encoded for an outstanding reservation.
    Path = maps:get(Name, maps:get(sources, B)),
    Expected = maps:get(Name, maps:get(source_hashes, B)),
    {ok, Bytes} = file:read_file(Path),
    Expected = string:lowercase(binary:encode_hex(crypto:hash(sha256, Bytes))),
    {maps:get(Name, maps:get(contracts, B)), binary_to_list(Path)}.
safe_read(F) -> try F() catch _:_ -> {error, contract_configuration_or_read_failed} end.

%% Management remains outside the LLM capability catalogue. Call only after
%% authenticating Requester. Budget allocation is NOT assumed to transfer tokens.
management(Action, Request) when is_map(Request) ->
    safe_read(fun() ->
        Owner = maps:get(requester, Request), AgentId = maps:get(agent_id, Request),
        true = damage_agent_policy:owner(Owner),
        true = lists:member(AgentId, proplists:get_value(Owner,
            damage_agent_policy:env(agent_bindings, []), [])),
        true = damage_agent_codec:text(AgentId, 128),
        {ok, Network} = application:get_env(damage, ae_network_id),
        {Name, Fun, Args} = management_args(Action, AgentId, Request),
        case Action of
            register ->
                {ok,PolicyCt} = resolve_contract(Owner, <<"agent_policy">>),
                {ok,TreasuryCt} = resolve_contract(Owner, <<"agent_treasury">>),
                PolicyCt = maps:get(policy_contract,Request),
                TreasuryCt = maps:get(treasury_contract,Request);
            _ -> ok
        end,
        {ok, Ct} = resolve_contract(Owner, atom_to_binary(Name, utf8)),
        {ok, Path, Hash} = source(Name),
        B = #{owner => Owner, network_id => string_value(Network),
              contracts => #{Name => Ct}, sources => #{Name => Path},
              source_hashes => #{Name => Hash}},
        mutate(B, Name, Fun, Args)
    end);
management(_, _) -> {error, missing_requester}.
management_args(register, AgentId, R) ->
    Controller = maps:get(controller, R),
    Policy = maps:get(policy_contract, R), Treasury = maps:get(treasury_contract, R),
    <<"ak_", _/binary>> = Controller,
    <<"ct_", _/binary>> = Policy, <<"ct_", _/binary>> = Treasury,
    Metadata = maps:get(metadata_hash, R), Capabilities = maps:get(capability_hash, R),
    true = damage_agent_codec:text(Metadata, 128),
    true = damage_agent_codec:text(Capabilities, 128),
    {agent_registry, "register_agent", [AgentId, Controller, Policy, Treasury, Metadata, Capabilities]};
management_args(fund, AgentId, R) ->
    N = maps:get(amount, R), true = is_integer(N) andalso N > 0 andalso N =< 9007199254740991,
    {agent_treasury, "allocate_budget", [AgentId, integer_to_list(N)]};
management_args(pause, AgentId, _) -> {agent_registry, "pause_agent", [AgentId]};
management_args(revoke, AgentId, _) -> {agent_registry, "revoke_agent", [AgentId]}.
