%%% Implement against the user's wallet service / official Ae SDK bridge.
%%% This is a contract, NOT a fake wallet or a private-key store.
-module(erm_lens_wallet_adapter).
-callback status(map()) -> {ok, #{account := binary(), network := binary()}} | {error, term()}.
-callback token_meta(binary(), map()) ->
    {ok, #{decimals := non_neg_integer(), symbol := binary()}} | {error, term()}.
-callback resolve_account(binary(), map()) ->
    {ok, #{attestation := map(), claim := map()}} | {error, term()}.
-callback prepare_tip(map(), map()) ->
    {ok, #{request := map(), fee_aettos := non_neg_integer()}} | {error, term()}.
%%% submit_tip MUST bind the decoded transaction to request, obtain explicit
%%% wallet approval, durably deduplicate request_id per sender/network, and
%%% reconcile an ambiguous broadcast before any retry. A timeout is not proof
%%% of non-submission. Recheck request expiry after approval and immediately
%%% before broadcasting. The Lens UI cannot provide chain-level exactly-once.
-callback submit_tip(map(), map()) -> {ok, map()} | {error, term()}.
-callback register_account(map(), map()) -> {ok, map()} | {error, term()}.
