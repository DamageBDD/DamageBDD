%%--------------------------------------------------------------------
%% Vault readiness guard.
%% Fail closed before any NIP-46 method that depends on identity or signing.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_vault_guard).

-export([assert_ready/2]).

%% Expected VaultState shape:
%% #{
%%   sealed := false,
%%   integrity := ok,
%%   pubkey_hex := <<"...">>
%% }
-spec assert_ready(map(), binary()) -> ok | {error, atom()}.
assert_ready(VaultState, ExpectedPubkeyHex) ->
    case maps:get(sealed, VaultState, true) of
        true -> {error, vault_sealed};
        false -> assert_integrity(VaultState, ExpectedPubkeyHex)
    end.

assert_integrity(VaultState, ExpectedPubkeyHex) ->
    case maps:get(integrity, VaultState, failed) of
        ok -> assert_pubkey(VaultState, ExpectedPubkeyHex);
        _ -> {error, vault_integrity_failed}
    end.

assert_pubkey(VaultState, ExpectedPubkeyHex) ->
    case maps:get(pubkey_hex, VaultState, undefined) of
        ExpectedPubkeyHex -> ok;
        _Other -> {error, vault_pubkey_mismatch}
    end.
