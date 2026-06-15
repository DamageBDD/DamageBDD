-module(damage_nwc_ledger_cache).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% Public lifecycle/API.
-export([
    start_link/0,
    start/0,
    stop/0,
    ensure_started/0,

    ensure_synced/1,
    sync_ledger/1,
    sync_ledger/2,
    apply_events/2,

    balance_msat/2,
    balance_msat_by_client/2,
    policy/2,
    policy_by_client/2,
    transactions/4,
    transactions_by_client/5,

    put_policy/4,
    mark_revoked/2,
    apply_local_credit/5,
    apply_local_debit/5,
    apply_local_register/6,
    apply_local_limits/6,
    apply_local_revoke/3,

    client_hash/1,
    client_hash_hex/1,
    checkpoint/1,
    invalidate/1,
    clear/0
]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(BAL_TAB, damage_nwc_ledger_balances).
-define(POL_TAB, damage_nwc_ledger_policies).
-define(TX_TAB, damage_nwc_ledger_transactions).
-define(CKPT_TAB, damage_nwc_ledger_checkpoints).

-define(DEFAULT_SYNC_LIMIT, 100).
-define(DEFAULT_TX_LIMIT, 100).
-define(MAX_TXS_PER_CLIENT, 500).
-define(SYNC_FRESH_MS, 5000).

%% -------------------------------------------------------------------
%% Lifecycle
%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start() ->
    case whereis(?MODULE) of
        undefined ->
            gen_server:start({local, ?MODULE}, ?MODULE, [], []);
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:call(Pid, stop)
    end.

ensure_started() ->
    case start() of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, Why} -> {error, Why}
    end,
    create_tables().

init([]) ->
    create_tables(),
    {ok, #{}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

create_tables() ->
    ensure_table(?BAL_TAB, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ensure_table(?POL_TAB, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ensure_table(?TX_TAB, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ensure_table(?CKPT_TAB, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ok.

ensure_table(Tab, Opts) ->
    case ets:info(Tab) of
        undefined ->
            _ = ets:new(Tab, Opts),
            ok;
        _ ->
            ok
    end.

%% -------------------------------------------------------------------
%% Sync API
%% -------------------------------------------------------------------

ensure_synced(LedgerCt0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?CKPT_TAB, LedgerCt) of
        [{LedgerCt, #{last_sync_ms := LastSync}}] when Now - LastSync < ?SYNC_FRESH_MS ->
            ok;
        _ ->
            sync_ledger(LedgerCt)
    end.

sync_ledger(LedgerCt) ->
    sync_ledger(LedgerCt, #{}).

sync_ledger(LedgerCt0, Opts0) when is_map(Opts0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Limit = clamp_int(
        int_value(maps:get(limit, Opts0, ?DEFAULT_SYNC_LIMIT), ?DEFAULT_SYNC_LIMIT), 1, 100
    ),
    Direction = maps:get(direction, Opts0, backward),
    case fetch_ledger_events(LedgerCt, Limit, Direction) of
        {ok, RawEvents} ->
            {ok, Summary} = apply_events(LedgerCt, RawEvents),
            update_checkpoint(LedgerCt, Summary),
            ok;
        {error, _} = Error ->
            Error
    end.

apply_events(LedgerCt0, RawEvents) when is_list(RawEvents) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Summary0 = #{seen => 0, applied => 0, ignored => 0, latest_height => 0, latest_at => 0},
    Summary = lists:foldl(
        fun(Raw, Acc0) ->
            Acc1 = Acc0#{seen := maps:get(seen, Acc0, 0) + 1},
            case apply_event(LedgerCt, Raw) of
                {ok, Event} ->
                    Acc1#{
                        applied := maps:get(applied, Acc1, 0) + 1,
                        latest_height := max_int(
                            maps:get(latest_height, Acc1, 0), maps:get(height, Event, 0)
                        ),
                        latest_at := max_int(maps:get(latest_at, Acc1, 0), maps:get(at, Event, 0))
                    };
                ignored ->
                    Acc1#{ignored := maps:get(ignored, Acc1, 0) + 1}
            end
        end,
        Summary0,
        RawEvents
    ),
    {ok, Summary};
apply_events(_LedgerCt, _Other) ->
    {error, bad_events}.

fetch_ledger_events(LedgerCt, Limit, Direction) ->
    case code:ensure_loaded(damage_nwc_http) of
        {module, damage_nwc_http} ->
            case erlang:function_exported(damage_nwc_http, ledger_events, 3) of
                true ->
                    case catch damage_nwc_http:ledger_events(LedgerCt, Limit, Direction) of
                        {ok, Events} when is_list(Events) -> {ok, Events};
                        {error, _} = Error -> Error;
                        {'EXIT', Why} -> {error, {ledger_events_exit, Why}};
                        Other -> {error, {bad_ledger_events_reply, Other}}
                    end;
                false ->
                    {error, ledger_events_not_exported}
            end;
        Error ->
            {error, {damage_nwc_http_not_loaded, Error}}
    end.

update_checkpoint(LedgerCt, Summary) ->
    Checkpoint = maps:merge(Summary, #{last_sync_ms => erlang:system_time(millisecond)}),
    true = ets:insert(?CKPT_TAB, {LedgerCt, Checkpoint}),
    ok.

checkpoint(LedgerCt0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    case ets:lookup(?CKPT_TAB, LedgerCt) of
        [{LedgerCt, Ckpt}] -> {ok, Ckpt};
        [] -> not_found
    end.

%% -------------------------------------------------------------------
%% Read API
%% -------------------------------------------------------------------

balance_msat(LedgerCt0, ClientHashOrPub0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    lookup_first(?BAL_TAB, [{LedgerCt, Ref} || Ref <- lookup_refs(ClientHashOrPub0)], balance_msat).

balance_msat_by_client(LedgerCt, ClientPubHex) ->
    balance_msat(LedgerCt, client_hash(ClientPubHex)).

policy(LedgerCt0, ClientHashOrPub0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    case lookup_first_map(?POL_TAB, [{LedgerCt, Ref} || Ref <- lookup_refs(ClientHashOrPub0)]) of
        {ok, P} -> {ok, P};
        not_found -> not_found
    end.

policy_by_client(LedgerCt, ClientPubHex) ->
    policy(LedgerCt, client_hash(ClientPubHex)).

transactions(LedgerCt0, ClientHashOrPub0, Limit0, Offset0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Limit = clamp_int(int_value(Limit0, ?DEFAULT_TX_LIMIT), 1, ?MAX_TXS_PER_CLIENT),
    Offset = clamp_int(int_value(Offset0, 0), 0, 1000000),
    case lookup_first_tx(?TX_TAB, [{LedgerCt, Ref} || Ref <- lookup_refs(ClientHashOrPub0)]) of
        {ok, Txs} -> {ok, take(Limit, drop(Offset, Txs))};
        not_found -> {ok, []}
    end.

transactions_by_client(LedgerCt, ClientPubHex, Limit, Offset, _Opts) ->
    transactions(LedgerCt, client_hash(ClientPubHex), Limit, Offset).

lookup_first(Tab, [Key | Rest], Field) ->
    case ets:lookup(Tab, Key) of
        [{Key, Map}] when is_map(Map) ->
            {ok, maps:get(Field, Map, 0)};
        _ ->
            lookup_first(Tab, Rest, Field)
    end;
lookup_first(_Tab, [], _Field) ->
    not_found.

lookup_first_map(Tab, [Key | Rest]) ->
    case ets:lookup(Tab, Key) of
        [{Key, Map}] when is_map(Map) -> {ok, Map};
        _ -> lookup_first_map(Tab, Rest)
    end;
lookup_first_map(_Tab, []) ->
    not_found.

lookup_first_tx(Tab, [Key | Rest]) ->
    case ets:lookup(Tab, Key) of
        [{Key, Txs}] when is_list(Txs) -> {ok, Txs};
        _ -> lookup_first_tx(Tab, Rest)
    end;
lookup_first_tx(_Tab, []) ->
    not_found.

%% -------------------------------------------------------------------
%% Mutation/local update API
%% -------------------------------------------------------------------

put_policy(LedgerCt0, ClientHashOrPub0, Policy0, Meta0) when is_map(Policy0), is_map(Meta0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Hash = canonical_hash(ClientHashOrPub0),
    Policy1 = normalize_policy(Policy0),
    Old =
        case ets:lookup(?POL_TAB, {LedgerCt, Hash}) of
            [{{LedgerCt, Hash}, P}] when is_map(P) -> P;
            _ -> #{}
        end,
    Policy = maps:merge(
        maps:merge(base_policy(), Old),
        maps:merge(Policy1, Meta0#{updated_at => erlang:system_time(second)})
    ),
    true = ets:insert(?POL_TAB, {{LedgerCt, Hash}, Policy}),
    ok.

mark_revoked(LedgerCt0, ClientHashOrPub0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    Hash = canonical_hash(ClientHashOrPub0),
    Old =
        case ets:lookup(?POL_TAB, {LedgerCt, Hash}) of
            [{{LedgerCt, Hash}, P}] when is_map(P) -> P;
            _ -> base_policy()
        end,
    Policy = Old#{revoked => true, updated_at => erlang:system_time(second)},
    true = ets:insert(?POL_TAB, {{LedgerCt, Hash}, Policy}),
    ok.

apply_local_credit(LedgerCt, ClientPubHex, AmountMsat0, Ref0, Meta0) ->
    AmountMsat = int_value(AmountMsat0, 0),
    Hash = client_hash(ClientPubHex),
    Balance0 = current_balance_msat(LedgerCt, Hash),
    Event = maps:merge(normalize_local_meta(Meta0), #{
        client_pubkey_hash => Hash,
        kind => 0,
        type => <<"credit">>,
        amount_msat => AmountMsat,
        delta_msat => AmountMsat,
        delta_sat => AmountMsat div 1000,
        ref => to_bin(Ref0),
        balance_after_msat => Balance0 + AmountMsat,
        balance_after_sat => (Balance0 + AmountMsat) div 1000,
        at => erlang:system_time(second),
        height => 0,
        source => local_contract_ok,
        chain_confirmed => false,
        pending_chain => true
    }),
    case apply_event(LedgerCt, Event) of
        {ok, _} -> ok;
        ignored -> ok
    end.

apply_local_debit(LedgerCt, ClientPubHex, AmountMsat0, Ref0, Meta0) ->
    AmountMsat = int_value(AmountMsat0, 0),
    Hash = client_hash(ClientPubHex),
    Balance0 = current_balance_msat(LedgerCt, Hash),
    BalanceAfter = erlang:max(0, Balance0 - AmountMsat),
    Event = maps:merge(normalize_local_meta(Meta0), #{
        client_pubkey_hash => Hash,
        kind => 1,
        type => <<"debit">>,
        amount_msat => AmountMsat,
        delta_msat => -AmountMsat,
        delta_sat => (-AmountMsat) div 1000,
        ref => to_bin(Ref0),
        balance_after_msat => BalanceAfter,
        balance_after_sat => BalanceAfter div 1000,
        at => erlang:system_time(second),
        height => 0,
        source => local_contract_ok,
        chain_confirmed => false,
        pending_chain => true
    }),
    case apply_event(LedgerCt, Event) of
        {ok, _} -> ok;
        ignored -> ok
    end.

apply_local_register(LedgerCt, ClientPubHex, MaxSingleMsat0, MaxTotalMsat0, ExpiresHeight0, Meta0) ->
    Hash = client_hash(ClientPubHex),
    Event = maps:merge(normalize_local_meta(Meta0), #{
        client_pubkey_hash => Hash,
        kind => 2,
        type => <<"minted">>,
        max_single_msat => int_value(MaxSingleMsat0, 0),
        max_total_msat => int_value(MaxTotalMsat0, 0),
        expires_height => int_value(ExpiresHeight0, 0),
        at => erlang:system_time(second),
        height => 0,
        source => local_contract_ok,
        chain_confirmed => false,
        pending_chain => true
    }),
    case apply_event(LedgerCt, Event) of
        {ok, _} -> ok;
        ignored -> ok
    end.

apply_local_limits(LedgerCt, ClientPubHex, MaxSingleMsat0, MaxTotalMsat0, ExpiresHeight0, Meta0) ->
    Hash = client_hash(ClientPubHex),
    Event = maps:merge(normalize_local_meta(Meta0), #{
        client_pubkey_hash => Hash,
        kind => 4,
        type => <<"limits_updated">>,
        max_single_msat => int_value(MaxSingleMsat0, 0),
        max_total_msat => int_value(MaxTotalMsat0, 0),
        expires_height => int_value(ExpiresHeight0, 0),
        at => erlang:system_time(second),
        height => 0,
        source => local_contract_ok,
        chain_confirmed => false,
        pending_chain => true
    }),
    case apply_event(LedgerCt, Event) of
        {ok, _} -> ok;
        ignored -> ok
    end.

apply_local_revoke(LedgerCt, ClientPubHex, Meta0) ->
    Hash = client_hash(ClientPubHex),
    Event = maps:merge(normalize_local_meta(Meta0), #{
        client_pubkey_hash => Hash,
        kind => 3,
        type => <<"revoked">>,
        at => erlang:system_time(second),
        height => 0,
        source => local_contract_ok,
        chain_confirmed => false,
        pending_chain => true
    }),
    case apply_event(LedgerCt, Event) of
        {ok, _} -> ok;
        ignored -> ok
    end.

normalize_local_meta(Meta) when is_map(Meta) -> Meta;
normalize_local_meta(_) -> #{}.

current_balance_msat(LedgerCt, Hash) ->
    case balance_msat(LedgerCt, Hash) of
        {ok, Balance} -> Balance;
        not_found -> 0
    end.

apply_event(LedgerCt0, Raw0) ->
    case normalize_event(Raw0) of
        undefined ->
            ignored;
        Event0 ->
            LedgerCt = to_bin(LedgerCt0),
            Event = normalize_confirmed_event(Event0),
            Hash = canonical_hash(maps:get(client_pubkey_hash, Event, <<>>)),
            case Hash of
                <<>> ->
                    ignored;
                _ ->
                    Kind = int_value(maps:get(kind, Event, -1), -1),
                    apply_kind(LedgerCt, Hash, Kind, Event),
                    {ok, Event#{client_pubkey_hash => Hash}}
            end
    end.

normalize_confirmed_event(Event) ->
    Event#{
        chain_confirmed => maps:get(chain_confirmed, Event, true),
        pending_chain => maps:get(pending_chain, Event, false)
    }.

apply_kind(LedgerCt, Hash, 0, Event) ->
    Amount = int_value(maps:get(amount_msat, Event, 0), 0),
    BalanceAfter = int_value(
        maps:get(balance_after_msat, Event, current_balance_msat(LedgerCt, Hash) + Amount), 0
    ),
    put_balance(LedgerCt, Hash, BalanceAfter, Event),
    append_tx(LedgerCt, Hash, event_to_tx(credit, Amount, Event));
apply_kind(LedgerCt, Hash, 1, Event) ->
    Amount = int_value(maps:get(amount_msat, Event, 0), 0),
    BalanceAfter = int_value(
        maps:get(
            balance_after_msat, Event, erlang:max(0, current_balance_msat(LedgerCt, Hash) - Amount)
        ),
        0
    ),
    put_balance(LedgerCt, Hash, BalanceAfter, Event),
    bump_spent(LedgerCt, Hash, Amount),
    append_tx(LedgerCt, Hash, event_to_tx(debit, Amount, Event));
apply_kind(LedgerCt, Hash, 2, Event) ->
    put_policy(LedgerCt, Hash, event_policy(Event), event_meta(Event#{revoked => false})),
    maybe_put_balance_from_event(LedgerCt, Hash, Event);
apply_kind(LedgerCt, Hash, 3, Event) ->
    mark_revoked(LedgerCt, Hash),
    maybe_put_balance_from_event(LedgerCt, Hash, Event);
apply_kind(LedgerCt, Hash, 4, Event) ->
    put_policy(LedgerCt, Hash, event_policy(Event), event_meta(Event)),
    maybe_put_balance_from_event(LedgerCt, Hash, Event);
apply_kind(_LedgerCt, _Hash, _Kind, _Event) ->
    ok.

put_balance(LedgerCt, Hash, BalanceMsat, Event) ->
    Row = #{
        balance_msat => BalanceMsat,
        balance_sat => BalanceMsat div 1000,
        updated_at => maps:get(at, Event, erlang:system_time(second)),
        height => maps:get(height, Event, 0),
        tx_hash => maps:get(tx_hash, Event, <<>>),
        source => maps:get(source, Event, chain_event),
        chain_confirmed => maps:get(chain_confirmed, Event, true),
        pending_chain => maps:get(pending_chain, Event, false)
    },
    true = ets:insert(?BAL_TAB, {{LedgerCt, Hash}, Row}),
    ok.

maybe_put_balance_from_event(LedgerCt, Hash, Event) ->
    case maps:get(balance_after_msat, Event, undefined) of
        B when is_integer(B) -> put_balance(LedgerCt, Hash, B, Event);
        _ -> ok
    end.

append_tx(LedgerCt, Hash, Tx0) ->
    Key = {LedgerCt, Hash},
    Existing =
        case ets:lookup(?TX_TAB, Key) of
            [{Key, Txs0}] when is_list(Txs0) -> Txs0;
            _ -> []
        end,
    Txs1 = dedupe_txs([Tx0 | Existing]),
    Txs = take(?MAX_TXS_PER_CLIENT, sort_txs(Txs1)),
    true = ets:insert(?TX_TAB, {Key, Txs}),
    ok.

bump_spent(LedgerCt, Hash, AmountMsat) ->
    Old =
        case ets:lookup(?POL_TAB, {LedgerCt, Hash}) of
            [{{LedgerCt, Hash}, P}] when is_map(P) -> P;
            _ -> base_policy()
        end,
    Spent = int_value(maps:get(spent_msat, Old, 0), 0) + AmountMsat,
    true = ets:insert(
        ?POL_TAB,
        {{LedgerCt, Hash}, Old#{spent_msat => Spent, updated_at => erlang:system_time(second)}}
    ),
    ok.

%% -------------------------------------------------------------------
%% Event decoding
%% -------------------------------------------------------------------

normalize_event(Event0) when is_map(Event0) ->
    Event = normalize_keys(Event0),
    case {maps:is_key(client_pubkey_hash, Event), maps:is_key(kind, Event)} of
        {true, true} ->
            normalize_decoded_event(Event);
        _ ->
            decode_ledger_event(Event)
    end;
normalize_event(_Other) ->
    undefined.

normalize_decoded_event(Event0) ->
    Kind = int_value(maps:get(kind, Event0, -1), -1),
    Event0#{
        client_pubkey_hash => normalize_event_hash(maps:get(client_pubkey_hash, Event0, <<>>)),
        kind => Kind,
        type => event_type(Kind),
        at => int_value(
            maps:get(at, Event0, erlang:system_time(second)), erlang:system_time(second)
        ),
        height => int_value(maps:get(height, Event0, 0), 0)
    }.

decode_ledger_event(Raw) ->
    case ledger_event_args(Raw) of
        {undefined, _Kind, _Payload} ->
            undefined;
        {ClientHash0, Kind0, Payload0} ->
            Kind = int_value(arg_value(Kind0), -1),
            ClientHash = normalize_event_hash(arg_value(ClientHash0)),
            Payload = decode_payload(arg_value(Payload0)),
            PayloadMap = decode_ledger_payload(Kind, Payload),
            maps:merge(
                #{
                    client_pubkey_hash => ClientHash,
                    kind => Kind,
                    type => event_type(Kind),
                    at => event_time(Raw),
                    tx_hash => safe_bin(
                        get_any(Raw, [tx_hash, <<"tx_hash">>, hash, <<"hash">>], <<>>)
                    ),
                    height => int_value(
                        get_any(Raw, [height, <<"height">>, block_height, <<"block_height">>], 0), 0
                    ),
                    source => chain_event,
                    chain_confirmed => true,
                    pending_chain => false
                },
                PayloadMap
            )
    end.

ledger_event_args(Raw) ->
    case
        get_any(
            Raw,
            [args, <<"args">>, arguments, <<"arguments">>, decoded_args, <<"decoded_args">>],
            undefined
        )
    of
        [A, B, C | _] ->
            {arg_value(A), arg_value(B), arg_value(C)};
        _ ->
            Topics = get_any(Raw, [topics, <<"topics">>], []),
            Data = get_any(Raw, [data, <<"data">>, payload, <<"payload">>], <<>>),
            case Topics of
                [_EventHash, ClientHash, Kind0 | _] -> {ClientHash, Kind0, Data};
                [ClientHash, Kind0 | _] -> {ClientHash, Kind0, Data};
                _ -> {undefined, -1, <<>>}
            end
    end.

arg_value(#{<<"value">> := V}) -> V;
arg_value(#{value := V}) -> V;
arg_value({_, V}) -> V;
arg_value(V) -> V.

decode_ledger_payload(Kind, Payload0) ->
    Payload = decode_payload(Payload0),
    Parts = binary:split(Payload, <<"|">>, [global]),
    decode_ledger_payload_parts(Kind, Parts).

decode_ledger_payload_parts(Kind, [Amount0, Ref, MetaHash, Height0, BalanceAfter0 | _]) when
    Kind =:= 0; Kind =:= 1
->
    Amount = int_value(Amount0, 0),
    Delta =
        case Kind of
            0 -> Amount;
            1 -> -Amount
        end,
    #{
        amount_msat => Amount,
        delta_msat => Delta,
        delta_sat => Delta div 1000,
        ref => to_bin(Ref),
        meta_sha256 => normalize_meta_hash(MetaHash),
        height => int_value(Height0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0),
        balance_after_sat => int_value(BalanceAfter0, 0) div 1000
    };
decode_ledger_payload_parts(Kind, [
    MaxSingle0, MaxTotal0, ExpiresHeight0, Height0, BalanceAfter0 | _
]) when Kind =:= 2; Kind =:= 4 ->
    #{
        max_single_msat => int_value(MaxSingle0, 0),
        max_total_msat => int_value(MaxTotal0, 0),
        expires_height => int_value(ExpiresHeight0, 0),
        height => int_value(Height0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0),
        balance_after_sat => int_value(BalanceAfter0, 0) div 1000
    };
decode_ledger_payload_parts(3, [
    _MaxSingle0, _MaxTotal0, _ExpiresHeight0, Height0, BalanceAfter0 | _
]) ->
    #{
        height => int_value(Height0, 0),
        balance_after_msat => int_value(BalanceAfter0, 0),
        balance_after_sat => int_value(BalanceAfter0, 0) div 1000
    };
decode_ledger_payload_parts(_Kind, _Parts) ->
    #{}.

decode_payload(Payload) when is_binary(Payload) ->
    case Payload of
        <<"ba_", _/binary>> -> maybe_decode_bytearray(Payload);
        <<"cb_", _/binary>> -> maybe_decode_bytearray(Payload);
        _ -> Payload
    end;
decode_payload(Payload) when is_list(Payload) ->
    unicode:characters_to_binary(Payload);
decode_payload(Payload) ->
    to_bin(Payload).

maybe_decode_bytearray(Encoded) ->
    maybe_decode_bytearray(Encoded, [bytearray, contract_bytearray]).

maybe_decode_bytearray(Encoded, [Type | Rest]) ->
    case catch aeser_api_encoder:decode(Type, Encoded) of
        {Type, Bin} when is_binary(Bin) -> Bin;
        Bin when is_binary(Bin) -> Bin;
        _ -> maybe_decode_bytearray(Encoded, Rest)
    end;
maybe_decode_bytearray(Encoded, []) ->
    Encoded.

event_type(0) -> <<"credit">>;
event_type(1) -> <<"debit">>;
event_type(2) -> <<"minted">>;
event_type(3) -> <<"revoked">>;
event_type(4) -> <<"limits_updated">>;
event_type(_) -> <<"event">>.

event_policy(Event) ->
    #{
        max_single_msat => int_value(maps:get(max_single_msat, Event, 0), 0),
        max_total_msat => int_value(maps:get(max_total_msat, Event, 0), 0),
        expires_height => int_value(maps:get(expires_height, Event, 0), 0)
    }.

event_meta(Event) ->
    #{
        updated_at => maps:get(at, Event, erlang:system_time(second)),
        height => maps:get(height, Event, 0),
        tx_hash => maps:get(tx_hash, Event, <<>>),
        source => maps:get(source, Event, chain_event),
        chain_confirmed => maps:get(chain_confirmed, Event, true),
        pending_chain => maps:get(pending_chain, Event, false),
        revoked => maps:get(revoked, Event, maps:get(kind, Event, -1) =:= 3)
    }.

event_to_tx(KindAtom, AmountMsat, Event) ->
    KindBin =
        case KindAtom of
            credit -> <<"credit">>;
            debit -> <<"debit">>;
            _ -> to_bin(KindAtom)
        end,
    #{
        kind => KindBin,
        type =>
            case KindAtom of
                credit -> <<"incoming">>;
                debit -> <<"outgoing">>;
                _ -> <<"unknown">>
            end,
        amount_msat => AmountMsat,
        amount_sat => AmountMsat div 1000,
        ref => to_bin(maps:get(ref, Event, <<>>)),
        payment_hash => to_bin(maps:get(ref, Event, <<>>)),
        meta_sha256 => normalize_meta_hash(maps:get(meta_sha256, Event, <<>>)),
        height => int_value(maps:get(height, Event, 0), 0),
        balance_after_msat => int_value(maps:get(balance_after_msat, Event, 0), 0),
        balance_after_sat => int_value(maps:get(balance_after_msat, Event, 0), 0) div 1000,
        created_at => int_value(maps:get(at, Event, 0), 0),
        settled_at => int_value(maps:get(at, Event, 0), 0),
        tx_hash => to_bin(maps:get(tx_hash, Event, <<>>)),
        source => maps:get(source, Event, chain_event),
        chain_confirmed => maps:get(chain_confirmed, Event, true),
        pending_chain => maps:get(pending_chain, Event, false)
    }.

%% -------------------------------------------------------------------
%% Invalidations
%% -------------------------------------------------------------------

invalidate(LedgerCt0) ->
    ok = ensure_started(),
    LedgerCt = to_bin(LedgerCt0),
    delete_matching(?BAL_TAB, LedgerCt),
    delete_matching(?POL_TAB, LedgerCt),
    delete_matching(?TX_TAB, LedgerCt),
    ets:delete(?CKPT_TAB, LedgerCt),
    ok.

clear() ->
    ok = ensure_started(),
    ets:delete_all_objects(?BAL_TAB),
    ets:delete_all_objects(?POL_TAB),
    ets:delete_all_objects(?TX_TAB),
    ets:delete_all_objects(?CKPT_TAB),
    ok.

delete_matching(Tab, LedgerCt) ->
    MatchSpec = [{{{LedgerCt, '_'}, '_'}, [], [true]}],
    ets:select_delete(Tab, MatchSpec),
    ok.

%% -------------------------------------------------------------------
%% Keys/normalization/utilities
%% -------------------------------------------------------------------

client_hash(ClientPubHex) ->
    lower_hex(crypto:hash(sha256, normalize_client_pubkey(ClientPubHex))).

client_hash_hex(ClientPubHex) ->
    client_hash(ClientPubHex).

canonical_hash(<<>>) ->
    <<>>;
canonical_hash(undefined) ->
    <<>>;
canonical_hash(Hash0) ->
    Hash = normalize_event_hash(Hash0),
    case byte_size(Hash) of
        0 -> <<>>;
        _ -> Hash
    end.

lookup_refs(Ref0) ->
    Direct = normalize_event_hash(Ref0),
    ClientHash = client_hash(Ref0),
    lists:usort([Direct, ClientHash, to_bin(Ref0)]).

normalize_client_pubkey(Key0) ->
    Key = to_bin(Key0),
    case byte_size(Key) of
        32 -> lower_hex(Key);
        _ -> lowercase_bin(Key)
    end.

normalize_event_hash(undefined) -> <<>>;
normalize_event_hash(<<>>) -> <<>>;
normalize_event_hash(B) when is_binary(B), byte_size(B) =:= 32 -> lower_hex(B);
normalize_event_hash(<<"ba_", _/binary>> = B) -> normalize_event_hash(maybe_decode_bytearray(B));
normalize_event_hash(<<"cb_", _/binary>> = B) -> normalize_event_hash(maybe_decode_bytearray(B));
normalize_event_hash(B) when is_binary(B) -> lowercase_bin(B);
normalize_event_hash(L) when is_list(L) -> normalize_event_hash(unicode:characters_to_binary(L));
normalize_event_hash(I) when is_integer(I) -> integer_to_binary(I);
normalize_event_hash(V) -> to_bin(V).

normalize_policy(Policy0) ->
    Policy = normalize_keys(Policy0),
    #{
        revoked => bool_value(maps:get(revoked, Policy, false), false),
        max_single_msat => int_value(maps:get(max_single_msat, Policy, 0), 0),
        max_total_msat => int_value(maps:get(max_total_msat, Policy, 0), 0),
        expires_height => int_value(maps:get(expires_height, Policy, 0), 0),
        spent_msat => int_value(maps:get(spent_msat, Policy, 0), 0)
    }.

base_policy() ->
    #{
        revoked => false,
        max_single_msat => 0,
        max_total_msat => 0,
        expires_height => 0,
        spent_msat => 0,
        updated_at => 0,
        height => 0,
        source => local_cache,
        chain_confirmed => false,
        pending_chain => false
    }.

normalize_keys(Map) when is_map(Map) ->
    maps:from_list([{normalize_key(K), V} || {K, V} <- maps:to_list(Map)]);
normalize_keys(Other) ->
    Other.

normalize_key(K) when is_atom(K) -> K;
normalize_key(<<"client_pubkey_hash">>) -> client_pubkey_hash;
normalize_key(<<"kind">>) -> kind;
normalize_key(<<"type">>) -> type;
normalize_key(<<"at">>) -> at;
normalize_key(<<"tx_hash">>) -> tx_hash;
normalize_key(<<"height">>) -> height;
normalize_key(<<"block_height">>) -> block_height;
normalize_key(<<"amount_msat">>) -> amount_msat;
normalize_key(<<"delta_msat">>) -> delta_msat;
normalize_key(<<"delta_sat">>) -> delta_sat;
normalize_key(<<"ref">>) -> ref;
normalize_key(<<"meta_sha256">>) -> meta_sha256;
normalize_key(<<"balance_after_msat">>) -> balance_after_msat;
normalize_key(<<"balance_after_sat">>) -> balance_after_sat;
normalize_key(<<"max_single_msat">>) -> max_single_msat;
normalize_key(<<"max_total_msat">>) -> max_total_msat;
normalize_key(<<"expires_height">>) -> expires_height;
normalize_key(<<"revoked">>) -> revoked;
normalize_key(<<"spent_msat">>) -> spent_msat;
normalize_key(<<"chain_confirmed">>) -> chain_confirmed;
normalize_key(<<"pending_chain">>) -> pending_chain;
normalize_key(<<"source">>) -> source;
normalize_key(K) -> K.

get_any(Map, [K | Rest], Default) when is_map(Map) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> get_any(Map, Rest, Default)
    end;
get_any(_Map, [], Default) ->
    Default;
get_any(_Other, _Keys, Default) ->
    Default.

int_value(V, _Default) when is_integer(V) -> V;
int_value(V, _Default) when is_float(V) -> trunc(V);
int_value(V, Default) when is_binary(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(V, Default) when is_list(V) ->
    case catch list_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(_, Default) ->
    Default.

bool_value(true, _Default) -> true;
bool_value(false, _Default) -> false;
bool_value(<<"true">>, _Default) -> true;
bool_value(<<"false">>, _Default) -> false;
bool_value(<<"1">>, _Default) -> true;
bool_value(<<"0">>, _Default) -> false;
bool_value("true", _Default) -> true;
bool_value("false", _Default) -> false;
bool_value("1", _Default) -> true;
bool_value("0", _Default) -> false;
bool_value(_, Default) -> Default.

safe_bin(B) when is_binary(B) -> B;
safe_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
safe_bin(I) when is_integer(I) -> integer_to_binary(I);
safe_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
safe_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_bin(V) -> safe_bin(V).

lowercase_bin(Bin) when is_binary(Bin) ->
    try
        list_to_binary(string:lowercase(binary_to_list(Bin)))
    catch
        _:_ -> Bin
    end.

lower_hex(Bin) when is_binary(Bin) ->
    lowercase_bin(binary:encode_hex(Bin)).

normalize_meta_hash(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    lower_hex(Bin);
normalize_meta_hash(Bin) when is_binary(Bin) ->
    lowercase_bin(Bin);
normalize_meta_hash(Other) ->
    to_bin(Other).

event_time(Raw) ->
    T0 = int_value(
        get_any(Raw, [micro_time, <<"micro_time">>, micro_time_ms, <<"micro_time_ms">>], 0), 0
    ),
    case T0 of
        T when T > 1000000000000000 -> T div 1000000;
        T when T > 1000000000000 -> T div 1000;
        T when T > 0 -> T;
        _ ->
            int_value(
                get_any(
                    Raw,
                    [time, <<"time">>, timestamp, <<"timestamp">>, block_time, <<"block_time">>],
                    erlang:system_time(second)
                ),
                erlang:system_time(second)
            )
    end.

sort_txs(Txs) ->
    lists:sort(fun(A, B) -> tx_order(A) >= tx_order(B) end, Txs).

tx_order(Tx) ->
    first_positive_int([
        maps:get(settled_at, Tx, 0),
        maps:get(created_at, Tx, 0),
        maps:get(height, Tx, 0)
    ]).

dedupe_txs(Txs) ->
    {Out, _Seen} = lists:foldl(
        fun(Tx, {Acc, Seen}) ->
            Key = tx_key(Tx),
            case maps:is_key(Key, Seen) of
                true -> {Acc, Seen};
                false -> {[Tx | Acc], maps:put(Key, true, Seen)}
            end
        end,
        {[], #{}},
        Txs
    ),
    lists:reverse(Out).

tx_key(Tx) ->
    case maps:get(tx_hash, Tx, <<>>) of
        <<>> ->
            {
                maps:get(kind, Tx, <<>>),
                maps:get(ref, Tx, <<>>),
                maps:get(height, Tx, 0),
                maps:get(amount_msat, Tx, 0)
            };
        Hash ->
            Hash
    end.

first_positive_int([H | T]) ->
    case int_value(H, 0) of
        I when I > 0 -> I;
        _ -> first_positive_int(T)
    end;
first_positive_int([]) ->
    0.

clamp_int(I, Min, _Max) when is_integer(I), I < Min -> Min;
clamp_int(I, _Min, Max) when is_integer(I), I > Max -> Max;
clamp_int(I, _Min, _Max) when is_integer(I) -> I;
clamp_int(_, Min, _Max) -> Min.

max_int(A, B) when A >= B -> A;
max_int(_A, B) -> B.

drop(N, List) when N =< 0 -> List;
drop(_N, []) -> [];
drop(N, [_ | T]) -> drop(N - 1, T).

take(N, _List) when N =< 0 -> [];
take(_N, []) -> [];
take(N, [H | T]) -> [H | take(N - 1, T)].
