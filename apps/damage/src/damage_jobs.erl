%%--------------------------------------------------------------------
%% damage_jobs.erl — High-level JobRegistry interface + operator tools
%%
%% Defaults assume:
%%   - Contract source at priv/contracts/JobRegistry.aes
%%   - You pass the on-chain contract id (<<"ct_...">>) via Opts or env
%%
%% All public calls accept Opts:
%%   #{ct := <<"ct_...">>, src := "contracts/JobRegistry.aes", payfor := boolean()}
%%
%% By default, payfor=false (caller pays fees). Set payfor=true to have the
%% node wrap as PayingFor using damage_ae:payfor_tx/1 path.
%%--------------------------------------------------------------------
-module(damage_jobs).
-compile(warn_export_all).

-include_lib("kernel/include/logger.hrl").

%% ─── Public API ───────────────────────────────────────────────────────────────
-export([
    %% Client/job lifecycle

    % submit(AeAccount, FeatureHash, BudgetAetto, Opts)
    submit/4,
    % dry_run_ack(AeAccount, JobId, Opts)
    dry_run_ack/3,
    % start(AeAccount, JobId, Opts)
    start/3,
    % record_step(ChanPidOrNone, JobId, StepIdx, StepHash, PriceAetto, Opts)
    record_step/6,
    % settle_batch(AeAccount, JobId, StepsRoot, Count, Sigs, Opts, Mode)
    settle_batch/7,

    %% Views (no state change)

    % job_info(Viewer, JobId, Opts)
    job_info/3,
    % job_status(Viewer, JobId, Opts)
    job_status/3,

    %% Operator convenience

    % op_set_fee_bps(Operator, Bps, Opts)
    op_set_fee_bps/3,
    % op_set_runner(Operator, NodeAk, Opts)
    op_set_runner/3,
    % op_withdraw(Operator, ToAk, Opts)
    op_withdraw/3,
    % op_pause(Operator, JobId, Opts)
    op_pause/3,
    % op_unpause(Operator, JobId, Opts)
    op_unpause/3,
    % deploy node job registry
    deploy_jobregistry/0,
    ct_id/1
]).

%% ─── Defaults ────────────────────────────────────────────────────────────────
-define(DEFAULT_SRC, "contracts/JobRegistry.aes").

-define(JOB_REGISTRY_CONTRACT,
    "ct_JJGKrTpqtivJCfMGJZo9iWrmKTFyD47ipCiNLtdiqxtnQ3PKQ"
).

%% Pull the contract id from Opts or application env
-spec ct_id(map()) -> binary().
ct_id(Opts) ->
    case maps:get(ct, Opts, undefined) of
        <<"ct_", _/binary>> = Ct ->
            Ct;
        _ ->
            case application:get_env(damage, job_registry_ct) of
                {ok, <<"ct_", _/binary>> = C} -> C;
                _ -> error({missing_contract_id, job_registry_ct})
            end
    end.

-spec src(map()) -> string().
src(Opts) ->
    maps:get(src, Opts, ?DEFAULT_SRC).

-spec use_payfor(map()) -> boolean().
use_payfor(Opts) -> maps:get(payfor, Opts, false).

%% Helpers to format common Sophia args (strings/ints)
to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(I) when is_integer(I) -> integer_to_list(I);
to_s(L) when is_list(L) -> L.

%% ─── Thin wrappers around damage_ae posting paths ────────────────────────────
call_user(AeAccount, Ct, Src, Fun, Args, Opts) ->
    case use_payfor(Opts) of
        true -> damage_ae:contract_call_payfor_user(AeAccount, Ct, Src, Fun, Args);
        false -> damage_ae:contract_call(AeAccount, Ct, Src, Fun, Args)
    end.

view_user(AeAccount, Ct, Src, Fun, Args) ->
    damage_ae:contract_call_dry(AeAccount, Ct, Src, Fun, Args).

%% ─── Client-facing flows ─────────────────────────────────────────────────────

%% 1) Submit a feature for execution with a max budget (aetto)
%%    Sophia: submit(feature_hash : string, budget_aetto : int)
submit(AeAccount, FeatureHash, BudgetAetto, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    Args = [to_s(FeatureHash), to_s(BudgetAetto)],
    call_user(AeAccount, Ct, Src, "submit", Args, Opts).

%% 2) Confirm you accept the dry-run result produced by node (bind the dry_run_hash)
%%    Sophia: dry_run_ack(job_id : string)
dry_run_ack(AeAccount, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    Args = [to_s(JobId)],
    call_user(AeAccount, Ct, Src, "dry_run_ack", Args, Opts).

%% 3) Start execution after ack
%%    Sophia: start(job_id : string)
start(AeAccount, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(AeAccount, Ct, Src, "start", [to_s(JobId)], Opts).

%% 4) Record a single step success + pay price (channel path or direct)
%% If ChanPid is a channel pid, we use an off-chain contract_call update
%% (cheaper, round++). Else we call on-chain and pay gas.
%%    Sophia: record_step(job_id : string, step_idx : int, step_hash : string, price : int)
record_step(ChanPidOrNone, JobId, StepIdx, StepHash, PriceAetto, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    %% entrypoint
    Fun = <<"record_step">>,
    ArgsFate = [to_s(JobId), StepIdx, to_s(StepHash), PriceAetto],
    case ChanPidOrNone of
        undefined ->
            %% on-chain
            call_user(
                maps:get(public_key, Opts, admin),
                Ct,
                Src,
                "record_step",
                [to_s(JobId), to_s(StepIdx), to_s(StepHash), to_s(PriceAetto)],
                Opts
            );
        Pid when is_pid(Pid) ->
            %% off-chain update via your channels module (two-phase, round++)
            %% Gas estimate for off-chain VM path; adjust if needed.
            Gas = 3_000_000,
            Meta = #{job_id => JobId, step_idx => StepIdx, step_hash => StepHash},
            damage_channels:channel_contract_call(
                %% amount=0
                Pid,
                Ct,
                Src,
                Fun,
                ArgsFate,
                Gas,
                0,
                Meta
            )
    end.

%% 5) Settle multiple steps at once with Merkle root + sigs
%%    Sophia: settle_batch(job_id : string, steps_root : string, count : int, sigs : list(bytes))
%% Mode: 'payfor | 'direct (who pays fees)
settle_batch(AeAccount, JobId, StepsRoot, Count, SigsBytes, Opts, Mode) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    %% keep args shape compatible with your earlier call style
    EncodedSigs =
        "[" ++ string:join([to_s(binary_to_integer(S)) || S <- SigsBytes], ",") ++ "]",
    Args = [to_s(JobId), to_s(StepsRoot), to_s(Count), EncodedSigs],
    Opts1 =
        case Mode of
            payfor -> maps:put(payfor, true, Opts);
            _ -> Opts
        end,
    call_user(AeAccount, Ct, Src, "settle_batch", Args, Opts1).

%% ─── Views ───────────────────────────────────────────────────────────────────

job_info(Viewer, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    view_user(Viewer, Ct, Src, "get_job", [to_s(JobId)]).

job_status(Viewer, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    view_user(Viewer, Ct, Src, "get_status", [to_s(JobId)]).

%% ─── Operator tools ──────────────────────────────────────────────────────────

%% Set protocol fee bps (e.g., 50 = 0.50%)
op_set_fee_bps(Operator, Bps, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(Operator, Ct, Src, "set_fee_bps", [to_s(Bps)], Opts).

%% Set/rotate the runner node (ak_... account that executes)
op_set_runner(Operator, NodeAk, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(Operator, Ct, Src, "set_runner", [to_s(NodeAk)], Opts).

%% Withdraw accumulated protocol fees to ToAk
op_withdraw(Operator, ToAk, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(Operator, Ct, Src, "withdraw_fees", [to_s(ToAk)], Opts).

op_pause(Operator, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(Operator, Ct, Src, "pause_job", [to_s(JobId)], Opts).

op_unpause(Operator, JobId, Opts) ->
    Ct = ct_id(Opts),
    Src = src(Opts),
    call_user(Operator, Ct, Src, "unpause_job", [to_s(JobId)], Opts).

deploy_jobregistry() ->
    damage_ae:contract_deploy(?DEFAULT_SRC, []).
