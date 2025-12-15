%%-------------------------------------------------------------------
%% @doc
%%  damage_channels.erl — High-level channel manager for DamageBDD
%%  - Creates and manages Æternity state channels
%%  - Executes Sophia contract calls off‑chain (two‑phase commit)
%%  - Keeps token.aes unchanged; integrates with existing damage_ae.erl
%%
%%  Notes
%%  - This is a lightweight gen_server wrapper around the node’s channel FSM
%%    and your existing on‑chain helpers in damage_ae.erl.
%%  - Storage is purely in‑memory; persist snapshots in your app as needed.
%%-------------------------------------------------------------------
-module(damage_channels).
-author("Steven Joseph <steven@stevenjoseph.in>").
-compile(warn_export_all).
-behaviour(gen_server).

%% Explicitly export gen_server callbacks to silence warnings
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([channel_create_tx/8]).
-export([channel_contract_call/8]).
-export([init_job/2, finalize_snapshot/2]).
-export([build_channel_create_tx/8]).
-export([finalize_channel_create/3, expected_signers/1, actual_signers/1]).

-export([test/0]).
-export([get_existing_channel/1]).
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%%===================================================================
%% API
%%===================================================================
-export([
    start_link/1, start_link/2,
    stop/1,
    open/2,
    accept/2,
    reestablish/2,
    update_contract/5,
    update_ack/2,
    update_error/2,
    close_mutual/2,
    close_solo/1,
    state/1
]).

-export([snapshot_solo/2]).
-export([force_progress_contract_call/2]).
-import(damage_ae, [contract_path/1]).
-import(damage_utils, [ct_id/2, to_bin/1, to_int/1]).

%%===================================================================
%% Types & Records
%%===================================================================

%% key blocks
-define(DEFAULT_LOCK_PERIOD, 144).
%% microblock ok for low value
-define(DEFAULT_MIN_DEPTH, 0).

-record(ch, {
    %% channel_id (32 bytes)
    id = undefined :: binary() | undefined,
    %% monotonically increasing
    round = 0 :: non_neg_integer(),
    %% root hash of offchain trees
    state_hash = <<0:256>> :: binary(),
    %% ak_…
    initiator = <<>> :: binary(),
    %% ak_…
    responder = <<>> :: binary(),
    lock_period = ?DEFAULT_LOCK_PERIOD :: non_neg_integer(),
    min_depth = ?DEFAULT_MIN_DEPTH :: non_neg_integer(),
    reserve = 0 :: non_neg_integer(),
    delegates = [] :: [binary()],
    %% Off‑chain working set
    fsm = undefined :: pid() | undefined,
    pending_updates = [] :: [term()],
    last_payload = undefined :: term() | undefined,
    %% {CtId() => {CodeHash, State}}
    contracts = #{} :: map(),
    %% arbitrary
    meta = #{} :: map()
}).

-record(state, {
    ch = #ch{} :: #ch{},
    %% your node client / websocket
    node = undefined :: pid() | undefined,
    %% #{public_key => <<>>, private_key => <<>>}
    keypair = undefined :: map() | undefined
}).

%%===================================================================
%% Public API
%%===================================================================
start_link(KeyPair) -> gen_server:start_link(?MODULE, #{keypair => KeyPair}, []).
start_link(KeyPair, Meta) ->
    gen_server:start_link(?MODULE, #{keypair => KeyPair, meta => Meta}, []).
stop(Pid) -> gen_server:call(Pid, stop).

%% Open channel (initiator)
open(Pid, Opts) -> gen_server:call(Pid, {open, Opts}).

%% Accept channel (responder path)
accept(Pid, Opts) -> gen_server:call(Pid, {accept, Opts}).

%% Reestablish after restart
reestablish(Pid, Payload) -> gen_server:call(Pid, {reestablish, Payload}).

%% Two‑phase off‑chain contract update
%% update_contract: propose an off‑chain contract call, returns unsigned payload to co‑sign
%% CtId = contract id (on-chain counterpart), Fun = string(), Args = list(), Gas = int()
update_contract(Pid, CtId, Fun, Args, Gas) ->
    gen_server:call(Pid, {update_contract, CtId, Fun, Args, Gas}).

%% Accept the update (co‑sign the proposed payload)
update_ack(Pid, Payload) -> gen_server:call(Pid, {update_ack, Payload}).

%% Reject the update
update_error(Pid, Reason) -> gen_server:call(Pid, {update_error, Reason}).

%% On‑chain helpers (unilateral when needed)
%% snapshot_solo(Pid, Opts) ->
%%   Opts = #{
%%     channel_id := <<"ch_...">>,
%%     from_id    := <<"ak_...">>,   %% who submits (initiator or responder)
%%     round      := integer(),
%%     state_hash := <<32-bytes>>,
%%     ttl        := 0 | integer(),
%%     fee        := integer()       %% enough for tx
%%   }.
snapshot_solo(Pid, Opts) ->
    gen_server:call(Pid, {snapshot_solo, Opts}, 60000).
%% force_progress_contract_call(Pid, Opts) ->
%%   Opts = #{
%%     channel_id  := <<"ch_...">>,
%%     from_id     := <<"ak_...">>,  %% party driving FP
%%     ct_id       := <<"ct_...">>,
%%     fun         := <<"entrypoint">> | atom(),
%%     args        := list(),         %% ABI-encodable
%%     amount      := non_neg_integer(),
%%     gas         := pos_integer(),
%%     gas_price   := pos_integer(),
%%     round       := integer(),      %% next round to enforce
%%     ttl         := 0 | integer(),
%%     fee         := integer()
%%   }.
force_progress_contract_call(Pid, Opts) ->
    gen_server:call(Pid, {force_progress_contract_call, Opts}, 120000).

%% Pull the contract id from Opts or application env

%% init_job(ChannelId, Meta = #{feature_hash := FH, report_hash := RH, cost := Cost})
-spec init_job(binary(), map()) ->
    {ok, #{job_id := binary(), channel_pid := pid(), init_receipt := map()}}
    | {error, term()}.
init_job(ChannelId, _Meta) ->
    %% 1) ensure a channel exists or create new one
    {ok, ChanPid} = get_channel(ChannelId),
    #{public_key := NodePubKey} = secrets:node_keypair(),

    %% 2) call JobRegistry.init_job(job_id, feature_hash, report_hash, cost) INSIDE CHANNEL
    %% generate job_id off-chain (32 bytes)
    JobId = crypto:strong_rand_bytes(32),

    Args = [
        JobId,
        ?DAMAGE_TOKEN_CONTRACT,
        NodePubKey,
        1000,
        1000,
        1000,
        1764939345972
    ],

    %% Gas for off-chain contract call
    Gas = 3_000_000,

    %% Call off-chain using resolved JobRegistry contract id
    CtId = ct_id(job_registry_ct, ?JOB_REGISTRY_CONTRACT),
    Src = "contracts/JobRegistry.aes",

    case
        channel_contract_call(
            ChanPid, CtId, contract_path(Src), "create_job", Args, Gas, 0, #{job_id => JobId}
        )
    of
        {ok, Receipt} ->
            {ok, #{
                job_id => JobId,
                channel_pid => ChanPid,
                init_receipt => Receipt
            }};
        Error ->
            Error
    end.
-spec finalize_snapshot(pid(), map()) -> {ok, term()} | {error, term()}.
finalize_snapshot(ChanPid, Opts = #{from_id := FromId}) ->
    %% read current channel state
    ?LOG_INFO("Chan snap ~p", [ChanPid]),
    State =
        damage_channels:state(ChanPid),
    Ch = State#state.ch,

    SnapOpts = #{
        channel_id => Ch#ch.id,
        from_id => FromId,
        round => Ch#ch.round,
        state_hash => Ch#ch.state_hash,
        ttl => maps:get(ttl, Opts, 0),
        fee => maps:get(fee, Opts, 20000000000000)
    },
    ?LOG_INFO("Chan snap ~p", [SnapOpts]),
    snapshot_solo(ChanPid, SnapOpts).

-define(MDW_CHANNEL_SCAN_LIMIT, 25).

%% -------------------------------------------------------------------
%% Public: ensure there is a channel process for UserAk <-> NodeAk
%% Mirrors the JS ensureChannel():
%%   - try to reuse an in-memory process
%%   - otherwise, look up an existing on-chain ChannelCreateTx
%%     and /v3/channels/<id> in MDW and bind a process to that.
%%   - DOES NOT create a new on-chain channel – that is done by
%%     the browser wallet via /tx/prepare_create_channel.
%% -------------------------------------------------------------------
get_channel(ChannelId) ->
    case get_existing_channel(ChannelId) of
        {ok, ChMap} ->
            %% Seed our channel gen_server with real on-chain meta
            #{public_key := NodePub, private_key := NodePriv} =
                secrets:node_keypair(),
            KeyPair = #{public_key => NodePub, private_key => NodePriv},

            ChannelId = maps:get(<<"channel">>, ChMap, undefined),
            InitiatorId = maps:get(<<"initiator">>, ChMap),
            ResponderId = maps:get(<<"responder">>, ChMap),

            Meta = #{
                channel_id => ChannelId,
                initiator_id => InitiatorId,
                responder_id => ResponderId,
                state => maps:get(<<"state">>, ChMap, undefined),
                round => maps:get(<<"round">>, ChMap, 0)
            },

            {ok, Pid} = damage_channels:start_link(KeyPair, Meta),

            %% In-memory “open” mirrors the js options; we default a few
            _ = damage_channels:open(Pid, #{
                channel_id => ChannelId,
                initiator_pubkey => InitiatorId,
                responder_pubkey => ResponderId,
                lock_period => maps:get(<<"lock_period">>, ChMap, 144),
                minimum_depth => maps:get(<<"minimum_depth">>, ChMap, 0),
                channel_reserve => maps:get(<<"channel_reserve">>, ChMap, 0)
            }),

            {ok, Pid};
        {error, not_found} ->
            ?LOG_WARNING("get_channel: no open channel found for channel id ~p ", [ChannelId]),
            {error, no_open_channel};
        {error, Reason} ->
            ?LOG_WARNING(
                "get_channel: failed to lookup channel for id ~p : ~p",
                [ChannelId, Reason]
            ),
            {error, Reason}
    end.

get_mdw_transaction(TxId) ->
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, Prefix} ->
            PathBin =
                Prefix ++
                    "v3/transactions/" ++
                    TxId,
            Headers = [{<<"accept">>, <<"application/json">>}],
            StreamRef = gun:get(ConnPid, PathBin, Headers),
            case gun:await(ConnPid, StreamRef, 50000) of
                {response, _Fin, 200, _RespHeaders} ->
                    {ok, Body} = gun:await_body(ConnPid, StreamRef),
                    ?LOG_DEBUG("chanel Data ~p", [Body]),
                    case jsx:decode(Body, [{labels, atom}, return_maps]) of
                        Acts when is_map(Acts) ->
                            {ok, Acts};
                        _ ->
                            {error, ae_invalid_reply}
                    end;
                Other ->
                    ?LOG_DEBUG("chanel path ~s", [PathBin]),
                    {error, {ae_http_error, Other}}
            end;
        Error ->
            Error
    end.
get_existing_channel(ChannelId) ->
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, Prefix} ->
            PathBin =
                Prefix ++
                    "v3/channels/" ++
                    ChannelId,
            Headers = [{<<"accept">>, <<"application/json">>}],
            StreamRef = gun:get(ConnPid, PathBin, Headers),
            case gun:await(ConnPid, StreamRef, 50000) of
                {response, _Fin, 200, _RespHeaders} ->
                    {ok, Body} = gun:await_body(ConnPid, StreamRef),
                    ?LOG_DEBUG("chanel Data ~p", [Body]),
                    case jsx:decode(Body, [return_maps]) of
                        Acts when is_map(Acts) ->
                            {ok, Acts};
                        _ ->
                            {error, ae_invalid_reply}
                    end;
                Other ->
                    ?LOG_DEBUG("chanel path ~s", [PathBin]),
                    {error, {ae_http_error, Other}}
            end;
        Error ->
            Error
    end.

%% Close channel
close_mutual(Pid, Dist) -> gen_server:call(Pid, {close_mutual, Dist}).
close_solo(Pid) -> gen_server:call(Pid, close_solo).

%% Inspect current channel state
state(Pid) -> gen_server:call(Pid, state).

%% 2) public API
-spec channel_contract_call(
    %% Channel server pid
    pid(),
    %% CtId <<"ct_...">>
    binary(),
    %% Contract source path (for AACI)
    string(),
    %% Entry fun
    binary() | atom(),
    %% Args (FATE encodable)
    list(),
    %% Gas
    non_neg_integer(),
    %% Amount (aetto)
    non_neg_integer(),
    %% Meta (arbitrary)
    map()
) -> {ok, map()} | {error, term()}.
channel_contract_call(Pid, CtId, Source, Fun, Args, Gas, Amount, Meta) ->
    gen_server:call(
        Pid, {channel_contract_call, CtId, Source, Fun, Args, Gas, Amount, Meta}, 60000
    ).

%%===================================================================
%% gen_server
%%===================================================================
init(#{keypair := KeyPair} = Init) ->
    process_flag(trap_exit, true),
    {ok, #state{keypair = KeyPair, ch = #ch{meta = maps:get(meta, Init, #{})}}}.

handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
%% ---------------- Open / Accept / Reestablish ----------------
handle_call({open, Opts0}, _From, S0) ->
    %% Minimal open handshake framing (actual wire handled by your channel FSM client)
    Ch0 = S0#state.ch,
    Initiator = maps:get(initiator_pubkey, Opts0),
    Responder = maps:get(responder_pubkey, Opts0),
    Lock = maps:get(lock_period, Opts0, ?DEFAULT_LOCK_PERIOD),
    MinDepth = maps:get(minimum_depth, Opts0, ?DEFAULT_MIN_DEPTH),
    Reserve = maps:get(channel_reserve, Opts0, 0),
    ChannelId = maps:get(channel_id, Opts0),
    Ch1 = Ch0#ch{
        initiator = Initiator,
        responder = Responder,
        lock_period = Lock,
        min_depth = MinDepth,
        reserve = Reserve
    },
    %% TODO: call node FSM to send channel_open/funding_created/funding_locked; set real channel_id
    Ch2 = Ch1#ch{id = ChannelId},
    {reply, {ok, ChannelId}, S0#state{ch = Ch2}};
handle_call(state, _From, S0) ->
    {reply, S0, S0};
handle_call({accept, Opts0}, _From, S0) ->
    %% Symmetric to open/2; here we accept and set parameters
    Lock = maps:get(lock_period, Opts0, ?DEFAULT_LOCK_PERIOD),
    MinDepth = maps:get(minimum_depth, Opts0, ?DEFAULT_MIN_DEPTH),
    Ch1 = S0#state.ch#ch{lock_period = Lock, min_depth = MinDepth},
    {reply, ok, S0#state{ch = Ch1}};
handle_call({reestablish, Payload}, _From, S0) ->
    %% Payload must be last mutually authenticated off‑chain state
    %% Here we trust the node FSM to verify proof-of-inclusion and restore trees
    Ch1 = S0#state.ch,
    Round = maps:get(round, Payload, Ch1#ch.round),
    Root = maps:get(state_hash, Payload, Ch1#ch.state_hash),
    {reply, ok, S0#state{ch = Ch1#ch{round = Round, state_hash = Root, last_payload = Payload}}};
%% ---------------- Off‑chain update (two‑phase) ----------------
handle_call({update_contract, CtId, FunName, Args, Gas}, _From, S0 = #state{ch = Ch0}) ->
    %% Construct an unsigned payload that calls CtId:FunName(Args) with Gas on the channel’s off‑chain state
    %% NOTE: 'fun' is a reserved word in Erlang; avoid it as a map key or variable name.
    %% Caller app co-signs using its account; peer must ack via update_ack
    Update = #{
        type => contract_call,
        ct => CtId,
        function => FunName,
        args => Args,
        gas => Gas,
        round => Ch0#ch.round + 1
    },
    % peer must ack via update_ack
    {reply, {ok, Update}, S0#state{
        ch = Ch0#ch{pending_updates = [Update | Ch0#ch.pending_updates]}
    }};
handle_call({update_ack, Payload}, _From, S0 = #state{ch = Ch0}) ->
    %% Peer agreed; commit update locally and bump round/state hash (hashing is mocked here)
    Round1 = Ch0#ch.round + 1,
    Root1 = crypto:hash(sha256, term_to_binary({Payload, Round1})),
    Ch1 = Ch0#ch{round = Round1, state_hash = Root1, last_payload = Payload, pending_updates = []},
    {reply, {ok, #{round => Round1, state_hash => Root1}}, S0#state{ch = Ch1}};
handle_call({update_error, Reason}, _From, S0 = #state{ch = Ch0}) ->
    ?LOG_WARNING("update rejected: ~p", [Reason]),
    {reply, {error, Reason}, S0#state{ch = Ch0#ch{pending_updates = []}}};
%% ---------------- On‑chain safety valves ----------------

handle_call({snapshot_solo, Opts}, _From, S = #state{}) ->
    Ch = S#state.ch,
    ChId = Ch#ch.id,
    FromId = maps:get(from_id, Opts),
    {ok, _Nonce} = vanillae:next_nonce(FromId),
    %Round = maps:get(round, Opts),
    StateHash = maps:get(state_hash, Opts),
    TTL = maps:get(ttl, Opts, 0),
    Fee = maps:get(fee, Opts, 2_000_000_000_0000),
    #{public_key := _PublicKey, private_key := PrivateKey} = S#state.keypair,

    %% Build unsigned snapshot tx; wallet of FromId must sign
    ?LOG_INFO("Snapshotting ~p", [Ch]),
    {ok, #{tx := Tx}} = build_channel_snapshot_solo_tx(
        ChId,
        FromId,
        StateHash,
        TTL,
        Fee
    ),
    Sig = damage_ae:make_transaction_signature_base58(PrivateKey, Tx),
    SignedTx = damage_ae:attach_signature_base58(Tx, Sig),
    ?LOG_INFO("Snapshotting unsigned ~p", [Tx]),
    Res =
        case vanillae:post_tx(SignedTx) of
            {ok, #{"tx_hash" := ContractCallTxHash}} ->
                damage_ae:wait_tx(ContractCallTxHash);
            Error ->
                Error
        end,
    {reply, Res, S};
handle_call({force_progress_contract_call, Opts}, _From, S = #state{}) ->
    ChId = maps:get(channel_id, Opts),
    FromId = maps:get(from_id, Opts),
    CtId = maps:get(ct_id, Opts),
    Source = maps:get(source, Opts),
    Fun0 = maps:get("fun", Opts),
    Fun =
        if
            is_atom(Fun0) -> atom_to_binary(Fun0, utf8);
            true -> Fun0
        end,
    Args = maps:get(args, Opts, []),
    Amount = maps:get(amount, Opts, 0),
    Gas = maps:get(gas, Opts, 3_000_000),
    GasPrice = maps:get(gas_price, Opts, vanillae:min_gas_price()),
    Round = maps:get(round, Opts),
    TTL = maps:get(ttl, Opts, 0),
    Fee = maps:get(fee, Opts, 2_000_000_000_0000),

    %% Prepare calldata
    {ok, AACI} = vanillae:prepare_contract(Source),
    {ok, Calldata} = aeb_fate_abi:encode_call_data(AACI, Fun, Args),

    %% Build unsigned force-progress tx
    {ok, Unsigned} = vanillae:channel_force_progress_unsigned(
        ChId,
        FromId,
        CtId,
        Calldata,
        Amount,
        Gas,
        GasPrice,
        Round,
        TTL,
        Fee
    ),

    %% Sign with FromId’s key (or prompt wallet)
    {ok, Signed} = signer:sign_tx(FromId, Unsigned),

    %% Post (optionally paying_for wrapper if node covers fee)
    Res = damage_ae:post_signed_or_payfor(Signed, false),
    {reply, Res, S};
%% 4) handler (add to handle_call/3)
handle_call(
    {channel_contract_call, CtId, Source, Fun, Args, Gas, Amount, Meta},
    _From,
    S0 = #state{ch = Ch0}
) ->
    GasPrice = vanillae:min_gas_price(),
    %Fun = to_bin(Fun0),
    try
        {ok, AACI} = vanillae:prepare_contract(Source),
        ?LOG_DEBUG("Contract prepared ~p ~p", [Source, AACI]),
        {ok, Calldata} = vanillae:encode_call_data(AACI, Fun, Args),

        %% Off-chain update payload (two-phase; we auto-ack since node is responder)
        Update = #{
            type => contract_call,
            ct_id => CtId,
            function => Fun,
            calldata => Calldata,
            gas => Gas,
            gas_price => GasPrice,
            amount => Amount,
            from => Ch0#ch.initiator,
            to => Ch0#ch.responder,
            meta => Meta,
            round => Ch0#ch.round + 1
        },

        Round1 = Ch0#ch.round + 1,
        Root1 = crypto:hash(sha256, term_to_binary({Update, Round1, Ch0#ch.state_hash})),

        Ch1 = Ch0#ch{
            round = Round1,
            state_hash = Root1,
            last_payload = Update,
            pending_updates = []
        },

        Receipt = #{
            kind => contract_call,
            ct_id => CtId,
            "fun" => Fun,
            round => Round1,
            state_hash => Root1,
            gas => Gas,
            gas_price => GasPrice,
            amount => Amount,
            meta => Meta
        },
        {reply, {ok, Receipt}, S0#state{ch = Ch1}}
    catch
        C:R:S ->
            {reply, {error, {C, R, S}}, S0}
    end;
%% ---------------- Closing ----------------
handle_call({close_mutual, _Dist}, _From, S0) ->
    %% Dist = #{initiator := AmountI, responder := AmountR}
    %% TODO: co-sign and post channel_close_mutual
    {reply, ok, S0};
handle_call(close_solo, _From, S0) ->
    %% TODO: post channel_close_solo and handle timers per lock_period
    {reply, ok, S0}.

%% ---------------- Test Sequence ----------------
%% A simple end-to-end smoke test that exercises: open -> update -> ack -> settle_batch(test)

handle_info(_Info, S) -> {noreply, S}.

%% Default cast handler
handle_cast(_Msg, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_V, S, _E) -> {ok, S}.

%%--------------------------------------------------------------------
%% Build *unsigned* channel_create_tx (v2) for the initiator to sign.
%% Returns {ok, #{tx := EncodedUnsignedTx, tx_hash := TxHash}}.
%%--------------------------------------------------------------------

build_channel_create_tx(
    InitiatorPubKey,
    ResponderPubKey,
    IniAmt0,
    ResAmt0,
    Reserve0,
    Lock0,
    TTL0,
    Fee0
) ->
    try
        IniAmt = to_int(IniAmt0),
        ResAmt = to_int(ResAmt0),
        Reserve = to_int(Reserve0),
        Lock = to_int(Lock0),
        TTL = to_int(TTL0),
        Fee = to_int(Fee0),
        %Gas = min_gas(),

        (IniAmt >= 0) orelse error(bad_initiator_amount),
        (ResAmt >= 0) orelse error(bad_responder_amount),
        (Reserve >= 0) orelse error(bad_reserve),
        (Lock >= 0) orelse error(bad_lock),
        (TTL >= 0) orelse error(bad_ttl),
        (Fee >= 0) orelse error(bad_fee),

        %% Nonce must be the *initiator* account nonce
        {ok, Nonce} = vanillae:next_nonce(InitiatorPubKey),

        %% Optional: empty delegates; fresh state hash (can be 32 zeroes)
        InitStateHash = <<0:256>>,
        InitDelegates = [],

        %% --- Fields/Template for channel_create_tx v2 (Iris) ---
        Type = channel_create_tx,
        Version = 2,
        {account_pubkey, InitiatorId} = aeser_api_encoder:decode(InitiatorPubKey),
        {account_pubkey, ResponderId} = aeser_api_encoder:decode(ResponderPubKey),

        Fields = [
            {initiator_id, aeser_id:create(account, InitiatorId)},
            {initiator_amount, IniAmt},
            {responder_id, aeser_id:create(account, ResponderId)},
            {responder_amount, ResAmt},
            {channel_reserve, Reserve},
            {lock_period, Lock},
            {ttl, TTL},
            {fee, Fee},
            {initiator_delegate_ids, InitDelegates},
            {responder_delegate_ids, InitDelegates},
            {state_hash, InitStateHash},
            {nonce, Nonce}
        ],

        Template = [
            {initiator_id, id},
            {initiator_amount, int},
            {responder_id, id},
            {responder_amount, int},
            {channel_reserve, int},
            {lock_period, int},
            {ttl, int},
            {fee, int},
            {initiator_delegate_ids, [id]},
            {responder_delegate_ids, [id]},
            {state_hash, binary},
            {nonce, int}
        ],

        ?LOG_DEBUG("build_channel_create_tx fields ~p ~p", [Fields, Template]),
        %% --- Serialize (unsigned) and encode ---
        TxBin = aeser_chain_objects:serialize(Type, Version, Template, Fields),
        EncTx = aeser_api_encoder:encode(transaction, TxBin),
        TxHash = aeser_api_encoder:encode(tx_hash, TxBin),
        ?LOG_DEBUG("build_channel_create_tx ~p ~p", [TxBin, EncTx]),
        %{ok, _} = vanillae:dry_run(EncTx),
        {ok, #{
            tx => EncTx,
            tx_hash => TxHash,
            initiator => InitiatorId,
            responder => ResponderId
        }}
    catch
        C:R:S ->
            ?LOG_ERROR("build_channel_create_tx failed: ~p:~p~n~p", [C, R, S]),
            {error, {C, R}}
    end.
%%--------------------------------------------------------------------
%% @doc
%%  Build an unsigned channel_snapshot_solo_tx ready for signing & post.
%%
%%  Args:
%%    ChannelId0   - <<"ch_...">> encoded channel id
%%    FromPubKey   - <<"ak_...">> account that pays fee / posts the tx
%%    Payload0     - signed off-chain tx (binary, non-empty)
%%    TTL0         - block height ttl / relative ttl (int-ish)
%%    Fee0         - fee in aetto (int-ish)
%%
%%  Returns:
%%    {ok, #{tx := EncTx, tx_hash := TxHash,
%%           channel_id := ChannelIdBin,
%%           from_id    := FromIdBin}}
%%    | {error, {Class, Reason}}
%%--------------------------------------------------------------------
build_channel_snapshot_solo_tx(
    ChannelId0,
    FromPubKey,
    Payload0,
    TTL0,
    Fee0
) ->
    try
        TTL = to_int(TTL0),
        Fee = to_int(Fee0),

        (TTL >= 0) orelse error(bad_ttl),
        (Fee >= 0) orelse error(bad_fee),

        %% Payload must be a non-empty binary
        (is_binary(Payload0)) orelse error(bad_payload_type),
        (byte_size(Payload0) > 0) orelse error(empty_payload),

        %% Nonce must be the *from* account nonce
        {ok, Nonce} = vanillae:next_nonce(FromPubKey),

        %% --- Fields / Template for channel_snapshot_solo_tx ---
        Type = channel_snapshot_solo_tx,
        Version = 1,

        {channel, ChannelId} = aeser_api_encoder:decode(ChannelId0),
        {account_pubkey, FromId} = aeser_api_encoder:decode(FromPubKey),

        Fields = [
            {channel_id, aeser_id:create(channel, ChannelId)},
            {from_id, aeser_id:create(account, FromId)},
            {payload, Payload0},
            {ttl, TTL},
            {fee, Fee},
            {nonce, Nonce}
        ],

        Template = [
            {channel_id, id},
            {from_id, id},
            {payload, binary},
            {ttl, int},
            {fee, int},
            {nonce, int}
        ],

        ?LOG_DEBUG("build_channel_snapshot_solo_tx fields ~p ~p", [Fields, Template]),

        TxBin = aeser_chain_objects:serialize(Type, Version, Template, Fields),
        EncTx = aeser_api_encoder:encode(transaction, TxBin),
        TxHash = aeser_api_encoder:encode(tx_hash, TxBin),

        ?LOG_DEBUG("build_channel_snapshot_solo_tx ~p ~p", [TxBin, EncTx]),

        {ok, #{
            tx => EncTx,
            tx_hash => TxHash,
            channel_id => ChannelId,
            from_id => FromId
        }}
    catch
        C:R:S ->
            ?LOG_ERROR("build_channel_snapshot_solo_tx failed: ~p:~p~n~p", [C, R, S]),
            {error, {C, R}}
    end.

poll_channel(Fun, Args, Interval, Timeout) ->
    poll_channel(Fun, Args, Interval, Timeout, erlang:monotonic_time(millisecond)).

poll_channel(Fun, Args, Interval, Timeout, StartTime) ->
    case apply(Fun, Args) of
        {error, {ae_http_error, _}} ->
            Elapsed = erlang:monotonic_time(millisecond) - StartTime,
            if
                Elapsed >= Timeout ->
                    exit({timeout_error, {polling_failed, failed, Fun, Args}});
                true ->
                    timer:sleep(Interval),
                    poll_channel(Fun, Args, Interval, Timeout, StartTime)
            end;
        {ok, #{block_height := -1} = Result} ->
            Elapsed = erlang:monotonic_time(millisecond) - StartTime,
            if
                Elapsed >= Timeout ->
                    exit({timeout_error, {polling_failed, Result, Fun, Args}});
                true ->
                    timer:sleep(Interval),
                    poll_channel(Fun, Args, Interval, Timeout, StartTime)
            end;
        {ok,
            #{
                block_hash :=
                    _BlockHash,
                block_height := BlockHeight,
                tx := #{channel_id := _ChannelId} = Tx
            } = Result} when BlockHeight > 0 ->
            ?LOG_DEBUG("poll tx got value ~p ", [Result]),
            {ok, Tx}
    end.

wait_channel(ConId) ->
    poll_channel(fun get_mdw_transaction/1, [ConId], 2000, 55000).
%% Verify that the signed tx was signed by the *expected* account (initiator),
%% then post directly or wrap in paying_for so node pays fee.
-spec finalize_channel_create(binary(), binary(), boolean()) ->
    {ok, map()} | {error, term()}.
finalize_channel_create(UnsignedTx, SignedTx, _UsePayFor) ->
    #{public_key := _NodeAeAccount, private_key := PrivateKey} = secrets:node_keypair(),
    {transaction, TX} = aeser_api_encoder:decode(UnsignedTx),
    Sig = damage_ae:make_transaction_signature(PrivateKey, TX),
    SignedTXTemplate = [{signatures, [binary]}, {transaction, binary}],
    ?LOG_INFO("Signed Tx client ~p", [SignedTx]),
    {transaction, SignedBin} = aeser_api_encoder:decode(SignedTx),
    ?LOG_INFO("Signed Tx client ~p", [SignedBin]),
    {_Type, _Vsn, [[SigClient], _Tx]} = aeser_chain_objects:deserialize_type_and_vsn(SignedBin),

    Fields = [{signatures, [Sig, SigClient]}, {transaction, TX}],
    SignedTxNode = aeser_chain_objects:serialize(signed_tx, 1, SignedTXTemplate, Fields),
    SignedTxFinal = aeser_api_encoder:encode(transaction, SignedTxNode),
    case vanillae:post_tx(SignedTxFinal) of
        {ok, #{"tx_hash" := ContractCallTxHash}} ->
            wait_channel(ContractCallTxHash);
        Error ->
            Error
    end.

%% Determine who MUST sign an *unsigned* tx
-spec expected_signers(binary()) -> {ok, [binary()]} | {error, term()}.
expected_signers(EncUnsignedTx) ->
    try
        ?LOG_INFO("expected_signers ~p", [EncUnsignedTx]),
        {transaction, TxBin} = aeser_api_encoder:decode(EncUnsignedTx),
        Tx = aetx:deserialize_from_binary(TxBin),
        ?LOG_INFO("expected_signers ~p", [Tx]),
        Pks = aetx:signers(Tx),
        {ok, [aeser_api_encoder:encode(account_pubkey, PK) || PK <- Pks]}
    catch
        C:R:_ -> {error, {C, R}}
    end.

%% Extract who DID sign a *signed* tx
-spec actual_signers(binary()) -> {ok, [binary()]} | {error, term()}.
actual_signers(EncSignedTx) ->
    try
        {tx, SignedBin} = aeser_api_encoder:decode(EncSignedTx),
        Signed = aetx_sign:deserialize_from_binary(SignedBin),
        Pks = aetx_sign:signers(Signed),
        {ok, [aeser_api_encoder:encode(account_pubkey, PK) || PK <- Pks]}
    catch
        C:R:_ -> {error, {C, R}}
    end.
%%====================================================================
%% Create and post a ChannelCreate transaction
%%====================================================================

-spec channel_create_tx(
    binary(),
    binary(),
    integer(),
    integer(),
    integer(),
    integer(),
    integer(),
    integer()
) -> {ok, map()} | {error, term()}.
channel_create_tx(
    InitiatorId,
    ResponderId,
    InitiatorAmount,
    ResponderAmount,
    ChannelReserve,
    LockPeriod,
    TTL,
    Fee
) ->
    try
        {ok, Nonce} = vanillae:next_nonce(InitiatorId),
        #{public_key := _NodePub, private_key := NodePriv} = secrets:node_keypair(),

        {account_pubkey, InitiatorPubKey} = aeser_api_encoder:decode(InitiatorId),
        ?LOG_DEBUG("channel_create_tx ~p ~p ~p", [InitiatorId, InitiatorPubKey, ResponderId]),
        {account_pubkey, ResponderPubKey} = aeser_api_encoder:decode(ResponderId),

        StateHash = crypto:strong_rand_bytes(32),
        DelegateIds = [],

        Fields = [
            {initiator_id, aeser_id:create(account, InitiatorPubKey)},
            {initiator_amount, InitiatorAmount},
            {responder_id, aeser_id:create(account, ResponderPubKey)},
            {responder_amount, ResponderAmount},
            {channel_reserve, ChannelReserve},
            {lock_period, LockPeriod},
            {ttl, TTL},
            {fee, Fee},
            {initiator_delegate_ids, DelegateIds},
            {responder_delegate_ids, DelegateIds},
            {state_hash, StateHash},
            {nonce, Nonce}
        ],

        Template = [
            {initiator_id, id},
            {initiator_amount, int},
            {responder_id, id},
            {responder_amount, int},
            {channel_reserve, int},
            {lock_period, int},
            {ttl, int},
            {fee, int},
            {initiator_delegate_ids, [id]},
            {responder_delegate_ids, [id]},
            {state_hash, binary},
            {nonce, int}
        ],

        Type = channel_create_tx,
        Version = 2,

        TxBin = aeser_chain_objects:serialize(Type, Version, Template, Fields),
        Tx = aeser_api_encoder:encode(transaction, TxBin),

        Sig = damage_ae:make_transaction_signature_base58(NodePriv, Tx),
        SignedTx = damage_ae:attach_signature_base58(Tx, Sig),

        case vanillae:post_tx(SignedTx) of
            {ok, #{"tx_hash" := TxHash}} ->
                ?LOG_INFO("Channel created on-chain: ~p", [TxHash]),
                damage_ae:wait_tx(TxHash);
            Error ->
                ?LOG_ERROR("Channel creation failed: ~p", [Error]),
                {error, Error}
        end
    catch
        C:R:S ->
            ?LOG_ERROR("channel_create_tx failed: ~p:~p~n~p", [C, R, S]),
            {error, {C, R}}
    end.

test() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {TestPubKey, _Password, UserPrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    Balance = damage_ae:balance(TestPubKey),
    %to_int((Balance /100)*80),
    InitiatorAmt = 100,
    ?LOG_INFO("Test account balance ~p ~p ~p", [TestPubKey, Balance, InitiatorAmt]),
    #{public_key := NodePublicKey, private_key := NodePrivateKey} =
        _KeyPair = secrets:node_keypair(),

    {ok, #{
        tx :=
            Tx,
        tx_hash :=
            _TxHash,
        initiator :=
            _Initiator,
        responder := _Responder
    }} =
        damage_channels:build_channel_create_tx(
            to_bin(NodePublicKey),
            to_bin(TestPubKey),
            InitiatorAmt,
            11,
            10,
            144,
            0,
            damage_ae:min_fee()
        ),
    ?LOG_INFO("Channel opening privkey ~p ", [UserPrivateKey]),
    Sig = damage_ae:make_transaction_signature_base58(UserPrivateKey, Tx),
    SignedTx = damage_ae:attach_signature_base58(Tx, Sig),
    ?LOG_INFO("Channel opening ~p ~p", [SignedTx]),
    {ok, #{channel_id := ChannelId}} = finalize_channel_create(Tx, SignedTx, <<>>),
    ?LOG_INFO("Channel opend ~p", [ChannelId]),

    {ok,
        #{
            job_id := JobId,
            channel_pid := ChannelPid,
            init_receipt := _Receipt
        } = Receipt} = init_job(ChannelId, #{}),
    ?LOG_INFO("Channel receipt ~p", [Receipt]),

    %% Propose off-chain contract call and ack it
    {ok, Update} = update_contract(
        ChannelPid, ?JOB_REGISTRY_CONTRACT, <<"fund_job">>, [JobId, 1], 100000
    ),
    {ok, #{round := _R, state_hash := StateHash} = _Ack} = update_ack(ChannelPid, Update),

    {ok, #{
        tx :=
            SnapTx,
        tx_hash :=
            _SnapTxHash,
        from_id :=
            _FromId,
        channel_id := _ChannelId
    }} =
        build_channel_snapshot_solo_tx(
            ChannelId,
            to_bin(NodePublicKey),
            StateHash,
            0,
            damage_ae:min_fee()
        ),
    SnapSig = damage_ae:make_transaction_signature_base58(NodePrivateKey, SnapTx),
    SignedSnapTx = damage_ae:attach_signature_base58(SnapTx, SnapSig),
    ?LOG_INFO("Snapshotting unsigned ~p", [SignedSnapTx]),
    {ok, Res} =
        case vanillae:post_tx(SignedSnapTx) of
            {ok, #{"tx_hash" := ContractCallTxHash}} ->
                case damage_ae:wait_tx(ContractCallTxHash) of
                    {ok, Resp} ->
                        {ok, Resp};
                    #{
                        "error_code" := "invalid_at_protocol",
                        "reason" := "Invalid tx"
                    } ->
                        {error, invalid_tx};
                    Error ->
                        Error
                end;
            Error ->
                Error
        end,
    ?LOG_INFO("Snapshotting result ~p", [Res]),

    %{ok, Res} = finalize_snapshot(ChannelPid, #{
    %    from_id => to_bin(NodePublicKey), fee => damage_ae:min_fee()
    %}),
    %?LOG_INFO("Channel snapshot_solo ~p", [Res]),

    %% Batch-settle in test mode (no chain call)
    %JobId = crypto:strong_rand_bytes(32),
    %StepsRoot = crypto:hash(sha256, <<"steps">>),
    %Count = 3,
    %Sigs = [<<"1">>, <<"2">>],
    %{ok, #{mock := true}} = damage_jobs:settle_batch(
    %    ChannelPid,
    %    JobId,
    %    StepsRoot,
    %    Count,
    %    Sigs,
    %    #{ct => <<"ct_job_registry">>, source => <<"src">>, payer => test}
    %),
    ok.
