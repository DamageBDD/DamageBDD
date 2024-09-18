-module(damage_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, stop/0, subscribe/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Define the record to store state
-record(
  state,
  {
    conn_pid = undefined,
    streamref = undefined
}).
-define(NOSTR_PROC, {?MODULE, nostr}).

%%% API Functions

%% Start the gen_server
start_link() -> gen_server:start_link(?MODULE, [], []).

%% Stop the gen_server
stop() ->
  {ok, Pid} = gproc:lookup_local_name(?NOSTR_PROC),
    gen_server:call(Pid, stop).

%% Subscribe to the relay
subscribe() ->
gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), subscribe).

%%% gen_server Callbacks

%% Initialize the server and open a WebSocket connection
init([]) ->
    {ok, Host} = application:get_env(damage, nostr_relay), 
    {ok, ConnPid} = gun:open(Host, 443,#{
          transport => tls,
          tls_opts => [{verify, none}]
        }),
    %{ok, _} = gun:await_up(ConnPid),
    Ref = gun:ws_upgrade(ConnPid, "/"),
    gproc:reg_other({n, l, ?NOSTR_PROC}, self()),
    ?LOG_INFO("Started damage nostr", []),

    {ok, #state{conn_pid = ConnPid, streamref = Ref}}.

%% Handle synchronous calls (stop request)
handle_call(stop, _From, State) ->
    gun:shutdown(State#state.conn_pid),
    {stop, normal, ok, State};


%% Handle asynchronous casts (subscribe request)
handle_call(subscribe, _From, State) ->
    SubscriptionMessage = <<"[\"REQ\", \"RAND\", {\"kinds\": [1],\"limit\": 8}]">>, %% Subscribe to all messages
    ?LOG_INFO("Nostr Sending message: ~s~n", [SubscriptionMessage]),
    ok =gun:ws_send(State#state.conn_pid, State#state.streamref, {text, SubscriptionMessage}),
  {reply, ok, State}.

handle_cast(Any, State) ->
    ?LOG_INFO("Nostr got cast message: ~s~n", [Any]),
    {noreply, State}.
%% Handle messages from the WebSocket (gun events)
handle_info({gun_ws, _ConnPid, _, {text, Message}}, State) ->
    ?LOG_INFO("Nostr Received message: ~s~n", [Message]),
    {noreply, State};

handle_info({gun_ws, _ConnPid, _, {close, _}}, State) ->
    ?LOG_INFO("Nostr WebSocket connection closed~n"),
    {stop, normal, State};

handle_info({gun_down, _ConnPid, _, _, _}, State) ->
    ?LOG_INFO("Nostr WebSocket connection down~n"),
    {stop, normal, State};
handle_info(Any, State) ->
    ?LOG_INFO("Nostr info ~p", [Any]),
    {stop, normal, State}.

%% Cleanup when the server terminates
terminate(Reason, State) ->
    ?LOG_INFO("Nostr WebSocket connection terminating~p", [Reason]),
    gun:shutdown(State#state.conn_pid),
    ok.

%% No code changes expected in this example
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
