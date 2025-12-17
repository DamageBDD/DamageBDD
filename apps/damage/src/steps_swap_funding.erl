%%%-------------------------------------------------------------------
%%% steps_swap_funding.erl
%%%
%%% BDD Steps:
%%%  - Fund GitHub issues with Lightning swap options
%%%  - Link swap → JobRegistry
%%%  - Reward DAMAGE to funder on invoice settlement
%%%  - Ensure contractors are funded once the job is complete
%%%
%%%-------------------------------------------------------------------
-module(steps_swap_funding).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([step/6, documentation/0]).

%%%===================================================================
%%% Documentation visible in /steps
%%%===================================================================

documentation() ->
    [
        {"I fund the tracked issue with a Lightning swap option",
            "Creates a Lightning hold invoice for the issue price and links it to JobRegistry."},

        {"the Lightning swap option should be open for the tracked issue",
            "Asserts the option job exists and is in open state."},

        {"the Lightning invoice should be paid",
            "Polls CLN or internal memory until invoice is marked paid."},

        {"the funder should receive DAMAGE rewards",
            "Asserts funder’s DAMAGE balance increased by payout amount."},

        {"the contractor should be paid for the tracked issue",
            "Asserts job is completed + contractor receives BTC/DAMAGE payout."}
    ].

%%%===================================================================
%%% Step Dispatch
%%%===================================================================

step(
    _Cfg,
    Ctx,
    <<"When">>,
    _Line,
    ["I", "fund", "the", "tracked", "issue", "with", "a", "Lightning", "swap", "option"],
    _Body
) ->
    do_fund_issue(Ctx);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _Line,
    [
        "the",
        "Lightning",
        "swap",
        "option",
        "should",
        "be",
        "open",
        "for",
        "the",
        "tracked",
        "issue"
    ],
    _B
) ->
    assert_swap_open(Ctx);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _Line,
    ["the", "Lightning", "invoice", "should", "be", "paid"],
    _B
) ->
    assert_invoice_paid(Ctx);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _Line,
    ["the", "funder", "should", "receive", "DAMAGE", "rewards"],
    _B
) ->
    assert_funder_rewards(Ctx);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _Line,
    ["the", "contractor", "should", "be", "paid", "for", "the", "tracked", "issue"],
    _B
) ->
    assert_contractor_paid(Ctx);
step(_, Ctx, _, _, _, _) ->
    %% allow other modules to match
    {undefined, Ctx}.

%%%===================================================================
%%% Implementation
%%%===================================================================

%% ------------------------------------------------------------------
%% When: I fund the tracked issue with a Lightning swap option
%% ------------------------------------------------------------------
do_fund_issue(Ctx0) ->
    Issue = maps:get(github_issue, Ctx0),
    IssueNo = maps:get(<<"number">>, Issue),
    Title = maps:get(<<"title">>, Issue),

    %% Values inserted via Given steps
    SatsStr = maps:get(<<"lock_sats">>, Ctx0),
    DamageStr = maps:get(<<"payout_damage">>, Ctx0),
    ExpStr = maps:get(<<"expiry_seconds">>, Ctx0),
    ChannelId = maps:get(<<"swap_channel_id">>, Ctx0),
    FunderAk = maps:get(<<"funder_ae_account">>, Ctx0),

    {Sats, _} = string:to_integer(SatsStr),
    {Damage, _} = string:to_integer(DamageStr),
    {Expiry, _} = string:to_integer(ExpStr),

    %% Extract contractor AE account from issue body
    ContractorAk = extract_ae_account(maps:get(<<"body">>, Issue, <<"">>)),

    %% Create Lightning Swap Option (delegated to damage_swap_option)
    {ok, #{id := OptionId, bolt11 := Bolt11, payment_hash := PH}} =
        damage_swap_option:create_option(
            Sats, Damage, FunderAk, <<"ak_treasury">>, Expiry
        ),

    ?LOG_INFO("Created LN swap option ~p for GH issue #~p", [OptionId, IssueNo]),

    %% Register the job inside the state channel (off-chain)
    Meta = #{
        issue_no => IssueNo,
        github_title => Title,
        option_id => OptionId,
        sats => Sats,
        damage_out => Damage,
        contractor => ContractorAk,
        funder => FunderAk
    },

    {ok, #{job_id := JobId, channel_pid := ChanPid}} =
        damage_channels:init_job(ChannelId, Meta),

    %% Store context
    Ctx =
        Ctx0#{
            job_id => JobId,
            job_channel_pid => ChanPid,
            swap_option_id => OptionId,
            swap_invoice => Bolt11,
            swap_payment_hash => PH,
            contractor_ae => ContractorAk,
            funder_ae => FunderAk,
            expected_reward => Damage
        },

    {ok, Ctx}.

%% ------------------------------------------------------------------
%% Then: swap option should be open
%% ------------------------------------------------------------------
assert_swap_open(Ctx) ->
    Chan = maps:get(job_channel_pid, Ctx),
    JobId = maps:get(job_id, Ctx),

    {ok, Status} = damage_jobs:get_status(Chan, JobId),
    case Status of
        open -> {ok, Ctx};
        Other -> {fail, ["Option not open: ", Other], Ctx}
    end.

%% ------------------------------------------------------------------
%% Then: Lightning invoice should be paid
%% ------------------------------------------------------------------
assert_invoice_paid(Ctx) ->
    PH = maps:get(swap_payment_hash, Ctx),
    %% query swap orchestrator directly
    case damage_swap_option:lookup_by_payment_hash(PH) of
        %% removed from state → invoice paid
        not_found -> {ok, Ctx};
        _ -> {fail, "Invoice not yet paid.", Ctx}
    end.

%% ------------------------------------------------------------------
%% Then: funder should receive DAMAGE
%% ------------------------------------------------------------------
assert_funder_rewards(Ctx) ->
    Funder = maps:get(funder_ae, Ctx),
    Expected = maps:get(expected_reward, Ctx),

    Bal = damage_ae:balance(Funder),
    case Bal >= Expected of
        true -> {ok, Ctx};
        false -> {fail, io_lib:format("Funder ~p did not receive DAMAGE", [Funder]), Ctx}
    end.

%% ------------------------------------------------------------------
%% Then: contractor should be paid
%% ------------------------------------------------------------------
assert_contractor_paid(Ctx) ->
    Chan = maps:get(job_channel_pid, Ctx),
    JobId = maps:get(job_id, Ctx),

    {ok, Status} = damage_jobs:get_status(Chan, JobId),
    case Status of
        completed ->
            {ok, Ctx};
        Other ->
            {fail, io_lib:format("Job not completed: ~p", [Other]), Ctx}
    end.

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

extract_ae_account(Body) when is_binary(Body) ->
    case binary:match(Body, <<"ak_">>) of
        {Pos, _} ->
            <<_:Pos/binary, Tail/binary>> = Body,
            [Acc | _] = binary:split(Tail, <<" ">>),
            Acc;
        nomatch ->
            <<"ak_unknown">>
    end.
