%% -------------------------------------------------------------------
%% damage_node_registry.erl
%%
%% Erlang interface for NodeRegistry (Sophia @compiler >= 6).
%% Mirrors the style of identity_server: gen_server + ETS cache +
%% damage_ae:contract_call wrappers.
%%
%% Expected Sophia entrypoints (from your NodeRegistry v2):
%%   - register_account(account, registry, tier) : bool
%%   - get_user_info(account) : user_info
%%   - is_registered(account) : bool
%%   - get_registry(account) : address
%%   - update_tier(account, tier) : bool
%%   - register_node(owner_account, node_id, meta, cfg) : bool
%%   - get_node(node_id) : node_info
%%   - get_node_owner(node_id) : address
%%   - is_node_registered(node_id) : bool
%%   - get_nodes_for(account) : list(address)
%%   - update_node_meta(node_id, meta) : bool
%%   - update_node_cfg(node_id, cfg) : bool
%%   - reassign_node(node_id, new_owner_account) : bool
%%   - set_node_enabled(node_id, enabled) : bool
%%
%% NOTE:
%% - This module assumes you have:
%%     * damage_ae:contract_call/[4,5,6] similar to your identity_server usage
%%     * secrets:node_keypair/0 for signed stateful calls
%%     * ?NODE_REGISTRY_CONTRACT macro in damage.hrl (or set_contract/1 API below)
%% -------------------------------------------------------------------

-module(damage_node_registry).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(gen_server).

-export([
    start_link/0,
    set_contract/1,
    clear_cache/0,
    clear_cache/1,

    %% account-level
    register_account/3,
    get_user_info/1,
    is_registered/1,
    get_registry/1,
    update_tier/2,
    get_registry_ct_from_node_registry/1,

    %% node-level
    register_node/4,
    get_node/1,
    get_node_owner/1,
    is_node_registered/1,
    get_nodes_for/1,
    update_node_meta/2,
    update_node_cfg/2,
    reassign_node/2,
    set_node_enabled/2,

    deploy_node_registry/0,
    deploy_node_registry/1,

    ensure_account_registry/2,
    ensure_account_registry/3,
    ensure_registered_account/3,
    update_registry/2,

    %% test helpers
    test/0
]).
-define(NODE_REGISTRY_CONTRACT,
    "ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ"
).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(DEFAULT_CONTRACT_PATH, "node_registry.aes").
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

clear_cache() ->
    gen_server:call(?MODULE, clear_cache).

clear_cache(Key) ->
    gen_server:call(?MODULE, {clear_cache, Key}).

register_account(Account, Registry, Tier) ->
    gen_server:call(?MODULE, {register_account, Account, Registry, Tier}, ?AE_TIMEOUT).

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

%% MetaMap keys: name, endpoint, location, version, notes
%% CfgMap  keys: enabled, max_conc, pricing_tier, cfg_json
register_node(OwnerAccount, NodeId, MetaMap, CfgMap) ->
    gen_server:call(?MODULE, {register_node, OwnerAccount, NodeId, MetaMap, CfgMap}, ?AE_TIMEOUT).

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
        #{"return_type" := "revert", "return_value" := <<"Account not registered">>} ->
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
    {ok, #state{ets_table = Tab, contract_id = ?NODE_REGISTRY_CONTRACT}}.

handle_call({set_contract, ContractId0}, _From, State) ->
    ContractId = to_bin(ContractId0),
    erlang:put(node_registry_contract_id, ContractId),
    ets:delete_all_objects(State#state.ets_table),
    {reply, ok, State#state{contract_id = ContractId}};
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
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    Account = to_bin(Account0),
    Registry = to_bin(Registry0),
    Tier = to_bin(Tier0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "register_account",
        [Account, Registry, Tier]
    ),

    invalidate_account(State, Account),
    {reply, Resp, State};
handle_call({update_tier, Account0, Tier0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    Account = to_bin(Account0),
    Tier = to_bin(Tier0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "update_tier",
        [Account, Tier]
    ),

    invalidate_account(State, Account),
    {reply, Resp, State};
handle_call({update_registry, Account0, Registry0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    Account = to_bin(Account0),
    Registry = to_bin(Registry0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "update_registry",
        [Account, Registry]
    ),

    invalidate_account(State, Account),
    {reply, Resp, State};
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

handle_call({register_node, Owner0, NodeId0, MetaMap0, CfgMap0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    Owner = to_bin(Owner0),
    NodeId = to_bin(NodeId0),
    MetaRec = meta_map_to_record(MetaMap0),
    CfgRec = cfg_map_to_record(CfgMap0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "register_node",
        [Owner, NodeId, MetaRec, CfgRec]
    ),

    invalidate_node(State, NodeId),
    invalidate_account(State, Owner),
    {reply, Resp, State};
handle_call({update_node_meta, NodeId0, MetaMap0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    NodeId = to_bin(NodeId0),
    MetaRec = meta_map_to_record(MetaMap0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "update_node_meta",
        [NodeId, MetaRec]
    ),

    invalidate_node(State, NodeId),
    {reply, Resp, State};
handle_call({update_node_cfg, NodeId0, CfgMap0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    NodeId = to_bin(NodeId0),
    CfgRec = cfg_map_to_record(CfgMap0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "update_node_cfg",
        [NodeId, CfgRec]
    ),

    invalidate_node(State, NodeId),
    {reply, Resp, State};
handle_call({reassign_node, NodeId0, NewOwner0}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    NodeId = to_bin(NodeId0),
    NewOwner = to_bin(NewOwner0),

    %% fetch old owner before mutation so we can invalidate both sides
    OldOwnerResp = cached_contract_call(State, {node_owner, NodeId}, "get_node_owner", [NodeId]),
    OldOwner =
        case OldOwnerResp of
            #{"return_type" := "ok", "return_value" := {address, OwnerBin}} ->
                aeser_api_encoder:encode(account_pubkey, OwnerBin);
            _ ->
                undefined
        end,

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "reassign_node",
        [NodeId, NewOwner]
    ),

    invalidate_node(State, NodeId),
    invalidate_account(State, NewOwner),
    case OldOwner of
        undefined -> ok;
        _ -> invalidate_account(State, OldOwner)
    end,
    {reply, Resp, State};
handle_call({set_node_enabled, NodeId0, Enabled}, _From, State) ->
    ContractId = require_contract(State),
    KeyPair = secrets:node_keypair(),
    NodeId = to_bin(NodeId0),

    Resp = damage_ae:contract_call(
        KeyPair,
        ContractId,
        damage_ae:contract_path(State#state.contract_path),
        "set_node_enabled",
        [NodeId, Enabled]
    ),

    invalidate_node(State, NodeId),
    {reply, Resp, State};
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
        notes => <<"poolboy worker nodes">>
    },

    Cfg = #{
        enabled => true,
        max_conc => 64,
        pricing_tier => <<"market">>,
        cfg_json => <<"{\"tags\":[\"http\",\"selenium\"],\"limits\":{\"cpu\":8}}">>
    },

    ?LOG_INFO("register_node -> ~p", [register_node(Owner, NodeId, Meta, Cfg)]),
    ?LOG_INFO("get_node -> ~p", [get_node(NodeId)]),
    ok.

%%% =========================
%%% INTERNAL HELPERS
%%% =========================

require_contract(#state{contract_id = undefined}) ->
    error(
        {node_registry_contract_not_set, "call set_contract/1 or define ?NODE_REGISTRY_CONTRACT"}
    );
require_contract(#state{contract_id = C}) ->
    C.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> list_to_binary(io_lib:format("~p", [V])).

cached_contract_call(State, CacheKey, Func, Args) ->
    case cache_get(State, CacheKey) of
        {ok, Val} ->
            Val;
        miss ->
            ContractId = require_contract(State),
            KeyPair = secrets:node_keypair(),
            Resp = damage_ae:contract_call(
                KeyPair,
                ContractId,
                damage_ae:contract_path(State#state.contract_path),
                Func,
                Args
            ),
            maybe_cache_put(State, CacheKey, Resp),
            Resp
    end.

maybe_cache_put(State, Key, Resp) ->
    case is_cacheable_response(Resp) of
        true -> cache_put(State, Key, Resp);
        false -> ok
    end.

is_cacheable_response(#{"return_type" := "ok"}) ->
    true;
is_cacheable_response(_) ->
    false.

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

%% Convert Erlang maps into Sophia records-as-maps expected by your contract_call encoder.
%% This assumes your damage_ae encoder supports nested record maps in the usual style:
%%   #{field := Value, ...}
meta_map_to_record(M) when is_map(M) ->
    #{
        name => to_bin(maps:get(name, M, <<"">>)),
        endpoint => to_bin(maps:get(endpoint, M, <<"">>)),
        location => to_bin(maps:get(location, M, <<"">>)),
        version => to_bin(maps:get(version, M, <<"">>)),
        notes => to_bin(maps:get(notes, M, <<"">>))
    }.

cfg_map_to_record(M) when is_map(M) ->
    #{
        enabled => maps:get(enabled, M, true),
        max_conc => maps:get(max_conc, M, 0),
        pricing_tier => to_bin(maps:get(pricing_tier, M, <<"">>)),
        cfg_json => to_bin(maps:get(cfg_json, M, <<"">>))
    }.

%% -------------------------------------------------------------------
%% Deployment helper
%% -------------------------------------------------------------------

%% Deploy using the node (service) keypair (server-owned deployment)
-spec deploy_node_registry() -> binary().
deploy_node_registry() ->
    DeployPath = damage_ae:contract_path(?DEFAULT_CONTRACT_PATH),
    KeyPair = secrets:node_keypair(),
    case damage_ae:contract_deploy(KeyPair, DeployPath, []) of
        #{"contract_id" := ContractId} ->
            %% Optional: remember + hot-set for this runtime
            erlang:put(node_registry_contract_id, ContractId),
            SetContractResult =
                try gen_server:call(?MODULE, {set_contract, ContractId}) of
                    Result ->
                        {ok, Result}
                catch
                    Class:Reason:Stack ->
                        ?LOG_DEBUG(
                            "set_contract failed contract_id=~p class=~p reason=~p stack=~p",
                            [ContractId, Class, Reason, Stack]
                        ),
                        {error, {Class, Reason, Stack}}
                end,
            ?LOG_DEBUG(
                "set_contract result contract_id=~p result=~p",
                [ContractId, SetContractResult]
            ),
            ContractId;
        #{"return_type" := "revert"} = Info ->
            error({node_registry_deploy_revert, Info});
        Other ->
            error({node_registry_deploy_failed, Other})
    end.

%% Deploy using a provided keypair (account-owned deployment)
%% Returns ContractId (<<"ct_...">>)
-spec deploy_node_registry(map()) -> binary().
deploy_node_registry(KeyPair) when is_map(KeyPair) ->
    %% IMPORTANT:
    %% - contract_path here should point at the NodeRegistry Sophia file
    %% - you already keep State#state.contract_path as "contracts/node_registry.aes"
    %%   but deploy needs the on-disk path (same pattern as AccountRegistry)
    DeployPath = damage_ae:contract_path(?DEFAULT_CONTRACT_PATH),

    %% If your deploy fn is named differently (contract_deploy_for vs contract_deploy),
    %% swap this call to match your damage_ae API.
    case damage_ae:contract_deploy_for(KeyPair, DeployPath, []) of
        #{"contract_id" := ContractId} ->
            %% Optional: remember + hot-set for this runtime
            erlang:put(node_registry_contract_id, ContractId),
            SetContractResult =
                try gen_server:call(?MODULE, {set_contract, ContractId}) of
                    Result ->
                        {ok, Result}
                catch
                    Class:Reason:Stack ->
                        ?LOG_DEBUG(
                            "set_contract failed contract_id=~p class=~p reason=~p stack=~p",
                            [ContractId, Class, Reason, Stack]
                        ),
                        {error, {Class, Reason, Stack}}
                end,
            ?LOG_DEBUG(
                "set_contract result contract_id=~p result=~p",
                [ContractId, SetContractResult]
            ),
            ContractId;
        #{"return_type" := "revert"} = Info ->
            error({node_registry_deploy_revert, Info});
        Other ->
            error({node_registry_deploy_failed, Other})
    end.
