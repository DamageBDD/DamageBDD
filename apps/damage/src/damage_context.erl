%%%-------------------------------------------------------------------
%%% DamageBDD scoped context API.
%%%
%%% Context values are encrypted and stored off-chain by
%%% damage_context_store. Frozen context proofs are published to IPFS and
%%% included in the execution report; no separate context contract is used.
%%%
%%% Public HTTP ownership is derived from authentication state; callers never
%%% choose an arbitrary owner address in a request body.
%%%-------------------------------------------------------------------
-module(damage_context).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% Lifecycle compatibility.
-export([
    start_link/0,
    start_link/1,
    ensure_started/0,
    stop/0
]).

%% Scope constructors and identity.
-export([
    node_scope/0,
    account_scope/1,
    wallet_scope/2,
    agent_scope/2,
    resolve_scope/1,
    scope_key/1,
    namespace/1
]).

%% Clean programmatic API.
-export([
    ensure_scope/1,
    get/2,
    get_scope/1,
    get_context/1,
    get_entries/1,
    snapshot/1,
    public_snapshot/1,
    public_effective_snapshot/1,
    version/1,
    root/1,
    put/3,
    put/4,
    delete/2,
    clear/1,
    apply_changes/2,
    apply_changes/3,
    load_context/1,
    effective_context/2,
    effective_context/3,
    prepare_run_context/1,
    context_proofs/1,
    write_run_proof/2,
    publish_run_proof/2
]).

%% Compatibility API retained for existing callers.
-export([
    get_context_proc/1,
    restart_context_proc/1,
    add_context/3,
    add_context/4,
    contract_add_context/4,
    contract_delete_context/2,
    contract_get_context/1
]).

%% Rendering and redaction helpers used by the runner.
-export([
    get_global_template_context/1,
    get_stepargs/1,
    render_body_args/2,
    clean_secrets/3
]).

%% Cowboy REST API.
-export([
    init/2,
    trails/0,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_json/2,
    from_json/2,
    from_html/2,
    delete_resource/2
]).

%% Lightweight test helpers.
-export([test/0, test_account_context/0]).

-define(SCHEMA_VERSION, 2).
%% A tuple cannot be produced by the JSON decoders used by the public API.
%% It therefore acts as an internal idempotency marker rather than a
%% client-forgeable boolean flag.
-define(EFFECTIVE_MARKER, {prepared, ?SCHEMA_VERSION}).
-define(DEFAULT_MAX_REQUEST_BYTES, 1048576).
-define(MAX_KEY_BYTES, 256).
-define(TRAILS_TAG, ["Context Management"]).
-define(REDACTED_TEXT_MARKER, <<"XX-REDACTED-XX">>).

-type scope_kind() :: node | account | wallet | agent.
-type scope() :: #{
    kind := scope_kind(),
    owner := binary(),
    id := binary()
}.
-type context_key() :: binary() | list() | atom().
-type entry() :: #{
    value := term(),
    sensitive := boolean(),
    exposure := template | step_only,
    inheritance := default | locked | none,
    locked := boolean(),
    updated_at := non_neg_integer()
}.

%%%===================================================================
%%% Lifecycle
%%%===================================================================

start_link() ->
    damage_context_store:start_link().

%% Compatibility with the previous per-account worker specification. There is
%% now one shared store process, so the account argument is intentionally
%% ignored.
start_link(_AeAccount) ->
    start_link().

ensure_started() ->
    damage_context_store:ensure_started().

stop() ->
    damage_context_store:stop().

%%%===================================================================
%%% Scope model
%%%===================================================================

-spec node_scope() -> scope() | {error, term()}.
node_scope() ->
    case node_account() of
        {ok, Owner} -> canonical_scope(node, Owner, <<"default">>);
        {error, _} = Error -> Error
    end.

-spec account_scope(binary() | list()) -> scope().
account_scope(AeAccount) ->
    canonical_scope(account, normalize_account(AeAccount), <<"default">>).

-spec wallet_scope(binary() | list(), term()) -> scope().
wallet_scope(AeAccount, WalletId) ->
    canonical_scope(wallet, normalize_account(AeAccount), normalize_scope_id(WalletId)).

-spec agent_scope(binary() | list(), term()) -> scope().
agent_scope(AeAccount, AgentId) ->
    canonical_scope(agent, normalize_account(AeAccount), normalize_scope_id(AgentId)).

-spec resolve_scope(term()) -> {ok, scope()} | {error, term()}.
resolve_scope(node) ->
    case node_scope() of
        #{kind := node} = Scope -> {ok, Scope};
        {error, _} = Error -> Error
    end;
resolve_scope({account, AeAccount}) ->
    {ok, account_scope(AeAccount)};
resolve_scope({wallet, AeAccount, WalletId}) ->
    {ok, wallet_scope(AeAccount, WalletId)};
resolve_scope({agent, AeAccount, AgentId}) ->
    {ok, agent_scope(AeAccount, AgentId)};
resolve_scope(#{kind := Kind, owner := Owner} = Scope0) ->
    Id = maps:get(id, Scope0, <<"default">>),
    case valid_scope_kind(Kind) of
        true ->
            {ok, canonical_scope(Kind, normalize_account(Owner), normalize_scope_kind_id(Kind, Id))};
        false ->
            {error, {invalid_context_scope_kind, Kind}}
    end;
resolve_scope(<<"ak_", _/binary>> = AeAccount) ->
    {ok, account_scope(AeAccount)};
resolve_scope(AeAccount) when is_list(AeAccount) ->
    resolve_scope(normalize_account(AeAccount));
resolve_scope(Other) ->
    {error, {invalid_context_scope, Other}}.

-spec scope_key(scope()) -> {scope_kind(), binary(), binary()}.
scope_key(#{kind := Kind, owner := Owner, id := Id}) ->
    {Kind, Owner, Id}.

-spec namespace(scope() | term()) -> binary().
namespace(Scope0) ->
    case resolve_scope(Scope0) of
        {ok, #{kind := node}} -> <<"node">>;
        {ok, #{kind := account}} -> <<"account">>;
        {ok, #{kind := wallet, id := Id}} -> <<"wallet:", Id/binary>>;
        {ok, #{kind := agent, id := Id}} -> <<"agent:", Id/binary>>;
        {error, Reason} -> error(Reason)
    end.

canonical_scope(Kind, Owner, Id) ->
    #{kind => Kind, owner => Owner, id => Id}.

valid_scope_kind(node) -> true;
valid_scope_kind(account) -> true;
valid_scope_kind(wallet) -> true;
valid_scope_kind(agent) -> true;
valid_scope_kind(_) -> false.

node_account() ->
    try secrets:node_keypair() of
        #{public_key := PublicKey} -> {ok, normalize_account(PublicKey)};
        Error -> {error, {node_wallet_unavailable, Error}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Node wallet lookup failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            {error, {node_wallet_unavailable, Class, Reason}}
    end.

stable_scope_id(Value) ->
    %% Treat equivalent textual identifiers consistently across list, binary,
    %% atom and integer input forms before deriving the fixed storage ID.
    lower_hex(crypto:hash(sha256, normalize_binary(Value))).

normalize_scope_kind_id(node, _Id) ->
    <<"default">>;
normalize_scope_kind_id(account, _Id) ->
    <<"default">>;
normalize_scope_kind_id(wallet, Id) ->
    normalize_scope_id(Id);
normalize_scope_kind_id(agent, Id) ->
    normalize_scope_id(Id).

normalize_scope_id(Value0) ->
    Candidate = list_to_binary(
        string:lowercase(binary_to_list(normalize_binary(Value0)))
    ),
    case byte_size(Candidate) =:= 64 andalso is_lower_hex(Candidate) of
        true -> Candidate;
        false -> stable_scope_id(Value0)
    end.

is_lower_hex(<<>>) ->
    true;
is_lower_hex(<<C, Rest/binary>>) when
    (C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f)
->
    is_lower_hex(Rest);
is_lower_hex(_) ->
    false.
%%%===================================================================
%%% Public context API
%%%===================================================================

-spec ensure_scope(term()) -> {ok, map()} | {error, term()}.
ensure_scope(Scope0) ->
    with_scope(Scope0, fun damage_context_store:ensure_scope/1).

-spec get(term(), context_key()) -> {ok, term()} | not_found | {error, term()}.
get(Scope0, Key0) ->
    Key = normalize_context_key(Key0),
    case snapshot(Scope0) of
        {ok, #{entries := Entries}} ->
            case maps:find(Key, Entries) of
                {ok, #{value := Value}} -> {ok, Value};
                error -> not_found
            end;
        {error, _} = Error ->
            Error
    end.

-spec get_scope(term()) -> map().
get_scope(Scope0) ->
    case snapshot(Scope0) of
        {ok, #{entries := Entries}} ->
            entry_values(Entries);
        {error, Reason} ->
            ?LOG_ERROR("Failed to read context scope=~p reason=~p", [Scope0, Reason]),
            #{}
    end.

%% Compatibility: a raw account address means the account scope.
-spec get_context(binary() | list() | map() | undefined) -> map().
get_context(undefined) ->
    #{};
get_context(#{public_key := AeAccount} = ContextIn) ->
    maps:merge(get_context(AeAccount), ContextIn);
get_context(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    maybe_refresh_account_context(AeAccount, get_scope(account_scope(AeAccount))).

-spec get_entries(term()) -> {ok, map()} | {error, term()}.
get_entries(Scope0) ->
    case snapshot(Scope0) of
        {ok, #{entries := Entries}} -> {ok, Entries};
        {error, _} = Error -> Error
    end.

-spec snapshot(term()) -> {ok, map()} | {error, term()}.
snapshot(Scope0) ->
    with_scope(Scope0, fun damage_context_store:snapshot/1).

-spec public_snapshot(term()) -> {ok, map()} | {error, term()}.
public_snapshot(Scope0) ->
    case snapshot(Scope0) of
        {ok, #{entries := Entries} = Snapshot0} ->
            PublicEntries = maps:map(fun(_Key, Entry) -> public_entry(Entry) end, Entries),
            {ok, Snapshot0#{entries => PublicEntries}};
        {error, _} = Error ->
            Error
    end.

-spec public_effective_snapshot(binary() | list()) -> {ok, map()} | {error, term()}.
public_effective_snapshot(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    case effective_entries_and_proofs(AeAccount, []) of
        {ok, Entries, Proofs} ->
            PublicEntries = maps:map(fun(_Key, Entry) -> public_entry(Entry) end, Entries),
            {ok, #{
                schema_version => ?SCHEMA_VERSION,
                account => AeAccount,
                entries => PublicEntries,
                proofs => Proofs
            }};
        {error, _} = Error ->
            Error
    end.

-spec version(term()) -> non_neg_integer() | {error, term()}.
version(Scope0) ->
    case snapshot(Scope0) of
        {ok, #{version := Version}} -> Version;
        {error, _} = Error -> Error
    end.

-spec root(term()) -> binary() | {error, term()}.
root(Scope0) ->
    case snapshot(Scope0) of
        {ok, #{root := Root}} -> Root;
        {error, _} = Error -> Error
    end.

-spec put(term(), context_key(), term()) -> {ok, map()} | {error, term()}.
put(Scope0, Key, Value) ->
    put(Scope0, Key, Value, #{}).

-spec put(term(), context_key(), term(), map() | list() | atom()) ->
    {ok, map()} | {error, term()}.
put(Scope0, Key, Value, Meta) ->
    apply_changes(Scope0, #{
        set => #{Key => #{value => Value, meta => Meta}},
        delete => []
    }).

-spec delete(term(), context_key()) -> {ok, map()} | {error, term()}.
delete(Scope0, Key) ->
    apply_changes(Scope0, #{set => #{}, delete => [Key]}).

-spec clear(term()) -> {ok, map()} | {error, term()}.
clear(Scope0) ->
    with_scope(Scope0, fun damage_context_store:clear/1).

-spec apply_changes(term(), map()) -> {ok, map()} | {error, term()}.
apply_changes(Scope0, Changes) ->
    apply_changes(Scope0, Changes, undefined).

-spec apply_changes(term(), map(), undefined | non_neg_integer() | binary() | list()) ->
    {ok, map()} | {error, term()}.
apply_changes(Scope0, Changes0, ExpectedVersion0) ->
    case {resolve_scope(Scope0), normalize_expected_version(ExpectedVersion0)} of
        {{ok, Scope}, {ok, ExpectedVersion}} ->
            case normalize_changes(Scope, Changes0) of
                {ok, #{set := SetEntries, delete := DeleteKeys}} ->
                    damage_context_store:apply_changes(
                        Scope,
                        SetEntries,
                        DeleteKeys,
                        ExpectedVersion
                    );
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

%% Compatibility reload for account context.
load_context(undefined) ->
    ok;
load_context(AeAccount) ->
    case resolve_scope(account_scope(AeAccount)) of
        {ok, Scope} -> damage_context_store:reload(Scope);
        {error, _} = Error -> Error
    end.

with_scope(Scope0, Fun) when is_function(Fun, 1) ->
    case resolve_scope(Scope0) of
        {ok, Scope} -> Fun(Scope);
        {error, _} = Error -> Error
    end.

%%%===================================================================
%%% Mutation normalization and policy
%%%===================================================================

normalize_changes(Scope, Changes) when is_map(Changes) ->
    Set0 = map_get_any(Changes, [set, <<"set">>], #{}),
    Delete0 = map_get_any(Changes, [delete, <<"delete">>], []),
    case {normalize_set_entries(Scope, Set0), normalize_delete_keys(Delete0)} of
        {{ok, Set}, {ok, Delete}} -> {ok, #{set => Set, delete => Delete}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
normalize_changes(_Scope, _Changes) ->
    {error, invalid_changes}.

normalize_set_entries(Scope, Set0) when is_map(Set0) ->
    try
        Set = maps:fold(
            fun(Key0, Spec, Acc) ->
                Key = validate_context_key(Key0),
                {Value, Meta} = normalize_value_spec(Spec),
                Entry = normalize_entry(Scope, Key, Value, Meta),
                maps:put(Key, Entry, Acc)
            end,
            #{},
            Set0
        ),
        {ok, Set}
    catch
        throw:Reason ->
            {error, Reason};
        error:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Context entry normalization failed reason=~p stack=~p",
                [Reason, Stacktrace]
            ),
            {error, Reason}
    end;
normalize_set_entries(_Scope, _Set0) ->
    {error, invalid_set_map}.

normalize_value_spec(#{value := Value} = Spec) ->
    NestedMeta = map_get_any(Spec, [meta, <<"meta">>], #{}),
    {Value, merge_meta(Spec, NestedMeta)};
normalize_value_spec(#{<<"value">> := Value} = Spec) ->
    NestedMeta = map_get_any(Spec, [meta, <<"meta">>], #{}),
    {Value, merge_meta(Spec, NestedMeta)};
normalize_value_spec(Value) ->
    {Value, #{}}.

merge_meta(Spec, NestedMeta) when is_map(NestedMeta) ->
    maps:merge(Spec, NestedMeta);
merge_meta(Spec, _NestedMeta) ->
    Spec.

-spec normalize_entry(scope(), binary(), term(), map()) -> entry().
normalize_entry(#{kind := node}, Key, Value, Meta) ->
    Sensitive = meta_sensitive(Meta, Key),
    case Sensitive of
        true ->
            %% Node-private values are available only to trusted Erlang code.
            %% They are never inserted into user-authored Gherkin templates.
            #{
                value => Value,
                sensitive => true,
                exposure => step_only,
                inheritance => none,
                locked => true,
                updated_at => erlang:system_time(second)
            };
        false ->
            Exposure = normalize_exposure(
                map_get_any(Meta, [exposure, <<"exposure">>], undefined),
                node,
                false
            ),
            Inheritance0 = map_get_any(
                Meta,
                [inheritance, <<"inheritance">>, inherit, <<"inherit">>],
                undefined
            ),
            Locked0 = meta_bool(Meta, [locked, <<"locked">>], false),
            Inheritance = normalize_inheritance(Inheritance0, Locked0, node, false),
            #{
                value => Value,
                sensitive => false,
                exposure => Exposure,
                inheritance => Inheritance,
                locked => Inheritance =:= locked,
                updated_at => erlang:system_time(second)
            }
    end;
normalize_entry(#{kind := Kind}, Key, Value, Meta) ->
    Sensitive = meta_sensitive(Meta, Key),
    Exposure = normalize_exposure(
        map_get_any(Meta, [exposure, <<"exposure">>], undefined),
        Kind,
        Sensitive
    ),
    #{
        value => Value,
        sensitive => Sensitive,
        exposure => Exposure,
        inheritance => none,
        locked => false,
        updated_at => erlang:system_time(second)
    }.

normalize_delete_keys(Keys) when is_list(Keys) ->
    try
        {ok, [validate_context_key(Key) || Key <- Keys]}
    catch
        throw:Reason ->
            {error, Reason};
        error:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Context delete normalization failed reason=~p stack=~p",
                [Reason, Stacktrace]
            ),
            {error, Reason}
    end;
normalize_delete_keys(undefined) ->
    {ok, []};
normalize_delete_keys(_) ->
    {error, invalid_delete_list}.

validate_context_key(Key0) ->
    Key = normalize_context_key(Key0),
    case byte_size(Key) of
        0 ->
            throw(empty_context_key);
        N when N > ?MAX_KEY_BYTES -> throw({context_key_too_long, N});
        _ ->
            case lists:member(normalize_key(Key), reserved_context_keys()) of
                true -> throw({reserved_context_key, Key});
                false -> Key
            end
    end.

normalize_exposure(undefined, node, true) ->
    step_only;
normalize_exposure(undefined, _Kind, _Sensitive) ->
    template;
normalize_exposure(template, _Kind, _Sensitive) ->
    template;
normalize_exposure(step_only, _Kind, _Sensitive) ->
    step_only;
normalize_exposure(Value, Kind, Sensitive) ->
    case normalize_key(Value) of
        <<"template">> -> template;
        <<"step_only">> -> step_only;
        <<"steponly">> -> step_only;
        _ -> normalize_exposure(undefined, Kind, Sensitive)
    end.

normalize_inheritance(_Value, _Locked, Kind, _Sensitive) when Kind =/= node -> none;
normalize_inheritance(_Value, true, node, _Sensitive) ->
    locked;
normalize_inheritance(undefined, false, node, true) ->
    none;
normalize_inheritance(undefined, false, node, false) ->
    default;
normalize_inheritance(default, false, node, _Sensitive) ->
    default;
normalize_inheritance(locked, _Locked, node, _Sensitive) ->
    locked;
normalize_inheritance(none, false, node, _Sensitive) ->
    none;
normalize_inheritance(Value, false, node, Sensitive) ->
    case normalize_key(Value) of
        <<"default">> -> default;
        <<"locked">> -> locked;
        <<"none">> -> none;
        _ -> normalize_inheritance(undefined, false, node, Sensitive)
    end.

meta_sensitive(masked, _Key) ->
    true;
meta_sensitive(sensitive, _Key) ->
    true;
meta_sensitive(Meta, Key) when is_list(Meta) ->
    lists:member(masked, Meta) orelse
        lists:member(sensitive, Meta) orelse
        is_sensitive_key(Key);
meta_sensitive(Meta, Key) when is_map(Meta) ->
    case
        map_get_any(
            Meta,
            [sensitive, <<"sensitive">>, masked, <<"masked">>, secret, <<"secret">>],
            undefined
        )
    of
        true -> true;
        <<"true">> -> true;
        "true" -> true;
        false -> false;
        <<"false">> -> false;
        "false" -> false;
        undefined -> is_sensitive_key(Key);
        _ -> is_sensitive_key(Key)
    end;
meta_sensitive(_, Key) ->
    is_sensitive_key(Key).

meta_bool(Meta, Keys, Default) when is_map(Meta) ->
    case map_get_any(Meta, Keys, Default) of
        true -> true;
        <<"true">> -> true;
        "true" -> true;
        false -> false;
        <<"false">> -> false;
        "false" -> false;
        _ -> Default
    end;
meta_bool(_Meta, _Keys, Default) ->
    Default.

normalize_expected_version(undefined) ->
    {ok, undefined};
normalize_expected_version(null) ->
    {ok, undefined};
normalize_expected_version(Value) when is_integer(Value), Value >= 0 -> {ok, Value};
normalize_expected_version(Value) when is_binary(Value); is_list(Value) ->
    try list_to_integer(binary_to_list(normalize_binary(Value))) of
        Integer when Integer >= 0 -> {ok, Integer};
        _ -> {error, invalid_expected_version}
    catch
        _:_ -> {error, invalid_expected_version}
    end;
normalize_expected_version(_) ->
    {error, invalid_expected_version}.

%%%===================================================================
%%% Effective execution context
%%%===================================================================

-spec effective_context(binary() | list() | undefined, map()) -> map().
effective_context(AeAccount, RuntimeContext) ->
    effective_context(AeAccount, RuntimeContext, []).

-spec effective_context(binary() | list() | undefined, map(), [term()]) -> map().
effective_context(undefined, RuntimeContext, AdditionalScopes) ->
    build_effective_context(undefined, RuntimeContext, AdditionalScopes);
effective_context(AeAccount0, RuntimeContext, AdditionalScopes) ->
    build_effective_context(normalize_account(AeAccount0), RuntimeContext, AdditionalScopes).

build_effective_context(AeAccount, RuntimeContext, AdditionalScopes0) ->
    AdditionalScopes = normalize_additional_scopes(AeAccount, AdditionalScopes0),
    Bundles0 = required_context_bundles(AeAccount, AdditionalScopes),
    {Bundles, AccountValues} = refresh_account_bundle_for_execution(AeAccount, Bundles0),
    NodeBundle = maps:get(node, Bundles),
    AccountBundle = maps:get(account, Bundles, undefined),
    AdditionalBundles = maps:get(additional, Bundles, []),

    Defaults = get_global_template_context(#{}),
    NodeEntries = bundle_entries(NodeBundle),
    NodeDefaultEntries = filter_node_entries(NodeEntries, default),
    NodeLockedEntries = filter_node_entries(NodeEntries, locked),
    AccountEntries0 = bundle_entries(AccountBundle),
    %AccountEntries = filter_template_entries(AccountEntries0),
    ExtraEntries = lists:foldl(
        fun(Bundle, Acc) ->
            maps:merge(Acc, filter_template_entries(bundle_entries(Bundle)))
        end,
        #{},
        AdditionalBundles
    ),
    NodeDefaults = entry_values(NodeDefaultEntries),
    NodeLocked = entry_values(NodeLockedEntries),
    ExtraValues = entry_values(ExtraEntries),
    ProtectedKeys = protected_runtime_keys(),
    RuntimeMutable = maps:without(ProtectedKeys, RuntimeContext),
    RuntimeProtected = maps:with(ProtectedKeys, RuntimeContext),

    Context0 = maps:merge(Defaults, NodeDefaults),
    Context1 = maps:merge(Context0, AccountValues),
    Context2 = maps:merge(Context1, ExtraValues),
    Context3 = maps:merge(Context2, RuntimeMutable),
    Context4 = maps:merge(Context3, NodeLocked),
    Context5 = maps:merge(Context4, RuntimeProtected),
    Proofs = proofs_from_bundles(Bundles),
    RedactionValues = frozen_redactions(
        NodeEntries,
        AccountEntries0,
        AccountValues,
        AdditionalBundles
    ),
    RedactionRef = register_frozen_redactions(RedactionValues),
    Context5#{
        damage_context_effective => ?EFFECTIVE_MARKER,
        account_context => AccountValues,
        node_context => maps:merge(NodeDefaults, NodeLocked),
        context_proofs => Proofs,
        context_redaction_ref => RedactionRef
    }.

-spec prepare_run_context(map()) -> map().
prepare_run_context(#{damage_context_effective := ?EFFECTIVE_MARKER} = Context) ->
    Context;
prepare_run_context(Context0) when is_map(Context0) ->
    Context = strip_internal_context_fields(Context0),
    AeAccount = context_account(Context),
    AdditionalScopes = maps:get(context_scopes, Context, []),
    effective_context(AeAccount, Context, AdditionalScopes).

-spec context_proofs(binary() | list() | undefined) -> map().
context_proofs(AeAccount0) ->
    context_proofs(AeAccount0, []).

context_proofs(AeAccount0, AdditionalScopes0) ->
    AeAccount =
        case AeAccount0 of
            undefined -> undefined;
            _ -> normalize_account(AeAccount0)
        end,
    AdditionalScopes = normalize_additional_scopes(AeAccount, AdditionalScopes0),
    try
        proofs_from_bundles(required_context_bundles(AeAccount, AdditionalScopes))
    catch
        error:{context_scope_unavailable, Scope, Reason} ->
            #{status => unavailable, scope => json_safe(Scope), error => json_safe(Reason)}
    end.

required_context_bundles(AeAccount, AdditionalScopes) ->
    NodeBundle = required_snapshot_bundle(node),
    AccountBundle =
        case AeAccount of
            undefined -> undefined;
            _ -> required_snapshot_bundle(account_scope(AeAccount))
        end,
    AdditionalBundles = [required_snapshot_bundle(Scope) || Scope <- AdditionalScopes],
    #{node => NodeBundle, account => AccountBundle, additional => AdditionalBundles}.

required_snapshot_bundle(Scope0) ->
    case resolve_scope(Scope0) of
        {ok, Scope} ->
            case damage_context_store:freeze_snapshot(Scope) of
                {ok, Snapshot} ->
                    #{scope => Scope, snapshot => Snapshot};
                {error, Reason} ->
                    error({context_scope_unavailable, scope_key(Scope), Reason})
            end;
        {error, Reason} ->
            error({context_scope_unavailable, Scope0, Reason})
    end.

refresh_account_bundle_for_execution(undefined, Bundles) ->
    {Bundles, #{}};
refresh_account_bundle_for_execution(AeAccount, Bundles) ->
    refresh_account_bundle_for_execution(AeAccount, Bundles, 1).

refresh_account_bundle_for_execution(AeAccount, Bundles, RetriesLeft) ->
    AccountBundle = maps:get(account, Bundles),
    Scope = maps:get(scope, AccountBundle),
    Snapshot = maps:get(snapshot, AccountBundle),
    Entries = maps:get(entries, Snapshot, #{}),
    StoredValues = entry_values(filter_template_entries(Entries)),
    RefreshedValues = maybe_refresh_account_context(AeAccount, StoredValues),
    SetEntries = refreshed_account_entries(Scope, Entries, RefreshedValues),
    case map_size(SetEntries) of
        0 ->
            {Bundles, StoredValues};
        _ ->
            Version = maps:get(version, Snapshot, 0),
            case damage_context_store:apply_changes(Scope, SetEntries, [], Version) of
                {ok, _Summary} ->
                    RefreshedBundle = required_snapshot_bundle(Scope),
                    RefreshedStoredValues = entry_values(
                        filter_template_entries(bundle_entries(RefreshedBundle))
                    ),
                    {maps:put(account, RefreshedBundle, Bundles), RefreshedStoredValues};
                {error, {version_conflict, _CurrentVersion}} when RetriesLeft > 0 ->
                    LatestBundle = required_snapshot_bundle(Scope),
                    refresh_account_bundle_for_execution(
                        AeAccount,
                        maps:put(account, LatestBundle, Bundles),
                        RetriesLeft - 1
                    );
                {error, Reason} ->
                    error({
                        context_scope_unavailable,
                        scope_key(Scope),
                        {account_context_refresh_persist_failed, Reason}
                    })
            end
    end.

refreshed_account_entries(Scope, Entries, RefreshedValues) ->
    maps:fold(
        fun(Key0, Value, Acc) ->
            Key = normalize_context_key(Key0),
            case maps:find(Key, Entries) of
                {ok, Entry} ->
                    case maps:get(value, Entry, undefined) =:= Value of
                        true -> Acc;
                        false ->
                            maps:put(
                                Key,
                                Entry#{value => Value, updated_at => erlang:system_time(second)},
                                Acc
                            )
                    end;
                error ->
                    maps:put(Key, normalize_entry(Scope, Key, Value, #{}), Acc)
            end
        end,
        #{},
        RefreshedValues
    ).

bundle_entries(undefined) ->
    #{};
bundle_entries(#{snapshot := Snapshot}) ->
    maps:get(entries, Snapshot, #{}).

proofs_from_bundles(#{node := NodeBundle} = Bundles) ->
    NodeProof = proof_from_bundle(NodeBundle),
    Base =
        case maps:get(account, Bundles, undefined) of
            undefined -> #{node => NodeProof};
            AccountBundle -> #{node => NodeProof, account => proof_from_bundle(AccountBundle)}
        end,
    AdditionalProofs = maps:from_list([
        {namespace(maps:get(scope, Bundle)), proof_from_bundle(Bundle)}
     || Bundle <- maps:get(additional, Bundles, [])
    ]),
    case map_size(AdditionalProofs) of
        0 -> Base;
        _ -> Base#{additional => AdditionalProofs}
    end.

proof_from_bundle(#{scope := Scope, snapshot := Snapshot}) ->
    proof_from_snapshot(Scope, Snapshot).

proof_from_snapshot(Scope, Snapshot) ->
    #{
        status => available,
        kind => maps:get(kind, Scope),
        owner => maps:get(owner, Scope),
        id => maps:get(id, Scope),
        namespace => namespace(Scope),
        version => maps:get(version, Snapshot, 0),
        root => maps:get(root, Snapshot, <<>>),
        updated_at => maps:get(updated_at, Snapshot, 0)
    }.

frozen_redactions(NodeEntries, AccountEntries, AccountValues, AdditionalBundles) ->
    Values0 = sensitive_entry_values(NodeEntries, #{}),
    Values1 = sensitive_entry_values(AccountEntries, AccountValues) ++ Values0,
    Values2 = lists:foldl(
        fun(Bundle, Acc) ->
            sensitive_entry_values(bundle_entries(Bundle), #{}) ++ Acc
        end,
        Values1,
        AdditionalBundles
    ),
    lists:usort([Value || Value <- Values2, redaction_value_present(Value)]).

sensitive_entry_values(Entries, MaterializedValues) ->
    maps:fold(
        fun(Key, Entry, Acc) ->
            case maps:get(sensitive, Entry, false) of
                true ->
                    StoredValue = maps:get(value, Entry, undefined),
                    MaterializedValue = maps:get(Key, MaterializedValues, StoredValue),
                    [StoredValue, MaterializedValue | Acc];
                false ->
                    Acc
            end
        end,
        [],
        Entries
    ).

redaction_value_present(undefined) -> false;
redaction_value_present(none) -> false;
redaction_value_present(null) -> false;
redaction_value_present(<<>>) -> false;
redaction_value_present([]) -> false;
redaction_value_present(_) -> true.

register_frozen_redactions([]) ->
    none;
register_frozen_redactions(Values) ->
    case damage_context_store:register_redactions(Values) of
        {ok, Token} -> Token;
        {error, Reason} ->
            error({context_scope_unavailable, context_redactions, Reason})
    end.

-spec write_run_proof(string() | binary(), map()) -> ok | {error, term()}.
write_run_proof(
    RunDir,
    #{damage_context_effective := ?EFFECTIVE_MARKER, context_proofs := Proofs}
) when is_map(Proofs) ->
    case first_unavailable_proof(Proofs) of
        none ->
            case attach_proof_witnesses(Proofs) of
                {ok, WitnessedProofs} ->
                    Proof = #{
                        schema_version => 3,
                        captured_at => erlang:system_time(second),
                        publication => #{
                            type => <<"ipfs_report">>,
                            separate_context_contract => false
                        },
                        contexts => WitnessedProofs
                    },
                    write_run_proof_file(RunDir, Proof);
                {error, _} = Error ->
                    Error
            end;
        {unavailable, Reason} ->
            {error, {context_proof_unavailable, Reason}}
    end;
write_run_proof(_RunDir, _Context) ->
    {error, context_not_prepared}.


-spec publish_run_proof(string() | binary(), map()) -> {ok, map()} | {error, term()}.
publish_run_proof(RunDir, Context) ->
    case write_run_proof(RunDir, Context) of
        ok ->
            %% ipfs:add/3 constructs query and multipart fields as binaries.
            %% Keep the filesystem path binary at that API boundary.
            Path = normalize_binary(run_proof_path(RunDir)),
            case safe_add_context_proof(Path) of
                {ok, HashList} ->
                    case context_proof_cid(HashList, Path) of
                        {ok, Cid} ->
                            {ok, #{
                                hash => Cid,
                                cid => Cid,
                                uri => <<"ipfs://", Cid/binary>>,
                                url => context_ipfs_url(Cid),
                                file => <<"context_proof.json">>
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, Reason} ->
                    {error, {context_ipfs_add_failed, Reason}};
                Other ->
                    {error, {unexpected_context_ipfs_add_result, Other}}
            end;
        {error, _} = Error ->
            Error
    end.

safe_add_context_proof(Path) when is_binary(Path) ->
    try damage_ipfs:add({file, Path}) of
        Result ->
            Result
    catch
        exit:Reason ->
            {error, {context_ipfs_add_exit, Reason}};
        Class:Reason:Stacktrace ->
            {error, {context_ipfs_add_crashed, Class, Reason, Stacktrace}}
    end.

run_proof_path(RunDir) ->
    filename:join(normalize_path(RunDir), "context_proof.json").

context_proof_cid(HashList, Path) when is_list(HashList) ->
    ExpectedName = normalize_binary(filename:basename(normalize_path(Path))),
    Named = [
        normalize_binary(Cid)
     || Item <- HashList,
        Cid <- [map_get_any(Item, [<<"Hash">>, "Hash", hash, <<"hash">>], undefined)],
        Name <- [map_get_any(Item, [<<"Name">>, "Name", name, <<"name">>], undefined)],
        Cid =/= undefined,
        Name =/= undefined,
        normalize_binary(filename:basename(normalize_path(Name))) =:= ExpectedName
    ],
    case Named of
        [Cid | _] ->
            {ok, Cid};
        [] ->
            Cids = [
                normalize_binary(Cid)
             || Item <- HashList,
                Cid <- [map_get_any(Item, [<<"Hash">>, "Hash", hash, <<"hash">>], undefined)],
                Cid =/= undefined
            ],
            case lists:reverse(Cids) of
                [Cid | _] -> {ok, Cid};
                [] -> {error, {context_ipfs_hash_not_found, HashList}}
            end
    end;
context_proof_cid(Other, _Path) ->
    {error, {invalid_context_ipfs_add_result, Other}}.

context_ipfs_url(Cid) ->
    case configured_context_ipfs_gateway() of
        undefined ->
            <<"ipfs://", Cid/binary>>;
        Gateway ->
            append_cid_to_gateway(Gateway, Cid)
    end.

configured_context_ipfs_gateway() ->
    configured_context_ipfs_gateway([
        context_ipfs_gateway_url,
        ipfs_gateway_url,
        context_ipfs_gateway
    ]).

configured_context_ipfs_gateway([Key | Rest]) ->
    case application:get_env(damage, Key) of
        {ok, Value} when is_binary(Value); is_list(Value) ->
            case normalize_binary(Value) of
                <<>> -> configured_context_ipfs_gateway(Rest);
                Gateway -> Gateway
            end;
        _ ->
            configured_context_ipfs_gateway(Rest)
    end;
configured_context_ipfs_gateway([]) ->
    undefined.

append_cid_to_gateway(Gateway0, Cid) ->
    Gateway = trim_trailing_slashes(normalize_binary(Gateway0)),
    case binary:match(Gateway, <<"{cid}">>) of
        nomatch -> <<Gateway/binary, "/", Cid/binary>>;
        _ -> binary:replace(Gateway, <<"{cid}">>, Cid, [global])
    end.

trim_trailing_slashes(Value) when is_binary(Value) ->
    unicode:characters_to_binary(
        string:trim(binary_to_list(Value), trailing, "/")
    ).

normalize_path(Value) when is_binary(Value) -> binary_to_list(Value);
normalize_path(Value) when is_list(Value) -> Value;
normalize_path(Value) -> binary_to_list(normalize_binary(Value)).

attach_proof_witnesses(#{
    status := available,
    kind := Kind,
    owner := Owner,
    id := Id,
    version := Version,
    root := Root
} = Proof) ->
    Scope = canonical_scope(Kind, normalize_account(Owner), Id),
    case damage_context_store:witness(Scope, Version, Root) of
        {ok, Witness} -> {ok, Proof#{witness => Witness}};
        {error, Reason} ->
            {error, {context_snapshot_witness_unavailable, scope_key(Scope), Reason}}
    end;
attach_proof_witnesses(Map) when is_map(Map) ->
    maps:fold(
        fun(Key, Value, {ok, Acc}) ->
            case attach_proof_witnesses(Value) of
                {ok, WitnessedValue} -> {ok, maps:put(Key, WitnessedValue, Acc)};
                {error, _} = Error -> Error
            end;
           (_Key, _Value, {error, _} = Error) ->
                Error
        end,
        {ok, #{}},
        Map
    );
attach_proof_witnesses(List) when is_list(List) ->
    attach_proof_witness_list(List, []);
attach_proof_witnesses(Value) ->
    {ok, Value}.

attach_proof_witness_list([Value | Rest], Acc) ->
    case attach_proof_witnesses(Value) of
        {ok, WitnessedValue} -> attach_proof_witness_list(Rest, [WitnessedValue | Acc]);
        {error, _} = Error -> Error
    end;
attach_proof_witness_list([], Acc) ->
    {ok, lists:reverse(Acc)}.

write_run_proof_file(RunDir, Proof) ->
    Path = run_proof_path(RunDir),
    try jsx:encode(json_safe(Proof)) of
        Encoded ->
            case filelib:ensure_dir(Path) of
                ok -> file:write_file(Path, Encoded);
                {error, Reason} -> {error, {context_proof_dir_failed, Reason}}
            end
    catch
        Class:Reason:Stacktrace ->
            {error, {context_proof_encode_failed, Class, Reason, Stacktrace}}
    end.

first_unavailable_proof(#{status := unavailable} = Proof) ->
    {unavailable, maps:get(error, Proof, unavailable)};
first_unavailable_proof(Map) when is_map(Map) ->
    first_unavailable_proof_values(maps:values(Map));
first_unavailable_proof(_Other) ->
    none.

first_unavailable_proof_values([Value | Rest]) ->
    case first_unavailable_proof(Value) of
        none -> first_unavailable_proof_values(Rest);
        Unavailable -> Unavailable
    end;
first_unavailable_proof_values([]) ->
    none.

effective_entries_and_proofs(AeAccount, AdditionalScopes0) ->
    AdditionalScopes = normalize_additional_scopes(AeAccount, AdditionalScopes0),
    try
        Bundles = required_context_bundles(AeAccount, AdditionalScopes),
        NodeEntries = bundle_entries(maps:get(node, Bundles)),
        Defaults = filter_node_entries(NodeEntries, default),
        Locked = filter_node_entries(NodeEntries, locked),
        AccountEntries = filter_template_entries(
            bundle_entries(maps:get(account, Bundles, undefined))
        ),
        ExtraEntries = lists:foldl(
            fun(Bundle, Acc) ->
                maps:merge(Acc, filter_template_entries(bundle_entries(Bundle)))
            end,
            #{},
            maps:get(additional, Bundles, [])
        ),
        Entries = maps:merge(
            maps:merge(maps:merge(Defaults, AccountEntries), ExtraEntries),
            Locked
        ),
        {ok, Entries, proofs_from_bundles(Bundles)}
    catch
        error:{context_scope_unavailable, Scope, Reason} ->
            {error, {context_scope_unavailable, Scope, Reason}}
    end.


filter_node_entries(Entries, Inheritance) ->
    maps:filter(
        fun(_Key, Entry) ->
            maps:get(exposure, Entry, step_only) =:= template andalso
                maps:get(inheritance, Entry, none) =:= Inheritance andalso
                node_template_sensitivity_allowed(Entry)
        end,
        Entries
    ).

filter_template_entries(Entries) ->
    maps:filter(
        fun(_Key, Entry) -> maps:get(exposure, Entry, template) =:= template end,
        Entries
    ).

node_template_sensitivity_allowed(#{sensitive := true}) ->
    false;
node_template_sensitivity_allowed(_Entry) ->
    true.

normalize_additional_scopes(_AeAccount, []) ->
    [];
normalize_additional_scopes(AeAccount, Scopes) when is_list(Scopes) ->
    lists:reverse(
        lists:foldl(
            fun(Scope0, Acc) ->
                case resolve_scope(Scope0) of
                    {ok, #{kind := Kind, owner := Owner} = Scope} when
                        Kind =/= node, Owner =:= AeAccount
                    ->
                        [Scope | Acc];
                    {ok, _OtherScope} ->
                        Acc;
                    {error, _} ->
                        Acc
                end
            end,
            [],
            Scopes
        )
    );
normalize_additional_scopes(_AeAccount, _Other) ->
    [].

entry_values(Entries) ->
    maps:map(fun(_Key, Entry) -> maps:get(value, Entry) end, Entries).
maybe_refresh_account_context(undefined, Values) ->
    Values;
maybe_refresh_account_context(AeAccount, Values) when is_map(Values) ->
    case custodial_account_keypair(AeAccount) of
        {ok, KeyPair} ->
            case code:ensure_loaded(damage_access_token) of
                {module, damage_access_token} ->
                    case erlang:function_exported(damage_access_token, maybe_refresh, 2) of
                        true ->
                            try damage_access_token:maybe_refresh(Values, KeyPair) of
                                Refreshed when is_map(Refreshed) -> Refreshed;
                                _ -> Values
                            catch
                                Class:Reason:Stacktrace ->
                                    ?LOG_WARNING(
                                        "Account context token refresh failed account=~p class=~p reason=~p stack=~p",
                                        [AeAccount, Class, Reason, Stacktrace]
                                    ),
                                    Values
                            end;
                        false ->
                            Values
                    end;
                _ ->
                    Values
            end;
        {error, _} ->
            Values
    end.

custodial_account_keypair(AeAccount) ->
    try identity_server:get_account(AeAccount) of
        #{public_key := PublicKey, private_key := PrivateKey} when is_binary(PrivateKey) ->
            {ok, #{
                public_key => normalize_account(PublicKey),
                private_key => PrivateKey
            }};
        Other ->
            {error, {no_custodial_keypair, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Account key lookup failed account=~p class=~p reason=~p stack=~p",
                [AeAccount, Class, Reason, Stacktrace]
            ),
            {error, {account_key_lookup_failed, Class, Reason}}
    end.


public_entry(#{sensitive := true} = Entry) ->
    Entry#{value => ?REDACTED_TEXT_MARKER};
public_entry(Entry) ->
    Entry.

strip_internal_context_fields(Context) ->
    maps:without(internal_context_keys(), Context).

internal_context_keys() ->
    Atoms = [
        damage_context_effective,
        context_redactions,
        context_redaction_ref,
        context_proofs,
        context_ipfs_hash,
        context_ipfs_uri,
        context_ipfs_url,
        account_context,
        node_context
    ],
    Atoms ++ [atom_to_binary(Key, utf8) || Key <- Atoms].

context_account(Context) ->
    case Context of
        #{public_key := AeAccount} -> normalize_account(AeAccount);
        #{address := AeAccount} -> normalize_account(AeAccount);
        _ -> undefined
    end.

protected_runtime_keys() ->
    Atoms = [
        public_key,
        address,
        private_key,
        node_public_key,
        access_token,
        auth_type,
        username,
        token_contract,
        formatter_state,
        run_id,
        run_dir,
        feature_hash,
        report_hash,
        context_ipfs_hash,
        context_ipfs_uri,
        context_ipfs_url,
        context_proofs,
        context_redactions,
        context_redaction_ref,
        damage_context_effective,
        context_scopes,
        proxy
    ],
    Atoms ++ [atom_to_binary(Key, utf8) || Key <- Atoms].

reserved_context_keys() ->
    lists:usort(
        [normalize_key(Key) || Key <- protected_runtime_keys()] ++
            [<<"account_context">>, <<"node_context">>]
    ).


%%%===================================================================
%%% Compatibility wrappers
%%%===================================================================

get_context_proc(_AeAccount) ->
    case ensure_started() of
        ok -> whereis(damage_context_store);
        {error, Reason} -> error({damage_context_start_failed, Reason})
    end.

restart_context_proc(AeAccount) ->
    ok = load_context(AeAccount),
    get_context_proc(AeAccount).

add_context(AeAccount, Key, Value) ->
    put(account_scope(AeAccount), Key, Value).

add_context(AeAccount, Key, Value, masked) ->
    put(account_scope(AeAccount), Key, Value, #{sensitive => true});
add_context(AeAccount, Key, Value, Meta) ->
    put(account_scope(AeAccount), Key, Value, Meta).

%% Legacy names now target the encrypted off-chain account scope.
contract_add_context(AeAccount, Key, Value, Meta) ->
    add_context(AeAccount, Key, Value, Meta).

contract_delete_context(AeAccount, Key) ->
    delete(account_scope(AeAccount), Key).

contract_get_context(AeAccount) ->
    public_snapshot(account_scope(AeAccount)).

%%%===================================================================
%%% Cowboy REST API
%%%===================================================================

trails() ->
    [
        context_trail("/context", account_context),
        trails:trail(
            "/context/effective",
            damage_context,
            #{action => account_effective},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Get the effective account context after node inheritance.",
                    produces => ["application/json"]
                }
            }
        ),
        context_trail("/node/context", node_context)
    ].

context_trail(Path, Action) ->
    trails:trail(
        Path,
        damage_context,
        #{action => Action},
        #{
            get => #{
                tags => ?TRAILS_TAG,
                description => "Get a scoped context. Sensitive values are redacted.",
                produces => ["application/json"]
            },
            post => #{
                tags => ?TRAILS_TAG,
                description => "Set one value or apply an atomic context change set.",
                produces => ["application/json"]
            },
            patch => #{
                tags => ?TRAILS_TAG,
                description => "Apply an atomic versioned context change set.",
                produces => ["application/json"]
            },
            delete => #{
                tags => ?TRAILS_TAG,
                description => "Delete a context value using the key query parameter.",
                produces => ["application/json"],
                parameters => [
                    #{
                        name => <<"key">>,
                        in => <<"query">>,
                        required => true,
                        type => <<"string">>
                    }
                ]
            }
        }
    ).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

is_authorized(Req, State0) ->
    case damage_http:is_authorized(Req, State0) of
        {true, Req1, State1} ->
            case is_node_action(maps:get(action, State1, undefined)) of
                false ->
                    {true, Req1, State1};
                true ->
                    case maps:get(public_key, State1, undefined) of
                        undefined ->
                            {{false, ?AUTH_HEADER}, Req1, State1};
                        Authenticated ->
                            case is_node_admin(Authenticated) of
                                true -> {true, Req1, State1};
                                false -> {{false, ?AUTH_HEADER}, Req1, State1}
                            end
                    end
            end;
        Other ->
            Other
    end.

is_node_action(node_context) -> true;
is_node_action(_) -> false.

-spec is_node_admin(term()) -> boolean().
is_node_admin(AeAccount0) ->
    AeAccount = normalize_account(AeAccount0),
    case application:get_env(damage, node_admins, []) of
        Admins when is_list(Admins) ->
            lists:any(
                fun(Admin) -> normalize_account(Admin) =:= AeAccount end,
                Admins
            );
        Invalid ->
            ?LOG_ERROR("Invalid node_admins application env value: ~p", [Invalid]),
            false
    end.

allowed_methods(Req, #{action := account_effective} = State) ->
    {[<<"GET">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PATCH">>, <<"DELETE">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

from_html(Req, State) ->
    from_json(Req, State).

to_json(Req, #{action := account_effective, public_key := AeAccount} = State) ->
    case public_effective_snapshot(AeAccount) of
        {ok, Snapshot0} ->
            Body = maps:merge(#{status => ok}, Snapshot0),
            {jsx:encode(json_safe(Body)), set_no_store(Req), State};
        {error, Reason} ->
            reply_json_stop(
                503,
                #{
                    status => error,
                    error => <<"CONTEXT_EFFECTIVE_UNAVAILABLE">>,
                    reason => Reason
                },
                Req,
                State
            )
    end;
to_json(Req, State) ->
    case scope_from_state(State) of
        {ok, Scope} ->
            case public_snapshot(Scope) of
                {ok, Snapshot0} ->
                    Body = maps:merge(#{status => ok}, snapshot_json(Snapshot0)),
                    {jsx:encode(json_safe(Body)), set_no_store(Req), State};
                {error, Reason} ->
                    reply_json_stop(
                        503,
                        #{
                            status => error,
                            error => <<"CONTEXT_STORE_UNAVAILABLE">>,
                            reason => Reason
                        },
                        Req,
                        State
                    )
            end;
        {error, Reason} ->
            reply_json_stop(
                400,
                #{status => error, error => <<"INVALID_CONTEXT_SCOPE">>, reason => Reason},
                Req,
                State
            )
    end.

from_json(Req0, State) ->
    case scope_from_state(State) of
        {ok, Scope} -> handle_context_mutation(Scope, Req0, State);
        {error, Reason} -> reply_json_stop(400, #{status => error, error => Reason}, Req0, State)
    end.


handle_context_mutation(Scope, Req0, State) ->
    case read_json_body(Req0) of
        {ok, Json, Req} ->
            case api_changes(Json) of
                {ok, Changes, ExpectedVersion} ->
                    case apply_changes(Scope, Changes, ExpectedVersion) of
                        {ok, Summary} ->
                            reply_json_stop(200, #{status => ok, context => Summary}, Req, State);
                        {error, {version_conflict, CurrentVersion}} ->
                            reply_json_stop(
                                409,
                                #{
                                    status => error,
                                    error => <<"VERSION_CONFLICT">>,
                                    current_version => CurrentVersion
                                },
                                Req,
                                State
                            );
                        {error, {context_too_large, Size, Max}} ->
                            reply_json_stop(
                                413,
                                #{
                                    status => error,
                                    error => <<"CONTEXT_TOO_LARGE">>,
                                    size => Size,
                                    max_size => Max
                                },
                                Req,
                                State
                            );
                        {error, Reason} ->
                            reply_json_stop(422, #{status => error, error => Reason}, Req, State)
                    end;
                {error, Reason} ->
                    reply_json_stop(400, #{status => error, error => Reason}, Req, State)
            end;
        {error, body_too_large, Req} ->
            reply_json_stop(
                413, #{status => error, error => <<"REQUEST_BODY_TOO_LARGE">>}, Req, State
            );
        {error, Reason, Req} ->
            reply_json_stop(400, #{status => error, error => Reason}, Req, State)
    end.

delete_resource(Req0, State) ->
    case {scope_from_state(State), cowboy_req:match_qs([key], Req0)} of
        {{ok, Scope}, #{key := Key}} when Key =/= undefined ->
            case delete(Scope, Key) of
                {ok, Summary} ->
                    reply_json_stop(200, #{status => ok, context => Summary}, Req0, State);
                {error, Reason} ->
                    reply_json_stop(422, #{status => error, error => Reason}, Req0, State)
            end;
        {{error, Reason}, _} ->
            reply_json_stop(400, #{status => error, error => Reason}, Req0, State);
        _ ->
            reply_json_stop(
                400,
                #{status => error, error => <<"KEY_REQUIRED">>},
                Req0,
                State
            )
    end.

scope_from_state(#{action := node_context}) ->
    resolve_scope(node);
scope_from_state(#{public_key := AeAccount}) ->
    resolve_scope(account_scope(AeAccount));
scope_from_state(State) ->
    {error, {context_owner_missing, maps:get(action, State, undefined)}}.

api_changes(#{<<"key">> := Key, <<"value">> := Value} = Json) ->
    Expected = map_get_any(Json, [<<"expected_version">>, <<"version">>], undefined),
    Meta = maps:without([<<"key">>, <<"value">>, <<"expected_version">>, <<"version">>], Json),
    {ok, #{set => #{Key => #{value => Value, meta => Meta}}, delete => []}, Expected};
api_changes(Json) when is_map(Json) ->
    Set = maps:get(<<"set">>, Json, #{}),
    Delete = maps:get(<<"delete">>, Json, []),
    Expected = maps:get(<<"expected_version">>, Json, undefined),
    {ok, #{set => Set, delete => Delete}, Expected};
api_changes(_) ->
    {error, <<"INVALID_CONTEXT_REQUEST">>}.

read_json_body(Req0) ->
    Max = env_pos_int(context_max_request_bytes, ?DEFAULT_MAX_REQUEST_BYTES),
    read_json_body(Req0, <<>>, Max).

read_json_body(Req0, Acc, Max) ->
    case cowboy_req:read_body(Req0, #{length => erlang:min(Max + 1, 65536), period => 5000}) of
        {ok, Data, Req} ->
            Body = <<Acc/binary, Data/binary>>,
            case byte_size(Body) =< Max of
                false -> {error, body_too_large, Req};
                true -> decode_json(Body, Req)
            end;
        {more, Data, Req} ->
            Body = <<Acc/binary, Data/binary>>,
            case byte_size(Body) =< Max of
                false -> {error, body_too_large, Req};
                true -> read_json_body(Req, Body, Max)
            end
    end.

decode_json(<<>>, Req) ->
    {ok, #{}, Req};
decode_json(Body, Req) ->
    try jsx:decode(Body, [return_maps]) of
        Json when is_map(Json) -> {ok, Json, Req};
        _ -> {error, <<"JSON_OBJECT_REQUIRED">>, Req}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Context JSON decode failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            {error, <<"INVALID_JSON">>, Req}
    end.


reply_json_stop(Status, Body0, Req0, State) ->
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"private, no-store">>
        },
        jsx:encode(json_safe(Body0)),
        Req0
    ),
    {stop, Req, State}.

set_no_store(Req) ->
    cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req).

snapshot_json(#{
    schema_version := SchemaVersion,
    scope := Scope,
    version := Version,
    root := Root,
    updated_at := UpdatedAt,
    entries := Entries
}) ->
    #{
        schema_version => SchemaVersion,
        scope => Scope#{namespace => namespace(Scope)},
        version => Version,
        root => Root,
        updated_at => UpdatedAt,
        entries => Entries
    }.

%%%===================================================================
%%% Runner context and rendering helpers
%%%===================================================================

get_global_template_context(Context) ->
    DamageApi =
        case application:get_env(damage, api_url) of
            {ok, Value} -> Value;
            _ -> <<>>
        end,
    Context0 = maps:merge(
        #{
            api_url => DamageApi,
            formatter_state => #damage_state{},
            headers => [],
            token_contract => list_to_binary(?DAMAGE_TOKEN_CONTRACT),
            timestamp => date_util:now_to_seconds_hires(os:timestamp()),
            proxy => {socks5, "127.0.0.1", 9050}
        },
        Context
    ),
    case node_account() of
        {ok, NodePublicKey} -> maps:put(node_public_key, NodePublicKey, Context0);
        {error, _} -> Context0
    end.

get_stepargs(Body) when is_list(Body) ->
    case lists:keytake(<<"\"\"\"">>, 1, Body) of
        {value, {<<"\"\"\"">>, Doc}, Body0} ->
            {
                damage_utils:binarystr_join(Body0, <<" ">>),
                damage_utils:binarystr_join(Doc)
            };
        _ ->
            {damage_utils:binarystr_join(Body, <<" ">>), <<>>}
    end.

render_body_args(Body, Context) when is_map(Context) ->
    {Body0, Args} = get_stepargs(Body),
    try
        Body1 = damage_utils:tokenize(damage_utils:render(Body0, Context)),
        case Args of
            <<>> -> {ok, {Body1, Args}};
            _ -> {ok, {Body1, damage_utils:render(Args, Context)}}
        end
    catch
        error:{unbound_var, Fail}:Stacktrace ->
            ?LOG_ERROR("unbound_var ~p stack=~p", [Fail, Stacktrace]),
            {error, {Body0, Args}, {unbound_var, Fail}};
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "render error class=~p reason=~p body=~p stack=~p",
                [Class, Reason, Body0, Stacktrace]
            ),
            {error, {Body0, Args}, {render, Class, Reason}}
    end.

%%%===================================================================
%%% Secret redaction
%%%===================================================================

clean_secrets(
    #{
        damage_context_effective := ?EFFECTIVE_MARKER,
        context_redaction_ref := RedactionRef
    } = Context0,
    Body,
    Args
) when is_binary(RedactionRef) ->
    Context = damage_utils:normalize_context(Context0),
    {Body0, Args0} = redact_known_sensitive_values(Context, Body, Args),
    case damage_context_store:redactions(RedactionRef) of
        {ok, Redactions} ->
            {Body1, Args1} = redact_frozen_values(Redactions, Body0, Args0),
            %% Frozen values protect the exact run snapshot. Current values are
            %% also redacted for trusted steps that intentionally read a live
            %% step-only secret after context preparation.
            redact_current_scope_entries(Context0, Body1, Args1);
        {error, Reason} ->
            %% Never emit an unredacted step when the frozen redaction set is
            %% unavailable. The execution result remains intact; only formatter
            %% output is replaced with a fail-closed marker.
            ?LOG_ERROR("Frozen context redactions unavailable: ~p", [Reason]),
            {?REDACTED_TEXT_MARKER, ?REDACTED_TEXT_MARKER}
    end;
clean_secrets(
    #{
        damage_context_effective := ?EFFECTIVE_MARKER,
        context_redaction_ref := none
    } = Context0,
    Body,
    Args
) ->
    Context = damage_utils:normalize_context(Context0),
    {Body0, Args0} = redact_known_sensitive_values(Context, Body, Args),
    redact_current_scope_entries(Context0, Body0, Args0);
clean_secrets(#{public_key := _AeAccount} = Context0, Body, Args) ->
    %% Compatibility path for callers that have not prepared an immutable run
    %% context yet.
    Context = damage_utils:normalize_context(Context0),
    {Body0, Args0} = redact_known_sensitive_values(Context, Body, Args),
    redact_current_scope_entries(Context0, Body0, Args0);
clean_secrets(Context0, Body, Args) ->
    Context = damage_utils:normalize_context(Context0),
    redact_known_sensitive_values(Context, Body, Args).

redact_frozen_values([Value | Rest], Body0, Args0) ->
    {Body, Args} = redact_value(Value, Body0, Args0),
    redact_frozen_values(Rest, Body, Args);
redact_frozen_values([], Body, Args) ->
    {Body, Args}.

redact_current_scope_entries(#{public_key := AeAccount} = Context, Body0, Args0) ->
    {Body1, Args1} = redact_scope_entries(account_scope(AeAccount), Body0, Args0),
    {Body2, Args2} = redact_scope_entries(node, Body1, Args1),
    AdditionalScopes = maps:get(context_scopes, Context, []),
    lists:foldl(
        fun(Scope, {BodyAcc, ArgsAcc}) -> redact_scope_entries(Scope, BodyAcc, ArgsAcc) end,
        {Body2, Args2},
        AdditionalScopes
    );
redact_current_scope_entries(_Context, Body, Args) ->
    {Body, Args}.

redact_scope_entries(Scope, Body, Args) ->
    case get_entries(Scope) of
        {ok, Entries} -> clean_context_secrets(Entries, Body, Args);
        {error, _} -> {Body, Args}
    end.

clean_context_secrets(Entries, Body, Args) when is_map(Entries) ->
    maps:fold(
        fun(_Key, Entry, {Body1, Args1}) ->
            case Entry of
                #{value := SecretValue, sensitive := true} ->
                    redact_value(SecretValue, Body1, Args1);
                _ ->
                    {Body1, Args1}
            end
        end,
        {Body, Args},
        Entries
    );
clean_context_secrets(_Entries, Body, Args) ->
    {Body, Args}.

redact_known_sensitive_values(Context, Body, Args) ->
    maps:fold(
        fun(Key, Value, {Body1, Args1}) ->
            case is_sensitive_key(Key) of
                true -> redact_value(Value, Body1, Args1);
                false when is_map(Value) -> clean_nested_sensitive(Value, Body1, Args1);
                false -> {Body1, Args1}
            end
        end,
        {Body, Args},
        Context
    ).

clean_nested_sensitive(Value, Body, Args) when is_map(Value) ->
    maps:fold(
        fun(Key, InnerValue, {Body1, Args1}) ->
            case {is_sensitive_key(Key), InnerValue} of
                {true, _} -> redact_value(InnerValue, Body1, Args1);
                {false, Map} when is_map(Map) -> clean_nested_sensitive(Map, Body1, Args1);
                _ -> {Body1, Args1}
            end
        end,
        {Body, Args},
        Value
    );
clean_nested_sensitive(_Value, Body, Args) ->
    {Body, Args}.

is_sensitive_key(Key0) ->
    Key = normalize_key(Key0),
    lists:member(Key, [
        <<"access_token">>,
        <<"authorization">>,
        <<"auth">>,
        <<"bearer">>,
        <<"token">>,
        <<"api_key">>,
        <<"apikey">>,
        <<"secret">>,
        <<"password">>,
        <<"private_key">>,
        <<"nsec">>,
        <<"macaroon">>,
        <<"invoice_macaroon">>,
        <<"payment_preimage">>,
        <<"preimage">>,
        <<"payment_hash">>,
        <<"invoice">>,
        <<"bolt11">>,
        <<"rune">>,
        <<"cookie">>,
        <<"set-cookie">>,
        <<"x-preimage">>,
        <<"x-macaroon">>
    ]).

redact_value(Value0, Body, Args) ->
    Value = normalize_binary(Value0),
    case Value of
        <<>> -> {Body, Args};
        <<"null">> -> {Body, Args};
        _ -> {redact_binary(Body, Value), redact_binary(Args, Value)}
    end.

redact_binary(Data, Value) when is_binary(Data) ->
    binary:replace(Data, Value, ?REDACTED_TEXT_MARKER, [global]);
redact_binary(Data, _Value) ->
    Data.

%%%===================================================================
%%% Generic helpers
%%%===================================================================

normalize_account(AeAccount) when is_binary(AeAccount) -> AeAccount;
normalize_account(AeAccount) when is_list(AeAccount) -> unicode:characters_to_binary(AeAccount);
normalize_account(AeAccount) -> normalize_binary(AeAccount).

normalize_context_key(Key) when is_binary(Key) -> Key;
normalize_context_key(Key) when is_list(Key) -> unicode:characters_to_binary(Key);
normalize_context_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
normalize_context_key(Key) -> normalize_binary(Key).

normalize_key(Key) ->
    list_to_binary(string:lowercase(binary_to_list(normalize_context_key(Key)))).

normalize_binary(Value) when is_binary(Value) -> Value;
normalize_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
normalize_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

map_get_any(_Map, [], Default) ->
    Default;
map_get_any(Map, [Key | Rest], Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> map_get_any(Map, Rest, Default)
    end;
map_get_any(_Other, _Keys, Default) ->
    Default.

env_pos_int(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, Value} when is_integer(Value), Value > 0 -> Value;
        {ok, Value} when is_binary(Value); is_list(Value) ->
            try list_to_integer(binary_to_list(normalize_binary(Value))) of
                Integer when Integer > 0 -> Integer;
                _ -> Default
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(Key), json_safe(Value)} || {Key, Value} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) ->
    case io_lib:printable_unicode_list(List) of
        true -> unicode:characters_to_binary(List);
        false -> [json_safe(Value) || Value <- List]
    end;
json_safe(Tuple) when is_tuple(Tuple) ->
    [json_safe(Value) || Value <- tuple_to_list(Tuple)];
json_safe(undefined) ->
    null;
json_safe(none) ->
    null;
json_safe(null) ->
    null;
json_safe(true) ->
    true;
json_safe(false) ->
    false;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Value) when is_binary(Value); is_integer(Value); is_float(Value) -> Value;
json_safe(Value) ->
    normalize_binary(Value).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_list(Key) -> unicode:characters_to_binary(Key);
json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) -> normalize_binary(Key).

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

%%%===================================================================
%%% Tests
%%%===================================================================

test() ->
    AccountA = <<"ak_context_account_a">>,
    AccountB = <<"ak_context_account_b">>,
    ScopeA = account_scope(AccountA),
    ScopeB = account_scope(AccountB),
    _ = clear(ScopeA),
    _ = clear(ScopeB),
    {ok, _} = put(ScopeA, <<"server">>, <<"https://example.test">>),
    {ok, _} = put(ScopeA, <<"api_token">>, <<"secret-value">>, #{sensitive => true}),
    {ok, <<"https://example.test">>} = get(ScopeA, <<"server">>),
    not_found = get(ScopeB, <<"server">>),
    {ok, #{entries := #{<<"api_token">> := #{value := ?REDACTED_TEXT_MARKER}}}} =
        public_snapshot(ScopeA),
    ok.

test_account_context() ->
    Body = <<"token testpassword token">>,
    Args = <<"testpassword">>,
    clean_secrets(#{password => <<"testpassword">>}, Body, Args).
