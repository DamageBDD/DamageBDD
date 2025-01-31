-module(damage_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

%% API

-export([start_link/0, stop/0]).
-export([subscribe/0, getinfo/0, reply/3]).

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
    test_nip05/0,
    test_simple/0
  ]
).
-export([get_posts_since/2]).
-export([get_public_keys/1]).
-export([decode_npub/1]).

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

get_posts_since(Npub, Since) ->
  gen_server:call(
    gproc:lookup_local_name(?NOSTR_PROC),
    {get_posts_since, Npub, Since}
  ).

reply(OriginalEventId, OriginalAuthorPubKey, ReplyContent) ->
  gen_server:call(
    gproc:lookup_local_name(?NOSTR_PROC),
    {reply, OriginalEventId, OriginalAuthorPubKey, ReplyContent}
  ).

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
  {ok, _} = gun:await_up(ConnPid, ?DEFAULT_TIMEOUT),
  gproc:reg_other({n, l, ?NOSTR_PROC}, self()),
  StreamRef = gun:ws_upgrade(ConnPid, "/", []),
  {upgrade, [<<"websocket">>], _} = gun:await(ConnPid, StreamRef),
  ?LOG_INFO("Started damage nostr", []),
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1]}]),
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

handle_call(
  {reply, OriginalEventId, OriginalAuthorPubKey, ReplyContent},
  _From,
  State
) ->
  %% Function: send_reply/5
  %% Sends a reply to a Nostr event via WebSocket.
  %%
  %% Params:
  %% - RelayPid: The process ID of the gun WebSocket connection.
  %% - PrivateKey: Your private key (binary).
  %% - OriginalEventId: The ID of the event being replied to.
  %% - OriginalAuthorPubKey: The public key of the original event's author.
  %% - ReplyContent: The content of your reply message.
  PrivateKey = damage_utils:pass_get(
  %% Step 1: Create the event
  PublicKey = get_public_key(PrivateKey),
  Event =
    #{
      <<"pubkey">> => PublicKey,
      <<"created_at">> => os:system_time(second),
      %% Kind 1 for a text event
      <<"kind">> => 1,
      <<"tags">> => [
        %% Tag for event ID being replied to
        [<<"e">>, OriginalEventId],
        %% Tag for public key of original author
        [<<"p">>, OriginalAuthorPubKey]
      ],
      <<"content">> => ReplyContent
    },
  %% Step 2: Generate event ID (hash) and sign the event
  EventId = get_event_id(Event),
  SignedEvent = maps:put(<<"id">>, EventId, Event),
  Signature = sign_event(SignedEvent, PrivateKey),
  FinalEvent = maps:put(<<"sig">>, Signature, SignedEvent),
  %% Step 3: Convert the event to JSON
  EventJson = jsx:encode([<<"EVENT">>, FinalEvent]),
  %% Step 4: Send the event via WebSocket (gun)
  ?LOG_INFO("Nostr Sending message: ~p ~p", [State, EventJson]),
  ok =
    gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
  gun:flush(State#state.conn_pid),
  {reply, ok, State};

handle_call(subscribe, _From, State) ->
  %% Subscribe to all messages
  SubscriptionMessage =
    jsx:encode([<<"REQ">>, <<"damagebdd">>, #{kinds => [1]}]),
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
  ok = handle_event(jsx:decode(Message, [{labels, atom}])),
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

find_feature(Str) ->
  case re:match(<<"[^\"]FeatureK.*?">>, Str, [cased]) of
    {ok, Matched} -> lists:sublist(Str, 0, string:index(Matched, ")") + 1);
    error -> none
  end.


handle_feature(
  AeAccount,
  #{id := _OriginalEventId, tags := _Tags, content := Content, pubkey := Npub} =
    _Event
) ->
  Context = #{npub => Npub, ae_account => AeAccount},
  Config = get_config(Context),
  Feature = find_feature(Content),
  jsx:encode(
    execute_bdd(
      Config,
      damage_context:get_account_context(
        damage_context:get_global_template_context(
          maps:put(feature, Feature, Context)
        )
      ),
      Context
    )
  ).


handle_event_payload(0, _) -> ok;

handle_event_payload(
  _Found,
  #{id := OriginalEventId, tags := _Tags, content := Content, pubkey := Npub} =
    Event
) ->
  case damage_ae:resolve_npub(Npub) of
    error -> ok;
    notfound -> ok;

    AeAccount ->
      case damage_ae:balance(AeAccount) of
        Balance when Balance > 0 ->
          ?LOG_INFO("Nostr Received feature from: ~s ~s~n", [Npub, Content]),
          handle_feature(AeAccount, Event);

        Other ->
          reply(
            OriginalEventId,
            Npub,
            <<
              "Insufficient balance, please top up balance at `/api/accounts/topup` balance:",
              Other/binary
            >>
          )
      end
  end.


handle_event([<<"EOSE">>, <<"damagebdd">>]) -> ok;

handle_event(
  [
    <<"EVENT">>,
    <<"damagebdd">>,
    #{id := _OriginalEventId, tags := _Tags, content := Content, pubkey := Npub} =
      Event
  ]
) ->
  case throttle:check(damage_nostr_rate, Npub) of
    {limit_exceeded, _, _} ->
      ?LOG_WARNING("Npub ~p exceeded api limit", [Npub]);

    _ ->
      handle_event_payload(
        string:str(string:to_lower(binary_to_list(Content)), "damagebdd"),
        Event
      )
  end.


get_config(#{npub := Npub} = _Context) ->
  AeAccount = damage_ae:resolve_npub(Npub),
  damage:get_default_config(AeAccount, 1, []).


execute_bdd(Config, Context, #{feature := FeatureData}) ->
  case damage:execute_data(Config, Context, FeatureData) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      #{
        status => <<"notok">>,
        failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
        line => Line
      };

    {parse_error, LineNo, Message} ->
      ?LOG_DEBUG("nostr execute_bdd failure ~p.", [Message]),
      #{
        status => <<"notok">>,
        message => list_to_binary(Message),
        line => LineNo,
        hint
        =>
        <<
          "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
        >>
      };

    #{report_hash := _} = Result -> maps:merge(Result, #{status => <<"ok">>})
  end.

%% Utility function to get public key from private key

get_public_key(PrivateKey) ->
  %% This would use the elliptic curve (secp256k1) to get the public key
  %% You can use an Erlang NIF library like `libsecp256k1` or custom code
  %% Placeholder: Replace this with actual key generation code
  PublicKey = crypto:hash(sha256, PrivateKey),
  PublicKey.

%% Utility function to generate event ID (hash) from event data

get_event_id(Event) ->
  %% Event ID is the sha256 hash of the serialized event fields
  %% You can customize the serialization as needed
  EventJson = jsx:encode(Event),
  crypto:hash(sha256, EventJson).

%% Utility function to sign the event with the private key

sign_event(Event, PrivateKey) ->
  EventJson = jiffy:encode(Event),
  Signature =
    crypto:sign(ecdsa, sha256, EventJson, [PrivateKey, {curve, secp256k1}]),
  Signature.


get_public_keys(<<"asyncmind">>) ->
  {ok, Npub} = application:get_env(damage, nost_npub),
  [decode_npub(Npub)];

get_public_keys(_) -> [].


decode_npub(Npub) ->
  {ok, #{data := <<PublicKey:64/binary, "00">>}} =
    bech32:decode(
      Npub,
      [
        {
          converter,
          fun
            (Data) ->
              {ok, Base8} = bech32:convertbits(Data, 5, 8),
              Binary = erlang:list_to_binary(Base8),
              Hex = binary:encode_hex(Binary),
              {ok, Hex}
          end
        }
      ]
    ),
  string:lowercase(binary_to_list(PublicKey)).


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


test_nip05() ->
  Npub = "npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc",
  Expected =
    <<"16D114303D8203115918CA34A220E925C022C09168175A5ACE5E9F3B61640947">>,
  ExpectedLen = size(Expected),
  {ok, #{data := <<Expected:ExpectedLen/binary, "00">>}} =
    bech32:decode(
      Npub,
      [
        {
          converter,
          fun
            (Data) ->
              {ok, Base8} = bech32:convertbits(Data, 5, 8),
              Binary = erlang:list_to_binary(Base8),
              Hex = binary:encode_hex(Binary),
              {ok, Hex}
          end
        }
      ]
    ).
