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
        find_best_peer_to_open/0,
        score_peers_for_opening/1,
        top_five_nodes/1,
        inbound_capacity/2,
        verify_peer/1,
        subscribe/0
    ]
).
-export([register_listener/1]).
-export([broadcast/2]).
-export([test/0]).
% 5 minutes in ms
-define(CACHE_TTL, 300000).
-define(CLN_HTTP_TIMEOUT, 300000).

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
    ets:insert(cln_channel_cache, {Key, {Value, erlang:monotonic_time(millisecond)}}).

get_cache(Key) ->
    case ets:lookup(cln_channel_cache, Key) of
        [{_, {Val, T}}] ->
            Now = erlang:monotonic_time(millisecond),
            case Now - T =< ?CACHE_TTL of
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
                gen_server:call(W, {scid_to_channel_id_uncached, SCID})
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
                gen_server:call(W, {channel_id_to_scid_uncached, CID})
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
                case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
                case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
    From,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {"content-type", "application/json"}],
    {reply, #{id := SourceNodeId}, _} = handle_call(getinfo, From, State),

    ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{source => SourceNodeId}),

    NodeIds = lists:usort(
        lists:flatten([[maps:get(source, Chan), maps:get(destination, Chan)] || Chan <- ChannelList])
    ),

    Aliases = resolve_aliases(NodeIds, Host, Port, Options, Rune),
    ChannelBalances = get_channel_balances(Host, Port, Options, Rune),

    lists:foreach(
        fun(#{short_channel_id := ShortChannelId, source := Source, destination := Destination}) ->
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
                "~s (~s) <--> ~s (~s): Ours: ~p msat, Theirs: ~p msat~s~n",
                [SourceAlias, Source, DestAlias, Destination, OurMsat, TheirMsat, RebalanceFlag]
            )
        end,
        ChannelList
    ),

    {reply, ChannelList, State};
handle_call(
    find_best_peer_to_open,
    _From,
    State = #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options}
) ->
    Headers = [{"Rune", Rune}, {"content-type", "application/json"}],
    ChannelList = get_cached_channel_list(Host, Port, Options, Headers, #{}),

    NodeCount = lists:foldl(
        fun(#{source := Src, destination := Dst}, Acc) ->
            Acc1 = maps:update_with(Src, fun(N) -> N + 1 end, 1, Acc),
            maps:update_with(Dst, fun(N) -> N + 1 end, 1, Acc1)
        end,
        #{},
        ChannelList
    ),

    Sorted = lists:sort(fun({_, A}, {_, B}) -> A > B end, maps:to_list(NodeCount)),
    Top = lists:sublist(Sorted, 5),
    Aliases = lists:map(
        fun({NodeId, Count}) ->
            {NodeId, get_node_alias(Host, Port, Options, Rune, NodeId), Count}
        end,
        Top
    ),
    {reply, Aliases, State};
handle_call(
    {verify_peer, NodeId},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} = State
) ->
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    %% 1. Connect to node

    %% 2. List node info
    NodeInfo = list_node_info(NodeId, Host, Port, Options, Rune),

    %% 3. List channel policy entries (if any)
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
    ?LOG_ERROR("got getinfo on gun websocket  State ~p", [State]),
    Headers = [{"Rune", Rune}, {<<"content-type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/getinfo",
    %% Construct the request body
    ReqJson = jsx:encode(#{}),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
    {create_invoice, Amount, Description, Expiry, Label},
    _From,
    #state{cln_host = Host, cln_port = Port, rune = Rune, options = Options} =
        State
) ->
    Headers = [{<<"Rune">>, Rune}, {<<"Content-Type">>, <<"application/json">>}],
    {ok, ConnPid} = gun:open(Host, Port, Options),
    %% Construct the API request URL
    Path = "/v1/invoice",
    %% Construct the request body
    ReqJson =
        jsx:encode(
            #{
                amount_msat => Amount,
                label => Label,
                description => Description,
                expiry => Expiry
            }
        ),
    ?LOG_DEBUG("sending req head ~p ~p", [Headers, ReqJson]),
    %% Send the HTTP POST request
    StreamRef = gun:post(ConnPid, Path, Headers, ReqJson),
    {ok, Response} =
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
    ok = handle_event(ConnPid, StreamRef, Message),
    {noreply, State};
handle_info({gun_ws, _, _, close} = Info, State) ->
    ?LOG_DEBUG("handle_info got close on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State};
handle_info({gun_down, _, ws, normal, _} = Info, State) ->
    ?LOG_DEBUG("handle_info got gun_down on gun websocket Info ~p, State ~p", [Info, State]),
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG("handle_info got unknown on gun websocket Info ~p, State ~p", [Info, State]),
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
handle_event(
    _ConnPid,
    _StreamRef,
    [
        <<"message">>,
        #{
            origin := <<"pay">>,
            payload :=
                #{
                    payment_hash := PaymentHash,
                    bolt11 :=
                        PaymentRequest
                }
        }
    ]
) ->
    ?LOG_INFO("cln: websocket payment event payrequest ~p payhash ~p", [PaymentRequest, PaymentHash]),
    case list_invoices_by_payment_hash(PaymentHash) of
        #{invoices := [Invoice | _]} ->
            ?LOG_INFO("cln: websocket payment invoice ~p", [Invoice]),
            broadcast(invoice_paid, Invoice);
        #{invoices := []} ->
            ?LOG_INFO("cln: unknown payment invoice ~p", [PaymentHash]),
            []
    end;
handle_event(_ConnPid, _StreamRef, _UnknownEvent) ->
    %?LOG_DEBUG("Websocket unknown event ~p", [UnknownEvent]),
    ok.

terminate(Reason, State) ->
    gun:shutdown(State#state.conn_pid),
    erlang:cancel_timer(State#state.heartbeat_timer),
    ?LOG_ERROR("Terminating clnconnect ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

subscribe() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, subscribe) end
    ).
getinfo() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, getinfo) end
    ).

list_invoices() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {list_invoices, #{index => <<"created">>, limit => 10}})
        end
    ).
list_invoices_by_label(Label) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, {list_invoices, #{label => Label}}) end
    ).
list_invoices_by_invoicestring(InvoiceString) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, {list_invoices, #{invstring => InvoiceString}}) end
    ).
list_invoices_by_payment_hash(PaymentHash) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) -> gen_server:call(Worker, {list_invoices, #{payment_hash => PaymentHash}}) end
    ).

create_invoice(Amount, Description) ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, Amount, Description, 3600, Label})
        end
    ).

create_invoice(Amount, Description, Expiry) ->
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("asyncmind" ++ Timestamp),
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, Amount, Description, Expiry, Label})
        end
    ).
create_invoice(Amount, Description, Expiry, Label) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {create_invoice, Amount, Description, Expiry, Label})
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
        fun(Worker) -> gen_server:call(Worker, list_channels) end
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
-spec score_peers_for_opening([map()]) -> [{binary(), float()}].
score_peers_for_opening(ChannelList) ->
    %% 100k sats = $100 AUD
    MinSats = 100000,
    Now = erlang:system_time(second),

    lists:foldl(
        fun(
            #{
                source := Src,
                destination := Dst,
                satoshis := Sats,
                base_fee_millisatoshi := BaseFee,
                fee_per_millionth := FeeRate,
                last_update := LU
            },
            Acc
        ) ->
            PeerPairs = [Src, Dst],
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
                PeerPairs
            )
        end,
        #{},
        ChannelList
    ).
top_five_nodes(ChannelList) ->
    {ok, ScoreMap} = score_peers_for_opening(ChannelList),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A > B end, maps:to_list(ScoreMap)),
    _Top5 = lists:sublist(Sorted, 5).

compute_score(Sats, BaseFee, FeeRate, LastUpdate, Now) ->
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
            (#{destination := NodeId1, satoshis := Sats}, Acc) when NodeId1 =:= NodeId ->
                Acc + Sats;
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
    TTL = 60,
    case ets:lookup(cln_channel_cache, listchannels) of
        [{listchannels, {Timestamp, Channels}}] when Now - Timestamp < TTL ->
            ?LOG_DEBUG("Using cached listchannels", []),
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
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
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
%% Channel = #{base_fee_msat => integer(), fee_per_millionth => integer()}
%% AmountMsat = integer(), e.g., 100000000 for 100,000 sats
estimate_routing_fee(Channel, AmountMsat) ->
    BaseFee = maps:get(base_fee_msat, Channel, 0),
    FeePPM = maps:get(fee_per_millionth, Channel, 0),
    Fee = BaseFee + ((AmountMsat * FeePPM) div 1000000),
    Fee.
