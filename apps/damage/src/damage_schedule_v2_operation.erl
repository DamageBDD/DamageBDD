%% Operation metadata only. Do not persist the request, signed bytes, keys,
%% backend response bodies or exception stacks in the operation journal.
-module(damage_schedule_v2_operation).
-export([identity/3, public/1, failure/2, recover/1, blocks_owner/1]).

identity(Owner, Kind, Spec0) when is_binary(Owner), is_map(Spec0) ->
    Spec = maps:without([request_id, <<"request_id">>], Spec0),
    Digest = crypto:hash(sha256, term_to_binary({Kind, Spec}, [deterministic])),
    Key = maps:get(request_id, Spec0, maps:get(<<"request_id">>, Spec0, Digest)),
    case is_binary(Key) andalso byte_size(Key) > 0 andalso byte_size(Key) =< 128 of
        true ->
            Hash = crypto:hash(sha256, term_to_binary({Owner, Kind, Key}, [deterministic])),
            Id = <<"sop_", (string:lowercase(binary:encode_hex(Hash)))/binary>>,
            {ok, Id, Digest};
        false -> {error, invalid_request_id}
    end;
identity(_, _, _) -> {error, invalid_operation}.

public(Op) ->
    maps:with([operation_id, kind, status, stage, schedule_id, created_at,
        updated_at, error, tx_hash, result, superseded_by], Op).

blocks_owner(#{status := running}) -> true;
blocks_owner(#{status := reconciliation_required}) -> true;
blocks_owner(_) -> false.

recover(#{status := running} = Op) -> failure(Op, worker_interrupted);
recover(Op) -> Op.

failure(Op, Reason) ->
    Status = failure_status(maps:get(stage, Op, queued), Reason),
    Safe = error_summary(Reason, 0),
    maps:merge(maps:remove(result, Op), Safe#{
        status => Status, updated_at => erlang:system_time(second)}).

failure_status(queued, _) -> failed;
failure_status(preparing, _) -> failed;
failure_status(ensuring_vault, schedule_v2_contract_not_configured) -> failed;
failure_status(_, _) -> reconciliation_required.

error_summary({error, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary({ok, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary({tx_poll_timeout, Meta}, _) when is_map(Meta) ->
    with_hash(#{error => <<"confirmation_timeout">>}, Meta);
error_summary({create_schedule_failed, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary({allowance_failed, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary({fund_schedule_failed, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary({signed_transaction_failed, Reason}, N) when N < 8 -> error_summary(Reason, N + 1);
error_summary(operation_deadline, _) -> #{error => <<"operation_deadline_exceeded">>};
error_summary(worker_interrupted, _) -> #{error => <<"worker_interrupted">>};
error_summary(feature_required, _) -> #{error => <<"feature_required">>};
error_summary(schedule_v2_contract_not_configured, _) -> #{error => <<"schedule_v2_contract_not_configured">>};
error_summary({invalid_cron, _}, _) -> #{error => <<"invalid_cron">>};
error_summary({invalid_lock_amount, _}, _) -> #{error => <<"invalid_lock_amount">>};
error_summary(_, _) -> #{error => <<"schedule_operation_failed">>}.

with_hash(M, Meta) ->
    case maps:get(tx_hash, Meta, undefined) of
        <<"th_", Rest/binary>> = Hash when byte_size(Rest) > 0, byte_size(Rest) =< 100 ->
            case re:run(Rest, <<"^[1-9A-HJ-NP-Za-km-z]+$">>, [{capture, none}]) of
                match -> M#{tx_hash => Hash};
                nomatch -> M
            end;
        _ -> M
    end.
