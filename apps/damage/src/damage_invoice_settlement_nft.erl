%%%-------------------------------------------------------------------
%%% Optional AEX-141 settlement attestation + reward for paid invoices.
%%%
%%% The public token commits to private invoice/payment state by SHA-256 only.
%%% No customer name, email, address, amount, payment reference or invoice PDF
%%% is passed to the contract. The NFT is intentionally transferable; transfer
%%% changes collectible ownership, never the private invoice or receivable.
%%%-------------------------------------------------------------------
-module(damage_invoice_settlement_nft).
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([status/0, prepare/1, prepare/2, mint/1, attestation_hash/1, contract_source/0]).
-ifdef(TEST).
-export([configured/0, reward_class/0, lookup_token/3]).
-endif.

-define(SOURCE, "contracts/invoice_settlement_nft.aes").

status() ->
    Contract = configured_contract(),
    #{
        enabled => configured(),
        contract_id =>
            case Contract of
                <<>> -> null;
                _ -> Contract
            end,
        reward_class => reward_class(),
        standard => <<"AEX-141">>,
        transferable => true
    }.

configured() ->
    C = settlement_cfg(),
    proplists:get_value(enabled, C, false) =:= true andalso
        valid_contract_text(configured_contract()).

reward_class() ->
    V = to_bin(proplists:get_value(reward_class, settlement_cfg(), <<"settlement">>)),
    case re:run(V, <<"^[A-Za-z0-9_-]{1,32}$">>, [{capture, none}]) of
        match -> V;
        nomatch -> <<"settlement">>
    end.

prepare(I) when is_map(I) ->
    Customer = maps:get(customer, I, #{}),
    prepare(I, maps:get(account, Customer, <<>>));
prepare(_) ->
    {error, <<"Invalid invoice settlement state">>}.

prepare(I, Recipient) when is_map(I), is_binary(Recipient) ->
    case configured() of
        false ->
            {error, <<"Settlement reward NFT is not enabled on this node">>};
        true ->
            case valid_account_text(Recipient) of
                false ->
                    {error,
                        <<"Choose a valid Aeternity settlement account before minting a reward">>};
                true ->
                    {ok, #{
                        status => <<"queued">>,
                        attestation_sha256 => attestation_hash(I),
                        recipient => Recipient,
                        contract_id => configured_contract(),
                        reward_class => reward_class()
                    }}
            end
    end;
prepare(_, _) ->
    {error, <<"Invalid invoice settlement recipient">>}.

attestation_hash(I) when is_map(I) ->
    Customer = maps:get(customer, I, #{}),
    Canonical = #{
        schema_version => 1,
        invoice_id => maps:get(id, I, <<>>),
        invoice_number => maps:get(number, I, null),
        plan_id => maps:get(plan_id, I, <<>>),
        customer_id => maps:get(id, Customer, <<>>),
        pdf_sha256 => maps:get(pdf_sha256, I, <<>>),
        paid_on => maps:get(paid_on, I, <<>>),
        payment_reference => maps:get(payment_reference, I, <<>>),
        currency => maps:get(currency, I, <<>>),
        total_minor => maps:get(total_minor, I, 0)
    },
    lower_hex(crypto:hash(sha256, term_to_binary(Canonical, [deterministic]))).

mint(I) when is_map(I) ->
    try
        true = maps:get(status, I) =:= <<"paid">>,
        S = maps:get(settlement_nft, I),
        Hash = maps:get(attestation_sha256, S),
        true = Hash =:= attestation_hash(I),
        Recipient = maps:get(recipient, S),
        Contract = maps:get(contract_id, S),
        Reward = maps:get(reward_class, S),
        ok = validate_encoded(account_pubkey, Recipient),
        ok = validate_encoded(contract_pubkey, Contract),
        KeyPair = secrets:node_keypair(),
        #{public_key := _Public, private_key := _Private} = KeyPair,
        case lookup_token(KeyPair, Contract, Hash) of
            {ok, Token} ->
                {ok, result(Token, Contract, Hash, Recipient, Reward, true, undefined)};
            none ->
                mint_new(KeyPair, Contract, Hash, Recipient, maps:get(paid_on, I), Reward);
            {error, _} ->
                {error, settlement_lookup_failed}
        end
    catch
        _:_ -> {error, settlement_mint_failed}
    end;
mint(_) ->
    {error, settlement_mint_failed}.

mint_new(KeyPair, Contract, Hash, Recipient, PaidOn, Reward) ->
    Args = [to_list(Recipient), to_list(Hash), to_list(PaidOn), to_list(Reward)],
    %% Use the tracked write path: it performs a final dry-run, submits exactly
    %% once and distinguishes execution rejection from an uncertain submission.
    %% The tracked API deliberately does not expose the contract return value,
    %% so the immutable attestation index is the source of truth for token id.
    Outcome = damage_ae:contract_call_tracked(
        KeyPair, Contract, contract_source(), "mint_settlement", Args
    ),
    reconcile_mint(Outcome, KeyPair, Contract, Hash, Recipient, Reward).

reconcile_mint(
    {error, #{status := rejected} = Rejection} = Outcome,
    KeyPair,
    Contract,
    Hash,
    Recipient,
    Reward
) ->
    %% A duplicate/idempotency race can legitimately reject a second write
    %% after the first one has mined. Reconcile the unique hash before treating
    %% any execution rejection as terminal.
    case lookup_token(KeyPair, Contract, Hash) of
        {ok, Token} ->
            {ok, result(Token, Contract, Hash, Recipient, Reward, true, tx_hash(Outcome))};
        none ->
            {error, {settlement_mint_rejected, redacted_rejection(Rejection)}};
        {error, _} ->
            %% A prior uncertain attempt may already have minted the unique
            %% attestation. If reconciliation is unavailable, keep the outcome
            %% unknown rather than allowing a conflicting recipient retry.
            {error, settlement_outcome_unknown}
    end;
reconcile_mint({error, Reason}, _KeyPair, _Contract, _Hash, _Recipient, _Reward) when
    Reason =:= invalid_signing_keypair; Reason =:= transaction_prepare_failed
->
    {error, settlement_mint_failed};
reconcile_mint(Outcome, KeyPair, Contract, Hash, Recipient, Reward) ->
    %% Once a POST may have happened we never infer failure from a missing
    %% response. Query the contract's unique hash index. If the token is not yet
    %% visible, surface an unknown outcome; an explicit retry is idempotent at
    %% contract level and will reconcile the same attestation hash.
    case lookup_token(KeyPair, Contract, Hash) of
        {ok, Token} ->
            {ok,
                result(
                    Token,
                    Contract,
                    Hash,
                    Recipient,
                    Reward,
                    outcome_reused(Outcome),
                    tx_hash(Outcome)
                )};
        none ->
            case Outcome of
                {ok, #{status := confirmed}} -> {error, settlement_outcome_unknown};
                {ok, #{status := submitted}} -> {error, settlement_outcome_unknown};
                {ok, #{status := submission_unknown}} -> {error, settlement_outcome_unknown};
                _ -> {error, settlement_outcome_unknown}
            end;
        {error, _} ->
            {error, settlement_outcome_unknown}
    end.

lookup_token(#{public_key := _, private_key := _} = KeyPair, Contract, Hash) ->
    %% Reads must stay read-only. Do not use contract_query/5 here because that
    %% helper may fall back to an on-chain call when dry-run is unavailable.
    case
        damage_ae:contract_call_dry(
            KeyPair, Contract, contract_source(), "settlement_token", [to_list(Hash)]
        )
    of
        Call when is_map(Call) ->
            case damage_release_nft:call_return(Call) of
                {ok, Encoded} ->
                    case damage_release_nft:option_value(Encoded) of
                        {ok, Token} when is_integer(Token), Token > 0 -> {ok, Token};
                        none -> none;
                        _ -> {error, invalid_settlement_lookup}
                    end;
                _ ->
                    {error, settlement_lookup_failed}
            end;
        _ ->
            {error, settlement_lookup_failed}
    end.

outcome_reused({ok, #{status := confirmed}}) -> false;
outcome_reused(_) -> true.

redacted_rejection(Rejection) ->
    maps:with([status, stage, reason], Rejection).

result(Token, Contract, Hash, Recipient, Reward, Reused, TxHash) ->
    Base = #{
        token_id => Token,
        contract_id => Contract,
        attestation_sha256 => Hash,
        recipient => Recipient,
        reward_class => Reward,
        reused => Reused
    },
    case TxHash of
        undefined -> Base;
        _ -> Base#{tx_hash => TxHash}
    end.

tx_hash({ok, Call}) ->
    tx_hash(Call);
tx_hash({error, Call}) when is_map(Call) -> tx_hash(Call);
tx_hash(Call) when is_map(Call) ->
    first([
        maps:get(tx_hash, Call, undefined),
        maps:get("tx_hash", Call, undefined),
        maps:get(<<"tx_hash">>, Call, undefined)
    ]);
tx_hash(_) ->
    undefined.
first([undefined | Rest]) -> first(Rest);
first([V | _]) when is_binary(V); is_list(V) -> to_bin(V);
first([_ | Rest]) -> first(Rest);
first([]) -> undefined.

settlement_cfg() ->
    case damage_enterprise_invoices:cfg(settlement_nft, []) of
        C when is_list(C) -> C;
        _ -> []
    end.
configured_contract() -> to_bin(proplists:get_value(contract_id, settlement_cfg(), <<>>)).
valid_contract_text(B) -> valid_encoded_text(contract_pubkey, B).
valid_account_text(B) -> valid_encoded_text(account_pubkey, B).
valid_encoded_text(Type, B) when is_binary(B), byte_size(B) < 100 ->
    try aeser_api_encoder:decode(B) of
        {Type, Raw} when is_binary(Raw), byte_size(Raw) =:= 32 -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_encoded_text(_, _) ->
    false.
validate_encoded(Type, Encoded) ->
    case aeser_api_encoder:decode(Encoded) of
        {Type, Raw} when is_binary(Raw), byte_size(Raw) =:= 32 -> ok;
        _ -> error(invalid_encoded_id)
    end.

contract_source() -> damage_ae:contract_path(damage, ?SOURCE).
lower_hex(B) -> string:lowercase(binary:encode_hex(B)).
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(_) -> <<>>.
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
