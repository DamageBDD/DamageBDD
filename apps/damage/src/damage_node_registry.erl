%% -------------------------------------------------------------------
%% damage_node_registry.erl
%%
%% Client for the canonical Damage network NodeRegistry v3.
%%
%% The registry is global per Aeternity network.  Durable node identity,
%% routing, compatibility and policy anchors live on-chain; high-frequency
%% liveness/load telemetry stays off-chain and is signed by the node key.
%% -------------------------------------------------------------------

-module(damage_node_registry).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(gen_server).

-export([
    start_link/0,
    set_contract/1,
    contract_id/0,
    resolve_contract_id/0,
    validate_contract/1,
    network_info/0,
    node_count/0,
    get_node_at/1,
    recent_node_ids/1,
    clear_cache/0,
    clear_cache/1,

    %% operator/account-level
    register_account/3,
    register_operator/1,
    set_operator_active/2,
    get_user_info/1,
    is_registered/1,
    get_registry/1,
    update_tier/2,
    get_registry_ct_from_node_registry/1,

    %% node-level
    register_node/4,
    register_self/3,
    get_node/1,
    get_node_owner/1,
    is_node_registered/1,
    get_nodes_for/1,
    update_node_meta/2,
    update_node_cfg/2,
    reassign_node/2,
    set_node_enabled/2,
    set_node_status/2,

    %% governance / explicit genesis tooling
    set_registry_paused/1,
    set_protocol_version/1,
    set_successor/1,
    set_governance/1,
    deploy_node_registry/0,
    deploy_node_registry/1,

    ensure_account_registry/2,
    ensure_account_registry/3,
    ensure_registered_account/3,
    update_registry/2,

    %% test helpers
    test/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(DEFAULT_CONTRACT_PATH, "node_registry.aes").
-define(REGISTRY_VERSION, 3).
-define(DEFAULT_PROTOCOL_VERSION, 1).
-define(ETS_TABLE, node_registry_cache).
-define(DEFAULT_TTL_MS, 30_000).

-record(state, {
    ets_table,
    contract_id = undefined,
    contract_path = ?DEFAULT_CONTRACT_PATH,
    ttl_ms = ?DEFAULT_TTL_MS
}).

%% =========================
%% PUBLIC API
%% =========================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

set_contract(ContractId) when is_binary(ContractId); is_list(ContractId) ->
    gen_server:call(?MODULE, {set_contract, ContractId}).

%% Public contract identifier for read-only middleware indexing.
contract_id() ->
    gen_server:call(?MODULE, get_contract_id).

%% Resolve the canonical contract from explicit node config or the
%% network-scoped contract table.  There is intentionally no compiled-in
%% contract id: a wrong default partitions the network.
resolve_contract_id() ->
    case application:get_env(damage, node_registry_ct) of
        {ok, CtId0} ->
            normalize_contract_id(CtId0);
        undefined ->
            resolve_network_contract()
    end.

network_info() ->
    gen_server:call(?MODULE, network_info, ?AE_TIMEOUT).

node_count() ->
    gen_server:call(?MODULE, node_count, ?AE_TIMEOUT).

get_node_at(Index) when is_integer(Index), Index >= 0 ->
    gen_server:call(?MODULE, {get_node_at, Index}, ?AE_TIMEOUT).

recent_node_ids(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {recent_node_ids, Limit}, ?AE_TIMEOUT).

clear_cache() ->
    gen_server:call(?MODULE, clear_cache).

clear_cache(Key) ->
    gen_server:call(?MODULE, {clear_cache, Key}).

register_account(Account, Registry, Tier) ->
    gen_server:call(?MODULE, {register_account, Account, Registry, Tier}, ?AE_TIMEOUT).

register_operator(Registry) ->
    gen_server:call(?MODULE, {register_operator, Registry}, ?AE_TIMEOUT).

set_operator_active(Account, Active) when is_boolean(Active) ->
    gen_server:call(?MODULE, {set_operator_active, Account, Active}, ?AE_TIMEOUT).

get_user_info(Account) ->
    gen_server:call(?MODULE, {get_user_info, Account}, ?AE_TIMEOUT).

is_registered(Account) ->
    gen_server:call(?MODULE, {is_registered, Account}, ?AE_TIMEOUT).

get_registry(Account) ->
    gen_server:call(?MODULE, {get_registry, Account}, ?AE_TIMEOUT).

update_tier(Account, Tier) ->
    gen_server:call(?MODULE, {update_tier, Account, Tier}, ?AE_TIMEOUT).
update_registry(Account, RegistryCt) ->
    gen_server:call(?MODULE, {update_registry, Account, RegistryCt}, ?AE_TIMEOUT).

%% -------- Node-level

%% MetaMap keys: name, endpoint, location, version, profile_uri,
%%               capability_hash, release_hash
%% CfgMap  keys: max_conc, protocol_min, protocol_max, pricing_hash
register_node(OwnerAccount, NodeId, MetaMap, CfgMap) ->
    gen_server:call(?MODULE, {register_node, OwnerAccount, NodeId, MetaMap, CfgMap}, ?AE_TIMEOUT).

register_self(OwnerAccount, MetaMap, CfgMap) ->
    gen_server:call(?MODULE, {register_self, OwnerAccount, MetaMap, CfgMap}, ?AE_TIMEOUT).

get_node(NodeId) ->
    gen_server:call(?MODULE, {get_node, NodeId}, ?AE_TIMEOUT).

get_node_owner(NodeId) ->
    gen_server:call(?MODULE, {get_node_owner, NodeId}, ?AE_TIMEOUT).

is_node_registered(NodeId) ->
    gen_server:call(?MODULE, {is_node_registered, NodeId}, ?AE_TIMEOUT).

get_nodes_for(Account) ->
    gen_server:call(?MODULE, {get_nodes_for, Account}, ?AE_TIMEOUT).

update_node_meta(NodeId, MetaMap) ->
    gen_server:call(?MODULE, {update_node_meta, NodeId, MetaMap}, ?AE_TIMEOUT).

update_node_cfg(NodeId, CfgMap) ->
    gen_server:call(?MODULE, {update_node_cfg, NodeId, CfgMap}, ?AE_TIMEOUT).

reassign_node(NodeId, NewOwnerAccount) ->
    gen_server:call(?MODULE, {reassign_node, NodeId, NewOwnerAccount}, ?AE_TIMEOUT).

set_node_enabled(NodeId, Enabled) when is_boolean(Enabled) ->
    gen_server:call(?MODULE, {set_node_enabled, NodeId, Enabled}, ?AE_TIMEOUT).

set_node_status(NodeId, Status) when is_integer(Status), Status >= 0, Status =< 4 ->
    gen_server:call(?MODULE, {set_node_status, NodeId, Status}, ?AE_TIMEOUT).

set_registry_paused(Paused) when is_boolean(Paused) ->
    gen_server:call(?MODULE, {set_registry_paused, Paused}, ?AE_TIMEOUT).

set_protocol_version(Version) when is_integer(Version), Version >= 0 ->
    gen_server:call(?MODULE, {set_protocol_version, Version}, ?AE_TIMEOUT).

set_successor(CtId) ->
    gen_server:call(?MODULE, {set_successor, CtId}, ?AE_TIMEOUT).

set_governance(Account) ->
    gen_server:call(?MODULE, {set_governance, Account}, ?AE_TIMEOUT).

%% Ensure this AE account has an AccountRegistry deployed (and recorded in NodeRegistry).
%% Returns {ok, RegistryCt} where RegistryCt is <<"ct_...">>.
-spec ensure_account_registry(binary() | list(), binary() | list()) ->
    {ok, binary()} | {error, term()}.
ensure_account_registry(AeAccount, Tier) ->
    ensure_account_registry(AeAccount, Tier, <<"">>).

-spec ensure_account_registry(binary() | list(), binary() | list(), binary() | list()) ->
    {ok, binary()} | {error, term()}.
ensure_account_registry(AeAccount0, Tier0, _RegistryLabel0) ->
    AeAccount = to_bin(AeAccount0),
    Tier = to_bin(Tier0),

    %% 1) If NodeRegistry already has a registry for this account, return it.
    case get_registry_ct_from_node_registry(AeAccount) of
        {ok, RegistryCt} ->
            {ok, RegistryCt};
        {error, not_registered} ->
            %% 2) Need to deploy + record
            case identity_server:get_account(AeAccount) of
                #{public_key := _Pub, private_key := _Priv} = KP ->
                    RegistryCt = to_bin(account_registry:deploy_account_registry(KP)),

                    %% 3) Record in NodeRegistry (admin-owned NodeRegistry call)
                    case ensure_registered_account(AeAccount, RegistryCt, Tier) of
                        {ok, true} ->
                            after_account_registry_deploy(AeAccount, RegistryCt),
                            {ok, RegistryCt};
                        {error, E2} ->
                            {error, {node_registry_register_failed, E2}}
                    end;
                Other ->
                    {error, {no_identity_account, AeAccount, Other}}
            end;
        {error, Why} ->
            {error, Why}
    end.

%% --- helpers

%% Extract per-account registry ct from NodeRegistry.get_registry(Account).
%% Normalizes to <<"ct_...">>.
-spec get_registry_ct_from_node_registry(binary()) ->
    {ok, binary()} | {error, not_registered} | {error, term()}.
get_registry_ct_from_node_registry(AeAccount) ->
    case damage_node_registry:get_registry(AeAccount) of
        #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
            {ok, aeser_api_encoder:encode(contract_pubkey, RegBin)};
        #{"return_type" := "revert", "return_value" := Msg} when
            Msg =:= <<"Account not registered">>;
            Msg =:= <<"Account not registered.">>;
            Msg =:= "Account not registered";
            Msg =:= "Account not registered."
        ->
            {error, not_registered};
        #{"return_type" := "revert", "return_value" := Msg} ->
            {error, {node_registry_revert, Msg}};
        Other ->
            {error, {node_registry_bad_reply, Other}}
    end.

%% Record (or refresh) the mapping in NodeRegistry.
%% This uses register_account/3 and tolerates "Already registered".
-spec ensure_registered_account(binary(), binary(), binary()) ->
    {ok, true} | {error, term()}.
ensure_registered_account(AeAccount, RegistryCt, Tier) ->
    case damage_node_registry:register_account(AeAccount, RegistryCt, Tier) of
        #{"return_type" := "ok", "return_value" := true} ->
            {ok, true};
        #{"return_type" := <<"ok">>, "return_value" := true} ->
            {ok, true};
        #{"return_type" := "revert", "return_value" := <<"Already registered">>} ->
            refresh_registered_account(AeAccount, RegistryCt, Tier);
        #{"return_type" := <<"revert">>, "return_value" := <<"Already registered">>} ->
            refresh_registered_account(AeAccount, RegistryCt, Tier);
        Other ->
            {error, {register_account_failed, Other}}
    end.

refresh_registered_account(AeAccount, RegistryCt, Tier) ->
    %% A deploy race or retry can hit an existing NodeRegistry row. Treat the
    %% freshly deployed AccountRegistry as authoritative and refresh both the
    %% registry pointer and tier. This also repairs stale NodeRegistry rows that
    %% point at AccountRegistry contracts that no longer exist.
    RegistryResp = damage_node_registry:update_registry(AeAccount, RegistryCt),
    TierResp = damage_node_registry:update_tier(AeAccount, Tier),
    case {contract_call_ok(RegistryResp), contract_call_ok(TierResp)} of
        {true, true} ->
            after_account_registry_deploy(AeAccount, RegistryCt),
            {ok, true};
        _ ->
            ?LOG_WARNING(
                "NodeRegistry account refresh failed account=~p registry=~p tier=~p registry_result=~p tier_result=~p",
                [AeAccount, RegistryCt, Tier, RegistryResp, TierResp]
            ),
            {error, {refresh_registered_account_failed, RegistryResp, TierResp}}
    end.

after_account_registry_deploy(AeAccount, RegistryCt) ->
    ?LOG_INFO("account registry deployed/registered account=~p registry_ct=~p", [
        AeAccount, RegistryCt
    ]),
    ignore_deploy_side_effect(
        fun() -> damage_node_registry:clear_cache({account, AeAccount}) end,
        node_registry_account_cache_clear
    ),
    ignore_deploy_side_effect(
        fun() -> damage_nwc_balance_cache:invalidate(AeAccount) end,
        nwc_balance_cache_invalidate
    ),
    ok.

ignore_deploy_side_effect(Fun, Label) when is_function(Fun, 0) ->
    try Fun() of
        _ ->
            ok
    catch
        Class:Reason:Stack ->
            ?LOG_DEBUG(
                "Ignoring deploy side-effect failure label=~p class=~p reason=~p stack=~p",
                [Label, Class, Reason, Stack]
            ),
            ok
    end.

contract_call_ok(#{"return_type" := "ok"}) -> true;
contract_call_ok(#{<<"return_type">> := <<"ok">>}) -> true;
contract_call_ok({ok, true}) -> true;
contract_call_ok(_) -> false.

%%% =========================
%%% gen_server CALLBACKS
%%% =========================

init([]) ->
    Tab = ets:new(?ETS_TABLE, [named_table, set, private]),
    ContractId =
        case resolve_contract_id() of
            {ok, CtId} -> CtId;
            _ -> undefined
        end,
    TtlMs = positive_env(node_registry_cache_ttl_ms, ?DEFAULT_TTL_MS),
    {ok, #state{ets_table = Tab, contract_id = ContractId, ttl_ms = TtlMs}}.

handle_call(get_contract_id, _From, #state{contract_id = ContractId} = State) ->
    {reply, ContractId, State};
handle_call({set_contract, ContractId0}, _From, State) ->
    case normalize_contract_id(ContractId0) of
        {ok, ContractId} ->
            erlang:put(node_registry_contract_id, ContractId),
            ets:delete_all_objects(State#state.ets_table),
            {reply, ok, State#state{contract_id = ContractId}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(network_info, _From, State) ->
    {reply, read_network_info(State), State};
handle_call(node_count, _From, State) ->
    {reply, read_node_count(State), State};
handle_call({get_node_at, Index}, _From, State) ->
    {reply, read_node_at(State, Index), State};
handle_call({recent_node_ids, Limit0}, _From, State) ->
    Limit = erlang:min(Limit0, 256),
    {reply, read_recent_node_ids(State, Limit), State};
handle_call(clear_cache, _From, State) ->
    ets:delete_all_objects(State#state.ets_table),
    {reply, ok, State};
handle_call({clear_cache, {account, Account0}}, _From, State) ->
    Account = to_bin(Account0),
    invalidate_account(State, Account),
    {reply, ok, State};
handle_call({clear_cache, {node, NodeId0}}, _From, State) ->
    NodeId = to_bin(NodeId0),
    invalidate_node(State, NodeId),
    {reply, ok, State};
handle_call({clear_cache, Key}, _From, State) ->
    cache_delete(State, normalize_cache_key(Key)),
    {reply, ok, State};
%% -------------------------
%% Account-level calls
%% -------------------------

handle_call({register_account, Account0, Registry0, Tier0}, _From, State) ->
    Account = to_bin(Account0),
    Registry = to_bin(Registry0),
    Tier = to_bin(Tier0),

    case
        contract_call_with_node_keypair(
            State, "register_account", [Account, Registry, Tier]
        )
    of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_account(State, Account),
            {reply, Resp, State}
    end;
handle_call({register_operator, Registry0}, _From, State) ->
    Registry = to_bin(Registry0),
    case contract_call_with_node_keypair(State, "register_operator", [Registry]) of
        {error, _} = Error -> {reply, Error, State};
        Resp -> {reply, Resp, State}
    end;
handle_call({set_operator_active, Account0, Active}, _From, State) ->
    Account = to_bin(Account0),
    case contract_call_with_node_keypair(State, "set_operator_active", [Account, Active]) of
        {error, _} = Error -> {reply, Error, State};
        Resp ->
            invalidate_account(State, Account),
            {reply, Resp, State}
    end;
handle_call({update_tier, Account0, Tier0}, _From, State) ->
    Account = to_bin(Account0),
    Tier = to_bin(Tier0),
    case contract_call_with_node_keypair(State, "update_tier", [Account, Tier]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_account(State, Account),
            {reply, Resp, State}
    end;
handle_call({update_registry, Account0, Registry0}, _From, State) ->
    Account = to_bin(Account0),
    Registry = to_bin(Registry0),
    case contract_call_with_node_keypair(State, "update_registry", [Account, Registry]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_account(State, Account),
            {reply, Resp, State}
    end;
%% -------------------------
%% Account-level reads
%% -------------------------

handle_call({get_user_info, Account0}, _From, State) ->
    Account = to_bin(Account0),
    {reply, cached_contract_call(State, {user_info, Account}, "get_user_info", [Account]), State};
handle_call({is_registered, Account0}, _From, State) ->
    Account = to_bin(Account0),
    {reply, cached_contract_call(State, {is_registered, Account}, "is_registered", [Account]),
        State};
handle_call({get_registry, Account0}, _From, State) ->
    Account = to_bin(Account0),
    {reply, cached_contract_call(State, {registry, Account}, "get_registry", [Account]), State};
%% -------------------------
%% Node-level writes
%% -------------------------

handle_call({register_self, Owner0, MetaMap0, CfgMap0}, _From, State) ->
    Owner = to_bin(Owner0),
    MetaRec = meta_map_to_record(MetaMap0),
    CfgRec = cfg_map_to_record(CfgMap0),
    case node_keypair() of
        {ok, #{public_key := NodeId} = KeyPair} ->
            Resp = contract_call_with_keypair(
                KeyPair, State, "register_node", [Owner, NodeId, MetaRec, CfgRec]
            ),
            invalidate_node(State, NodeId),
            invalidate_account(State, Owner),
            {reply, Resp, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({register_node, Owner0, NodeId0, MetaMap0, CfgMap0}, _From, State) ->
    Owner = to_bin(Owner0),
    NodeId = to_bin(NodeId0),
    MetaRec = meta_map_to_record(MetaMap0),
    CfgRec = cfg_map_to_record(CfgMap0),
    case
        contract_call_with_node_keypair(
            State, "register_node", [Owner, NodeId, MetaRec, CfgRec]
        )
    of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            invalidate_account(State, Owner),
            {reply, Resp, State}
    end;
handle_call({update_node_meta, NodeId0, MetaMap0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    MetaRec = meta_map_to_record(MetaMap0),
    case contract_call_with_node_keypair(State, "update_node_meta", [NodeId, MetaRec]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            {reply, Resp, State}
    end;
handle_call({update_node_cfg, NodeId0, CfgMap0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    CfgRec = cfg_map_to_record(CfgMap0),
    case contract_call_with_node_keypair(State, "update_node_cfg", [NodeId, CfgRec]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            {reply, Resp, State}
    end;
handle_call({reassign_node, NodeId0, NewOwner0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    NewOwner = to_bin(NewOwner0),

    %% Fetch the old owner only for cache invalidation. A transient read error
    %% must not prevent the mutation itself from returning its real result.
    OldOwnerResp = cached_contract_call(State, {node_owner, NodeId}, "get_node_owner", [NodeId]),
    OldOwner =
        case OldOwnerResp of
            #{"return_type" := "ok", "return_value" := {address, OwnerBin}} ->
                aeser_api_encoder:encode(account_pubkey, OwnerBin);
            _ ->
                undefined
        end,

    case contract_call_with_node_keypair(State, "reassign_node", [NodeId, NewOwner]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            invalidate_account(State, NewOwner),
            case OldOwner of
                undefined -> ok;
                _ -> invalidate_account(State, OldOwner)
            end,
            {reply, Resp, State}
    end;
handle_call({set_node_enabled, NodeId0, Enabled}, _From, State) ->
    NodeId = to_bin(NodeId0),
    case contract_call_with_node_keypair(State, "set_node_enabled", [NodeId, Enabled]) of
        {error, _} = Error ->
            {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            {reply, Resp, State}
    end;
handle_call({set_node_status, NodeId0, Status}, _From, State) ->
    NodeId = to_bin(NodeId0),
    case contract_call_with_node_keypair(State, "set_node_status", [NodeId, Status]) of
        {error, _} = Error -> {reply, Error, State};
        Resp ->
            invalidate_node(State, NodeId),
            {reply, Resp, State}
    end;
handle_call({set_registry_paused, Paused}, _From, State) ->
    {reply, contract_call_with_node_keypair(State, "set_paused", [Paused]), State};
handle_call({set_protocol_version, Version}, _From, State) ->
    {reply, contract_call_with_node_keypair(State, "set_protocol_version", [Version]), State};
handle_call({set_successor, CtId0}, _From, State) ->
    CtId = to_bin(CtId0),
    {reply, contract_call_with_node_keypair(State, "set_successor", [CtId]), State};
handle_call({set_governance, Account0}, _From, State) ->
    Account = to_bin(Account0),
    {reply, contract_call_with_node_keypair(State, "set_governance", [Account]), State};
%% -------------------------
%% Node-level reads
%% -------------------------

handle_call({get_node, NodeId0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    {reply, cached_contract_call(State, {node, NodeId}, "get_node", [NodeId]), State};
handle_call({get_node_owner, NodeId0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    {reply, cached_contract_call(State, {node_owner, NodeId}, "get_node_owner", [NodeId]), State};
handle_call({is_node_registered, NodeId0}, _From, State) ->
    NodeId = to_bin(NodeId0),
    {reply,
        cached_contract_call(State, {is_node_registered, NodeId}, "is_node_registered", [NodeId]),
        State};
handle_call({get_nodes_for, Account0}, _From, State) ->
    Account = to_bin(Account0),
    {reply, cached_contract_call(State, {nodes_for, Account}, "get_nodes_for", [Account]), State};
handle_call(Other, _From, State) ->
    ?LOG_WARNING("Unhandled call ~p", [Other]),
    {reply, {error, unhandled_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% =========================
%%% TEST
%%% =========================

test() ->
    %% Example maps for node meta/cfg
    Owner = <<"ak_...">>,
    NodeId = <<"ak_...">>,

    Meta = #{
        name => <<"Sydney Runner #1">>,
        endpoint => <<"https://runner1.damagebdd.com">>,
        location => <<"AU-SYD">>,
        version => <<"1.0.0">>,
        profile_uri => <<"ipfs://bafy...">>,
        capability_hash => <<"sha256:capabilities">>,
        release_hash => <<"sha256:release">>
    },

    Cfg = #{
        max_conc => 64,
        protocol_min => 1,
        protocol_max => 1,
        pricing_hash => <<"sha256:pricing">>
    },

    ?LOG_INFO("register_node -> ~p", [register_node(Owner, NodeId, Meta, Cfg)]),
    ?LOG_INFO("get_node -> ~p", [get_node(NodeId)]),
    ok.

%%% =========================
%%% INTERNAL HELPERS
%%% =========================

require_contract(#state{contract_id = undefined}) ->
    error({
        node_registry_contract_not_set,
        "configure damage.node_registry_ct or damage.node_registry_contracts"
    });
require_contract(#state{contract_id = C}) ->
    C.

normalize_contract_id(<<"ct_", _/binary>> = ContractId) ->
    {ok, ContractId};
normalize_contract_id(ContractId) when is_list(ContractId) ->
    try unicode:characters_to_binary(ContractId) of
        <<"ct_", _/binary>> = Bin -> {ok, Bin};
        Bin -> {error, {invalid_contract_id, Bin}}
    catch
        _:_ -> {error, {invalid_contract_id, ContractId}}
    end;
normalize_contract_id(Other) ->
    {error, {invalid_contract_id, Other}}.

resolve_network_contract() ->
    Network = expected_network_id(),
    Contracts = application:get_env(damage, node_registry_contracts, []),
    case [Ct || {Net, Ct} <- Contracts, to_bin(Net) =:= Network] of
        [CtId0 | _] -> normalize_contract_id(CtId0);
        [] -> missing
    end.

expected_network_id() ->
    to_bin(vanillae:network_id()).

expected_protocol_version() ->
    application:get_env(damage, node_protocol_version, ?DEFAULT_PROTOCOL_VERSION).

positive_env(Key, Default) ->
    case application:get_env(damage, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> list_to_binary(io_lib:format("~p", [V])).

cached_contract_call(State, CacheKey, Func, Args) ->
    case cache_get(State, CacheKey) of
        {ok, Val} ->
            Val;
        miss ->
            case node_keypair() of
                {ok, KeyPair} ->
                    ContractId = require_contract(State),
                    Resp = damage_ae:contract_call_dry(
                        KeyPair,
                        ContractId,
                        damage_ae:contract_path(damage, State#state.contract_path),
                        Func,
                        Args
                    ),
                    maybe_cache_put(State, CacheKey, Resp),
                    Resp;
                {error, _} = Error ->
                    Error
            end
    end.

node_keypair() ->
    try secrets:node_keypair() of
        #{public_key := _PublicKey, private_key := _PrivateKey} = KeyPair ->
            {ok, KeyPair};
        {error, node_locked} ->
            {error, node_locked};
        {error, Reason} ->
            {error, {node_keypair_unavailable, Reason}};
        Other ->
            {error, {invalid_node_keypair_result, Other}}
    catch
        Class:Reason ->
            {error, {node_keypair_lookup_failed, Class, Reason}}
    end.

contract_call_with_keypair(KeyPair, State, Func, Args) ->
    damage_ae:contract_call(
        KeyPair,
        require_contract(State),
        damage_ae:contract_path(damage, State#state.contract_path),
        Func,
        Args
    ).

contract_call_with_node_keypair(State, Func, Args) ->
    case node_keypair() of
        {ok, KeyPair} ->
            contract_call_with_keypair(KeyPair, State, Func, Args);
        {error, _} = Error ->
            Error
    end.

maybe_cache_put(State, Key, Resp) ->
    case is_cacheable_response(Resp) of
        true -> cache_put(State, Key, Resp);
        false -> ok
    end.

is_cacheable_response(#{"return_type" := "ok"}) -> true;
is_cacheable_response(#{<<"return_type">> := <<"ok">>}) -> true;
is_cacheable_response(#{return_type := ok}) -> true;
is_cacheable_response(_) -> false.

invalidate_account(State, Account) ->
    cache_delete(State, {user_info, Account}),
    cache_delete(State, {registry, Account}),
    cache_delete(State, {is_registered, Account}),
    cache_delete(State, {nodes_for, Account}),
    ok.

invalidate_node(State, NodeId) ->
    cache_delete(State, {node, NodeId}),
    cache_delete(State, {node_owner, NodeId}),
    cache_delete(State, {is_node_registered, NodeId}),
    ok.

cache_get(#state{ets_table = Tab, ttl_ms = TtlMs}, Key) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(Tab, Key) of
        [{Key, Ts, Val}] when (Now - Ts) =< TtlMs ->
            {ok, Val};
        [{Key, _Ts, _Val}] ->
            ets:delete(Tab, Key),
            miss;
        [] ->
            miss
    end.

cache_put(#state{ets_table = Tab}, Key, Val) ->
    Ts = erlang:monotonic_time(millisecond),
    ets:insert(Tab, {Key, Ts, Val}),
    ok.

cache_delete(#state{ets_table = Tab}, Key) ->
    ets:delete(Tab, Key),
    ok.
normalize_cache_key({user_info, Account}) ->
    {user_info, to_bin(Account)};
normalize_cache_key({registry, Account}) ->
    {registry, to_bin(Account)};
normalize_cache_key({is_registered, Account}) ->
    {is_registered, to_bin(Account)};
normalize_cache_key({nodes_for, Account}) ->
    {nodes_for, to_bin(Account)};
normalize_cache_key({node, NodeId}) ->
    {node, to_bin(NodeId)};
normalize_cache_key({node_owner, NodeId}) ->
    {node_owner, to_bin(NodeId)};
normalize_cache_key({is_node_registered, NodeId}) ->
    {is_node_registered, to_bin(NodeId)};
normalize_cache_key(Key) ->
    Key.

%% Convert Erlang maps into Sophia records-as-maps expected by the v3 contract.
meta_map_to_record(M) when is_map(M) ->
    #{
        name => to_bin(maps:get(name, M, <<>>)),
        endpoint => to_bin(maps:get(endpoint, M, <<>>)),
        location => to_bin(maps:get(location, M, <<>>)),
        version => to_bin(maps:get(version, M, <<>>)),
        profile_uri => to_bin(maps:get(profile_uri, M, <<>>)),
        capability_hash => to_bin(maps:get(capability_hash, M, <<>>)),
        release_hash => to_bin(maps:get(release_hash, M, <<>>))
    }.

cfg_map_to_record(M) when is_map(M) ->
    Protocol = expected_protocol_version(),
    #{
        max_conc => maps:get(max_conc, M, 0),
        protocol_min => maps:get(protocol_min, M, Protocol),
        protocol_max => maps:get(protocol_max, M, Protocol),
        pricing_hash => to_bin(maps:get(pricing_hash, M, <<>>))
    }.

%% -------------------------------------------------------------------
%% Canonical registry validation / explicit deployment
%% -------------------------------------------------------------------

-spec validate_contract(binary() | list()) -> {ok, map()} | {error, term()}.
validate_contract(CtId0) ->
    case normalize_contract_id(CtId0) of
        {ok, CtId} ->
            case node_keypair() of
                {ok, KeyPair} ->
                    Path = damage_ae:contract_path(damage, ?DEFAULT_CONTRACT_PATH),
                    Version = query_contract_value(KeyPair, CtId, Path, "registry_version", []),
                    Network = query_contract_value(KeyPair, CtId, Path, "network_id", []),
                    ExpectedNetwork = expected_network_id(),
                    case {normalize_int_value(Version), normalize_bin_value(Network)} of
                        {{ok, ?REGISTRY_VERSION}, {ok, ExpectedNetwork}} ->
                            {ok, #{
                                contract_id => CtId,
                                registry_version => ?REGISTRY_VERSION,
                                network_id => ExpectedNetwork
                            }};
                        {{ok, OtherVersion}, {ok, OtherNetwork}} ->
                            {error, {node_registry_identity_mismatch, #{
                                contract_id => CtId,
                                expected_registry_version => ?REGISTRY_VERSION,
                                registry_version => OtherVersion,
                                expected_network_id => ExpectedNetwork,
                                network_id => OtherNetwork
                            }}};
                        Other ->
                            {error, {node_registry_validation_failed, CtId, Other}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

query_contract_value(KeyPair, CtId, Path, Func, Args) ->
    %% Registry identity validation must be read-only and deterministic.
    %% Do not use damage_ae:contract_query/5 here: that API may fall back to
    %% an on-chain contract call when dry-run is unavailable, which is both
    %% inappropriate during startup validation and can return transaction-shaped
    %% results instead of a pure query result. All other NodeRegistry reads use
    %% contract_call_dry/5, so keep validation on the same path.
    case damage_ae:contract_call_dry(KeyPair, CtId, Path, Func, Args) of
        #{"return_type" := "ok", "return_value" := Value} ->
            Value;
        #{<<"return_type">> := <<"ok">>, <<"return_value">> := Value} ->
            Value;
        #{return_type := ok, return_value := Value} ->
            Value;
        {error, Reason} ->
            {error, {contract_dry_query_failed, Func, Reason}};
        #{"return_type" := ReturnType, "return_value" := ReturnValue} ->
            {error, {contract_dry_query_rejected, Func, ReturnType, ReturnValue}};
        #{<<"return_type">> := ReturnType, <<"return_value">> := ReturnValue} ->
            {error, {contract_dry_query_rejected, Func, ReturnType, ReturnValue}};
        Other ->
            {error, {contract_dry_query_failed, Func, Other}}
    end.

normalize_int_value(I) when is_integer(I) -> {ok, I};
normalize_int_value({int, I}) when is_integer(I) -> {ok, I};
normalize_int_value(Other) -> {error, {invalid_int_value, Other}}.

normalize_bin_value(B) when is_binary(B) -> {ok, B};
normalize_bin_value(L) when is_list(L) ->
    try {ok, unicode:characters_to_binary(L)}
    catch _:_ -> {error, {invalid_binary_value, L}} end;
normalize_bin_value({string, V}) -> normalize_bin_value(V);
normalize_bin_value(Other) -> {error, {invalid_binary_value, Other}}.

bootstrap_enabled() ->
    application:get_env(damage, node_registry_bootstrap, false) =:= true.

deploy_args() ->
    [binary_to_list(expected_network_id()), integer_to_list(expected_protocol_version())].

-spec deploy_node_registry() -> binary() | {error, term()}.
deploy_node_registry() ->
    case bootstrap_enabled() of
        false ->
            {error, node_registry_bootstrap_disabled};
        true ->
            case node_keypair() of
                {ok, KeyPair} -> deploy_node_registry_direct(KeyPair);
                {error, _} = Error -> Error
            end
    end.

%% Explicit account-owned bootstrap helper.  Kept for administrative tooling;
%% ordinary nodes never call it implicitly.
-spec deploy_node_registry(map()) -> binary() | {error, term()}.
deploy_node_registry(KeyPair) when is_map(KeyPair) ->
    case bootstrap_enabled() of
        false ->
            {error, node_registry_bootstrap_disabled};
        true ->
            DeployPath = damage_ae:contract_path(damage, ?DEFAULT_CONTRACT_PATH),
            case damage_ae:contract_deploy_for(KeyPair, DeployPath, deploy_args()) of
                #{"contract_id" := ContractId0} -> activate_deployed_contract(ContractId0);
                #{<<"contract_id">> := ContractId0} -> activate_deployed_contract(ContractId0);
                #{"return_type" := "revert"} = Info ->
                    {error, {node_registry_deploy_revert, Info}};
                Other ->
                    {error, {node_registry_deploy_failed, Other}}
            end
    end.

deploy_node_registry_direct(KeyPair) ->
    DeployPath = damage_ae:contract_path(damage, ?DEFAULT_CONTRACT_PATH),
    case damage_ae:contract_deploy(KeyPair, DeployPath, deploy_args()) of
        #{"contract_id" := ContractId0} -> activate_deployed_contract(ContractId0);
        #{<<"contract_id">> := ContractId0} -> activate_deployed_contract(ContractId0);
        #{"return_type" := "revert"} = Info ->
            {error, {node_registry_deploy_revert, Info}};
        Other ->
            {error, {node_registry_deploy_failed, Other}}
    end.

activate_deployed_contract(ContractId0) ->
    case normalize_contract_id(ContractId0) of
        {ok, ContractId} ->
            application:set_env(damage, node_registry_ct, ContractId),
            _ = damage_otp_compat:catch_value(fun() ->
                gen_server:call(?MODULE, {set_contract, ContractId})
            end),
            ContractId;
        {error, _} = Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% Typed reads used by directory/discovery APIs
%% -------------------------------------------------------------------

read_network_info(State) ->
    case {
        read_scalar(State, network_id, "network_id", []),
        read_scalar(State, protocol_version, "protocol_version", []),
        read_scalar(State, registry_version, "registry_version", []),
        read_scalar(State, governance, "governance", []),
        read_scalar(State, paused, "paused", [])
    } of
        {{ok, Network0}, {ok, Protocol0}, {ok, Registry0}, {ok, Governance0}, {ok, Paused0}} ->
            case {
                normalize_bin_value(Network0),
                normalize_int_value(Protocol0),
                normalize_int_value(Registry0),
                normalize_account_value(Governance0),
                normalize_bool_value(Paused0)
            } of
                {{ok, Network}, {ok, Protocol}, {ok, Registry}, {ok, Governance}, {ok, Paused}} ->
                    {ok, #{
                        contract_id => State#state.contract_id,
                        network_id => Network,
                        protocol_version => Protocol,
                        registry_version => Registry,
                        governance => Governance,
                        paused => Paused
                    }};
                Other ->
                    {error, {invalid_network_info, Other}}
            end;
        Other ->
            {error, {network_info_unavailable, Other}}
    end.

read_node_count(State) ->
    case read_scalar(State, node_count, "node_count", []) of
        {ok, Value} -> normalize_int_value(Value);
        Error -> Error
    end.

read_node_at(State, Index) ->
    case read_scalar(State, {node_at, Index}, "get_node_at", [Index]) of
        {ok, Value} -> normalize_account_value(Value);
        Error -> Error
    end.

read_recent_node_ids(State, Limit) ->
    case read_node_count(State) of
        {ok, 0} ->
            {ok, #{total => 0, node_ids => []}};
        {ok, Count} when Count > 0 ->
            N = erlang:min(Limit, Count),
            Start = Count - N,
            Indices = lists:reverse(lists:seq(Start, Count - 1)),
            collect_node_ids(State, Indices, [], Count);
        {error, _} = Error ->
            Error
    end.

collect_node_ids(_State, [], Acc, Total) ->
    {ok, #{total => Total, node_ids => lists:reverse(Acc)}};
collect_node_ids(State, [Index | Rest], Acc, Total) ->
    case read_node_at(State, Index) of
        {ok, NodeId} -> collect_node_ids(State, Rest, [NodeId | Acc], Total);
        {error, _} = Error -> Error
    end.

read_scalar(State, CacheKey, Func, Args) ->
    case cached_contract_call(State, CacheKey, Func, Args) of
        #{"return_type" := "ok", "return_value" := Value} -> {ok, Value};
        #{<<"return_type">> := <<"ok">>, <<"return_value">> := Value} -> {ok, Value};
        #{return_type := ok, return_value := Value} -> {ok, Value};
        {error, _} = Error -> Error;
        Other -> {error, {registry_read_failed, Func, Other}}
    end.

normalize_account_value({address, Raw}) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    try {ok, to_bin(aeser_api_encoder:encode(account_pubkey, Raw))}
    catch Class:Reason -> {error, {account_encode_failed, Class, Reason}} end;
normalize_account_value(Value) when is_binary(Value); is_list(Value) ->
    Bin = to_bin(Value),
    case Bin of
        <<"ak_", _/binary>> -> {ok, Bin};
        _ -> {error, {invalid_account_value, Value}}
    end;
normalize_account_value(Other) ->
    {error, {invalid_account_value, Other}}.

normalize_bool_value(true) -> {ok, true};
normalize_bool_value(false) -> {ok, false};
normalize_bool_value({bool, Value}) when is_boolean(Value) -> {ok, Value};
normalize_bool_value(Other) -> {error, {invalid_bool_value, Other}}.
