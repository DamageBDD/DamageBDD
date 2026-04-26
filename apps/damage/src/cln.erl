-module(cln).

-behaviour(gen_server).

%% API Functions
-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    newaddr/0,
    newaddr/1
]).

-export([
    getinfo/0,
    create_invoice/2,
    create_invoice/3,
    create_invoice/4,
    hold_invoice/4,
    hold_invoice_cancel/1,
    list_invoices/0,
    list_invoices/1,
    list_invoices_by_label/1,
    list_invoices_by_invoicestring/1,
    list_invoices_by_payment_hash/1,
    channel_id_to_scid/1,
    list_channels/0,
    list_all_channels/0,
    find_best_peer_to_open/0,
    find_best_peer_to_open/1,
    score_peers_for_opening/1,
    top_five_nodes/1,
    get_node_balance/0,
    open_channels_with_best_peers/0,
    open_channels_with_best_peers/1,
    inbound_capacity/2,
    verify_peer/1,
    clear_cache/0,
    estimate_routing_fee/2
]).

-export([register_listener/1]).
-export([existing_peers/1]).
-export([
    connect_peer/1,
    connect_peer/2,
    connect_peers/1,
    connect_best_peers/0,
    connect_best_peers/1,
    blacklist_peer/3,
    sats_to_msat/1,
    msat_to_sats/1
]).
-export([pay_invoice/1, pay_invoice/2]).
-export([
    list_funds/0,
    list_pays/0,
    list_sendpays/0,
    open_channel/3,
    open_channel/2
]).
-export([
    list_all_invoices/0,
    list_all_invoices/1
]).

-export([
    sort_invoices_desc/1,
    sort_sendpays_desc/1,
    sort_pays_desc/1,
    sort_peerchannels_desc/1,
    sort_outputs_desc/1
]).
%% -------------------------------------------------------------------
%% SQL-backed canned queries for CLN
%% Read-only, safe, parameterized-by-construction
%% -------------------------------------------------------------------

-export([
    sql/1,
    sql_rows/1,

    recent_invoices/1,
    recent_invoices/2,
    unpaid_invoices/1,
    unpaid_invoices/2,
    paid_invoices_since/2,
    invoice_counts_by_status/0,

    recent_account_events/2,
    recent_account_events/3,
    account_event_summary/1,
    account_event_summary/2,

    recent_peerchannels/1,
    peerchannel_summary/0
]).
-define(DEFAULT_LIST_INVOICES_PAGE_LIMIT, 100).
-export([test/0]).

%% Cache / timeouts
-define(CACHE_TTL_SECS, 300).
-define(CLN_HTTP_TIMEOUT, 600000).
-define(PEER_MIN_TTL, 604800000).
-define(PEER_BLACKLIST_TTL, 86400000).
-define(PEER_BLACKLIST_TTL_MIN, 86400000).
-define(PEER_BLACKLIST_TTL_CONN, 21600000).
-define(SECRETS_RETRY_MS, 60000).

%% Planning defaults
-define(DEFAULT_CHANNEL_OPEN_SATS, 200000).
-define(DEFAULT_RESERVE_SATS, 50000).
-define(DEFAULT_MIN_PER_CHANNEL_SATS, 100000).
-define(DEFAULT_INBOUND_BOOST_WEIGHT, 1.2).
-define(DEFAULT_MIN_INBOUND_RATIO, 0.5).

-define(SAT_TO_MSAT, 1000).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-record(state, {
    conn_pid = undefined,
    streamref = undefined,
    cln_host = undefined,
    cln_port = undefined,
    cln_wspath = undefined,
    cln_certfile = undefined,
    cln_keyfile = undefined,
    rune = undefined,
    readonly_rune = undefined,
    retry_timer = undefined,
    secrets_ready = false,
    options :: map(),
    heartbeat_timer = undefined
}).

-record(plan_ctx, {
    host,
    port,
    options,
    rune,
    target_msat,
    min_per_channel_msat,
    spendable_msat,
    opts = #{},
    attempts_left = 6,
    successes_left = 2
}).

%% ===================================================================
%% Public helpers
%% ===================================================================

sats_to_msat(Sats) when is_integer(Sats) ->
    Sats * ?SAT_TO_MSAT.

msat_to_sats(Msat) when is_integer(Msat) ->
    Msat div ?SAT_TO_MSAT.

start_link([]) ->
    gen_server:start_link(?MODULE, [], []).

to_sort_int(V) when is_integer(V) -> V;
to_sort_int(V) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> -1
    end;
to_sort_int(V) when is_list(V) ->
    try
        list_to_integer(V)
    catch
        _:_ -> -1
    end;
to_sort_int(_) ->
    -1.

map_get_any(Keys, Map, Default) ->
    lists:foldl(
        fun(Key, Acc) ->
            case Acc of
                Default ->
                    maps:get(Key, Map, Default);
                _ ->
                    Acc
            end
        end,
        Default,
        Keys
    ).

invoice_sort_key(Inv) ->
    {
        to_sort_int(map_get_any([created_index, <<"created_index">>], Inv, -1)),
        to_sort_int(map_get_any([updated_index, <<"updated_index">>], Inv, -1)),
        to_sort_int(map_get_any([created_at, <<"created_at">>], Inv, -1)),
        to_sort_int(
            map_get_any([expires_at, <<"expires_at">>, expiry_time, <<"expiry_time">>], Inv, -1)
        )
    }.

sort_invoices_desc(Invoices) when is_list(Invoices) ->
    lists:sort(
        fun(A, B) ->
            invoice_sort_key(A) >= invoice_sort_key(B)
        end,
        Invoices
    ).

sendpay_sort_key(Pay) ->
    {
        to_sort_int(map_get_any([created_at, <<"created_at">>], Pay, -1)),
        to_sort_int(map_get_any([updated_index, <<"updated_index">>], Pay, -1))
    }.

sort_sendpays_desc(Pays) when is_list(Pays) ->
    lists:sort(
        fun(A, B) ->
            sendpay_sort_key(A) >= sendpay_sort_key(B)
        end,
        Pays
    ).

pay_sort_key(Pay) ->
    {
        to_sort_int(
            map_get_any([created_at, <<"created_at">>, completed_at, <<"completed_at">>], Pay, -1)
        ),
        to_sort_int(map_get_any([updated_index, <<"updated_index">>], Pay, -1))
    }.

sort_pays_desc(Pays) when is_list(Pays) ->
    lists:sort(
        fun(A, B) ->
            pay_sort_key(A) >= pay_sort_key(B)
        end,
        Pays
    ).

peerchannel_sort_key(Chan) ->
    {
        to_sort_int(map_get_any([created_at, <<"created_at">>], Chan, -1)),
        to_sort_int(map_get_any([last_update, <<"last_update">>], Chan, -1)),
        to_sort_int(map_get_any([updated_at, <<"updated_at">>], Chan, -1))
    }.

sort_peerchannels_desc(Channels) when is_list(Channels) ->
    lists:sort(
        fun(A, B) ->
            peerchannel_sort_key(A) >= peerchannel_sort_key(B)
        end,
        Channels
    ).

output_sort_key(Out) ->
    {
        to_sort_int(map_get_any([blockheight, <<"blockheight">>], Out, -1)),
        to_sort_int(map_get_any([output, <<"output">>], Out, -1))
    }.

sort_outputs_desc(Outputs) when is_list(Outputs) ->
    lists:sort(
        fun(A, B) ->
            output_sort_key(A) >= output_sort_key(B)
        end,
        Outputs
    ).
%% ===================================================================
%% Init / state
%% ===================================================================

get_cln_client_config() ->
    {ok, Host} = application:get_env(damage, cln_host),
    {ok, Port} = application:get_env(damage, cln_port),
    {ok, Path} = application:get_env(damage, cln_wspath),
    {ok, CertFile} = application:get_env(damage, cln_certfile),
    {ok, KeyFile} = application:get_env(damage, cln_keyfile),
    Options = #{},
    #state{
        cln_host = Host,
        cln_port = Port,
        cln_wspath = Path,
        cln_certfile = CertFile,
        cln_keyfile = KeyFile,
        options = Options
    }.

load_runes(State) ->
    case {secrets:retrieve_decrypt(cln_rune), secrets:retrieve_decrypt(cln_readonly_rune)} of
        {{ok, Rune}, {ok, ReadOnly}} ->
            {ok, State#state{rune = Rune, readonly_rune = ReadOnly}};
        Error ->
            {error, Error}
    end.

init([]) ->
    ensure_cache_table(),
    State0 = get_cln_client_config(),
    case load_runes(State0) of
        {ok, State1} ->
            {ok, State1#state{secrets_ready = true}};
        {error, Error} ->
            ?LOG_DEBUG("cln worker error in init ~p ~p", [Error, State0]),
            TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
            {ok, State0#state{secrets_ready = false, retry_timer = TRef}}
    end.

ensure_cache_table() ->
    case ets:info(cln_channel_cache) of
        undefined ->
            ets:new(cln_channel_cache, [set, public, named_table, {read_concurrency, true}]),
            ?LOG_DEBUG("cln_channel_cache created");
        _ ->
            ok
    end.

%% ===================================================================
%% Cache helpers
%% ===================================================================

put_cache(Key, Value) ->
    put_cache(Key, Value, ?CACHE_TTL_SECS).

put_cache(Key, Value, TTLms) ->
    ets:insert(cln_channel_cache, {Key, {Value, erlang:monotonic_time(millisecond), TTLms}}).

get_cache(Key) ->
    get_cache(Key, ?CACHE_TTL_SECS).

get_cache(Key, DefaultTTL) ->
    case ets:lookup(cln_channel_cache, Key) of
        [{_, {Val, T, TTL}}] ->
            Now = erlang:monotonic_time(millisecond),
            case Now - T =< TTL of
                true ->
                    {ok, Val};
                false ->
                    ets:delete(cln_channel_cache, Key),
                    not_found
            end;
        [{_, {Val, T}}] ->
            Now = erlang:monotonic_time(millisecond),
            case Now - T =< DefaultTTL of
                true ->
                    {ok, Val};
                false ->
                    ets:delete(cln_channel_cache, Key),
                    not_found
            end;
        _ ->
            not_found
    end.

%% ===================================================================
%% Generic HTTP helpers
%% ===================================================================

%% ===================================================================
%% Generic HTTP helpers
%% ===================================================================

headers(Rune) ->
    [{<<"Rune">>, Rune}, {<<"content-type">>, <<"application/json">>}].

cln_post_json(Host, Port, Options, Rune, Path, ReqMap) ->
    cln_post_json_with_headers(
        Host,
        Port,
        Options,
        headers(Rune),
        Path,
        ReqMap
    ).

cln_post_json_with_headers(Host, Port, Options0, Headers, Path, ReqMap) ->
    Opts = cln_gun_opts(Host, Port, Options0),

    case
        damage_gun:post(
            Host,
            Port,
            Path,
            Headers,
            jsx:encode(ReqMap),
            Opts#{
                decode => json,
                close => true
            }
        )
    of
        {ok, #{json := Json}} ->
            Json;
        {error, #{body := Body, error := {invalid_json, _}}} ->
            {error, {invalid_cln_json, Body}};
        {error, Reason} ->
            {error, {cln_http_failed, Reason}}
    end.

cln_gun_opts(Host, Port, Options0) ->
    Transport = cln_transport(Host, Port, Options0),
    ProxyPolicy = cln_proxy_policy(Host, Transport, Options0),
    Options0#{
        transport => Transport,
        proxy => ProxyPolicy,
        http_opts => #{keepalive => infinity}
    }.

cln_transport(_Host, _Port, #{transport := Transport}) ->
    Transport;
cln_transport(Host, Port, _Options) ->
    case {normalize_host(Host), Port} of
        {"localhost", _} -> tcp;
        {"127.0.0.1", _} -> tcp;
        {"::1", _} -> tcp;
        {_, 3010} -> tcp;
        {_, 80} -> tcp;
        _ -> tls
    end.

cln_proxy_policy(_Host, _Transport, #{proxy := Proxy}) ->
    Proxy;
cln_proxy_policy(_Host, tcp, _Options) ->
    none;
cln_proxy_policy(Host, tls, _Options) ->
    %% Let damage_gun apply damage.proxy + damage.proxy_exclude.
    case damage_gun:proxy_for_host(Host) of
        none -> none;
        Proxy -> Proxy
    end.

normalize_host(H) when is_list(H) -> H;
normalize_host(H) when is_binary(H) -> binary_to_list(H).

maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
    ok.

maybe_cancel(undefined) ->
    ok;
maybe_cancel(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

%% ===================================================================
%% Normalization helpers
%% ===================================================================

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

normalize_peer(#{id := _} = M) ->
    M1 = M#{id := to_bin(maps:get(id, M))},
    M2 =
        case maps:get(host, M, undefined) of
            undefined -> M1;
            H -> M1#{host => to_bin(H)}
        end,
    case maps:get(port, M, undefined) of
        undefined -> M2;
        P when is_integer(P) -> M2#{port => P};
        P0 -> M2#{port => binary_to_integer(to_bin(P0))}
    end;
normalize_peer(Peer0) when is_binary(Peer0); is_list(Peer0) ->
    Peer = to_bin(Peer0),
    case binary:split(Peer, <<"@">>, [global]) of
        [Id] ->
            #{id => Id};
        [Id, HostPort] ->
            case binary:split(HostPort, <<":">>, [global]) of
                [H] -> #{id => Id, host => H, port => 9735};
                [H, P0] -> #{id => Id, host => H, port => binary_to_integer(P0)}
            end;
        _ ->
            #{id => Peer}
    end;
normalize_peer(Other) ->
    #{id => to_bin(Other)}.

btc_bin_to_sats(BtcBin) when is_binary(BtcBin) ->
    try
        F = list_to_float(binary_to_list(BtcBin)),
        {ok, trunc(F * 100000000)}
    catch
        _:_ -> error
    end.

parse_min_chan_size_sats(Msg0) ->
    Msg = to_bin(Msg0),
    case re:run(Msg, <<"min chan size of ([0-9]+(?:\\.[0-9]+)?) BTC">>, [{capture, [1], binary}]) of
        {match, [BtcBin]} -> btc_bin_to_sats(BtcBin);
        nomatch -> error
    end.

extract_min_open_sats(#{type := min_chan_size, min_sats := MinSats}) when is_integer(MinSats) ->
    {ok, MinSats};
extract_min_open_sats(Msg0) ->
    Msg = to_bin(Msg0),
    case parse_min_chan_size_sats(Msg) of
        {ok, MinSats} -> {ok, MinSats};
        error -> error
    end.

%% ===================================================================
%% Poolboy API wrappers
%% ===================================================================

getinfo() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, getinfo, ?CLN_HTTP_TIMEOUT)
    end).

list_invoices() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(
            Worker, {list_invoices, #{index => <<"created">>, limit => 10}}, ?CLN_HTTP_TIMEOUT
        )
    end).

list_invoices(Params) when is_map(Params) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {list_invoices, Params}, ?CLN_HTTP_TIMEOUT)
    end).

list_invoices_by_label(Label) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {list_invoices, #{label => Label}}, ?CLN_HTTP_TIMEOUT)
    end).

list_invoices_by_invoicestring(InvoiceString) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {list_invoices, #{invstring => InvoiceString}}, ?CLN_HTTP_TIMEOUT)
    end).

list_invoices_by_payment_hash(PaymentHash) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {list_invoices, #{payment_hash => PaymentHash}}, ?CLN_HTTP_TIMEOUT)
    end).

create_invoice(AmountMsats, Description) when
    is_integer(AmountMsats),
    AmountMsats > 0,
    (is_binary(Description) orelse is_list(Description))
->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(
            Worker,
            {create_invoice, AmountMsats, normalize_desc(Description), 3600, Label}
        )
    end).

create_invoice(AmountMsats, Description, Expiry) when
    is_integer(AmountMsats),
    AmountMsats > 0,
    (is_binary(Description) orelse is_list(Description)),
    is_integer(Expiry),
    Expiry > 0
->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(
            Worker,
            {create_invoice, AmountMsats, normalize_desc(Description), Expiry, Label}
        )
    end);
create_invoice(AmountMsats, Description, Label) when
    is_integer(AmountMsats),
    AmountMsats > 0,
    (is_binary(Description) orelse is_list(Description)),
    ((is_binary(Label) andalso Label =/= <<>>) orelse
        (is_list(Label) andalso Label =/= []))
->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(
            Worker,
            {create_invoice, AmountMsats, normalize_desc(Description), 3600, normalize_label(Label)}
        )
    end).

create_invoice(AmountMsats, Description, Expiry, Label) when
    is_integer(AmountMsats),
    AmountMsats > 0,
    (is_binary(Description) orelse is_list(Description)),
    is_integer(Expiry),
    Expiry > 0,
    ((is_binary(Label) andalso Label =/= <<>>) orelse
        (is_list(Label) andalso Label =/= []))
->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(
            Worker,
            {create_invoice, AmountMsats, normalize_desc(Description), Expiry,
                normalize_label(Label)}
        )
    end).
normalize_label(V) when is_binary(V), V =/= <<>> ->
    V;
normalize_label(V) when is_list(V), V =/= [] ->
    unicode:characters_to_binary(V).

normalize_desc(V) when is_binary(V) ->
    V;
normalize_desc(V) when is_list(V) ->
    unicode:characters_to_binary(V).

hold_invoice(Amount, Description, Expiry, Cltv) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {hold_invoice, Amount, Description, Expiry, Cltv})
    end).

hold_invoice_cancel(PaymentHash) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {hold_invoice_cancel, PaymentHash})
    end).

list_channels() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, list_channels, ?CLN_HTTP_TIMEOUT)
    end).

list_all_channels() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, list_all_channels, ?CLN_HTTP_TIMEOUT)
    end).

register_listener(Topic) when is_atom(Topic) ->
    gproc:reg({p, l, {cln_event, Topic}}).

find_best_peer_to_open() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, find_best_peer_to_open, ?CLN_HTTP_TIMEOUT)
    end).

find_best_peer_to_open(AmountSats) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {find_best_peer_to_open, AmountSats}, ?CLN_HTTP_TIMEOUT)
    end).

get_node_balance() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, get_node_balance, ?CLN_HTTP_TIMEOUT)
    end).

open_channels_with_best_peers() ->
    open_channels_with_best_peers(default_open_opts()).

open_channels_with_best_peers(Opts) when is_map(Opts) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {open_channels_with_best_peers, Opts}, ?CLN_HTTP_TIMEOUT)
    end).

connect_peers(Peers) when is_list(Peers) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_peers, Peers}, ?CLN_HTTP_TIMEOUT)
    end).
connect_peer(Peer) ->
    connect_peer(Peer, ?CLN_HTTP_TIMEOUT).

connect_peer(Peer, Timeout) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_peer, Peer}, Timeout)
    end).

connect_best_peers() ->
    connect_best_peers(#{}).

connect_best_peers(Opts) when is_map(Opts) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_best_peers, Opts}, ?CLN_HTTP_TIMEOUT)
    end).

pay_invoice(Bolt11) ->
    pay_invoice(Bolt11, #{}).

pay_invoice(Bolt11, Opts) ->
    poolboy:transaction(?MODULE, fun(W) ->
        gen_server:call(W, {pay_invoice, Bolt11, Opts}, ?CLN_HTTP_TIMEOUT)
    end).

verify_peer(NodeId) when is_binary(NodeId) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {verify_peer, NodeId})
    end).
newaddr() ->
    newaddr(<<"bech32">>).

newaddr(AddressType0) ->
    AddressType = to_bin(AddressType0),
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {newaddr, AddressType}, ?CLN_HTTP_TIMEOUT)
    end).

list_funds() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, list_funds, ?CLN_HTTP_TIMEOUT)
    end).

list_pays() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, list_pays, ?CLN_HTTP_TIMEOUT)
    end).

list_sendpays() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, list_sendpays, ?CLN_HTTP_TIMEOUT)
    end).

open_channel(NodeId, AmountSats) ->
    open_channel(NodeId, AmountSats, ?CLN_HTTP_TIMEOUT).

open_channel(NodeId, AmountSats, Timeout) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {open_channel, NodeId, AmountSats}, Timeout)
    end).
%% ===================================================================
%% Planning helpers
%% ===================================================================

default_open_opts() ->
    #{
        dry_run => false,
        verbose => true,
        inbound_mode => soft_boost,
        inbound_boost_weight => ?DEFAULT_INBOUND_BOOST_WEIGHT,
        min_inbound_ratio => ?DEFAULT_MIN_INBOUND_RATIO,
        target_msat => sats_to_msat(?DEFAULT_CHANNEL_OPEN_SATS),
        min_per_channel_msat => sats_to_msat(?DEFAULT_MIN_PER_CHANNEL_SATS),
        reserve_sats => ?DEFAULT_RESERVE_SATS,
        connect_before_open => true,
        max_open_attempts => 6,
        max_open_successes => 2
    }.

merge_open_opts(Opts) ->
    maps:merge(default_open_opts(), Opts).

-spec inbound_capacity_msat(binary(), [map()]) -> integer().
inbound_capacity_msat(NodeId, Channels) ->
    lists:foldl(
        fun
            (
                #{destination := NodeId1, amount_msat := Capacity, htlc_maximum_msat := HtlcMax},
                Acc
            ) when NodeId1 =:= NodeId ->
                Acc + min(Capacity, HtlcMax);
            (_, Acc) ->
                Acc
        end,
        0,
        Channels
    ).

-spec inbound_capacity(binary(), [map()]) -> integer().
inbound_capacity(NodeId, Channels) ->
    lists:foldl(
        fun
            (#{destination := NodeId1, amount_msat := AmountMsat}, Acc) when NodeId1 =:= NodeId ->
                Acc + (AmountMsat div 1000);
            (_, Acc) ->
                Acc
        end,
        0,
        Channels
    ).

-spec score_peers_for_opening([map()]) -> map().
score_peers_for_opening(ChannelList) ->
    score_peers_for_opening(ChannelList, 100000).

-spec score_peers_for_opening([map()], integer()) -> map().
score_peers_for_opening(ChannelList, MinSats) ->
    Now = erlang:system_time(second),
    TargetMsat = MinSats * 1000,
    lists:foldl(
        fun
            (
                #{
                    source := Src,
                    destination := Dst,
                    amount_msat := AmountMsat,
                    base_fee_millisatoshi := BaseFeeMsat,
                    fee_per_millionth := FeeRate,
                    last_update := LU,
                    active := true
                },
                Acc
            ) ->
                Sats = AmountMsat div 1000,
                PeerNodes = [Src, Dst],
                case Sats >= MinSats of
                    false ->
                        Acc;
                    true ->
                        FeeCostMsat = BaseFeeMsat + (TargetMsat * FeeRate div 1000000),
                        lists:foldl(
                            fun(NodeId, InnerAcc) ->
                                Score = compute_score(Sats, FeeCostMsat, LU, Now),
                                update_score(NodeId, Score, InnerAcc)
                            end,
                            Acc,
                            PeerNodes
                        )
                end;
            (#{active := false}, Acc) ->
                Acc
        end,
        #{},
        ChannelList
    ).

-spec score_candidates([map()], integer(), map()) ->
    [{binary(), float(), integer(), integer()}].
score_candidates(ChannelList, MinSats, Opts) ->
    BaseScores = score_peers_for_opening(ChannelList, MinSats),
    TargetMsat = maps:get(target_msat, Opts, MinSats * 1000),
    InMode = maps:get(inbound_mode, Opts, soft_boost),
    BoostW = maps:get(inbound_boost_weight, Opts, 1.0),
    lists:map(
        fun({NodeId, BaseScore}) ->
            InboundMsat = inbound_capacity_msat(NodeId, ChannelList),
            MinOpenMsat = sats_to_msat(get_peer_min_open_sats(NodeId)),
            InboundBoost =
                case InMode of
                    soft_boost ->
                        Ratio = InboundMsat / (TargetMsat + 1),
                        math:log10(1 + 9 * min(Ratio, 10));
                    _ ->
                        0.0
                end,
            {NodeId, BaseScore + InboundBoost * BoostW, InboundMsat, MinOpenMsat}
        end,
        maps:to_list(BaseScores)
    ).

sorted_open_candidates(ChannelList, ExistingPeers, Opts) ->
    TargetMsat = maps:get(target_msat, Opts),
    Candidates0 = score_candidates(ChannelList, TargetMsat div 1000, Opts),
    Candidates = [
        C
     || {NodeId, _Score, _InboundMsat, _MinOpenMsat} = C <- Candidates0,
        not sets:is_element(NodeId, ExistingPeers),
        not is_blacklisted(NodeId)
    ],
    lists:sort(
        fun({_, ScoreA, _, _}, {_, ScoreB, _, _}) ->
            ScoreA > ScoreB
        end,
        Candidates
    ).

build_plan_ctx(Host, Port, Options, Rune, BalanceSats, Opts) ->
    ReserveSats = maps:get(reserve_sats, Opts, ?DEFAULT_RESERVE_SATS),
    SpendableSats =
        case BalanceSats - ReserveSats of
            N when N =< 0 -> 0;
            N -> N
        end,
    #plan_ctx{
        host = Host,
        port = Port,
        options = Options,
        rune = Rune,
        target_msat = maps:get(target_msat, Opts),
        min_per_channel_msat = maps:get(min_per_channel_msat, Opts),
        spendable_msat = sats_to_msat(SpendableSats),
        opts = Opts,
        attempts_left = maps:get(max_open_attempts, Opts, 6),
        successes_left = maps:get(max_open_successes, Opts, 2)
    }.

try_ranked_peers_until_exhausted(#plan_ctx{attempts_left = 0}, _Sorted, SpendableLeftMsat) ->
    {[], [], SpendableLeftMsat};
try_ranked_peers_until_exhausted(#plan_ctx{successes_left = 0}, _Sorted, SpendableLeftMsat) ->
    {[], [], SpendableLeftMsat};
try_ranked_peers_until_exhausted(_PlanCtx, [], SpendableLeftMsat) ->
    {[], [], SpendableLeftMsat};
try_ranked_peers_until_exhausted(
    #plan_ctx{target_msat = TargetMsat, min_per_channel_msat = MinPer} = _PlanCtx,
    _Sorted,
    SpendableLeftMsat
) when SpendableLeftMsat < erlang:min(TargetMsat, MinPer) ->
    {[], [], SpendableLeftMsat};
try_ranked_peers_until_exhausted(
    PlanCtx = #plan_ctx{
        host = Host,
        port = Port,
        options = Options,
        rune = Rune,
        target_msat = TargetMsat,
        min_per_channel_msat = MinPerChannelMsat,
        opts = Opts
    },
    [{NodeId, _Score, InboundMsat, MinOpenMsat} | Rest],
    SpendableLeftMsat
) ->
    InMode = maps:get(inbound_mode, Opts, soft_boost),
    MinRatio = maps:get(min_inbound_ratio, Opts, 1.0),
    RequiredMsat = lists:max([TargetMsat, MinPerChannelMsat, MinOpenMsat]),
    case SpendableLeftMsat < RequiredMsat of
        true ->
            try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat);
        false ->
            InboundOk =
                case InMode of
                    hard_gate -> InboundMsat >= trunc(RequiredMsat * MinRatio);
                    _ -> true
                end,
            case InboundOk of
                false ->
                    try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat);
                true ->
                    attempt_ranked_peer(
                        #plan_ctx{
                            host = Host,
                            port = Port,
                            options = Options,
                            rune = Rune,
                            target_msat = TargetMsat,
                            min_per_channel_msat = MinPerChannelMsat,
                            opts = Opts
                        },
                        NodeId,
                        InboundMsat,
                        RequiredMsat,
                        Rest,
                        SpendableLeftMsat
                    )
            end
    end.

attempt_ranked_peer(PlanCtx, NodeId, InboundMsat, AmountMsat, Rest, SpendableLeftMsat) ->
    Opts = PlanCtx#plan_ctx.opts,
    DryRun = maps:get(dry_run, Opts, false),
    Verbose = maps:get(verbose, Opts, true),
    AmountSats = msat_to_sats(AmountMsat),
    NextPlanCtx = PlanCtx#plan_ctx{attempts_left = PlanCtx#plan_ctx.attempts_left - 1},
    case DryRun of
        true ->
            Verbose andalso
                ?LOG_INFO(
                    "DRYRUN would open ~s amount=~p msat (~p sats) inbound=~p msat remaining=~p msat",
                    [NodeId, AmountMsat, AmountSats, InboundMsat, SpendableLeftMsat]
                ),
            {Peers, Results, Spendable2} =
                SuccessPlanCtx = NextPlanCtx#plan_ctx{
                    successes_left = NextPlanCtx#plan_ctx.successes_left - 1
                },
            try_ranked_peers_until_exhausted(SuccessPlanCtx, Rest, SpendableLeftMsat),
            {
                [NodeId | Peers],
                [
                    #{
                        peer => NodeId,
                        dry_run => true,
                        ok => true,
                        action => would_open,
                        amount_msat => AmountMsat,
                        amount_sats => AmountSats,
                        inbound_msat => InboundMsat
                    }
                    | Results
                ],
                Spendable2
            };
        false ->
            maybe_connect_and_open(
                NextPlanCtx, NodeId, InboundMsat, AmountMsat, Rest, SpendableLeftMsat
            )
    end.

maybe_connect_and_open(
    PlanCtx = #plan_ctx{host = Host, port = Port, options = Options, rune = Rune, opts = Opts},
    NodeId,
    InboundMsat,
    AmountMsat,
    Rest,
    SpendableLeftMsat
) ->
    case maybe_connect_peer(Host, Port, Options, Rune, NodeId, Opts) of
        {error, ConnMsg} ->
            put_cache(
                peer_blacklist_key(NodeId),
                #{reason => ConnMsg, stage => connect},
                ?PEER_BLACKLIST_TTL_CONN
            ),
            {Peers, Results, Spendable2} =
                try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat),
            {
                Peers,
                [#{peer => NodeId, ok => false, error => ConnMsg, stage => connect} | Results],
                Spendable2
            };
        ok ->
            open_ranked_peer(PlanCtx, NodeId, InboundMsat, AmountMsat, Rest, SpendableLeftMsat)
    end.

open_ranked_peer(
    PlanCtx = #plan_ctx{host = Host, port = Port, options = Options, rune = Rune, opts = Opts},
    NodeId,
    InboundMsat,
    AmountMsat,
    Rest,
    SpendableLeftMsat
) ->
    AmountSats = msat_to_sats(AmountMsat),
    case open_channel_with_peer(Host, Port, Options, Rune, NodeId, AmountSats) of
        {ok, OkMap} ->
            {Peers, Results, Spendable2} =
                try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat - AmountMsat),
            {
                [NodeId | Peers],
                [
                    #{
                        peer => NodeId,
                        ok => true,
                        amount_msat => AmountMsat,
                        amount_sats => AmountSats,
                        result => OkMap
                    }
                    | Results
                ],
                Spendable2
            };
        {error, Msg} ->
            maybe_retry_open_with_peer_min(
                PlanCtx, NodeId, InboundMsat, Rest, SpendableLeftMsat, Msg, Opts
            )
    end.

maybe_retry_open_with_peer_min(PlanCtx, NodeId, InboundMsat, Rest, SpendableLeftMsat, Msg, Opts) ->
    InMode = maps:get(inbound_mode, Opts, soft_boost),
    MinRatio = maps:get(min_inbound_ratio, Opts, 1.0),
    case extract_min_open_sats(Msg) of
        {ok, MinSats} ->
            MinMsat = sats_to_msat(MinSats),
            RetryOk =
                MinMsat =< SpendableLeftMsat andalso
                    (InMode =/= hard_gate orelse InboundMsat >= trunc(MinMsat * MinRatio)),
            case RetryOk of
                true ->
                    retry_open_with_peer_min(
                        PlanCtx, NodeId, Rest, SpendableLeftMsat, MinSats, MinMsat
                    );
                false ->
                    cache_peer_min(NodeId, MinSats),
                    put_cache(
                        peer_blacklist_key(NodeId),
                        #{reason => Msg, min_sats => MinSats},
                        ?PEER_BLACKLIST_TTL_MIN
                    ),
                    append_failed_open_result(PlanCtx, Rest, SpendableLeftMsat, #{
                        peer => NodeId,
                        ok => false,
                        error => Msg,
                        stage => fundchannel
                    })
            end;
        error ->
            put_cache(
                peer_blacklist_key(NodeId),
                #{reason => Msg, stage => fundchannel_unknown},
                ?PEER_BLACKLIST_TTL_CONN
            ),
            append_failed_open_result(PlanCtx, Rest, SpendableLeftMsat, #{
                peer => NodeId,
                ok => false,
                error => Msg,
                stage => fundchannel_unknown
            })
    end.

retry_open_with_peer_min(
    PlanCtx = #plan_ctx{host = Host, port = Port, options = Options, rune = Rune},
    NodeId,
    Rest,
    SpendableLeftMsat,
    MinSats,
    MinMsat
) ->
    cache_peer_min(NodeId, MinSats),
    case open_channel_with_peer(Host, Port, Options, Rune, NodeId, MinSats) of
        {ok, OkMap2} ->
            {Peers, Results, Spendable2} =
                try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat - MinMsat),
            {
                [NodeId | Peers],
                [
                    #{
                        peer => NodeId,
                        ok => true,
                        amount_msat => MinMsat,
                        amount_sats => MinSats,
                        result => OkMap2
                    }
                    | Results
                ],
                Spendable2
            };
        {error, Msg2} ->
            put_cache(
                peer_blacklist_key(NodeId),
                #{reason => Msg2, min_sats => MinSats},
                ?PEER_BLACKLIST_TTL_MIN
            ),
            append_failed_open_result(PlanCtx, Rest, SpendableLeftMsat, #{
                peer => NodeId,
                ok => false,
                error => Msg2,
                stage => fundchannel_retry
            })
    end.

append_failed_open_result(PlanCtx, Rest, SpendableLeftMsat, Result) ->
    {Peers, Results, Spendable2} =
        try_ranked_peers_until_exhausted(PlanCtx, Rest, SpendableLeftMsat),
    {Peers, [Result | Results], Spendable2}.

compute_score(Sats, FeeCostMsat, LastUpdate, Now) ->
    CapacityScore = math:log10(Sats + 1),
    FeeScore = min(1000000 / (FeeCostMsat + 1), 1000),
    RecencyScore = 1.0 / (1.0 + (Now - LastUpdate) / 3600),
    CapacityScore + FeeScore * 0.3 + RecencyScore * 5.0.

update_score(NodeId, Score, Map) ->
    maps:update_with(NodeId, fun(S) -> S + Score end, Score, Map).

existing_peers(ChannelList) ->
    lists:foldl(
        fun(#{source := Src, destination := Dst}, Acc) ->
            Acc1 = sets:add_element(Src, Acc),
            sets:add_element(Dst, Acc1)
        end,
        sets:new(),
        ChannelList
    ).

top_five_nodes(ChannelList) ->
    ScoreMap = score_peers_for_opening(ChannelList),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A > B end, maps:to_list(ScoreMap)),
    lists:sublist(Sorted, 5).

estimate_routing_fee(Channel, AmountMsat) ->
    BaseFee = maps:get(base_fee_msat, Channel, 0),
    FeePPM = maps:get(fee_per_millionth, Channel, 0),
    BaseFee + ((AmountMsat * FeePPM) div 1000000).

%% ===================================================================
%% Channel / peer helpers
%% ===================================================================

peer_min_key(NodeId) -> {peer_min_open_sats, NodeId}.
peer_blacklist_key(NodeId) -> {peer_blacklist, NodeId}.

get_peer_min_open_sats(NodeId) ->
    case get_cache(peer_min_key(NodeId), ?PEER_MIN_TTL) of
        {ok, Min} when is_integer(Min) -> Min;
        _ -> 0
    end.

cache_peer_min(NodeId, MinSats) when is_integer(MinSats), MinSats > 0 ->
    put_cache(peer_min_key(NodeId), MinSats, ?PEER_MIN_TTL),
    ok;
cache_peer_min(_, _) ->
    ok.

blacklist_peer(NodeId, Reason, MinSats) ->
    ?LOG_DEBUG("cln: blacklist peer ~p reason ~p minsats ~p", [NodeId, Reason, MinSats]),
    put_cache(
        peer_blacklist_key(NodeId), #{reason => Reason, min_sats => MinSats}, ?PEER_BLACKLIST_TTL
    ),
    ok.

is_blacklisted(NodeId) ->
    case get_cache(peer_blacklist_key(NodeId), ?PEER_BLACKLIST_TTL) of
        {ok, _} -> true;
        _ -> false
    end.

maybe_connect_peer(Host, Port, Options, Rune, NodeId, Opts) ->
    DoConnect = maps:get(connect_before_open, Opts, true),
    Verbose = maps:get(verbose, Opts, true),
    case DoConnect of
        false ->
            ok;
        true ->
            case connect_peer_http(Host, Port, Options, Rune, NodeId) of
                {ok, _Res} ->
                    ok;
                {error, Msg} ->
                    Verbose andalso
                        ?LOG_INFO("connect_peer failed peer=~s reason=~p~n", [NodeId, Msg]),
                    {error, Msg}
            end
    end.

connect_peer_http(Host, Port, Options, Rune, Peer0) ->
    Peer = normalize_peer(Peer0),
    Req =
        case Peer of
            #{id := Id, host := H, port := P} -> #{id => Id, host => H, port => P};
            #{id := Id, host := H} -> #{id => Id, host => H};
            #{id := Id} -> #{id => Id}
        end,
    case cln_post_json(Host, Port, Options, Rune, "/v1/connect", Req) of
        #{code := _, message := Message} -> {error, Message};
        Body0 when is_map(Body0) -> {ok, Body0};
        Other -> {error, to_bin(Other)}
    end.

open_channel_with_peer(Host, Port, Options, Rune, NodeId, AmountSats) ->
    case
        cln_post_json(Host, Port, Options, Rune, "/v1/fundchannel", #{
            id => NodeId, amount => AmountSats
        })
    of
        #{code := _, data := #{id := NodeId, method := Method}, message := Message0} ->
            Message = to_bin(Message0),
            Err =
                case parse_min_chan_size_sats(Message) of
                    {ok, MinSats} ->
                        #{
                            type => min_chan_size,
                            min_sats => MinSats,
                            method => Method,
                            message => Message
                        };
                    error ->
                        Message
                end,
            ?LOG_INFO("Failed to open channel with ~p method ~p reason ~p", [
                NodeId, Method, Message
            ]),
            {error, Err};
        Body0 when is_map(Body0) ->
            {ok, Body0};
        Other ->
            {error, to_bin(Other)}
    end.

%% ===================================================================
%% Lookup / cache helpers
%% ===================================================================

channel_id_to_scid(CID0) when is_binary(CID0); is_list(CID0) ->
    CID = to_bin(CID0),
    case get_cache({cid, CID}) of
        {ok, SCID} ->
            SCID;
        not_found ->
            SCID = poolboy:transaction(?MODULE, fun(W) ->
                gen_server:call(W, {channel_id_to_scid_uncached, CID}, ?CLN_HTTP_TIMEOUT)
            end),
            put_cache({cid, CID}, SCID),
            put_cache({scid, SCID}, CID),
            SCID
    end.

get_cached_peer_channel_list(Host, Port, Options, Rune) ->
    case get_cache(listpeerchannels) of
        {ok, Cached} ->
            Cached;
        not_found ->
            Channels =
                case cln_post_json(Host, Port, Options, Rune, "/v1/listpeerchannels", #{}) of
                    #{channels := C} -> C;
                    _ -> []
                end,
            put_cache(listpeerchannels, Channels),
            Channels
    end.
get_cached_channel_list(Host, Port, Options, Headers, ReqMap) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(cln_channel_cache, listchannels) of
        [{listchannels, {Timestamp, Channels}}] when Now - Timestamp < ?CACHE_TTL_SECS ->
            Channels;
        [{listchannels, {Timestamp, Channels}}] when Now - Timestamp > ?CACHE_TTL_SECS ->
            ?LOG_INFO("Cache age ~p", [Now - Timestamp]),
            FreshChannels = fetch_channel_list(Host, Port, Options, Headers, ReqMap),
            ets:insert(cln_channel_cache, {listchannels, {Now, FreshChannels}}),
            Channels;
        _ ->
            Channels = fetch_channel_list(Host, Port, Options, Headers, ReqMap),
            ets:insert(cln_channel_cache, {listchannels, {Now, Channels}}),
            Channels
    end.

fetch_channel_list(Host, Port, Options, Headers, ReqMap) ->
    case cln_post_json_with_headers(Host, Port, Options, Headers, "/v1/listchannels", ReqMap) of
        Decoded when is_map(Decoded) -> maps:get(channels, Decoded, []);
        _ -> []
    end.

get_node_alias(Host, Port, Options, Rune, NodeId) ->
    case get_cache({node_alias, NodeId}) of
        {ok, Alias} ->
            Alias;
        not_found ->
            ?LOG_INFO("fetching aliases from node", []),
            Alias =
                case cln_post_json(Host, Port, Options, Rune, "/v1/listnodes", #{}) of
                    #{nodes := Nodes} ->
                        lists:foreach(
                            fun(N) ->
                                NId = maps:get(nodeid, N),
                                A = maps:get(alias, N, <<"unknown">>),
                                put_cache({node_alias, NId}, A)
                            end,
                            Nodes
                        ),
                        case
                            lists:keyfind(NodeId, 1, [
                                {maps:get(nodeid, N), maps:get(alias, N, <<"unknown">>)}
                             || N <- Nodes
                            ])
                        of
                            {_, A2} -> A2;
                            false -> <<"unknown">>
                        end;
                    _ ->
                        <<"unknown">>
                end,
            Alias
    end.

resolve_aliases(NodeIds, Host, Port, Options, Rune) ->
    lists:foldl(
        fun(NodeId, Acc) ->
            Alias = get_node_alias(Host, Port, Options, Rune, NodeId),
            maps:put(NodeId, Alias, Acc)
        end,
        #{},
        NodeIds
    ).

list_node_info(NodeId, Host, Port, Options, Rune) ->
    case cln_post_json(Host, Port, Options, Rune, "/v1/listnodes", #{id => NodeId}) of
        Body when is_map(Body) ->
            case maps:get(nodes, Body, []) of
                [NodeData | _] -> maps:with([alias, features, last_timestamp], NodeData);
                _ -> #{}
            end;
        _ ->
            #{}
    end.

list_channel_policies(NodeId, Host, Port, Options, Rune) ->
    case cln_post_json(Host, Port, Options, Rune, "/v1/listchannels", #{destination => NodeId}) of
        Body when is_map(Body) -> maps:get(channels, Body, []);
        _ -> []
    end.

get_node_balance(Host, Port, Options, Rune) ->
    Body = cln_post_json(Host, Port, Options, Rune, "/v1/listfunds", #{}),
    Outputs = maps:get(outputs, Body, []),
    Channels = maps:get(channels, Body, []),
    OnchainMsat =
        lists:foldl(
            fun(Output, Acc) ->
                Msat = maps:get(amount_msat, Output, 0),
                Status = maps:get(status, Output, <<"">>),
                Reserved = maps:get(reserved, Output, false),
                case {is_integer(Msat), Status, Reserved} of
                    {true, <<"confirmed">>, false} -> Acc + Msat;
                    _ -> Acc
                end
            end,
            0,
            Outputs
        ),
    ChannelMsat =
        lists:foldl(
            fun(Chan, Acc) ->
                OurMsat = maps:get(our_amount_msat, Chan, 0),
                Connected = maps:get(connected, Chan, false),
                State0 = maps:get(state, Chan, <<"">>),
                State =
                    case State0 of
                        S when is_binary(S) -> S;
                        S when is_list(S) -> list_to_binary(S);
                        _ -> <<"">>
                    end,
                case {is_integer(OurMsat), Connected, State} of
                    {true, true, <<"CHANNELD_NORMAL">>} -> Acc + OurMsat;
                    _ -> Acc
                end
            end,
            0,
            Channels
        ),
    #{
        onchain_msat => OnchainMsat,
        channel_msat => ChannelMsat,
        total_msat => OnchainMsat + ChannelMsat,
        onchain_sats => OnchainMsat div 1000,
        channel_sats => ChannelMsat div 1000,
        total_sats => (OnchainMsat + ChannelMsat) div 1000
    }.
clear_cache() ->
    ets:delete_all_objects(cln_channel_cache),
    ok.
%% ===================================================================
%% Gen server callbacks
%% ===================================================================

handle_call(
    {newaddr, AddressType0},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    AddressType = to_bin(AddressType0),
    ReqMap =
        case AddressType of
            <<"all">> ->
                #{};
            _ ->
                #{addresstype => AddressType}
        end,
    Reply =
        case cln_post_json(Host, Port, Options, Rune, "/v1/newaddr", ReqMap) of
            #{code := _, message := Message} ->
                {error, Message};
            Body when is_map(Body) ->
                {ok, Body};
            Other ->
                {error, to_bin(Other)}
        end,
    {reply, Reply, State};
handle_call(_Request, _From, #state{secrets_ready = false} = State) ->
    {reply, {error, secrets_not_ready}, State};
handle_call(
    {scid_to_channel_id_uncached, SCID},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Channels = cln_post_json(Host, Port, Options, Rune, "/v1/listpeerchannels", #{}),
    Match = lists:filter(
        fun
            (#{short_channel_id := S}) -> S == SCID;
            (_) -> false
        end,
        maps:get(channels, Channels, [])
    ),
    ChannelId =
        case Match of
            [#{channel_id := CID} | _] ->
                CID;
            ChannelId0 ->
                ?LOG_INFO("Channel cache ~p", [ChannelId0]),
                <<"not_found">>
        end,
    {reply, ChannelId, State};
handle_call(
    {channel_id_to_scid_uncached, CID},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Channels = cln_post_json(Host, Port, Options, Rune, "/v1/listpeerchannels", #{}),
    Match = lists:filter(
        fun
            (#{channel_id := ID}) -> ID == CID;
            (_) -> false
        end,
        maps:get(channels, Channels, [])
    ),
    SCID =
        case Match of
            [#{short_channel_id := SC} | _] -> SC;
            _ -> <<"not_found">>
        end,
    {reply, SCID, State};
handle_call(
    list_channels,
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    PeerChannels = get_cached_peer_channel_list(Host, Port, Options, Rune),
    NodeIds = lists:usort([maps:get(peer_id, Chan) || Chan <- PeerChannels]),
    Aliases = resolve_aliases(NodeIds, Host, Port, Options, Rune),

    lists:foreach(
        fun(Chan) ->
            PeerId = maps:get(peer_id, Chan, <<"unknown">>),
            PeerAlias = maps:get(PeerId, Aliases, <<"unknown">>),
            ChannelId = maps:get(channel_id, Chan, <<"not_found">>),
            ShortChannelId = maps:get(short_channel_id, Chan, <<"unknown">>),
            OurMsat = maps:get(to_us_msat, Chan, 0),
            TotalMsat = maps:get(total_msat, Chan, 0),
            TheirMsat = TotalMsat - OurMsat,
            Active = maps:get(peer_connected, Chan, false),
            StateName = maps:get(state, Chan, <<"unknown">>),

            Total = OurMsat + TheirMsat,
            Skew =
                if
                    Total =:= 0 -> 0;
                    true -> abs(OurMsat - TheirMsat) * 100 div Total
                end,
            RebalanceFlag =
                if
                    Skew > 80 -> " [⚠ needs rebalancing]";
                    true -> ""
                end,

            ?LOG_INFO(
                "Peer ~s (~s) channel_id=~s scid=~s connected=~p state=~p ours=~p msat theirs=~p msat~s",
                [
                    PeerAlias,
                    PeerId,
                    ChannelId,
                    ShortChannelId,
                    Active,
                    StateName,
                    OurMsat,
                    TheirMsat,
                    RebalanceFlag
                ]
            )
        end,
        PeerChannels
    ),
    {reply, PeerChannels, State};
handle_call(
    list_all_channels,
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    ChannelList = fetch_channel_list(Host, Port, Options, headers(Rune), #{}),
    {reply, ChannelList, State};
handle_call(find_best_peer_to_open, _From, State) ->
    do_find_best_peer_to_open(100000, State);
handle_call({find_best_peer_to_open, AmountSats}, _From, State) ->
    do_find_best_peer_to_open(AmountSats, State);
handle_call(
    get_node_balance,
    _From,
    #state{cln_host = Host, cln_port = Port, readonly_rune = Rune, options = Options} = State
) ->
    BalanceSats = get_node_balance(Host, Port, Options, Rune),
    {reply, BalanceSats, State};
handle_call(
    {open_channels_with_best_peers, UserOpts},
    From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Opts = merge_open_opts(UserOpts),
    Headers0 = headers(Rune),
    {reply, #{id := SourceNodeId}, _} = handle_call(getinfo, From, State),
    SelfChannels0 = fetch_channel_list(Host, Port, Options, Headers0, #{source => SourceNodeId}),
    SelfChannels1 = fetch_channel_list(Host, Port, Options, Headers0, #{destination => SourceNodeId}),
    SelfChannels = SelfChannels0 ++ SelfChannels1,
    #{onchain_sats := BalanceSats} = get_node_balance(Host, Port, Options, Rune),
    PlanCtx = build_plan_ctx(Host, Port, Options, Rune, BalanceSats, Opts),
    SpendableMsat = PlanCtx#plan_ctx.spendable_msat,
    SpendableSats = msat_to_sats(SpendableMsat),
    case SpendableSats =< 0 of
        true ->
            {reply, {error, insufficient_funds, BalanceSats}, State};
        false ->
            ChannelList = get_cached_channel_list(Host, Port, Options, Headers0, #{}),
            ExistingPeers = existing_peers(SelfChannels),
            Sorted = sorted_open_candidates(ChannelList, ExistingPeers, Opts),
            case Sorted of
                [] ->
                    {reply, {error, no_suitable_peers}, State};
                _ ->
                    {OpenedPeers, OpenResults, RemainingSpendableMsat} =
                        try_ranked_peers_until_exhausted(PlanCtx, Sorted, SpendableMsat),
                    Aliases = [
                        {NodeId, get_node_alias(Host, Port, Options, Rune, NodeId)}
                     || NodeId <- OpenedPeers
                    ],
                    Reply = #{
                        balance_sats => BalanceSats,
                        balance_msats => sats_to_msat(BalanceSats),
                        spendable_sats => SpendableSats,
                        spendable_msats => SpendableMsat,
                        remaining_spendable_sats => msat_to_sats(RemainingSpendableMsat),
                        remaining_spendable_msats => RemainingSpendableMsat,
                        target_msat => PlanCtx#plan_ctx.target_msat,
                        min_per_channel_msat => PlanCtx#plan_ctx.min_per_channel_msat,
                        channel_count => length(OpenedPeers),
                        peers => OpenedPeers,
                        aliases => Aliases,
                        results => OpenResults
                    },
                    {reply, Reply, State}
            end
    end;
handle_call(
    {verify_peer, NodeId},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    NodeInfo = list_node_info(NodeId, Host, Port, Options, Rune),
    ChannelPolicies = list_channel_policies(NodeId, Host, Port, Options, Rune),
    {reply, #{connectable => true, node_info => NodeInfo, channels => ChannelPolicies}, State};
handle_call(
    {list_invoices, Params},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Invoice = cln_post_json(Host, Port, Options, Rune, "/v1/listinvoices", Params),
    {reply, Invoice, State};
handle_call(
    getinfo, _From, #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Info = cln_post_json(Host, Port, Options, Rune, "/v1/getinfo", #{}),
    {reply, Info, State};
handle_call(
    {create_invoice, AmountMsats, Description, Expiry, Label},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    BaseReq = #{
        amount_msat => AmountMsats, label => Label, description => Description, expiry => Expiry
    },
    ReqMap =
        case byte_size(Description) > 640 of
            true ->
                ?LOG_DEBUG("create_invoice: description ~p bytes, enabling deschashonly", [
                    byte_size(Description)
                ]),
                BaseReq#{deschashonly => true};
            false ->
                BaseReq
        end,
    Invoice = cln_post_json(Host, Port, Options, Rune, "/v1/invoice", ReqMap),
    {reply, Invoice, State};
handle_call(
    {hold_invoice, Amount, Description, Expiry, CTLV},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    Invoice = cln_post_json(
        Host,
        Port,
        Options,
        Rune,
        "/v1/holdinvoice",
        #{
            amount_msat => Amount,
            label => Label,
            description => Description,
            expiry => Expiry,
            ctlv => CTLV
        }
    ),
    {reply, Invoice, State};
handle_call(
    {hold_invoice_cancel, PaymentHash},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Invoice = cln_post_json(Host, Port, Options, Rune, "/v1/holdinvoicecancel", #{
        payment_hash => PaymentHash
    }),
    {reply, Invoice, State};
handle_call(
    {pay_invoice, Bolt11, Opts},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    ReqMap = maps:merge(#{bolt11 => Bolt11}, Opts),
    case cln_post_json(Host, Port, Options, Rune, "/v1/pay", ReqMap) of
        {error, _} = E -> {reply, E, State};
        Reply -> {reply, Reply, State}
    end;
handle_call(
    {connect_peer, Peer0},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    case connect_peer_http(Host, Port, Options, Rune, Peer0) of
        {ok, Res} -> {reply, Res, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(
    {connect_peers, Peers},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Results = [
        begin
            case connect_peer_http(Host, Port, Options, Rune, P) of
                {ok, Res} -> #{peer => P, ok => true, result => Res};
                {error, Reason} -> #{peer => P, ok => false, error => Reason}
            end
        end
     || P <- Peers
    ],
    {reply, Results, State};
handle_call(
    {connect_best_peers, Opts},
    From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Headers0 = headers(Rune),
    N = maps:get(n, Opts, 300),
    MinInbound = maps:get(min_inbound_sats, Opts, 200000),
    MaxScan = maps:get(max_scan, Opts, 300),
    {reply, #{id := SourceNodeId}, _} = handle_call(getinfo, From, State),
    SelfChannels0 = fetch_channel_list(Host, Port, Options, Headers0, #{source => SourceNodeId}),
    SelfChannels1 = fetch_channel_list(Host, Port, Options, Headers0, #{destination => SourceNodeId}),
    SelfChannels = SelfChannels0 ++ SelfChannels1,
    ExistingPeers = existing_peers(SelfChannels),
    ChannelList = get_cached_channel_list(Host, Port, Options, Headers0, #{}),
    ScoreMap = score_peers_for_opening(ChannelList),
    ScoreList = maps:to_list(ScoreMap),
    Candidates0 = [
        begin
            Inbound = inbound_capacity(NodeId, ChannelList),
            {NodeId, Score, Inbound}
        end
     || {NodeId, Score} <- ScoreList,
        not sets:is_element(NodeId, ExistingPeers),
        not is_blacklisted(NodeId)
    ],
    Candidates = [C || C = {_NodeId, _Score, Inbound} <- Candidates0, Inbound >= MinInbound],
    Sorted = lists:sort(
        fun({_, ScoreA, InA}, {_, ScoreB, InB}) ->
            (ScoreA > ScoreB) orelse (ScoreA =:= ScoreB andalso InA > InB)
        end,
        Candidates
    ),
    ToTry = lists:sublist(Sorted, erlang:min(MaxScan, length(Sorted))),
    TopN = lists:sublist(ToTry, erlang:min(N, length(ToTry))),
    Results = [
        begin
            case connect_peer_http(Host, Port, Options, Rune, #{id => NodeId}) of
                {ok, Res} ->
                    #{peer => NodeId, ok => true, inbound_sats => Inbound, result => Res};
                {error, Reason} ->
                    put_cache(
                        peer_blacklist_key(NodeId),
                        #{reason => Reason, stage => connect},
                        ?PEER_BLACKLIST_TTL_CONN
                    ),
                    #{peer => NodeId, ok => false, inbound_sats => Inbound, error => Reason}
            end
        end
     || {NodeId, _Score, Inbound} <- TopN
    ],
    {reply,
        #{
            requested => N,
            considered => length(ToTry),
            connected => length([R || R = #{ok := true} <- Results]),
            results => Results
        },
        State};
handle_call(
    list_funds,
    _From,
    #state{cln_host = Host, cln_port = Port, readonly_rune = Rune, options = Options} = State
) ->
    Reply = cln_post_json(Host, Port, Options, Rune, "/v1/listfunds", #{}),
    {reply, Reply, State};
handle_call(
    list_pays,
    _From,
    #state{cln_host = Host, cln_port = Port, readonly_rune = Rune, options = Options} = State
) ->
    Reply = cln_post_json(Host, Port, Options, Rune, "/v1/listpays", #{}),
    {reply, Reply, State};
handle_call(
    list_sendpays,
    _From,
    #state{cln_host = Host, cln_port = Port, readonly_rune = Rune, options = Options} = State
) ->
    Reply = cln_post_json(Host, Port, Options, Rune, "/v1/listsendpays", #{}),
    {reply, Reply, State};
handle_call(
    {open_channel, NodeId, AmountSats},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Reply = open_channel_with_peer(Host, Port, Options, Rune, to_bin(NodeId), AmountSats),
    {reply, Reply, State};
handle_call(
    {sql, #{query := Query0}},
    _From,
    #state{
        cln_host = Host,
        cln_port = Port,
        readonly_rune = _Rune,
        rune = Rune,
        options = Options
    } = State
) ->
    Query = to_bin(Query0),
    Reply =
        case {Rune, Query} of
            {undefined, _} ->
                {error, readonly_rune_not_configured};
            {_, <<>>} ->
                {error, empty_sql_query};
            _ ->
                cln_post_json(
                    Host,
                    Port,
                    Options,
                    Rune,
                    "/v1/sql",
                    #{query => Query}
                )
        end,
    {reply, Reply, State};
handle_call(Request, From, State) ->
    ?LOG_ERROR("handle_call got unknown ~p, From ~p, State ~p", [Request, From, State]),
    {reply, err, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("handle_cast got unknown on gun websocket cast ~p,  State ~p", [Msg, State]),
    {noreply, State}.

handle_info({gun_response, ConnPid, _, _, _Status, _Headers}, #state{conn_pid = ConnPid} = State) ->
    {noreply, State};
handle_info({gun_error, _ConnPid, _StreamRef, {badstate, "The stream cannot be found."}}, State) ->
    {noreply, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    ?LOG_ERROR("got gun error ConnPid ~p, StreamRef ~p, \nReason ~p", [ConnPid, StreamRef, Reason]),
    {noreply, State};
handle_info({gun_down, ConnPid, _Reason}, State) when ConnPid =:= State#state.conn_pid ->
    {stop, normal, State};
handle_info({gun_up, _, _}, State) ->
    {noreply, State};
handle_info({gun_down, _, ws, normal, _}, State) ->
    ?LOG_DEBUG("cln websocket down", []),
    {noreply, State};
handle_info(retry_secrets, State0) ->
    case load_runes(State0) of
        {ok, State1} ->
            maybe_cancel(State0#state.retry_timer),
            {noreply, State1#state{secrets_ready = true, retry_timer = undefined}};
        {error, _} ->
            TRef = erlang:send_after(?SECRETS_RETRY_MS, self(), retry_secrets),
            {noreply, State0#state{retry_timer = TRef, secrets_ready = false}}
    end;
handle_info(Info, State) ->
    ?LOG_DEBUG("Unknown info ~p", [Info]),
    {noreply, State}.

terminate(Reason, State) ->
    maybe_close_gun(State#state.conn_pid),
    maybe_cancel(State#state.retry_timer),
    ?LOG_ERROR("Terminating clnconnect ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Invoice pagination helpers
%% -------------------------------------------------------------------
%% Opts supported:
%%   #{
%%      start => non_neg_integer(),
%%      page_limit => pos_integer(),
%%      min_created_index => non_neg_integer(),
%%      unpaid_only => boolean(),
%%      paid_only => boolean(),
%%      expired_only => boolean(),
%%      unexpired_only => boolean(),
%%      label_prefix => binary() | list(),
%%      min_expires_at => integer(),   %% absolute unix seconds
%%      max_expires_at => integer()    %% absolute unix seconds
%%    }
%%
%% Returns:
%%   {ok, [Invoice]}
%%   {error, Reason}
%% -------------------------------------------------------------------

list_all_invoices() ->
    list_all_invoices(#{}).

list_all_invoices(Opts0) when is_map(Opts0) ->
    Start = maps:get(start, Opts0, 0),
    PageLimit = maps:get(page_limit, Opts0, ?DEFAULT_LIST_INVOICES_PAGE_LIMIT),
    Order = maps:get(order, Opts0, desc),
    Filters = normalize_invoice_filters(Opts0),
    case list_all_invoices_page(Start, PageLimit, Filters, []) of
        {ok, Invoices} ->
            Sorted =
                case Order of
                    desc ->
                        sort_invoices_desc(Invoices);
                    asc ->
                        lists:sort(
                            fun(A, B) -> invoice_sort_key(A) =< invoice_sort_key(B) end,
                            Invoices
                        );
                    _ ->
                        sort_invoices_desc(Invoices)
                end,
            {ok, Sorted};
        Error ->
            Error
    end.

list_all_invoices_page(Start, PageLimit, Filters, Acc) ->
    Params = #{
        index => <<"created">>,
        start => Start,
        limit => PageLimit
    },
    case list_invoices(Params) of
        #{invoices := Invoices} when is_list(Invoices) ->
            Filtered = filter_invoices(Invoices, Filters),
            NewAcc = lists:reverse(Filtered, Acc),
            case Invoices of
                [] ->
                    {ok, lists:reverse(NewAcc)};
                _ ->
                    NextStart = next_invoice_created_start(Invoices, Start),
                    case length(Invoices) < PageLimit of
                        true ->
                            {ok, lists:reverse(NewAcc)};
                        false when NextStart =< Start ->
                            {error, {invalid_invoice_pagination_cursor, Start, NextStart}};
                        false ->
                            list_all_invoices_page(NextStart, PageLimit, Filters, NewAcc)
                    end
            end;
        Other ->
            {error, {unexpected_list_invoices_result, Other}}
    end.

normalize_invoice_filters(Opts0) ->
    #{
        min_created_index => maps:get(min_created_index, Opts0, undefined),
        unpaid_only => maps:get(unpaid_only, Opts0, false),
        paid_only => maps:get(paid_only, Opts0, false),
        expired_only => maps:get(expired_only, Opts0, false),
        unexpired_only => maps:get(unexpired_only, Opts0, false),
        label_prefix => normalize_optional_binary(maps:get(label_prefix, Opts0, undefined)),
        min_expires_at => maps:get(min_expires_at, Opts0, undefined),
        max_expires_at => maps:get(max_expires_at, Opts0, undefined)
    }.

filter_invoices(Invoices, Filters) ->
    [I || I <- Invoices, invoice_matches_filters(I, Filters)].

invoice_matches_filters(Invoice, Filters) ->
    created_index_matches(Invoice, maps:get(min_created_index, Filters, undefined)) andalso
        status_matches(
            Invoice,
            maps:get(unpaid_only, Filters, false),
            maps:get(paid_only, Filters, false),
            maps:get(expired_only, Filters, false)
        ) andalso
        label_prefix_matches(Invoice, maps:get(label_prefix, Filters, undefined)) andalso
        expiry_matches(
            Invoice,
            maps:get(unexpired_only, Filters, false),
            maps:get(min_expires_at, Filters, undefined),
            maps:get(max_expires_at, Filters, undefined)
        ).

created_index_matches(_Invoice, undefined) ->
    true;
created_index_matches(Invoice, MinCreatedIndex) when is_integer(MinCreatedIndex) ->
    case invoice_created_index(Invoice) of
        N when is_integer(N) -> N >= MinCreatedIndex;
        undefined -> false
    end.

status_matches(_Invoice, false, false, false) ->
    true;
status_matches(Invoice, UnpaidOnly, PaidOnly, ExpiredOnly) ->
    Status = invoice_status(Invoice),
    ((not UnpaidOnly) orelse Status =:= <<"unpaid">>) andalso
        ((not PaidOnly) orelse Status =:= <<"paid">>) andalso
        ((not ExpiredOnly) orelse Status =:= <<"expired">>).

label_prefix_matches(_Invoice, undefined) ->
    true;
label_prefix_matches(Invoice, Prefix) when is_binary(Prefix), Prefix =/= <<>> ->
    case invoice_label(Invoice) of
        Label when is_binary(Label) ->
            binary:longest_common_prefix([Label, Prefix]) =:= byte_size(Prefix);
        _ ->
            false
    end.

expiry_matches(Invoice, UnexpiredOnly, MinExpiresAt, MaxExpiresAt) ->
    ExpiresAt = invoice_expires_at(Invoice),
    unexpired_only_matches(ExpiresAt, UnexpiredOnly) andalso
        min_expires_at_matches(ExpiresAt, MinExpiresAt) andalso
        max_expires_at_matches(ExpiresAt, MaxExpiresAt).

unexpired_only_matches(_ExpiresAt, false) ->
    true;
unexpired_only_matches(ExpiresAt, true) when is_integer(ExpiresAt) ->
    ExpiresAt > erlang:system_time(second);
unexpired_only_matches(_ExpiresAt, true) ->
    false.

min_expires_at_matches(_ExpiresAt, undefined) ->
    true;
min_expires_at_matches(ExpiresAt, MinExpiresAt) when is_integer(ExpiresAt) ->
    ExpiresAt >= MinExpiresAt;
min_expires_at_matches(_ExpiresAt, _MinExpiresAt) ->
    false.

max_expires_at_matches(_ExpiresAt, undefined) ->
    true;
max_expires_at_matches(ExpiresAt, MaxExpiresAt) when is_integer(ExpiresAt) ->
    ExpiresAt =< MaxExpiresAt;
max_expires_at_matches(_ExpiresAt, _MaxExpiresAt) ->
    false.

next_invoice_created_start(Invoices, FallbackStart) ->
    MaxCreatedIndex =
        lists:foldl(
            fun(Invoice, Acc) ->
                case invoice_created_index(Invoice) of
                    N when is_integer(N), N > Acc -> N;
                    _ -> Acc
                end
            end,
            FallbackStart - 1,
            Invoices
        ),
    case MaxCreatedIndex >= FallbackStart of
        true -> MaxCreatedIndex + 1;
        false -> FallbackStart
    end.

invoice_created_index(#{created_index := N}) when is_integer(N) -> N;
invoice_created_index(#{<<"created_index">> := N}) when is_integer(N) -> N;
invoice_created_index(_) -> undefined.

invoice_expires_at(#{expires_at := N}) when is_integer(N) -> N;
invoice_expires_at(#{<<"expires_at">> := N}) when is_integer(N) -> N;
invoice_expires_at(#{expiry_time := N}) when is_integer(N) -> N;
invoice_expires_at(#{<<"expiry_time">> := N}) when is_integer(N) -> N;
invoice_expires_at(_) -> undefined.

invoice_label(#{label := L}) -> normalize_optional_binary(L);
invoice_label(#{<<"label">> := L}) -> normalize_optional_binary(L);
invoice_label(_) -> undefined.

invoice_status(#{status := S}) ->
    normalize_invoice_status(S);
invoice_status(#{<<"status">> := S}) ->
    normalize_invoice_status(S);
invoice_status(#{state := S}) ->
    normalize_invoice_status(S);
invoice_status(#{<<"state">> := S}) ->
    normalize_invoice_status(S);
invoice_status(_) ->
    undefined.

normalize_invoice_status(S) when is_binary(S) ->
    string:lowercase(S);
normalize_invoice_status(S) when is_list(S) ->
    binary:lowercase(unicode:characters_to_binary(S));
normalize_invoice_status(S) when is_atom(S) ->
    binary:lowercase(atom_to_binary(S, utf8));
normalize_invoice_status(_) ->
    undefined.

normalize_optional_binary(undefined) ->
    undefined;
normalize_optional_binary(V) when is_binary(V) ->
    V;
normalize_optional_binary(V) when is_list(V) ->
    unicode:characters_to_binary(V);
normalize_optional_binary(_) ->
    undefined.

%% -------------------------------------------------------------------
%% Low-level SQL wrapper
%% -------------------------------------------------------------------

sql(Query) when is_list(Query) ->
    sql(list_to_binary(Query));
sql(Query) when is_binary(Query), Query =/= <<>> ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {sql, #{query => Query}}, ?CLN_HTTP_TIMEOUT)
    end).

sql_rows(Query) ->
    case sql(Query) of
        #{rows := Rows} when is_list(Rows) -> {ok, Rows};
        Other -> {error, {unexpected_sql_result, Other}}
    end.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

sql_quote(V0) ->
    V = to_bin(V0),
    Esc = binary:replace(V, <<"'">>, <<"''">>, [global]),
    <<"'", Esc/binary, "'">>.

sql_limit(N) when is_integer(N), N > 0 ->
    integer_to_binary(N);
sql_limit(_) ->
    <<"50">>.

sql_unix_ts(Ts) when is_integer(Ts), Ts >= 0 ->
    integer_to_binary(Ts).

rows_to_maps(Cols, Rows) ->
    [
        maps:from_list(lists:zip(Cols, Row))
     || Row <- Rows, is_list(Row)
    ].

%% -------------------------------------------------------------------
%% Invoice canned queries
%% -------------------------------------------------------------------

recent_invoices(Limit) ->
    recent_invoices(<<"">>, Limit).

recent_invoices(LabelPrefix, Limit) ->
    Prefix =
        case to_bin(LabelPrefix) of
            <<>> -> <<"%">>;
            P -> <<P/binary, "%">>
        end,
    Q = iolist_to_binary([
        "SELECT label, description, status, amount_msat, amount_received_msat, ",
        "expires_at, created_index, updated_index, paid_at, payment_hash, bolt11 ",
        "FROM invoices ",
        "WHERE label LIKE ",
        sql_quote(Prefix),
        " ",
        "ORDER BY created_index DESC ",
        "LIMIT ",
        sql_limit(Limit)
    ]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [
                        label,
                        description,
                        status,
                        amount_msat,
                        amount_received_msat,
                        expires_at,
                        created_index,
                        updated_index,
                        paid_at,
                        payment_hash,
                        bolt11
                    ],
                    Rows
                )};
        Error ->
            Error
    end.

unpaid_invoices(Limit) ->
    unpaid_invoices(<<"">>, Limit).

unpaid_invoices(LabelPrefix, Limit) ->
    Prefix =
        case to_bin(LabelPrefix) of
            <<>> -> <<"%">>;
            P -> <<P/binary, "%">>
        end,
    Q = iolist_to_binary([
        "SELECT label, description, status, amount_msat, expires_at, created_index, payment_hash, bolt11 ",
        "FROM invoices ",
        "WHERE status = 'unpaid' ",
        "AND label LIKE ",
        sql_quote(Prefix),
        " ",
        "ORDER BY created_index DESC ",
        "LIMIT ",
        sql_limit(Limit)
    ]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [
                        label,
                        description,
                        status,
                        amount_msat,
                        expires_at,
                        created_index,
                        payment_hash,
                        bolt11
                    ],
                    Rows
                )};
        Error ->
            Error
    end.

paid_invoices_since(SinceTs, Limit) when is_integer(SinceTs), SinceTs >= 0 ->
    Q = iolist_to_binary([
        "SELECT label, description, status, amount_msat, amount_received_msat, paid_at, created_index, payment_hash ",
        "FROM invoices ",
        "WHERE status = 'paid' ",
        "AND paid_at IS NOT NULL ",
        "AND paid_at >= ",
        sql_unix_ts(SinceTs),
        " ",
        "ORDER BY paid_at DESC ",
        "LIMIT ",
        sql_limit(Limit)
    ]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [
                        label,
                        description,
                        status,
                        amount_msat,
                        amount_received_msat,
                        paid_at,
                        created_index,
                        payment_hash
                    ],
                    Rows
                )};
        Error ->
            Error
    end.

invoice_counts_by_status() ->
    Q = <<
        "SELECT status, COUNT(*) AS count, "
        "COALESCE(SUM(amount_msat), 0) AS total_amount_msat, "
        "COALESCE(SUM(amount_received_msat), 0) AS total_received_msat "
        "FROM invoices "
        "GROUP BY status "
        "ORDER BY status ASC"
    >>,
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok, rows_to_maps([status, count, total_amount_msat, total_received_msat], Rows)};
        Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% Account / bkpr canned queries
%% -------------------------------------------------------------------

recent_account_events(Account, Limit) ->
    recent_account_events(Account, undefined, Limit).

recent_account_events(Account0, Tag0, Limit) ->
    Account = to_bin(Account0),
    Base = [
        "SELECT account, type, tag, credit_msat, debit_msat, fees_msat, currency, ",
        "timestamp, description, outpoint, blockheight, origin, is_rebalance ",
        "FROM bkpr_accountevents ",
        "WHERE account = ",
        sql_quote(Account),
        " "
    ],
    TagSql =
        case Tag0 of
            undefined -> [];
            <<>> -> [];
            _ -> ["AND tag = ", sql_quote(to_bin(Tag0)), " "]
        end,
    Q = iolist_to_binary([
        Base,
        TagSql,
        "ORDER BY timestamp DESC ",
        "LIMIT ",
        sql_limit(Limit)
    ]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [
                        account,
                        type,
                        tag,
                        credit_msat,
                        debit_msat,
                        fees_msat,
                        currency,
                        timestamp,
                        description,
                        outpoint,
                        blockheight,
                        origin,
                        is_rebalance
                    ],
                    Rows
                )};
        Error ->
            Error
    end.

account_event_summary(Account0) ->
    account_event_summary(Account0, undefined).

account_event_summary(Account0, Tag0) ->
    Account = to_bin(Account0),
    Base = [
        "SELECT account, ",
        "COUNT(*) AS event_count, ",
        "COALESCE(SUM(credit_msat), 0) AS total_credit_msat, ",
        "COALESCE(SUM(debit_msat), 0) AS total_debit_msat, ",
        "COALESCE(SUM(fees_msat), 0) AS total_fees_msat ",
        "FROM bkpr_accountevents ",
        "WHERE account = ",
        sql_quote(Account),
        " "
    ],
    TagSql =
        case Tag0 of
            undefined -> [];
            <<>> -> [];
            _ -> ["AND tag = ", sql_quote(to_bin(Tag0)), " "]
        end,
    Q = iolist_to_binary([Base, TagSql, "GROUP BY account"]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [account, event_count, total_credit_msat, total_debit_msat, total_fees_msat],
                    Rows
                )};
        Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% Operator / channel canned queries
%% -------------------------------------------------------------------

recent_peerchannels(Limit) ->
    Q = iolist_to_binary([
        "SELECT peer_id, short_channel_id, to_us_msat, total_msat, ",
        "peerchannels_status.status, state_change_cause ",
        "FROM peerchannels ",
        "INNER JOIN peerchannels_status ON peerchannels_status.row = peerchannels.rowid ",
        "ORDER BY peerchannels.rowid DESC ",
        "LIMIT ",
        sql_limit(Limit)
    ]),
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps(
                    [peer_id, short_channel_id, to_us_msat, total_msat, status, state_change_cause],
                    Rows
                )};
        Error ->
            Error
    end.

peerchannel_summary() ->
    Q = <<
        "SELECT peerchannels_status.status, "
        "COUNT(*) AS channel_count, "
        "COALESCE(SUM(to_us_msat), 0) AS total_to_us_msat, "
        "COALESCE(SUM(total_msat), 0) AS total_capacity_msat "
        "FROM peerchannels "
        "INNER JOIN peerchannels_status ON peerchannels_status.row = peerchannels.rowid "
        "GROUP BY peerchannels_status.status "
        "ORDER BY channel_count DESC"
    >>,
    case sql_rows(Q) of
        {ok, Rows} ->
            {ok,
                rows_to_maps([status, channel_count, total_to_us_msat, total_capacity_msat], Rows)};
        Error ->
            Error
    end.

%% ===================================================================
%% Misc entry points
%% ===================================================================

test() ->
    test_listchannels().

test_listchannels() ->
    list_channels().

do_find_best_peer_to_open(
    AmountSats, #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Headers0 = headers(Rune),
    ChannelList = get_cached_channel_list(Host, Port, Options, Headers0, #{}),
    ScoreMap = score_peers_for_opening(ChannelList, AmountSats),
    NodeIds = maps:keys(ScoreMap),
    AliasesMap = resolve_aliases(NodeIds, Host, Port, Options, Rune),
    InboundMap =
        lists:foldl(
            fun
                (#{destination := Dst, amount_msat := MSats}, Acc) ->
                    maps:update_with(Dst, fun(V) -> V + MSats end, MSats, Acc);
                (_, Acc) ->
                    Acc
            end,
            #{},
            ChannelList
        ),
    Candidates = [
        begin
            Alias = maps:get(NodeId, AliasesMap, <<"unknown">>),
            Inbound = maps:get(NodeId, InboundMap, 0),
            {NodeId, Alias, Score, Inbound}
        end
     || {NodeId, Score} <- maps:to_list(ScoreMap)
    ],
    Suitable = [
        C
     || C = {_NodeId, _Alias, _Score, Inbound} <- Candidates, Inbound >= sats_to_msat(AmountSats)
    ],
    ?LOG_DEBUG("Suitable Candidates ~p", [Suitable]),
    Sorted = lists:sort(
        fun({_, _, ScoreA, InboundA}, {_, _, ScoreB, InboundB}) ->
            (ScoreA > ScoreB) orelse (ScoreA =:= ScoreB andalso InboundA > InboundB)
        end,
        Suitable
    ),
    Top5 = lists:sublist(Sorted, 5),
    {reply, Top5, State}.
