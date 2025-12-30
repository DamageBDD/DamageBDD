-module(cln).

-behaviour(gen_server).

%% API Functions

-export(
    [
        start_link/1,
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).
-export(
    [
        getinfo/0,
        create_invoice/2,
        create_invoice/3,
        create_invoice/4,
        hold_invoice/4,
        hold_invoice_cancel/1,
        list_invoices/0,
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
        inbound_capacity/2,
        verify_peer/1,
        estimate_routing_fee/2,
        subscribe/0
    ]
).
-export([register_listener/1]).
-export([broadcast/2]).
-export([existing_peers/1]).
-export([
    connect_peer/1,
    connect_peers/1,
    connect_best_peers/0,
    connect_best_peers/1,
    blacklist_peer/3
]).

-export([test/0]).
% 5 minutes in ms
-define(CACHE_TTL, 300000).
-define(CLN_HTTP_TIMEOUT, 300000).
%% 7 days in ms
-define(PEER_MIN_TTL, 604800000).
%% 24h in ms
-define(PEER_BLACKLIST_TTL, 86400000).
%% 24h for min-size rejects
-define(PEER_BLACKLIST_TTL_MIN, 86400000).
%% 6h for connect/init failures
-define(PEER_BLACKLIST_TTL_CONN, 21600000).

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
    options :: map(),
    heartbeat_timer = undefined
}).

%% API Functions

start_link([]) -> gen_server:start_link(?MODULE, [], []);
start_link([ws]) -> gen_server:start_link(?MODULE, [ws], []).

get_cln_client_config() ->
    {ok, Host} = application:get_env(damage, cln_host),
    {ok, Port} = application:get_env(damage, cln_port),
    {ok, Path} = application:get_env(damage, cln_wspath),
    {ok, CaCertFile} = application:get_env(damage, cln_cacertfile),
    {ok, CertFile} = application:get_env(damage, cln_certfile),
    {ok, KeyFile} = application:get_env(damage, cln_keyfile),
    TLSOptions =
        [
            {certfile, CertFile},
            {keyfile, KeyFile},
            {cacertfile, CaCertFile},
            % This ensures the server's certificate is verified
            {verify, verify_peer},
            % Ensure compatibility with recent TLS versions
            {versions, ['tlsv1.2', 'tlsv1.3']},
            % HTTP2 or HTTP/1.1, depending on your setup
            {alpn_protocols, ['http/1.1', h2]}
        ],
    Options =
        case Host of
            "localhost" -> #{};
            _ -> #{transport => tls, tls_opts => TLSOptions}
        end,
    State =
        #state{
            cln_host = Host,
            cln_port = Port,
            cln_wspath = Path,
            cln_certfile = CertFile,
            cln_keyfile = KeyFile,
            options = Options
        },
    case secrets:retrieve_decrypt(cln_rune) of
        {ok, RuneBin} ->
            State#state{rune = RuneBin};
        Error ->
            ?LOG_INFO("!!!! CLN Integration disabled, set `cln_rune` secret. ~p", [Error]),
            State#state{rune = <<"">>}
    end.

init([]) ->
    ?LOG_INFO("cln started"),
    case catch ets:new(cln_channel_cache, [set, public, named_table, {read_concurrency, true}]) of
        {badarg, exists} ->
            ?LOG_DEBUG("cln_channel_cache exists");
        _ ->
            ?LOG_DEBUG("cln_channel_cache created")
    end,
    State = get_cln_client_config(),
    HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
    ?LOG_DEBUG("State ~p ", [State]),
    {ok, State#state{
        heartbeat_timer = HeartbeatTimer
    }};
init([ws]) ->
    {ok, State} = init([]),
    ?LOG_INFO("cln ws started"),
    case secrets:retrieve_decrypt(cln_readonly_rune) of
        {ok, ReadOnlyRuneBin} ->
            {ok, ConnPid} = gun:open(
                State#state.cln_host, State#state.cln_port, State#state.options
            ),
            ?LOG_DEBUG("cln websocket upgrade using rune ~p", [ReadOnlyRuneBin]),
            StreamRef = gun:ws_upgrade(ConnPid, "/socket.io/?EIO=4&transport=websocket", [
                {<<"rune">>, ReadOnlyRuneBin}
            ]),

            ?LOG_DEBUG("cln websocket upgrade successfull ~p", [ConnPid]),
            {ok, State#state{
                conn_pid = ConnPid,
                streamref = StreamRef
            }};
        Error ->
            ?LOG_INFO("!!!! CLN Integration disabled, set `cln_rune` secret. ~p", [Error]),
            {ok, #state{}}
    end.

put_cache(Key, Value) ->
    put_cache(Key, Value, ?CACHE_TTL).

put_cache(Key, Value, TTLms) ->
    ets:insert(cln_channel_cache, {Key, {Value, erlang:monotonic_time(millisecond), TTLms}}).

get_cache(Key) ->
    get_cache(Key, ?CACHE_TTL).

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
            %% legacy entries created before TTL support
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

scid_to_channel_id(SCID0) when is_binary(SCID0); is_list(SCID0) ->
    SCID = size(SCID0),
    case get_cache({scid, SCID}) of
        {ok, CID} ->
            CID;
        not_found ->
            CID = poolboy:transaction(?MODULE, fun(W) ->
                gen_server:call(W, {scid_to_channel_id_uncached, SCID}, ?CLN_HTTP_TIMEOUT)
            end),
            put_cache({scid, SCID}, CID),
            put_cache({cid, CID}, SCID),
            CID
    end.
channel_id_to_scid(CID0) when is_binary(CID0); is_list(CID0) ->
    CID = size(CID0),
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

get_channel_balances(Host, Port, Options, Rune) ->
    case get_cache(channel_balances) of
        {ok, Cached} ->
            Cached;
        not_found ->
            Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
            {ok, ConnPid} = gun:open(Host, Port, Options),
            Path = "/v1/listpeerchannels",
            ReqJson = jsx:encode(#{}),
            StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
            Result =
                case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
                    {response, fin, _Status, _} ->
                        #{};
                    {response, nofin, _Status, _} ->
                        {ok, Body} = gun:await_body(ConnPid, StreamRef),
                        case jsx:decode(Body, [return_maps, {labels, atom}]) of
                            #{channels := Channels} ->
                                lists:foldl(
                                    fun(Chan, Acc) ->
                                        ChannelId = maps:get(channel_id, Chan),
                                        OurMsat = maps:get(to_us_msat, Chan),
                                        TheirMsat = maps:get(total_msat, Chan) - OurMsat,
                                        maps:put(
                                            ChannelId, #{ours => OurMsat, theirs => TheirMsat}, Acc
                                        )
                                    end,
                                    #{},
                                    Channels
                                );
                            _ ->
                                #{}
                        end;
                    _ ->
                        #{}
                end,
            gun:cancel(ConnPid, StreamRef),
            gun:close(ConnPid),
            put_cache(channel_balances, Result),
            Result
    end.

get_node_alias(Host, Port, Options, Rune, NodeId) ->
    case get_cache({node_alias, NodeId}) of
        {ok, Alias} ->
            ?LOG_INFO("got alias from cache ~p", [Alias]),
            Alias;
        not_found ->
            ?LOG_INFO("fetching aliases from node", []),
            Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
            {ok, ConnPid} = gun:open(Host, Port, Options),
            Path = "/v1/listnodes",
            ReqJson = jsx:encode(#{}),
            StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),

            Alias =
                case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
                    {response, nofin, _Status, _} ->
                        {ok, Body} = gun:await_body(ConnPid, StreamRef),
                        case jsx:decode(Body, [return_maps, {labels, atom}]) of
                            #{nodes := Nodes} ->
                                % Cache all aliases
                                lists:foreach(
                                    fun(N) ->
                                        NId = maps:get(nodeid, N),
                                        A = maps:get(alias, N, <<"unknown">>),
                                        put_cache({node_alias, NId}, A)
                                    end,
                                    Nodes
                                ),
                                % Return requested NodeId alias
                                case
                                    lists:keyfind(NodeId, 2, [
                                        {maps:get(nodeid, N), maps:get(alias, N, <<"unknown">>)}
                                     || N <- Nodes
                                    ])
                                of
                                    {_, A} -> A;
                                    false -> <<"unknown">>
                                end;
                            _ ->
                                <<"unknown">>
                        end;
                    _ ->
                        <<"unknown">>
                end,

            gun:cancel(ConnPid, StreamRef),
            gun:close(ConnPid),
            Alias
    end.
get_node_balance() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, get_node_balance, ?CLN_HTTP_TIMEOUT)
    end).

open_channels_with_best_peers() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, open_channels_with_best_peers, ?CLN_HTTP_TIMEOUT)
    end).
open_best_peers_loop(_Host, _Port, _Options, _Rune, [], _BaseAmount, _MinPerChannel, SpendableLeft) ->
    {[], [], SpendableLeft};
open_best_peers_loop(
    Host,
    Port,
    Options,
    Rune,
    [{{NodeId, _Score, Inbound, MinOpen}, PlannedAmount} | Rest],

    BaseAmount,
    MinPerChannel,
    SpendableLeft
) ->
    AmountToTry0 = lists:max([PlannedAmount, BaseAmount, MinPerChannel, MinOpen]),

    %% inbound too small => skip
    case Inbound >= AmountToTry0 of
        false ->
            open_best_peers_loop(
                Host, Port, Options, Rune, Rest, BaseAmount, MinPerChannel, SpendableLeft
            );
        true ->
            %% can't afford this peer => SKIP (do NOT stop)
            case AmountToTry0 =< SpendableLeft of
                false ->
                    open_best_peers_loop(
                        Host, Port, Options, Rune, Rest, BaseAmount, MinPerChannel, SpendableLeft
                    );
                true ->
                    case open_channel_with_peer(Host, Port, Options, Rune, NodeId, AmountToTry0) of
                        {ok, OkMap} ->
                            {Peers, Results, Spendable2} =
                                open_best_peers_loop(
                                    Host,
                                    Port,
                                    Options,
                                    Rune,
                                    Rest,
                                    BaseAmount,
                                    MinPerChannel,
                                    SpendableLeft - AmountToTry0
                                ),
                            {
                                [NodeId | Peers],
                                [
                                    #{
                                        peer => NodeId,
                                        amount_sats => AmountToTry0,
                                        ok => true,
                                        result => OkMap
                                    }
                                    | Results
                                ],
                                Spendable2
                            };
                        {error, Msg} ->
                            %% If error reveals a higher min, retry once with that min if affordable.
                            case extract_min_open_sats(Msg) of
                                {ok, MinSats} when
                                    MinSats > AmountToTry0,
                                    MinSats =< SpendableLeft,
                                    Inbound >= MinSats
                                ->
                                    cache_peer_min(NodeId, MinSats),
                                    case
                                        open_channel_with_peer(
                                            Host, Port, Options, Rune, NodeId, MinSats
                                        )
                                    of
                                        {ok, OkMap2} ->
                                            {Peers, Results, Spendable2} =
                                                open_best_peers_loop(
                                                    Host,
                                                    Port,
                                                    Options,
                                                    Rune,
                                                    Rest,
                                                    BaseAmount,
                                                    MinPerChannel,
                                                    SpendableLeft - MinSats
                                                ),
                                            {
                                                [NodeId | Peers],
                                                [
                                                    #{
                                                        peer => NodeId,
                                                        amount_sats => MinSats,
                                                        ok => true,
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
                                            {Peers, Results, Spendable2} =
                                                open_best_peers_loop(
                                                    Host,
                                                    Port,
                                                    Options,
                                                    Rune,
                                                    Rest,
                                                    BaseAmount,
                                                    MinPerChannel,
                                                    SpendableLeft
                                                ),
                                            {Peers,
                                                [
                                                    #{
                                                        peer => NodeId,
                                                        amount_sats => AmountToTry0,
                                                        ok => false,
                                                        error => Msg2
                                                    }
                                                    | Results
                                                ],
                                                Spendable2}
                                    end;
                                {ok, MinSats} ->
                                    %% Learned min but can't use it now => cache + blacklist
                                    cache_peer_min(NodeId, MinSats),
                                    put_cache(
                                        peer_blacklist_key(NodeId),
                                        #{reason => Msg, min_sats => MinSats},
                                        ?PEER_BLACKLIST_TTL_MIN
                                    ),
                                    {Peers, Results, Spendable2} =
                                        open_best_peers_loop(
                                            Host,
                                            Port,
                                            Options,
                                            Rune,
                                            Rest,
                                            BaseAmount,
                                            MinPerChannel,
                                            SpendableLeft
                                        ),
                                    {Peers,
                                        [
                                            #{
                                                peer => NodeId,
                                                amount_sats => AmountToTry0,
                                                ok => false,
                                                error => Msg
                                            }
                                            | Results
                                        ],
                                        Spendable2};
                                error ->
                                    %% Connect/init failures etc
                                    TTL =
                                        case is_connect_failure(Msg) of
                                            true -> ?PEER_BLACKLIST_TTL_CONN;
                                            false -> ?PEER_BLACKLIST_TTL_CONN
                                        end,
                                    put_cache(peer_blacklist_key(NodeId), #{reason => Msg}, TTL),
                                    {Peers, Results, Spendable2} =
                                        open_best_peers_loop(
                                            Host,
                                            Port,
                                            Options,
                                            Rune,
                                            Rest,
                                            BaseAmount,
                                            MinPerChannel,
                                            SpendableLeft
                                        ),
                                    {Peers,
                                        [
                                            #{
                                                peer => NodeId,
                                                amount_sats => AmountToTry0,
                                                ok => false,
                                                error => Msg
                                            }
                                            | Results
                                        ],
                                        Spendable2}
                            end
                    end
            end
    end.

is_connect_failure(Msg0) ->
    Msg = to_bin(Msg0),
    case binary:match(Msg, <<"All addresses failed">>) of
        nomatch -> false;
        _ -> true
    end.

required_open_sats(NodeId, Target, MinPerChannel) ->
    MinPeer = get_peer_min_open_sats(NodeId),
    lists:max([Target, MinPerChannel, MinPeer]).

pick_affordable(Cands, Spendable, Target, MinPerChannel) ->
    pick_affordable(Cands, Spendable, Target, MinPerChannel, 0, []).

pick_affordable([], _Spendable, _Target, _MinPerChannel, _Sum, Acc) ->
    lists:reverse(Acc);
pick_affordable(
    [{NodeId, _Score, Inbound, _MinPeer} = C | Rest], Spendable, Target, MinPerChannel, Sum, Acc
) ->
    Req = required_open_sats(NodeId, Target, MinPerChannel),
    case (Sum + Req =< Spendable) andalso (Inbound >= Req) of
        true ->
            pick_affordable(Rest, Spendable, Target, MinPerChannel, Sum + Req, [{C, Req} | Acc]);
        false ->
            pick_affordable(Rest, Spendable, Target, MinPerChannel, Sum, Acc)
    end.

handle_call(
    subscribe,
    _From,
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Message0 = jsx:encode([<<"subscribe">>]),
    Message =
        <<"42", Message0/binary>>,

    ?LOG_DEBUG("sending waitanyinvoice ~p", [Message]),
    ok =
        gun:ws_send(
            ConnPid,
            StreamRef,
            {text, Message}
        ),
    {reply, ok, State};
handle_call(
    {scid_to_channel_id_uncached, SCID},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listpeerchannels",
    ReqJson = jsx:encode(#{}),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Body} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, nofin, _, _} -> gun:await_body(ConnPid, StreamRef);
            _ -> <<"[]">>
        end,
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    Channels = jsx:decode(Body, [return_maps, {labels, atom}]),
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
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listpeerchannels",
    ReqJson = jsx:encode(#{}),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Body} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, nofin, _, _} -> gun:await_body(ConnPid, StreamRef);
            _ -> <<"[]">>
        end,
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    Channels = jsx:decode(Body, [return_maps, {labels, atom}]),
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
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {"content-type", "application/json"}],

    ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{}),

    NodeIds = lists:usort(
        lists:flatten([[maps:get(source, Chan), maps:get(destination, Chan)] || Chan <- ChannelList])
    ),

    Aliases = resolve_aliases(NodeIds, Host, Port, Options, Rune),
    ChannelBalances = get_channel_balances(Host, Port, Options, Rune),

    lists:foreach(
        fun(
            #{
                active := Active,
                public := Public,
                short_channel_id := ShortChannelId,
                source := Source,
                destination := Destination
            }
        ) ->
            SourceAlias = maps:get(Source, Aliases, <<"unknown">>),
            DestAlias = maps:get(Destination, Aliases, <<"unknown">>),
            ChannelId = scid_to_channel_id(ShortChannelId),
            Balance = maps:get(ChannelId, ChannelBalances, #{ours => 0, theirs => 0}),
            OurMsat = maps:get(ours, Balance),
            TheirMsat = maps:get(theirs, Balance),
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
            io:format(
                "Active ~p Public ~p ~s (~s) <--> ~s (~s): Ours: ~p msat, Theirs: ~p msat~s~n",
                [
                    Active,
                    Public,
                    SourceAlias,
                    Source,
                    DestAlias,
                    Destination,
                    OurMsat,
                    TheirMsat,
                    RebalanceFlag
                ]
            )
        end,
        ChannelList
    ),

    {reply, ChannelList, State};
handle_call(
    list_all_channels,
    _From,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {"content-type", "application/json"}],
    ChannelList = fetch_channel_list(Host, Port, Options, Headers, #{}),
    ?LOG_DEBUG("ChannelList ~p", [ChannelList]),
    {reply, ChannelList, State};
handle_call(
    find_best_peer_to_open,
    _From,
    State
) ->
    %% Default to 100k sats if no amount is specified
    do_find_best_peer_to_open(100000, State);
handle_call(
    {find_best_peer_to_open, AmountSats},
    _From,
    State
) ->
    do_find_best_peer_to_open(AmountSats, State);
handle_call(
    get_node_balance,
    _From,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    BalanceSats = get_node_balance(Host, Port, Options, Rune),
    {reply, BalanceSats, State};
handle_call(
    open_channels_with_best_peers,
    From,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],

    {reply, #{id := SourceNodeId}, _} = handle_call(getinfo, From, State),
    SelfChannels0 = fetch_channel_list(Host, Port, Options, Headers, #{source => SourceNodeId}),
    SelfChannels1 = fetch_channel_list(Host, Port, Options, Headers, #{destination => SourceNodeId}),
    SelfChannels = SelfChannels0 ++ SelfChannels1,
    ?LOG_INFO("Self channels ~p", [SelfChannels]),

    %% 1. Node balance (all spendable funds)
    BalanceSats = get_node_balance(Host, Port, Options, Rune),

    %% keep a small reserve so we don't strand the wallet
    Reserve = 100000,
    Spendable =
        case BalanceSats - Reserve of
            N when N =< 0 -> 0;
            N -> N
        end,

    case Spendable =< 0 of
        true ->
            {reply, {error, insufficient_funds, BalanceSats}, State};
        false ->
            %% 2. Network view
            ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{}),

            %% score peers (existing scoring)
            ScoreMap = score_peers_for_opening(ChannelList),
            ScoreList = maps:to_list(ScoreMap),

            %% 3. Build candidate list with inbound capacity
            %% build set of nodes we already have channels with
            ExistingPeers = existing_peers(SelfChannels),
            ?LOG_DEBUG("ExistingPeers ~p  ", [ExistingPeers]),

            %% build candidates: (skip existing peers + blacklisted peers)
            Candidates =
                [
                    begin
                        Inbound = inbound_capacity(NodeId, ChannelList),
                        MinOpen = get_peer_min_open_sats(NodeId),
                        {NodeId, Score, Inbound, MinOpen}
                    end
                 || {NodeId, Score} <- ScoreList,
                    not sets:is_element(NodeId, ExistingPeers),
                    not is_blacklisted(NodeId)
                ],

            %% sort by score, then inbound capacity
            Sorted =
                lists:sort(
                    fun({_, ScoreA, InboundA, _}, {_, ScoreB, InboundB, _}) ->
                        (ScoreA > ScoreB) orelse
                            (ScoreA =:= ScoreB andalso InboundA > InboundB)
                    end,
                    Candidates
                ),

            %% look deeper than 5
            MaxScan = 100,
            %% IMPORTANT: set to realistic default (your log shows 400k mins)
            Target = 400000,
            MinPerChannel = 100000,

            TopCandidates = lists:sublist(Sorted, MaxScan),

            Chosen = pick_affordable(TopCandidates, Spendable, Target, MinPerChannel),

            case Chosen of
                [] ->
                    {reply, {error, no_suitable_peers}, State};
                _ ->
                    CandidateCount = length(Chosen),

                    MaxNByBalance =
                        case Spendable div Target of
                            0 -> 1;
                            N0 -> N0
                        end,

                    RawN = erlang:min(MaxNByBalance, CandidateCount),
                    AmountPerPeer0 = Spendable div RawN,

                    %% baseline per-peer amount (may be bumped per-peer using cached mins)
                    BaseAmount =
                        case AmountPerPeer0 < MinPerChannel of
                            true -> Spendable;
                            false -> AmountPerPeer0
                        end,

                    %% open sequentially: if one peer rejects (min funding / min chan), cache+blacklist and move on
                    {OpenedPeers, OpenResults, RemainingSpendable} =
                        open_best_peers_loop(
                            Host,
                            Port,
                            Options,
                            Rune,
                            Chosen,
                            BaseAmount,
                            MinPerChannel,
                            Spendable
                        ),

                    Aliases =
                        [
                            {NodeId, get_node_alias(Host, Port, Options, Rune, NodeId)}
                         || NodeId <- OpenedPeers
                        ],

                    Reply = #{
                        balance_sats => BalanceSats,
                        spendable_sats => Spendable,
                        remaining_spendable_sats => RemainingSpendable,
                        base_per_peer_sats => BaseAmount,
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
    %% List node info
    NodeInfo = list_node_info(NodeId, Host, Port, Options, Rune),

    %% List channel policy entries (if any)
    ChannelPolicies = list_channel_policies(NodeId, Host, Port, Options, Rune),

    {reply, #{connectable => true, node_info => NodeInfo, channels => ChannelPolicies}, State};
handle_call(
    {list_invoices, Params},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/listinvoices",
    %% Construct the request body
    ReqJson = jsx:encode(Params),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, fin, Status, _RespHeaders} ->
                ?LOG_DEBUG("Got fin ~p", [Status]),
                no_data;
            {response, nofin, _Status, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            Default ->
                ?LOG_DEBUG("Got unknown ~p ", [Default])
        end,
    Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
    %% Parse the response JSON
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    %% Return the invoice details
    {reply, Invoice, State};
handle_call(
    getinfo,
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/getinfo",
    %% Construct the request body
    ReqJson = jsx:encode(#{}),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, fin, Status, _RespHeaders} ->
                ?LOG_DEBUG("Got fin ~p", [Status]),
                no_data;
            {response, nofin, _Status, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            Default ->
                ?LOG_DEBUG("Got unknown ~p ", [Default])
        end,
    ?LOG_DEBUG("Got getinfo response ~p", [Response]),
    Info = jsx:decode(Response, [return_maps, {labels, atom}]),
    %% Parse the response JSON
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    %% Return the invoice details
    {reply, Info, State};
handle_call(
    {create_invoice, AmountMsats, Description, Expiry, Label},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    Headers = [{<<"Rune">>, Rune}, {<<"Content-Type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/invoice",
    %% Construct the request body
    %% Base request
    BaseReq = #{
        amount_msat => AmountMsats,
        label => Label,
        description => Description,
        expiry => Expiry
    },

    %% BOLT11 description is limited to 640 bytes.
    %% If the zap request JSON is longer, ask CLN to only
    %% put the *hash* in the BOLT11 (deschashonly=true),
    %% but still store the full description in the DB.
    ReqMap =
        case byte_size(Description) > 640 of
            true ->
                ?LOG_DEBUG(
                    "create_invoice: description ~p bytes, enabling deschashonly",
                    [byte_size(Description)]
                ),
                BaseReq#{deschashonly => true};
            false ->
                BaseReq
        end,
    ReqJson = jsx:encode(ReqMap),

    ?LOG_DEBUG("sending req head ~p ~p", [Headers, ReqJson]),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, fin, Status, _RespHeaders} ->
                ?LOG_DEBUG("Got fin ~p", [Status]),
                no_data;
            {response, nofin, _Status, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} ->
                gun:await_body(ConnPid, StreamRef);
            Default ->
                ?LOG_DEBUG("Got unknown ~p ", [Default])
        end,
    Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
    %% Parse the response JSON
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    %% Return the invoice details
    {reply, Invoice, State};
handle_call(
    {hold_invoice, Amount, Description, Expiry, CTLV},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    %% Construct the request body
    Headers = [{<<"Rune">>, Rune}, {<<"Content-Type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/holdinvoice",
    %% Construct the request body
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    ReqJson =
        jsx:encode(
            #{
                amount_msat => Amount,
                label => Label,
                description => Description,
                expiry => Expiry,
                ctlv => CTLV
            }
        ),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, fin, _Status, _RespHeaders} -> no_data;
            {response, nofin, _Status, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
            Default -> ?LOG_WARNING("Got unknown ~p ", [Default])
        end,
    ?LOG_DEBUG("Got hold_invoice response ~p", [Response]),
    Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
    %% Parse the response JSON
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    %% Return the invoice details
    {reply, Invoice, State};
handle_call(
    {hold_invoice_cancel, PaymentHash},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    %% Construct the request body
    Headers = [{<<"Rune">>, Rune}, {<<"Content-Type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/holdinvoicecancel",
    %% Construct the request body
    ReqJson = jsx:encode(#{payment_hash => PaymentHash}),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, fin, _Status, _RespHeaders} -> no_data;
            {response, nofin, _Status, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
            {response, nofin, _RespHeaders} -> gun:await_body(ConnPid, StreamRef);
            Default -> ?LOG_WARNING("Got unknown ~p ", [Default])
        end,
    ?LOG_DEBUG("Got hold_invoice_cancel response ~p", [Response]),
    Invoice = jsx:decode(Response, [return_maps, {labels, atom}]),
    %% Parse the response JSON
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    %% Return the invoice details
    {reply, Invoice, State};
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
    Results =
        [
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
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],

    %% Defaults
    N = maps:get(n, Opts, 10),
    MinInbound = maps:get(min_inbound_sats, Opts, 200000),
    MaxScan = maps:get(max_scan, Opts, 300),

    {reply, #{id := SourceNodeId}, _} = handle_call(getinfo, From, State),

    %% Current channels so we don't try to reconnect to existing peers
    SelfChannels0 = fetch_channel_list(Host, Port, Options, Headers, #{source => SourceNodeId}),
    SelfChannels1 = fetch_channel_list(Host, Port, Options, Headers, #{destination => SourceNodeId}),
    SelfChannels = SelfChannels0 ++ SelfChannels1,
    ExistingPeers = existing_peers(SelfChannels),

    %% Network view (cached)
    ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{}),

    %% Score nodes (existing logic)
    ScoreMap = score_peers_for_opening(ChannelList),
    ScoreList = maps:to_list(ScoreMap),

    %% Build candidates: skip existing + blacklisted + insufficient inbound
    Candidates0 =
        [
            begin
                Inbound = inbound_capacity(NodeId, ChannelList),
                {NodeId, Score, Inbound}
            end
         || {NodeId, Score} <- ScoreList,
            not sets:is_element(NodeId, ExistingPeers),
            not is_blacklisted(NodeId)
        ],

    Candidates =
        [C || C = {_NodeId, _Score, Inbound} <- Candidates0, Inbound >= MinInbound],

    Sorted =
        lists:sort(
            fun({_, ScoreA, InA}, {_, ScoreB, InB}) ->
                (ScoreA > ScoreB) orelse (ScoreA =:= ScoreB andalso InA > InB)
            end,
            Candidates
        ),

    ToTry = lists:sublist(Sorted, erlang:min(MaxScan, length(Sorted))),
    TopN = lists:sublist(ToTry, erlang:min(N, length(ToTry))),

    Results =
        [
            begin
                case connect_peer_http(Host, Port, Options, Rune, #{id => NodeId}) of
                    {ok, Res} ->
                        #{peer => NodeId, ok => true, inbound_sats => Inbound, result => Res};
                    {error, Reason} ->
                        %% short blacklist for connect failures
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
handle_call(Request, From, State) ->
    ?LOG_ERROR(
        "handle_call got unknown ~p, From ~p, State ~p",
        [Request, From, State]
    ),
    {reply, err, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("handle_cast got unknown on gun websocket cast ~p,  State ~p", [Msg, State]),
    {noreply, State}.

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State) when
    StreamRef == State#state.streamref
->
    ?LOG_DEBUG("gun_upgrade upgraded ~p ", [StreamRef]),
    {noreply, State#state{conn_pid = ConnPid}};
handle_info(
    {gun_response, ConnPid, _, _, Status, Headers},
    State = #state{conn_pid = ConnPid}
) ->
    ?LOG_DEBUG(
        "gun_response got message on gun websocket ConnPid ~p, \nStatus ~p Headers ~p",
        [ConnPid, Status, Headers]
    ),
    {noreply, State};
handle_info({gun_error, _ConnPid, _StreamRef, {badstate, "The stream cannot be found."}}, State) ->
    {noreply, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, State) ->
    ?LOG_ERROR(
        "got gun error ConnPid ~p, StreamRef ~p, \nReason ~p",
        [ConnPid, StreamRef, Reason]
    ),
    {noreply, State};
handle_info(heartbeat, State) ->
    %% Send a ping message to check the connection
    %ok = gun:ws_send(State#state.conn_pid, State#state.streamref,  {text,  jsx:encode(#{jsonrpc => <<"2.0">>,  method => <<"getinfo">>, params => []})}),
    %% Reset the heartbeat timer
    HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
    {noreply, State#state{heartbeat_timer = HeartbeatTimer}};
handle_info({gun_down, ConnPid, _Reason}, State) when
    ConnPid =:= State#state.conn_pid
->
    io:format("Connection closed~n"),
    erlang:cancel_timer(State#state.heartbeat_timer),
    {stop, normal, State};
handle_info({gun_up, _, _} = _Info, State) ->
    %?LOG_DEBUG("handle_info gun_up websocket Info ~p, State ~p ", [Info, State]),
    {noreply, State};
handle_info({gun_ws, ConnPid, StreamRef, {text, <<"2">>}}, State) ->
    %?LOG_DEBUG("cln socket Received ping, sending pong. ~p ~p ~n", [ConnPid, StreamRef]),
    gun:ws_send(
        ConnPid,
        StreamRef,
        {text, <<"3">>}
    ),
    {noreply, State};
handle_info({gun_ws, ConnPid, StreamRef, {text, Message0}}, State) ->
    Message = parse_socketio_message(Message0),
    %?LOG_DEBUG("cln handle_info gun_ws ~p", [Message]),
    handle_event(ConnPid, StreamRef, Message),
    {noreply, State};
handle_info({gun_ws, _, _, close} = _Info, State) ->
    %?LOG_DEBUG("cln handle_info got close on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State};
handle_info({gun_down, _, ws, normal, _} = _Info, State) ->
    %?LOG_DEBUG("cln handle_info got gun_down on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State};
handle_info(_Info, State) ->
    %?LOG_DEBUG("cln handle_info got unknown on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State}.
handle_event(
    _ConnPid,
    _StreamRef,
    [
        <<"message">>,
        #{
            custommsg :=
                #{
                    payload :=
                        _Payload,
                    peer_id :=
                        _PeerId
                }
        }
    ] = _Message
) ->
    %?LOG_DEBUG("handle_event custommsg ~p", [Message]),
    ok;
handle_event(
    ConnPid,
    StreamRef,
    #{
        sid := SessionId,
        upgrades := [],
        pingTimeout := _PingTimeout,
        pingInterval := _PingInteraval
    } = _Event
) ->
    ?LOG_DEBUG("Websocket session created ~p", [SessionId]),
    gun:ws_send(
        ConnPid,
        StreamRef,
        {text, <<"40">>}
    );
handle_event(
    ConnPid,
    StreamRef,
    #{
        sid := _SessionId
    } = Event
) ->
    ?LOG_DEBUG("Websocket session got ~p", [Event]),
    Message0 = jsx:encode([<<"subscribe">>]),
    Message =
        <<"42", Message0/binary>>,
    ?LOG_DEBUG("sending waitanyinvoice ~p", [Message]),
    ok =
        gun:ws_send(
            ConnPid,
            StreamRef,
            {text, Message}
        );
%% Inbound invoice was paid (authoritative)
handle_event(
    _ConnPid,
    _StreamRef,
    [
        <<"message">>,
        #{
            invoice_payment :=
                #{
                    label := Label,
                    preimage := Preimage,
                    msat := MSat
                } = Pay
        }
    ]
) ->
    ?LOG_INFO("cln: invoice_payment label=~p msat=~p", [Label, MSat]),
    %% Prefer matching by label (unique for our created invoices); fall back to hash if needed later.
    case list_invoices_by_label(Label) of
        #{invoices := [Inv | _]} ->
            %% Enrich the invoice record with runtime facts and broadcast a single canonical event.
            PaidInv = Inv#{
                event => invoice_payment,
                details => Pay,
                preimage => Preimage,
                received_msat => MSat,
                paid_at_unix => erlang:system_time(second),
                status_runtime => <<"paid">>
            },
            broadcast(invoice_paid, PaidInv);
        _ ->
            %% We didn't create/track this label locally (rare). Still surface a useful payload.
            broadcast(invoice_paid, #{
                label => Label,
                preimage => Preimage,
                received_msat => MSat,
                details => Pay
            })
    end;
handle_event(_ConnPid, _StreamRef, _UnknownEvent) ->
    %?LOG_DEBUG("Websocket unknown event ~p", [UnknownEvent]),
    ok.

terminate(Reason, State) ->
    maybe_close_gun(State#state.conn_pid),
    erlang:cancel_timer(State#state.heartbeat_timer),
    ?LOG_ERROR("Terminating clnconnect ~p", [Reason]),
    ok.
maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

subscribe() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, subscribe, ?CLN_HTTP_TIMEOUT) end
    ).
getinfo() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, getinfo, ?CLN_HTTP_TIMEOUT) end
    ).

list_invoices() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker, {list_invoices, #{index => <<"created">>, limit => 10}}, ?CLN_HTTP_TIMEOUT
            )
        end
    ).
list_invoices_by_label(Label) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {list_invoices, #{label => Label}}, ?CLN_HTTP_TIMEOUT)
        end
    ).
list_invoices_by_invoicestring(InvoiceString) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker, {list_invoices, #{invstring => InvoiceString}}, ?CLN_HTTP_TIMEOUT
            )
        end
    ).
list_invoices_by_payment_hash(PaymentHash) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, {list_invoices, #{payment_hash => PaymentHash}}) end
    ).

create_invoice(AmountMsats, Description) ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, AmountMsats, Description, 3600, Label})
        end
    ).

create_invoice(AmountMsats, Description, Expiry) ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, AmountMsats, Description, Expiry, Label})
        end
    ).
create_invoice(AmountMsats, Description, Expiry, Label) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, AmountMsats, Description, Expiry, Label})
        end
    ).

hold_invoice(Amount, Description, Expiry, Cltv) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {hold_invoice, Amount, Description, Expiry, Cltv}
            )
        end
    ).

hold_invoice_cancel(PaymentHash) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, {hold_invoice_cancel, PaymentHash}) end
    ).
list_channels() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, list_channels, ?CLN_HTTP_TIMEOUT) end
    ).
list_all_channels() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, list_all_channels, ?CLN_HTTP_TIMEOUT) end
    ).
decode_payload(Payload) ->
    jsx:decode(Payload, [return_maps, {labels, atom}]).
parse_socketio_message(<<"0", Payload/binary>>) ->
    %% "42" is Socket.IO event prefix for normal message
    ?LOG_DEBUG("Got init sockeio 0 "),
    decode_payload(Payload);
parse_socketio_message(<<"40", Payload/binary>>) ->
    decode_payload(Payload);
parse_socketio_message(<<"42", Payload/binary>>) ->
    %% "42" is Socket.IO event prefix for normal message
    decode_payload(Payload);
parse_socketio_message(Other) ->
    %?LOG_DEBUG("unknown socketio message ~p", [Other]),
    Other.
register_listener(Topic) when is_atom(Topic) ->
    gproc:reg({p, l, {cln_event, Topic}}).

broadcast(Topic, Payload) ->
    Message = {cln_event, Topic, Payload},
    lists:foreach(
        fun(Pid) ->
            Pid ! Message,
            ?LOG_DEBUG("broadcast pid ~p", [Pid])
        end,
        gproc:lookup_pids({p, l, {cln_event, Topic}})
    ).
find_best_peer_to_open() ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, find_best_peer_to_open, ?CLN_HTTP_TIMEOUT)
    end).

find_best_peer_to_open(AmountSats) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {find_best_peer_to_open, AmountSats}, ?CLN_HTTP_TIMEOUT)
    end).
-spec score_peers_for_opening([map()]) -> map().
score_peers_for_opening(ChannelList) ->
    %% default scoring baseline (100k sats)
    score_peers_for_opening(ChannelList, 100000).

-spec score_peers_for_opening([map()], integer()) -> map().
score_peers_for_opening(ChannelList, MinSats) ->
    Now = erlang:system_time(second),

    lists:foldl(
        fun
            (
                #{
                    source := Src,
                    destination := Dst,
                    amount_msat := AmountMsat,
                    base_fee_millisatoshi := BaseFee,
                    fee_per_millionth := FeeRate,
                    last_update := LU,
                    active := true
                },
                Acc
            ) ->
                %% channel capacity in sats
                Sats = AmountMsat div 1000,
                PeerNodes = [Src, Dst],
                lists:foldl(
                    fun(NodeId, InnerAcc) ->
                        case Sats >= MinSats of
                            true ->
                                Score = compute_score(Sats, BaseFee, FeeRate, LU, Now),
                                update_score(NodeId, Score, InnerAcc);
                            false ->
                                InnerAcc
                        end
                    end,
                    Acc,
                    PeerNodes
                );
            (
                #{
                    % ignore inactive nodes
                    active := false
                },
                Acc
            ) ->
                Acc
        end,
        #{},
        ChannelList
    ).

top_five_nodes(ChannelList) ->
    ScoreMap = score_peers_for_opening(ChannelList),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A > B end, maps:to_list(ScoreMap)),
    lists:sublist(Sorted, 5).

compute_score(Sats, _BaseFee, FeeRate, LastUpdate, Now) ->
    %% Higher sats = better; lower fee = better; recent = better
    NormalizedSats = math:log10(Sats + 1),
    NormalizedFee = 1000000 / (FeeRate + 1),
    %% decays over time
    RecencyBonus = 1.0 / (1.0 + (Now - LastUpdate) / 3600),
    NormalizedSats + NormalizedFee * 0.1 + RecencyBonus * 5.

update_score(NodeId, Score, Map) ->
    maps:update_with(NodeId, fun(S) -> S + Score end, Score, Map).

-spec inbound_capacity(binary(), [map()]) -> integer().
inbound_capacity(NodeId, Channels) ->
    lists:foldl(
        fun
            (#{destination := NodeId1, amount_msat := AmountMsat}, Acc) when
                NodeId1 =:= NodeId
            ->
                Acc + (AmountMsat div 1000);
            (_, Acc) ->
                Acc
        end,
        0,
        Channels
    ).

test() ->
    test_listchannels().

test_listchannels() ->
    list_channels().

%% Shared global cache for listchannels
get_cached_channel_list(Host, Port, Options, Headers, ReqMap) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(cln_channel_cache, listchannels) of
        [{listchannels, {Timestamp, Channels}}] when Now - Timestamp < ?CACHE_TTL ->
            ?LOG_DEBUG("Using cached listchannels", []),
            Channels;
        [{listchannels, {Timestamp, Channels}}] when Now - Timestamp > ?CACHE_TTL ->
            ?LOG_INFO("Cache age ~p", [Now - Timestamp]),
            ?LOG_DEBUG("Fetching listchannels from CLN", []),
            Channels = fetch_channel_list(Host, Port, Options, Headers, ReqMap),
            ets:insert(cln_channel_cache, {listchannels, {Now, Channels}}),
            Channels;
        _ ->
            ?LOG_DEBUG("Fetching listchannels from CLN", []),
            Channels = fetch_channel_list(Host, Port, Options, Headers, ReqMap),
            ets:insert(cln_channel_cache, {listchannels, {Now, Channels}}),
            Channels
    end.

%% Helper: fetch /v1/listchannels
fetch_channel_list(Host, Port, Options, Headers, ReqMap) ->
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listchannels",
    ReqJson = jsx:encode(ReqMap),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Body} =
        case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
            {response, nofin, _, _} -> gun:await_body(ConnPid, StreamRef);
            _ -> <<"{}">>
        end,
    gun:cancel(ConnPid, StreamRef),
    gun:close(ConnPid),
    Decoded = jsx:decode(Body, [return_maps, {labels, atom}]),
    maps:get(channels, Decoded, []).

%% Helper: resolve aliases
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
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listnodes",
    ReqJson = jsx:encode(#{id => NodeId}),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    Body = get_json_body(ConnPid, StreamRef),
    gun:close(ConnPid),
    case maps:get(nodes, Body, []) of
        [NodeData | _] -> maps:with([alias, features, last_timestamp], NodeData);
        _ -> #{}
    end.

list_channel_policies(NodeId, Host, Port, Options, Rune) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listchannels",
    ReqJson = jsx:encode(#{destination => NodeId}),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    Body = get_json_body(ConnPid, StreamRef),
    gun:close(ConnPid),
    maps:get(channels, Body, []).

get_json_body(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, ?CLN_HTTP_TIMEOUT) of
        {response, nofin, _, _} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            jsx:decode(Body, [return_maps, {labels, atom}]);
        _ ->
            #{}
    end.
verify_peer(NodeId) when is_binary(NodeId) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {verify_peer, NodeId})
    end).
%% Connect to a single peer.
%% Peer can be:
%%   - <<"nodeid">>
%%   - "nodeid@host:port"
%%   - #{id => NodeId, host => Host, port => Port}
connect_peer(Peer) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_peer, Peer}, ?CLN_HTTP_TIMEOUT)
    end).

connect_peers(Peers) when is_list(Peers) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_peers, Peers}, ?CLN_HTTP_TIMEOUT)
    end).

%% Discover top peers by network score and attempt to connect to them.
%% Opts:
%%   #{n => 10, min_inbound_sats => 200000, max_scan => 300}
connect_best_peers() ->
    connect_best_peers(#{}).

connect_best_peers(Opts) when is_map(Opts) ->
    poolboy:transaction(?MODULE, fun(Worker) ->
        gen_server:call(Worker, {connect_best_peers, Opts}, ?CLN_HTTP_TIMEOUT)
    end).

%% Channel = #{base_fee_msat => integer(), fee_per_millionth => integer()}
%% AmountMsat = integer(), e.g., 100000000 for 100,000 sats
estimate_routing_fee(Channel, AmountMsat) ->
    BaseFee = maps:get(base_fee_msat, Channel, 0),
    FeePPM = maps:get(fee_per_millionth, Channel, 0),
    Fee = BaseFee + ((AmountMsat * FeePPM) div 1000000),
    Fee.
do_find_best_peer_to_open(
    AmountSats,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {"content-type", "application/json"}],
    ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{}),

    %% Score peers based on capacity/fees/recency for the given amount
    ScoreMap = score_peers_for_opening(ChannelList, AmountSats),

    %% Only consider nodes we actually scored
    NodeIds = maps:keys(ScoreMap),

    %% Resolve aliases for the candidate nodes
    AliasesMap = resolve_aliases(NodeIds, Host, Port, Options, Rune),

    %% Build inbound capacity map: how much liquidity peers already have
    InboundMap =
        lists:foldl(
            fun
                (#{destination := Dst, satoshis := Sats}, Acc) ->
                    maps:update_with(Dst, fun(V) -> V + Sats end, Sats, Acc);
                (_, Acc) ->
                    Acc
            end,
            #{},
            ChannelList
        ),

    %% Build {NodeId, Alias, Score, InboundCapacity} tuples
    Candidates =
        [
            begin
                Alias = maps:get(NodeId, AliasesMap, <<"unknown">>),
                Inbound = maps:get(NodeId, InboundMap, 0),
                {NodeId, Alias, Score, Inbound}
            end
         || {NodeId, Score} <- maps:to_list(ScoreMap)
        ],

    %% Filter out nodes whose inbound capacity is clearly too small for the amount
    Suitable =
        [
            C
         || C = {_NodeId, _Alias, _Score, Inbound} <- Candidates,
            Inbound >= AmountSats
        ],

    %% Sort primarily by score, secondary by inbound capacity
    Sorted =
        lists:sort(
            fun({_, _, ScoreA, InboundA}, {_, _, ScoreB, InboundB}) ->
                (ScoreA > ScoreB) orelse
                    (ScoreA =:= ScoreB andalso InboundA > InboundB)
            end,
            Suitable
        ),

    Top5 = lists:sublist(Sorted, 5),
    {reply, Top5, State}.
-spec existing_peers([map()]) -> sets:set().
existing_peers(ChannelList) ->
    lists:foldl(
        fun(#{source := Src, destination := Dst}, Acc) ->
            Acc1 = sets:add_element(Src, Acc),
            sets:add_element(Dst, Acc1)
        end,
        sets:new(),
        ChannelList
    ).
peer_min_key(NodeId) -> {peer_min_open_sats, NodeId}.
peer_blacklist_key(NodeId) -> {peer_blacklist, NodeId}.

get_peer_min_open_sats(NodeId) ->
    case get_cache(peer_min_key(NodeId), ?PEER_MIN_TTL) of
        {ok, Min} when is_integer(Min) -> Min;
        _ -> 0
    end.

blacklist_peer(NodeId, Reason, MinSats) ->
    put_cache(
        peer_blacklist_key(NodeId), #{reason => Reason, min_sats => MinSats}, ?PEER_BLACKLIST_TTL
    ),
    ok.

is_blacklisted(NodeId) ->
    case get_cache(peer_blacklist_key(NodeId), ?PEER_BLACKLIST_TTL) of
        {ok, _} -> true;
        _ -> false
    end.

cache_peer_min(NodeId, MinSats) when is_integer(MinSats), MinSats > 0 ->
    put_cache(peer_min_key(NodeId), MinSats, ?PEER_MIN_TTL),
    ok;
cache_peer_min(_, _) ->
    ok.

%% Parse common CLN error strings:
%% - "... invalid funding amount=260285 sat (min=400000 sat) ..."
%% - "... chan size of 0.00260285 BTC is below min chan size of 0.02000000 BTC ..."
extract_min_open_sats(Msg0) ->
    Msg = to_bin(Msg0),

    case re:run(Msg, <<"min=([0-9]+) sat">>, [{capture, [1], binary}]) of
        {match, [MinSatBin]} ->
            {ok, binary_to_integer(MinSatBin)};
        nomatch ->
            case
                re:run(Msg, <<"min chan size of ([0-9]+\\.[0-9]+) BTC">>, [{capture, [1], binary}])
            of
                {match, [MinBtcBin]} ->
                    {ok, btc_bin_to_sats(MinBtcBin)};
                nomatch ->
                    %% sometimes message is "... below min chan size of 0.02000000 BTC"
                    case
                        re:run(Msg, <<"below min chan size of ([0-9]+\\.[0-9]+) BTC">>, [
                            {capture, [1], binary}
                        ])
                    of
                        {match, [MinBtcBin2]} ->
                            {ok, btc_bin_to_sats(MinBtcBin2)};
                        nomatch ->
                            error
                    end
            end
    end.

btc_bin_to_sats(Bin) ->
    %% float parse, then sats
    F = list_to_float(binary_to_list(Bin)),
    trunc(F * 100000000).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

open_channel_with_peer(Host, Port, Options, Rune, NodeId, AmountSats) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/fundchannel",
    ReqJson = jsx:encode(#{
        id => NodeId,
        amount => AmountSats
    }),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    Res =
        case catch get_json_body(ConnPid, StreamRef) of
            #{
                code := _,
                data := #{id := NodeId, method := Method},
                message := Message
            } ->
                ?LOG_INFO("Failed to open channel with ~p method ~p reason ~p", [
                    NodeId, Method, Message
                ]),
                {error, Message};
            Body0 when is_map(Body0) ->
                {ok, Body0};
            Other ->
                {error, to_bin(Other)}
        end,
    gun:close(ConnPid),
    Res.

%% POST /v1/connect
connect_peer_http(Host, Port, Options, Rune, Peer0) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    Peer = normalize_peer(Peer0),

    Req =
        case Peer of
            #{id := Id, host := H, port := P} -> #{id => Id, host => H, port => P};
            #{id := Id, host := H} -> #{id => Id, host => H};
            #{id := Id} -> #{id => Id}
        end,

    {ok, ConnPid} = gun:open(Host, Port, Options),
    StreamRef = gun:post(ConnPid, "/v1/connect", Headers, jsx:encode(Req)),
    Res =
        case catch get_json_body(ConnPid, StreamRef) of
            %% CLN REST errors often decode into #{code:=..., message:=...}
            #{code := _, message := Message} ->
                {error, Message};
            Body0 when is_map(Body0) ->
                {ok, Body0};
            Other ->
                {error, to_bin(Other)}
        end,
    gun:close(ConnPid),
    Res.

%% Normalize Peer input into map with binary strings
normalize_peer(#{id := _} = M) ->
    %% already atom keys
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
    %% formats:
    %%   nodeid
    %%   nodeid@host
    %%   nodeid@host:port
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

get_node_balance(Host, Port, Options, Rune) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    Path = "/v1/listfunds",
    ReqJson = jsx:encode(#{}),
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    Body = get_json_body(ConnPid, StreamRef),
    gun:close(ConnPid),

    Outputs = maps:get(outputs, Body, []),

    %% Only count UTXOs that are confirmed and not reserved.
    %% listfunds.outputs fields include: amount_msat, status, reserved, ...
    TotalMsat =
        lists:foldl(
            fun(Output, Acc) ->
                Msat = maps:get(amount_msat, Output, 0),
                Status = maps:get(status, Output, <<"">>),
                Reserved = maps:get(reserved, Output, false),

                case {is_integer(Msat), Status, Reserved} of
                    {true, <<"confirmed">>, false} ->
                        Acc + Msat;
                    _ ->
                        Acc
                end
            end,
            0,
            Outputs
        ),

    %% sats
    TotalMsat div 1000.
