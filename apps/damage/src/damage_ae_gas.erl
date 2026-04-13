%%%-------------------------------------------------------------------
%%% damage_ae_gas.erl
%%% Gas calculation aligned with aepp-sdk-js tx-builder logic
%%%-------------------------------------------------------------------
-module(damage_ae_gas).

-export([
    tx_base_gas/1,
    tx_other_gas/4,
    build_gas/4,
    calculate_paying_for_gas/2
]).

-define(BASE_GAS, 15000).
-define(GAS_PER_BYTE, 20).
-define(KEY_BLOCK_INTERVAL, 3).

%% Keep these atoms aligned with however you represent tx tags internally.
%% If you use different names, adjust these atoms.
-type tx_tag() ::
    channel_force_progress_tx
    | channel_offchain_tx
    | paying_for_tx
    | oracle_register_tx
    | oracle_extend_tx
    | oracle_query_tx
    | oracle_response_tx
    | ga_meta_tx
    | term().

%%--------------------------------------------------------------------
%% Base gas
%% SDK logic:
%%   ChannelForceProgressTx => 30 * BASE_GAS
%%   ChannelOffChainTx      => 0
%%   PayingForTx            => BASE_GAS div 5
%%   everything else        => BASE_GAS
%%--------------------------------------------------------------------
-spec tx_base_gas(tx_tag()) -> non_neg_integer().
tx_base_gas(channel_force_progress_tx) ->
    30 * ?BASE_GAS;
tx_base_gas(channel_offchain_tx) ->
    0;
tx_base_gas(paying_for_tx) ->
    ?BASE_GAS div 5;
tx_base_gas(_) ->
    ?BASE_GAS.

%%--------------------------------------------------------------------
%% Other gas
%% SDK logic:
%%   oracle txs => tx_size * 20 + ceil(32000 * relative_ttl / floor((60*24*365)/3))
%%   ga_meta_tx/paying_for_tx => (tx_size - inner_tx_size) * 20
%%   default => tx_size * 20
%%--------------------------------------------------------------------
-spec tx_other_gas(tx_tag(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
tx_other_gas(Tag, TxSize, RelativeTtl, _InnerTxSize) when
    Tag =:= oracle_register_tx;
    Tag =:= oracle_extend_tx;
    Tag =:= oracle_query_tx;
    Tag =:= oracle_response_tx
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
%% Total gas
%%--------------------------------------------------------------------
-spec build_gas(tx_tag(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
build_gas(Tag, TxSize, RelativeTtl, InnerTxSize) ->
    tx_base_gas(Tag) + tx_other_gas(Tag, TxSize, RelativeTtl, InnerTxSize).

%%--------------------------------------------------------------------
%% PayingFor gas
%% The SDK treats PayingForTx as:
%%   base = BASE_GAS/5
%%   other = (outer_size - inner_size) * GAS_PER_BYTE
%%--------------------------------------------------------------------
-spec calculate_paying_for_gas(binary(), binary()) -> non_neg_integer().
calculate_paying_for_gas(PayingForTxBin, InnerTxBin) ->
    build_gas(
        paying_for_tx,
        byte_size(PayingForTxBin),
        0,
        byte_size(InnerTxBin)
    ).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(N, D) ->
    (N + D - 1) div D.
