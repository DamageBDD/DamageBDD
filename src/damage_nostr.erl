-module(damage_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

%% API

-export([start_link/0, stop/0, subscribe/0, getinfo/0]).

%% gen_server callbacks

-export(
  [
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    test/0,
    test_simple/0
  ]
).

%% Define the record to store state

-record(
  state,
  {conn_pid = undefined, streamref = undefined, heartbeat_timer = undefined}
).

-define(NOSTR_PROC, {?MODULE, nostr}).

%%% API Functions
%% Start the gen_server

start_link() -> gen_server:start_link(?MODULE, [], []).

%% Stop the gen_server

stop() ->
  {ok, Pid} = gproc:lookup_local_name(?NOSTR_PROC),
  gen_server:call(Pid, stop).

%% Subscribe to the relay

subscribe() -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), subscribe).

getinfo() -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), getinfo).

%%% gen_server Callbacks
%% Initialize the server and open a WebSocket connection

init([]) ->
  {ok, Host} = application:get_env(damage, nostr_relay),
  {ok, ConnPid} =
    gun:open(
      Host,
      443,
      #{transport => tls, tls_opts => [{verify, verify_peer}]}
    ),
  {ok, _} = gun:await_up(ConnPid),
  gproc:reg_other({n, l, ?NOSTR_PROC}, self()),
  StreamRef = gun:ws_upgrade(ConnPid, "/", []),
  {upgrade, [<<"websocket">>], _} = gun:await(ConnPid, StreamRef),
  ?LOG_INFO("Started damage nostr", []),
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1], since => 0}]),
  Frame = {text, SubscriptionMessage},
  gun:ws_send(ConnPid, StreamRef, Frame),
  HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
  {
    ok,
    #state{
      conn_pid = ConnPid,
      streamref = StreamRef,
      heartbeat_timer = HeartbeatTimer
    }
  }.

%% Handle synchronous calls (stop request)

handle_call(stop, _From, State) ->
  ?LOG_INFO("Nostr handle_call stop: ~p ", [State]),
  gun:shutdown(State#state.conn_pid),
  {stop, normal, ok, State};

%% Handle asynchronous casts (subscribe request)
handle_call(getinfo, _From, State) ->
  %% Subscribe to all messages
  SubscriptionMessage = jsx:encode([<<"REQ">>, <<"damagebdd">>, #{}]),
  ?LOG_INFO("Nostr Sending message: ~p ~p", [State, SubscriptionMessage]),
  ok =
    gun:ws_send(
      State#state.conn_pid,
      State#state.streamref,
      {text, SubscriptionMessage}
    ),
  gun:flush(State#state.conn_pid),
  {reply, ok, State};

handle_call(subscribe, _From, State) ->
  %% Subscribe to all messages
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1], since => 0}]),
  ?LOG_INFO("Nostr Sending message: ~p ~p", [State, SubscriptionMessage]),
  ok =
    gun:ws_send(
      State#state.conn_pid,
      State#state.streamref,
      {text, SubscriptionMessage}
    ),
  gun:flush(State#state.conn_pid),
  {reply, ok, State};

handle_call(Any, _From, State) ->
  ?LOG_INFO("Nostr handle_call unknown: ~p ~p", [State, Any]),
  gun:shutdown(State#state.conn_pid),
  {reply, ok, State}.


handle_cast(Any, State) ->
  ?LOG_INFO("Nostr got cast message: ~s~n", [Any]),
  {noreply, State}.

%% Handle messages from the WebSocket (gun events)

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State)
when StreamRef == State#state.streamref ->
  ?LOG_INFO("nost socket upgraded ~p ", [StreamRef]),
  {noreply, State#state{conn_pid = ConnPid}};

handle_info({gun_ws, _ConnPid, _, {text, Message}}, State) ->
  case jsx:decode(Message, [{labels, atom}]) of
    [
      <<"EVENT">>,
      <<"damagebdd">>,
      #{id := _Id, tags := _Tags, content := Content, pubkey := Npub}
    ] ->
      case string:str(string:to_lower(binary_to_list(Content)), "damagebdd") of
        0 -> ok;

        _Found ->
          ?LOG_INFO("Nostr Received message from: ~s ~s~n", [Npub, Content])
      end;

    [<<"EOSE">>, <<"damagebdd">>] -> ok
  end,
  {noreply, State, hibernate};

handle_info({gun_ws, _ConnPid, _, {close, _}}, State) ->
  ?LOG_INFO("Nostr WebSocket connection closed~n"),
  {noreply, State};

handle_info({gun_down, _ConnPid, _, _, _}, State) ->
  ?LOG_INFO("Nostr WebSocket connection down~n"),
  {stop, normal, State};

handle_info({gun_up, ConnPid, StreamRef}, State) ->
  ?LOG_INFO("Nostr info gun_up ~p", [ConnPid]),
  %% Subscribe to all messages
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1], limit => 8}]),
  ?LOG_INFO(
    "Nostr Sending message on gun_up: ~p ~p",
    [State, SubscriptionMessage]
  ),
  ok = gun:ws_send(ConnPid, StreamRef, {text, SubscriptionMessage}),
  gun:flush(State#state.conn_pid),
  {noreply, State};

handle_info({gun_response, _ConnPid, _, nofin, _, _Headers} = Any, State) ->
  ?LOG_INFO("Nostr gun_response info ~p", [Any]),
  {noreply, State};

handle_info(heartbeat, State) ->
  %% Send a ping message to check the connection
  ok = gun:ws_send(State#state.conn_pid, State#state.streamref, {ping, <<>>}),
  %% Reset the heartbeat timer
  %?LOG_INFO("Nostr heartbeat", []),
  HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
  {noreply, State#state{heartbeat_timer = HeartbeatTimer}};

handle_info(Any, State) ->
  ?LOG_INFO("Nostr any info ~p", [Any]),
  {noreply, State}.

%% Cleanup when the server terminates

terminate(Reason, State) ->
  ?LOG_INFO("Nostr WebSocket connection terminating~p", [Reason]),
  gun:shutdown(State#state.conn_pid),
  ok.

%% No code changes expected in this example

code_change(_OldVsn, State, _Extra) -> {ok, State}.

test_simple() ->
  {ok, ConnPid} =
    gun:open(
      "nos.lol",
      443,
      #{transport => tls, tls_opts => [{verify, verify_peer}]}
    ),
  StreamRef = gun:get(ConnPid, "/"),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, _Status, _Headers} -> no_data;

    {response, nofin, _Status, _Headers} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      io:format("~s~n", [Body])
  end.


test() ->
  {ok, ConnPid} =
    gun:open(
      "relay.n057r.club",
      443,
      #{transport => tls, tls_opts => [{verify, verify_peer}]}
    ),
  %ProtocolString = <<"nostr">>,
  {ok, _} = gun:await_up(ConnPid),
  StreamRef = gun:ws_upgrade(ConnPid, "/", []),
  {upgrade, [<<"websocket">>], _} = gun:await(ConnPid, StreamRef),
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1], limit => 8}]),
  Frame = {text, SubscriptionMessage},
  gun:ws_send(ConnPid, StreamRef, Frame),
  {ws, Frame} = gun:await(ConnPid, StreamRef),
  gun:close(ConnPid).
