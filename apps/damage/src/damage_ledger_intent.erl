%% -------------------------------------------------------------------
%% damage_ledger_intent.erl
%%
%% Produces wallet-signable "intents" for AE deployments + contract calls.
%% Used by /api/nwc/mint to support:
%%   - user_signed: return intents to wallet UI
%%   - server_signed: server executes the same intents
%% -------------------------------------------------------------------

-module(damage_ledger_intent).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([
    deploy_ledger_intent/2,
    upsert_registry_intent/3,
    ledger_register_intent/6,
    ledger_revoke_intent/3,
    ledger_credit_intent/6,
    ledger_debit_intent/6,
    ledger_set_operator_intent/4,
    migrate_user_ledger_intents/3
]).

-define(LEDGER_SRC_PATH, "contracts/DamageNWCLedger.aes").
-define(REGISTRY_NAME, <<"nwc_ledger">>).

-include_lib("kernel/include/logger.hrl").

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(L) when is_list(L) -> L;
to_str(I) when is_integer(I) -> integer_to_list(I);
to_str(Other) -> lists:flatten(io_lib:format("~p", [Other])).

%% Intent shapes are maps so they can be JSON encoded cleanly.
%%
%% Deploy intent:
%%  #{kind => <<"ae_contract_deploy">>, source_path => <<"...">>, init_args => [...]}
-spec deploy_ledger_intent(binary(), binary()) -> map().
deploy_ledger_intent(AdminAk, Label) ->
    #{
        kind => <<"ae_contract_deploy">>,
        label => to_bin(Label),
        source_path => to_bin(damage_ae:contract_path(damage, ?LEDGER_SRC_PATH)),
        init_args => [to_str(AdminAk)]
    }.

%% Upsert in AccountRegistry:
%%  #{kind => <<"ae_contract_call">>, contract_id => RegistryCt, <<"fun">> => <<"update_contract">>, args => [...]}
%% We prefer update_contract; caller can fall back to register_contract if needed.
-spec upsert_registry_intent(binary(), binary(), binary()) -> map().
upsert_registry_intent(RegistryCt, Name, LedgerCt) ->
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(RegistryCt),
        <<"fun">> => <<"update_contract">>,
        args => [to_str(Name), to_str(LedgerCt)]
    }.

%% -------------------------------------------------------------------
%% Migrate user ledger
%%
%% Returns an ordered bundle of intents:
%%   1) deploy new ledger contract
%%   2) update account registry nwc_ledger -> new contract
%%
%% The deployed contract id is not known ahead of time, so the registry
%% update uses a placeholder contract id that the wallet/UI should replace
%% with the actual deployed ct_... after the deploy transaction succeeds.
%%
%% Example return:
%% #{
%%   kind => <<"ae_intent_bundle">>,
%%   action => <<"migrate_user_ledger">>,
%%   registry_name => <<"nwc_ledger">>,
%%   intents => [DeployIntent, UpsertIntent]
%% }.
%% -------------------------------------------------------------------
-spec migrate_user_ledger_intents(binary(), binary(), binary()) -> map().
migrate_user_ledger_intents(AdminAk, RegistryCt, Label) ->
    DeployLabel =
        case to_bin(Label) of
            <<>> -> <<"DamageNWCLedgerMigration">>;
            B -> B
        end,

    DeployIntent = deploy_ledger_intent(AdminAk, DeployLabel),

    %% Wallet/UI should replace this after deploy with actual ct_...
    UpsertIntent = upsert_registry_intent(
        RegistryCt,
        ?REGISTRY_NAME,
        <<"ct_TBD_FROM_DEPLOY">>
    ),

    #{
        kind => <<"ae_intent_bundle">>,
        action => <<"migrate_user_ledger">>,
        label => DeployLabel,
        registry_name => ?REGISTRY_NAME,
        intents => [DeployIntent, UpsertIntent]
    }.

%% Ledger calls

-spec ledger_register_intent(binary(), binary(), binary(), integer(), integer(), integer()) ->
    map().
ledger_register_intent(LedgerCt, ClientPubHex, _Label, MaxSingleMsat, MaxTotalMsat, ExpiresHeight) ->
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(LedgerCt),
        <<"fun">> => <<"register">>,
        args => [
            to_str(ClientPubHex),
            integer_to_list(MaxSingleMsat),
            integer_to_list(MaxTotalMsat),
            integer_to_list(ExpiresHeight)
        ]
    }.

-spec ledger_revoke_intent(binary(), binary(), binary()) -> map().
ledger_revoke_intent(LedgerCt, ClientPubHex, _Reason) ->
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(LedgerCt),
        <<"fun">> => <<"revoke">>,
        args => [to_str(ClientPubHex)]
    }.

-spec ledger_credit_intent(binary(), binary(), integer(), binary(), binary(), binary()) -> map().
ledger_credit_intent(LedgerCt, ClientPubHex, AmountMsat, Ref, Meta, _Tag) ->
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(LedgerCt),
        <<"fun">> => <<"credit">>,
        args => [
            to_str(ClientPubHex),
            integer_to_list(AmountMsat),
            to_str(Ref),
            to_str(Meta)
        ]
    }.

-spec ledger_debit_intent(binary(), binary(), integer(), binary(), binary(), binary()) -> map().
ledger_debit_intent(LedgerCt, ClientPubHex, AmountMsat, Ref, Meta, _Tag) ->
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(LedgerCt),
        <<"fun">> => <<"debit">>,
        args => [
            to_str(ClientPubHex),
            integer_to_list(AmountMsat),
            to_str(Ref),
            to_str(Meta)
        ]
    }.

-spec ledger_set_operator_intent(binary(), binary(), binary(), boolean()) -> map().
ledger_set_operator_intent(LedgerCt, OperatorAk, _Tag, Enable) ->
    %% Sophia option(address): None | Some(address)
    Opt =
        case Enable of
            true -> #{<<"Some">> => to_str(OperatorAk)};
            false -> <<"None">>
        end,
    #{
        kind => <<"ae_contract_call">>,
        contract_id => to_bin(LedgerCt),
        <<"fun">> => <<"set_operator">>,
        args => [Opt]
    }.
