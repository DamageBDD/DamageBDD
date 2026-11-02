%%% AEX-141 adapter. Stateful calls use tracked writes; queries are dry-run ONLY.
%%% A failed/unknown post must NEVER be treated as a confirmed entitlement.
-module(damage_theme_nft).
-export([status/0, configured/0, register/2, is_registered/1,
         purchase_damage/2, mint_sats/3, owns/3, sats_token/1, registered_matches/3, contract_source/0]).

-define(SOURCE, "contracts/theme_nft.aes").
-define(DEFAULT_TOKEN, "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk").

contract_source() -> damage_ae:contract_path(damage, ?SOURCE).
contract() -> to_bin(application:get_env(damage, theme_nft_contract, <<>>)).
configured() ->
    case contract() of
        <<"ct_", _/binary>> = C ->
            try {contract_pubkey, _} = aeser_api_encoder:decode(C), true
            catch _:_ -> false end;
        _ -> false
    end.
status() -> #{enabled => configured(), standard => <<"AEX-141">>,
              contract => case configured() of true -> contract(); false -> null end,
              damage_token => to_bin(application:get_env(damage, theme_damage_token_contract, ?DEFAULT_TOKEN))}.

register(Manifest, Cid) ->
    case configured() of
        false -> {error, theme_nft_not_configured};
        true ->
            Key = maps:get(<<"key">>, Manifest),
            case is_registered(Key) of
                true -> {error, already_registered};
                false ->
                    KeyPair = secrets:node_keypair(),
                    #{public_key := Publisher} = KeyPair,
                    Args = [binary_to_list(Key), binary_to_list(Publisher), binary_to_list(Cid),
                            binary_to_list(maps:get(<<"sha256">>, Manifest)),
                            integer_to_list(maps:get(<<"price_damage">>, Manifest)),
                            integer_to_list(maps:get(<<"price_sats">>, Manifest))],
                    case damage_ae:contract_call_tracked(KeyPair, contract(), contract_source(), "register_theme", Args) of
                        {ok, Result} ->
                            case is_registered(Key) of
                                true -> {ok, #{status => registered, result => public_result(Result)}};
                                false -> {error, registration_outcome_unknown}
                            end;
                        {error, _} -> {error, registration_outcome_unknown}
                    end;
                unknown -> {error, chain_unavailable}
            end
    end.

is_registered(Key) ->
    case query("theme", [to_s(Key)]) of
        {ok, V} ->
            case damage_release_nft:option_value(V) of
                {ok, _} -> true;
                none -> false;
                _ -> unknown
            end;
        _ -> unknown
    end.

%% Read the immutable CID and SHA, not merely existence, before importing a
%% package from another node or acknowledging an uncertain registration.
registered_matches(Key, CID, Sha) ->
    case query("theme", [to_s(Key)]) of
        {ok, Value} ->
            case damage_release_nft:option_value(Value) of
                {ok, Record} -> match_theme_record(Record, CID, Sha);
                none -> false;
                _ -> unknown
            end;
        _ -> unknown
    end.
match_theme_record({tuple, {_, Cid, Digest, _, _}}, Cid, Digest) -> true;
match_theme_record({_, Cid, Digest, _, _}, Cid, Digest) -> true;
match_theme_record([_, Cid, Digest, _, _], Cid, Digest) -> true;
match_theme_record(#{<<"manifest_cid">> := Cid, <<"manifest_sha256">> := Digest}, Cid, Digest) -> true;
match_theme_record(_, _, _) -> false.

%% When the managed account has already approved the contract as AEX-9 spender,
%% this operation atomically collects DAMAGE and mints the licence. Wallet-only
%% sessions must execute the same entrypoint in their external wallet.
purchase_damage(#{public_key := Account, private_key := Private} = _Actor, Key) when
    is_binary(Account), is_binary(Private) ->
    case configured() of
        true ->
            case damage_ae:contract_call_tracked(
                #{public_key => Account, private_key => Private},
                contract(), contract_source(), "buy_damage", [to_s(Key)]
            ) of
                {ok, Result} -> {ok, public_result(Result)};
                {error, #{status := rejected} = Rejection} ->
                    {error, {chain_rejected, maps:with([status, stage, reason], Rejection)}};
                {error, _} -> {error, purchase_outcome_unknown}
            end;
        false -> {error, theme_nft_not_configured}
    end;
purchase_damage(_, _) -> {error, wallet_signature_required}.

%% The caller of mint_sats/3 must have verified the CLN invoice is paid and
%% the amount, label and payment hash match the durable order.
mint_sats(Recipient, ThemeKey, PaymentId) ->
    case sats_token(PaymentId) of
        {ok, Token} -> verified_sats(Token, Recipient, ThemeKey);
        none ->
            case configured() of
                false -> {error, theme_nft_not_configured};
                true ->
                    KeyPair = secrets:node_keypair(),
                    Args = [to_s(Recipient), to_s(ThemeKey), to_s(PaymentId)],
                    %% Never retry automatically after an uncertain submission.
                    _ = damage_ae:contract_call_tracked(
                        KeyPair, contract(), contract_source(), "mint_sats", Args),
                    case sats_token(PaymentId) of
                        {ok, Token} -> verified_sats(Token, Recipient, ThemeKey);
                        _ -> {error, mint_outcome_unknown}
                    end
            end;
        {error, _} -> {error, chain_unavailable}
    end.

verified_sats(Token, Recipient, Key) ->
    case owns(Token, Key, Recipient) of
        true -> {ok, Token};
        false -> {error, nft_entitlement_mismatch};
        unknown -> {error, chain_unavailable}
    end.

sats_token(PaymentId) ->
    case query("sats_purchase_token", [to_s(PaymentId)]) of
        {ok, V} ->
            case damage_release_nft:option_value(V) of
                {ok, Id} when is_integer(Id), Id > 0 -> {ok, Id};
                none -> none;
                _ -> {error, invalid_receipt}
            end;
        _ -> {error, chain_unavailable}
    end.

owns(Token, ThemeKey, Account) when is_integer(Token), Token > 0 ->
    case {query("owner", [integer_to_list(Token)]),
          query("token_theme", [integer_to_list(Token)])} of
        {{ok, OwnerValue}, {ok, ThemeValue}} ->
            case {damage_release_nft:option_value(OwnerValue),
                  damage_release_nft:option_value(ThemeValue)} of
                {{ok, Owner}, {ok, Theme}} ->
                    normalize_owner(Owner) =:= Account andalso to_bin(Theme) =:= ThemeKey;
                {none, _} -> false;
                {_, none} -> false;
                _ -> unknown
            end;
        _ -> unknown
    end;
owns(_, _, _) -> false.

normalize_owner({address, Raw}) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    aeser_api_encoder:encode(account_pubkey, Raw);
normalize_owner({account_pubkey, Raw}) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    aeser_api_encoder:encode(account_pubkey, Raw);
normalize_owner(Raw) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    aeser_api_encoder:encode(account_pubkey, Raw);
normalize_owner(<<"ak_", _/binary>> = Owner) -> Owner;
normalize_owner(_) -> undefined.

query(Func, Args) ->
    case configured() of
        false -> {error, not_configured};
        true ->
            try
                %% Use existing configured node keypair; dry-run cannot post a tx.
                #{public_key := _Reader} = KeyPair = secrets:node_keypair(),
                damage_release_nft:call_return(damage_ae:contract_call_dry(
                    KeyPair, contract(), contract_source(), Func, Args))
            catch _:_ -> {error, chain_query_failed} end
    end.
public_result(Result) when is_map(Result) ->
    maps:with([status, tx_hash, stage], Result);
public_result(_) -> #{status => unknown}.
to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(S) when is_list(S) -> S.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(_) -> <<>>.
