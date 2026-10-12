-module(damage_schedule_v2_contract).

-export([
    contract_address/0,
    ensure_contract/0,
    setup/0,
    is_custodial_wallet/1,
    deploy/0,
    create_schedule/2,
    fund_schedule/3,
    pause_schedule/2,
    resume_schedule/2,
    cancel_schedule/2,
    reserve_run/3,
    settle_run/6,
    release_run/2,
    mark_exhausted/1,
    prepare_token_upgrade/1,
    claim_token_upgrade/0,
    finish_token_upgrade/0,
    prepare_user_call/3,
    prepare_allowance/2,
    approve_allowance/2,
    post_signed/1,
    wait_tx_hash/1,
    call_result_ok/1,
    token_contract/0,
    contract_source/0
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-spec contract_address() -> {ok, binary()} | {error, term()}.
contract_address() ->
    case application:get_env(damage, schedule_v2_contract) of
        {ok, Value} -> {ok, to_bin(Value)};
        undefined ->
            retrieve_stored_contract_address()
    end.

retrieve_stored_contract_address() ->
    try secrets:retrieve_decrypt(schedule_v2_contract) of
        {ok, Value0} -> {ok, to_bin(Value0)};
        _ -> {error, schedule_v2_contract_not_configured}
    catch
        Class:Reason ->
            ?LOG_DEBUG(
                "Schedule V2 contract address lookup failed class=~p reason=~p",
                [Class, Reason]
            ),
            {error, schedule_v2_contract_not_configured}
    end.

-spec token_contract() -> binary().
token_contract() -> to_bin(?DAMAGE_TOKEN_CONTRACT).

-spec contract_source() -> string().
contract_source() ->
    resolve_contract_source(
        application:get_env(damage, schedule_v2_contract_source, "contracts/schedule_v2.aes")
    ).

token_source() ->
    resolve_contract_source(
        application:get_env(damage, damage_token_contract_source, "contracts/token.aes")
    ).

resolve_contract_source(Path0) ->
    Path =
        case Path0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L
        end,
    case filelib:is_file(Path) of
        true -> Path;
        false -> damage_ae:contract_path(damage, Path)
    end.

ensure_contract() ->
    damage_contract_bootstrap:ensure_schedule_vault().

%% Kept for the HTTP/admin recovery path, but all deployment and persistence
%% now goes through damage_contract_bootstrap so startup and UI use one source
%% of truth and cannot race separate vault deployments.
setup() ->
    damage_contract_bootstrap:ensure_schedule_vault().

deploy() ->
    damage_contract_bootstrap:ensure_schedule_vault().

create_schedule(Owner, Spec) ->
    call_user(
        Owner,
        "create_schedule",
        [
            to_s(maps:get(id, Spec)),
            to_s(maps:get(feature_hash, Spec)),
            to_s(maps:get(feature_title, Spec, <<"Feature">>)),
            to_s(maps:get(cron_spec, Spec)),
            integer_to_list(maps:get(start_at, Spec, 0)),
            integer_to_list(maps:get(end_at, Spec, 0)),
            integer_to_list(maps:get(concurrency, Spec, 1)),
            integer_to_list(maps:get(max_cost_per_run, Spec))
        ]
    ).

fund_schedule(Owner, ScheduleId, Amount) ->
    call_user(Owner, "fund_schedule", [to_s(ScheduleId), integer_to_list(Amount)]).

pause_schedule(Owner, ScheduleId) ->
    call_user(Owner, "pause_schedule", [to_s(ScheduleId)]).

resume_schedule(Owner, ScheduleId) ->
    call_user(Owner, "resume_schedule", [to_s(ScheduleId)]).

cancel_schedule(Owner, ScheduleId) ->
    call_user(Owner, "cancel_schedule", [to_s(ScheduleId)]).

reserve_run(ScheduleId, RunId, Amount) ->
    call_executor("reserve_run", [to_s(ScheduleId), to_s(RunId), integer_to_list(Amount)]).

settle_run(ScheduleId, RunId, Node, Amount, FeatureHash, ReportHash) ->
    call_executor(
        "settle_run",
        [
            to_s(ScheduleId),
            to_s(RunId),
            to_s(Node),
            integer_to_list(Amount),
            to_s(FeatureHash),
            to_s(ReportHash)
        ]
    ).

release_run(ScheduleId, RunId) ->
    call_executor("release_run", [to_s(ScheduleId), to_s(RunId)]).

mark_exhausted(ScheduleId) ->
    call_executor("mark_exhausted", [to_s(ScheduleId)]).

prepare_token_upgrade(NewToken) ->
    call_node_owner("prepare_token_upgrade", [to_s(NewToken)]).

claim_token_upgrade() ->
    call_node_owner("claim_token_upgrade", []).

finish_token_upgrade() ->
    call_node_owner("finish_token_upgrade", []).

prepare_user_call(Owner, Func, Args) ->
    case contract_address() of
        {ok, Contract} ->
            safe_eval(fun() ->
                damage_ae:contract_call_prepare_tx(
                    #{public_key => to_bin(Owner)}, Contract, contract_source(), Func, Args
                )
            end);
        Error -> Error
    end.

prepare_allowance(Owner0, RequestedAmount0) ->
    Owner = to_bin(Owner0),
    RequestedAmount = RequestedAmount0,
    case contract_address() of
        {ok, Contract} ->
            Exists = allowance_exists(Owner, Contract),
            {Func, Args} =
                case Exists of
                    true ->
                        {"change_allowance", [to_s(Contract), integer_to_list(RequestedAmount)]};
                    false ->
                        {"create_allowance", [to_s(Contract), integer_to_list(RequestedAmount)]}
                end,
            case safe_eval(fun() ->
                damage_ae:contract_call_prepare_tx(
                    #{public_key => Owner}, token_contract(), token_source(), Func, Args
                )
            end) of
                {ok, Tx} ->
                    {ok, #{tx => Tx, allowance_action => list_to_binary(Func), amount => RequestedAmount}};
                Error -> Error
            end;
        Error -> Error
    end.

approve_allowance(Owner0, RequestedAmount0) ->
    Owner = to_bin(Owner0),
    RequestedAmount = RequestedAmount0,
    case contract_address() of
        {ok, Contract} ->
            Exists = allowance_exists(Owner, Contract),
            {Func, Args} =
                case Exists of
                    true -> {"change_allowance", [to_s(Contract), integer_to_list(RequestedAmount)]};
                    false -> {"create_allowance", [to_s(Contract), integer_to_list(RequestedAmount)]}
                end,
            safe_eval(fun() ->
                damage_ae:contract_call(Owner, token_contract(), token_source(), Func, Args)
            end);
        Error -> Error
    end.

allowance_exists(Owner, Contract) ->
    KeyPair = #{public_key => Owner, private_key => <<>>},
    try damage_ae:contract_call_dry(
        KeyPair,
        token_contract(),
        token_source(),
        "change_allowance",
        [to_s(Contract), "0"]
    ) of
        Result -> call_result_ok(Result)
    catch
        _:_ -> false
    end.

call_user(Owner0, Func, Args) ->
    Owner = to_bin(Owner0),
    case is_custodial(Owner) of
        true ->
            case contract_address() of
                {ok, Contract} ->
                    safe_eval(fun() ->
                        damage_ae:contract_call(Owner, Contract, contract_source(), Func, Args)
                    end);
                Error -> Error
            end;
        false ->
            case prepare_user_call(Owner, Func, Args) of
                {ok, Tx} -> {signing_required, #{stage => list_to_binary(Func), tx => Tx}};
                Error -> Error
            end
    end.

call_executor(Func, Args) ->
    call_node_owner(Func, Args).

call_node_owner(Func, Args) ->
    case contract_address() of
        {ok, Contract} ->
            KeyPair = secrets:node_keypair(),
            safe_eval(fun() ->
                damage_ae:contract_call(KeyPair, Contract, contract_source(), Func, Args)
            end);
        Error -> Error
    end.

post_signed(SignedTx0) ->
    SignedTx = to_bin(SignedTx0),
    case vanillae:post_tx(SignedTx) of
        {ok, Posted} when is_map(Posted) ->
            case map_get_any(["tx_hash", <<"tx_hash">>, tx_hash], Posted, undefined) of
                undefined -> {error, {missing_tx_hash, Posted}};
                TxHash ->
                    Result = damage_ae:wait_tx(TxHash),
                    {ok, Result}
            end;
        Error -> {error, {post_tx_failed, Error}}
    end.

wait_tx_hash(TxHash0) ->
    TxHash = to_bin(TxHash0),
    try damage_ae:wait_tx(TxHash) of
        Result -> {ok, Result}
    catch
        Class:Reason:Stack -> {error, {wait_tx_failed, Class, Reason, Stack}}
    end.

call_result_ok({ok, Result}) -> call_result_ok(Result);
call_result_ok(Result) when is_map(Result) ->
    Value = map_get_any(["return_type", <<"return_type">>, return_type], Result, undefined),
    Value =:= "ok" orelse Value =:= <<"ok">> orelse Value =:= ok;
call_result_ok(_) -> false.

is_custodial_wallet(undefined) ->
    false;
is_custodial_wallet(Owner) ->
    try damage_ae:is_custodial(to_bin(Owner)) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

is_custodial(Owner) ->
    is_custodial_wallet(Owner).

safe_eval(Fun) when is_function(Fun, 0) ->
    try Fun() of
        Value -> {ok, Value}
    catch
        Class:Reason:Stack -> {error, {contract_operation_failed, Class, Reason, Stack}}
    end.

map_get_any([K | Rest], Map, Default) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> map_get_any(Rest, Map, Default)
    end;
map_get_any([], _Map, Default) -> Default.

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L;
to_s(A) when is_atom(A) -> atom_to_list(A);
to_s(I) when is_integer(I) -> integer_to_list(I).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
