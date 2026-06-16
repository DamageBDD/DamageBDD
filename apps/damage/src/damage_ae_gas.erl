%%%-------------------------------------------------------------------
%%% damage_ae_gas.erl
%%%
%%% Static transaction fee-gas calculation for æternity transactions.
%%%
%%% This intentionally models the protocol / aepp-sdk-js tx-builder
%%% fee-gas calculation.  Contract execution gas limit is a separate
%%% transaction field and must not be folded into the tx fee field.
%%%-------------------------------------------------------------------
-module(damage_ae_gas).

-export([
    tx_base_gas/1,
    tx_other_gas/4,
    build_gas/4,
    tx_fee_gas/2,
    tx_fee_gas/3,
    contract_tx_fee_gas/3,
    gas_to_fee/2,
    tx_fee/3,
    contract_tx_fee/4,
    calculate_paying_for_gas/2
]).

-define(BASE_GAS, 15000).
-define(GAS_PER_BYTE, 40).
-define(KEY_BLOCK_INTERVAL, 3).

%% Keep these atoms aligned with however you represent tx tags internally.
-type tx_tag() ::
    channel_force_progress_tx
    | channel_offchain_tx
    | contract_create_tx
    | contract_call_tx
    | ga_attach_tx
    | ga_meta_tx
    | paying_for_tx
    | oracle_register_tx
    | oracle_extend_tx
    | oracle_query_tx
    | oracle_response_tx
    | oracle_respond_tx
    | term().

%%--------------------------------------------------------------------
%% Base gas
%%
%% Protocol / SDK logic:
%%   ChannelForceProgressTx => 30 * BASE_GAS
%%   ChannelOffChainTx      => 0
%%   ContractCreateTx       => 5  * BASE_GAS
%%   ContractCallTx FATE    => 12 * BASE_GAS
%%   GaAttachTx             => 5  * BASE_GAS
%%   GaMetaTx               => 5  * BASE_GAS
%%   PayingForTx            => BASE_GAS div 5
%%   everything else        => BASE_GAS
%%--------------------------------------------------------------------
-spec tx_base_gas(tx_tag()) -> non_neg_integer().
tx_base_gas(channel_force_progress_tx) ->
    30 * ?BASE_GAS;
tx_base_gas(channel_offchain_tx) ->
    0;
tx_base_gas(contract_create_tx) ->
    5 * ?BASE_GAS;
tx_base_gas(contract_call_tx) ->
    12 * ?BASE_GAS;
tx_base_gas(ga_attach_tx) ->
    5 * ?BASE_GAS;
tx_base_gas(ga_meta_tx) ->
    5 * ?BASE_GAS;
tx_base_gas(paying_for_tx) ->
    ?BASE_GAS div 5;
tx_base_gas(_) ->
    ?BASE_GAS.

%%--------------------------------------------------------------------
%% Other fee-gas components
%%
%% Oracle txs include a relative TTL component.  PayingFor/GAMeta only
%% charge byte gas for the wrapper, not for the embedded inner tx again.
%%--------------------------------------------------------------------
-spec tx_other_gas(tx_tag(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
tx_other_gas(Tag, TxSize, RelativeTtl, _InnerTxSize) when
    Tag =:= oracle_register_tx;
    Tag =:= oracle_extend_tx;
    Tag =:= oracle_query_tx;
    Tag =:= oracle_response_tx;
    Tag =:= oracle_respond_tx
->
    TxSize * ?GAS_PER_BYTE +
        ceil_div(
            32000 * RelativeTtl,
            ((60 * 24 * 365) div ?KEY_BLOCK_INTERVAL)
        );
tx_other_gas(Tag, TxSize, _RelativeTtl, InnerTxSize) when
    Tag =:= ga_meta_tx;
    Tag =:= paying_for_tx
->
    erlang:max(0, TxSize - InnerTxSize) * ?GAS_PER_BYTE;
tx_other_gas(_Tag, TxSize, _RelativeTtl, _InnerTxSize) ->
    TxSize * ?GAS_PER_BYTE.

%%--------------------------------------------------------------------
%% Static fee-gas units for a serialized unsigned tx.  Contract execution
%% gas_limit is paid from execution accounting and must not be added to fee gas.
%%--------------------------------------------------------------------
-spec build_gas(tx_tag(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
build_gas(Tag, TxSize, RelativeTtl, InnerTxSize) ->
    tx_base_gas(Tag) + tx_other_gas(Tag, TxSize, RelativeTtl, InnerTxSize).

-spec tx_fee_gas(tx_tag(), binary()) -> non_neg_integer().
tx_fee_gas(Tag, TxBin) when is_binary(TxBin) ->
    build_gas(Tag, byte_size(TxBin), 1, 0).

-spec tx_fee_gas(tx_tag(), binary(), binary()) -> non_neg_integer().
tx_fee_gas(Tag, TxBin, InnerTxBin) when is_binary(TxBin), is_binary(InnerTxBin) ->
    build_gas(Tag, byte_size(TxBin), 1, byte_size(InnerTxBin)).

-spec contract_tx_fee_gas(tx_tag(), binary(), non_neg_integer()) -> non_neg_integer().
contract_tx_fee_gas(Tag, TxBin, _ExecutionGasLimit) ->
    tx_fee_gas(Tag, TxBin).

-spec gas_to_fee(non_neg_integer(), pos_integer()) -> non_neg_integer().
gas_to_fee(GasUnits, GasPrice) when
    is_integer(GasUnits), GasUnits >= 0, is_integer(GasPrice), GasPrice > 0
->
    GasUnits * GasPrice.

-spec tx_fee(tx_tag(), binary(), pos_integer()) -> non_neg_integer().
tx_fee(Tag, TxBin, GasPrice) ->
    gas_to_fee(tx_fee_gas(Tag, TxBin), GasPrice).

-spec contract_tx_fee(tx_tag(), binary(), non_neg_integer(), pos_integer()) -> non_neg_integer().
contract_tx_fee(Tag, TxBin, ExecutionGasLimit, GasPrice) ->
    gas_to_fee(contract_tx_fee_gas(Tag, TxBin, ExecutionGasLimit), GasPrice).

%%--------------------------------------------------------------------
%% PayingFor fee-gas.
%%
%% PayingForTx has no gas_limit field.  Its fee covers only the wrapper:
%%   BASE_GAS div 5 + (outer_size - signed_inner_size) * GAS_PER_BYTE
%%--------------------------------------------------------------------
-spec calculate_paying_for_gas(binary(), binary()) -> non_neg_integer().
calculate_paying_for_gas(PayingForTxBin, InnerTxBin) ->
    tx_fee_gas(paying_for_tx, PayingForTxBin, InnerTxBin).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(N, D) ->
    (N + D - 1) div D.
