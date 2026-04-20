%%%-------------------------------------------------------------------
%%% damage_ipfs_peers.erl
%%% Manage IPFS peers for DamageBDD from sys.config
%%%-------------------------------------------------------------------
-module(damage_ipfs_peers).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    ensure_started/0,
    add_peers/1,
    set_peers/1,
    get_peers/0,
    connect_all/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DEFAULT_IPFS_API, "http://127.0.0.1:5001").
-define(DEFAULT_RETRY_INTERVAL, 30000).

-record(state, {
    ipfs_api = ?DEFAULT_IPFS_API :: string(),
    self_peer_id = undefined,
    peers = [] :: [peer_spec()],
    retry_interval = ?DEFAULT_RETRY_INTERVAL :: non_neg_integer(),
    timer = undefined
}).

-type peer_spec() ::
    string()
    | binary()
    | #{
        peer_id => binary() | string(),
        addrs => [binary() | string()]
    }.

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

ensure_started() ->
    case whereis(?SERVER) of
        undefined ->
            start_link();
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

add_peers(Peers) when is_list(Peers) ->
    gen_server:cast(?SERVER, {add_peers, Peers}).

set_peers(Peers) when is_list(Peers) ->
    gen_server:call(?SERVER, {set_peers, Peers}).

get_peers() ->
    gen_server:call(?SERVER, get_peers).

connect_all() ->
    gen_server:call(?SERVER, connect_all).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    ok = ensure_inets(),

    IpfsApi = proplists:get_value(ipfs_api, Opts, env(ipfs_api, ?DEFAULT_IPFS_API)),
    RetryInterval = proplists:get_value(
        retry_interval,
        Opts,
        env(ipfs_peer_retry_interval, ?DEFAULT_RETRY_INTERVAL)
    ),
    Peers0 = proplists:get_value(ipfs_peers, Opts, env(ipfs_peers, [])),
    Peers = normalize_peer_specs(Peers0),
    SelfPeerId = get_self_peer_id(IpfsApi),

    ?LOG_INFO(
        "damage_ipfs_peers starting with ~p peers via ~p self=~p",
        [length(Peers), IpfsApi, SelfPeerId]
    ),

    TRef = erlang:send_after(1000, self(), connect_tick),

    {ok, #state{
        ipfs_api = IpfsApi,
        self_peer_id = SelfPeerId,
        peers = Peers,
        retry_interval = RetryInterval,
        timer = TRef
    }}.

handle_call(get_peers, _From, State = #state{peers = Peers}) ->
    {reply, Peers, State};
handle_call(connect_all, _From, State) ->
    Result = do_connect_all(State),
    {reply, Result, State};
handle_call({set_peers, Peers0}, _From, State) ->
    Peers = normalize_peer_specs(Peers0),
    Result = do_connect_all(State#state{peers = Peers}),
    {reply, Result, State#state{peers = Peers}};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({add_peers, Peers0}, State = #state{peers = Existing}) ->
    Peers = dedupe_peers(Existing ++ normalize_peer_specs(Peers0)),
    _ = do_connect_all(State#state{peers = Peers}),
    {noreply, State#state{peers = Peers}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect_tick, State = #state{retry_interval = RetryInterval}) ->
    _ =
        try
            do_connect_all(State)
        catch
            exit:{shutdown, _} ->
                {error, shutting_down};
            exit:shutdown ->
                {error, shutting_down};
            exit:{noproc, _} ->
                {error, dependency_gone};
            exit:noproc ->
                {error, dependency_gone};
            Class:Reason:Stack ->
                ?LOG_WARNING(
                    "IPFS connect tick failed during shutdown/restart ~p:~p ~p",
                    [Class, Reason, Stack]
                ),
                {error, {Class, Reason}}
        end,
    TRef = erlang:send_after(RetryInterval, self(), connect_tick),
    {noreply, State#state{timer = TRef}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer = TRef}) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

env(Key, Default) ->
    application:get_env(damage, Key, Default).

ensure_inets() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, {already_started, inets}} -> ok;
        {error, _} = Err -> exit({failed_to_start_inets, Err})
    end.

do_connect_all(#state{peers = Peers} = State) ->
    lists:map(
        fun(Peer) ->
            connect_peer(State, Peer)
        end,
        Peers
    ).

connect_peer(State = #state{self_peer_id = SelfPeerId}, PeerSpec) ->
    Ids = peer_target_ids(PeerSpec),

    case should_skip_self(SelfPeerId, Ids) of
        true ->
            %?LOG_DEBUG("Skipping self peer spec ~p", [PeerSpec]),
            {ok, skipped_self, PeerSpec};
        false ->
            connect_peer_addrs(State, PeerSpec)
    end.

should_skip_self(undefined, _) ->
    false;
should_skip_self(Self, Ids) ->
    lists:member(Self, Ids).

connect_peer_addrs(State, PeerSpec) ->
    case peer_addrs(PeerSpec) of
        [] ->
            {error, invalid_peer_spec};
        Addrs ->
            connect_addrs(State, Addrs, PeerSpec)
    end.

connect_addrs(_State, [], PeerSpec) ->
    {error, no_addrs, PeerSpec};
connect_addrs(State, [Addr | Rest], PeerSpec) ->
    case connect_multiaddr(State, Addr) of
        ok ->
            {ok, Addr, PeerSpec};
        {error, _} = Err ->
            case Rest of
                [] -> Err;
                _ -> connect_addrs(State, Rest, PeerSpec)
            end
    end.

connect_multiaddr(#state{ipfs_api = ApiBase}, Addr0) ->
    Addr = to_list(Addr0),
    Url = ApiBase ++ "/api/v0/swarm/connect?arg=" ++ uri_string:quote(Addr),
    try
        case httpc:request(post, {Url, [], "application/x-www-form-urlencoded", ""}, [], []) of
            {ok, {{_, 200, _}, _Headers, _Body}} ->
                ok;
            {ok, {{_, 500, _}, _Headers, Body}} ->
                case body_text(Body) of
                    Text when is_list(Text) ->
                        case is_already_connected(Text) of
                            true ->
                                ok;
                            false ->
                                ?LOG_WARNING("IPFS connect failed ~s -> ~s", [Addr, Text]),
                                {error, Text}
                        end
                end;
            {ok, {{_, Code, _}, _Headers, Body}} ->
                Text = body_text(Body),
                ?LOG_WARNING("IPFS connect http ~p for ~s -> ~s", [Code, Addr, Text]),
                {error, {http_error, Code, Text}};
            {error, {shutdown, _}} ->
                {error, shutting_down};
            {error, shutdown} ->
                {error, shutting_down};
            {error, noproc} ->
                {error, dependency_gone};
            Error ->
                ?LOG_WARNING("IPFS connect transport error ~s -> ~p", [Addr, Error]),
                {error, Error}
        end
    catch
        exit:{shutdown, _} ->
            {error, shutting_down};
        exit:shutdown ->
            {error, shutting_down};
        exit:{noproc, _} ->
            {error, dependency_gone};
        exit:noproc ->
            {error, dependency_gone};
        Class:Reason ->
            ?LOG_WARNING("IPFS connect crashed ~s -> ~p:~p", [Addr, Class, Reason]),
            {error, {Class, Reason}}
    end.

is_already_connected(Text) ->
    Lower = string:lowercase(Text),
    (string:str(Lower, "already connected") > 0) orelse
        (string:str(Lower, "connection already exists") > 0).

body_text(Body) when is_binary(Body) ->
    binary_to_list(Body);
body_text(Body) when is_list(Body) ->
    Body;
body_text(Body) ->
    io_lib:format("~p", [Body]).

normalize_peer_specs(Peers) ->
    dedupe_peers(
        lists:append([normalize_peer_spec(P) || P <- Peers])
    ).

normalize_peer_spec(Peer) when is_binary(Peer); is_list(Peer) ->
    [Peer];
normalize_peer_spec(#{peer_id := PeerId, addrs := Addrs}) when is_list(Addrs) ->
    [#{peer_id => PeerId, addrs => Addrs}];
normalize_peer_spec(#{addrs := Addrs}) when is_list(Addrs) ->
    [#{addrs => Addrs}];
normalize_peer_spec(Other) ->
    ?LOG_WARNING("Ignoring invalid IPFS peer spec: ~p", [Other]),
    [].

peer_addrs(Peer) when is_binary(Peer); is_list(Peer) ->
    [Peer];
peer_addrs(#{addrs := Addrs}) when is_list(Addrs) ->
    [to_list(A) || A <- Addrs];
peer_addrs(Other) ->
    ?LOG_WARNING("Invalid IPFS peer spec in peer_addrs/1: ~p", [Other]),
    [].

dedupe_peers(Peers) ->
    lists:reverse(
        lists:foldl(
            fun(P, Acc) ->
                case lists:member(P, Acc) of
                    true -> Acc;
                    false -> [P | Acc]
                end
            end,
            [],
            Peers
        )
    ).

to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) when is_list(V) -> V.

get_self_peer_id(ApiBase) ->
    Url = ApiBase ++ "/api/v0/id",
    case httpc:request(post, {Url, [], "application/x-www-form-urlencoded", ""}, [], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            extract_json_string_field(body_text(Body), "ID");
        _ ->
            undefined
    end.

peer_target_ids(Peer) when is_binary(Peer); is_list(Peer) ->
    case multiaddr_peer_id(Peer) of
        undefined -> [];
        Id -> [Id]
    end;
peer_target_ids(#{peer_id := PeerId, addrs := Addrs}) when is_list(Addrs) ->
    lists:usort([
        to_list(PeerId) | [Id || Id <- [multiaddr_peer_id(A) || A <- Addrs], Id =/= undefined]
    ]);
peer_target_ids(#{addrs := Addrs}) when is_list(Addrs) ->
    lists:usort([Id || Id <- [multiaddr_peer_id(A) || A <- Addrs], Id =/= undefined]);
peer_target_ids(_) ->
    [].

multiaddr_peer_id(Addr0) ->
    Addr = to_list(Addr0),
    Parts = string:tokens(Addr, "/"),
    multiaddr_peer_id_parts(Parts).

multiaddr_peer_id_parts(["p2p", Id]) ->
    Id;
multiaddr_peer_id_parts([_, _ | Rest]) ->
    multiaddr_peer_id_parts(Rest);
multiaddr_peer_id_parts(_) ->
    undefined.
extract_json_string_field(Text, Field) ->
    Needle = "\"" ++ Field ++ "\":\"",
    case string:str(Text, Needle) of
        0 ->
            undefined;
        Pos ->
            Start = Pos + length(Needle),
            Rest = string:slice(Text, Start - 1),
            case string:chr(Rest, $") of
                0 -> undefined;
                EndPos -> string:slice(Rest, 0, EndPos - 1)
            end
    end.
