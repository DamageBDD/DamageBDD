-module(damage_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

%% API

-export([start_link/0, stop/0]).
-export([subscribe/0, getinfo/0, reply_event/4]).

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
        test_generate_pdf/0,
        test_simple/0,
        test_post/0
    ]
).
-export([get_posts_since/2]).
-export([get_public_keys/1]).
-export([decode_npub/1]).

%% Define the record to store state

-record(state, {
    conn_pid = undefined,
    streamref = undefined,
    heartbeat_timer = undefined,
    public_key,
    private_key,
    npub_cache
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

subscribe() -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), subscribe).

getinfo() -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), getinfo).

get_posts_since(Npub, Since) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC),
        {get_posts_since, Npub, Since}
    ).

%%% gen_server Callbacks
%% Initialize the server and open a WebSocket connection

init([]) ->
    {ok, Host} = application:get_env(damage, nostr_relay),
    Nsec = damage_utils:pass_get(nostr_nsec_pass_path),
    PrivateKey = list_to_binary(decode_nsec(Nsec)),
    {ok, <<PublicKey/binary>>} = nostrlib_schnorr:new_publickey(PrivateKey),
    {ok, ConnPid} =
        gun:open(
            Host,
            443,
            #{transport => tls, tls_opts => [{verify, verify_peer}]}
        ),
    StreamRef = gun:ws_upgrade(ConnPid, "/", []),
    HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
    gproc:reg_other({n, l, ?NOSTR_PROC}, self()),
    {
        ok,
        #state{
            conn_pid = ConnPid,
            streamref = StreamRef,
            heartbeat_timer = HeartbeatTimer,
            private_key = PrivateKey,
            public_key = PublicKey,
            npub_cache = #{}
        }
    }.

%% Handle synchronous calls (stop request)

handle_call(stop, _From, State) ->
    ?LOG_INFO("Nostr handle_call stop: ~p ", [State]),
    gun:shutdown(State#state.conn_pid),
    {stop, normal, ok, State};
%% Handle asynchronous casts (subscribe request)
handle_call(
    subscribe,
    _From,
    #state{public_key = PublicKey} = State
) ->
    %% Subscribe to all messages
    Timestamp = erlang:system_time(seconds),
    SubscriptionMessage =
        jsx:encode([
            <<"REQ">>,
            <<"damagebdd">>,
            #{kinds => [1], since => Timestamp, '#p' => [lower_hex(PublicKey)]}
        ]),
    ?LOG_INFO("Nostr Sending subscription request: ~p ~p", [State, SubscriptionMessage]),
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
    %gun:shutdown(State#state.conn_pid),
    {reply, ok, State}.

handle_cast(Any, State) ->
    ?LOG_INFO("Nostr got cast message: ~s~n", [Any]),
    {noreply, State}.

%% Handle messages from the WebSocket (gun events)

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State) when
    StreamRef == State#state.streamref
->
    ?LOG_INFO("nost socket upgraded ~p ", [StreamRef]),
    handle_call(subscribe, gun, State),
    {noreply, State#state{conn_pid = ConnPid}};
handle_info({gun_ws, _ConnPid, _, {text, Message}}, State) ->
    ok = handle_event(jsx:decode(Message, [{labels, atom}]), State),
    {noreply, State};
handle_info({gun_ws, _ConnPid, _, {close, _}}, State) ->
    ?LOG_INFO("Nostr WebSocket connection closed~n"),
    {noreply, State};
handle_info({gun_down, _ConnPid, _, _, _}, State) ->
    ?LOG_INFO("Nostr WebSocket connection down~n"),
    {stop, normal, State};
handle_info({gun_up, ConnPid, _StreamRef}, State) ->
    ?LOG_INFO("Nostr info gun_up ~p", [ConnPid]),
    {noreply, State};
handle_info({gun_response, _ConnPid, _, nofin, _, _Headers} = Any, State) ->
    ?LOG_INFO("Nostr gun_response info ~p", [Any]),
    {noreply, State};
handle_info(heartbeat, State) ->
    %% Send a ping message to check the connection
    %ok = gun:ws_send(State#state.conn_pid, State#state.streamref, {ping, <<>>}),
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

handle_event_payload(0, Event, _) ->
    ?LOG_INFO("Got type 0 event ~p", [Event]),
    ok;
handle_event_payload(
    _Found,
    #{id := OriginalEventId, tags := _Tags, content := Content, pubkey := Npub} =
        _Event,
    #state{npub_cache = Cache} = State
) ->
    ?LOG_INFO("Got mention of damagebdd"),
    case re:match(<<"[^\"]Feature.*?">>, Content, [cased]) of
        {ok, Matched} ->
            Feature = lists:sublist(Content, 0, string:index(Matched, ")") + 1),

            case resolve_npub(Npub, Cache) of
                error ->
                    ok;
                notfound ->
                    ok;
                AeAccount ->
                    case damage_ae:balance(AeAccount) of
                        Balance when Balance > 0 ->
                            ?LOG_INFO("Nostr Received feature from: ~s ~s~n", [Npub, Content]),
                            Context = #{npub => Npub, ae_account => AeAccount},
                            AeAccount = resolve_npub(Npub, Cache),
                            Config = damage:get_default_config(AeAccount, 1, []),
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
                            );
                        Other ->
                            ?LOG_INFO("Nostr Received invalid feature from: ~s ~p result ~p~n", [
                                Npub, Content, Other
                            ]),
                            reply_event(
                                OriginalEventId,
                                Npub,
                                <<
                                    "Insufficient balance, please top up balance at `/api/accounts/topup`"
                                >>,
                                State
                            )
                    end
            end;
        none ->
            ?LOG_INFO("Nostr Received invalid message from: ~s ~p~n", [
                Npub, Content
            ])
    end.

handle_event([<<"OK">>, EventAck, true, <<>>] = _Event, _State) ->
    ?LOG_INFO("Got event EventAck for damagebdd topic ~p", [EventAck]),
    ok;
handle_event([<<"EOSE">>, <<"damagebdd">>] = Event, _State) ->
    ?LOG_INFO("Got event EOSE for damagebdd topic ~p", [Event]),
    ok;
handle_event(
    [
        <<"EVENT">>,
        <<"damagebdd">>,
        #{id := _OriginalEventId, tags := _Tags, content := Content, pubkey := Npub} =
            Event
    ],
    State
) ->
    ?LOG_INFO("Got event ~p", [Event]),
    case throttle:check(damage_nostr_rate, Npub) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("Npub ~p exceeded api limit", [Npub]);
        _ ->
            handle_event_payload(
                string:str(string:to_lower(binary_to_list(Content)), "damagebdd"),
                Event,
                State
            )
    end.

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
                hint =>
                    <<
                        "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
                    >>
            };
        #{report_hash := _} = Result ->
            maps:merge(Result, #{status => <<"ok">>})
    end.

get_public_keys(<<"asyncmind">>) ->
    {ok, Npub} = application:get_env(damage, nost_npub),
    [decode_npub(Npub)];
get_public_keys(_) ->
    [].
reply_event(
    OriginalEventId,
    OriginalAuthorPubKey,
    ReplyContent,
    #state{public_key = PublicKey, private_key = PrivateKey} = State
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
    Tags = [
        %% Tag for event ID being replied to
        [<<"e">>, OriginalEventId],
        %% Tag for public key of original author
        [<<"p">>, OriginalAuthorPubKey]
    ],

    Timestamp = erlang:system_time(seconds),
    Event = construct_event(lower_hex(PublicKey), ReplyContent, Timestamp, Tags),
    PostEvent = finalize_event(Event, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_INFO("Nostr Sending message: ~p ~p", [State, EventJson]),
    ok =
        gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
    gun:flush(State#state.conn_pid).

resolve_npub(NPub, Cache) ->
    case catch maps:get(NPub, Cache, undefined) of
        undefined ->
            case catch damage_ae:contract_call_admin_account("resolve_npub", [NPub]) of
                #{decodedResult := EncryptedMetaJson} ->
                    AeAccount = damage_utils:decrypt(base64:decode(EncryptedMetaJson)),
                    ?LOG_DEBUG("cache miss npub ~p ~p", [NPub, AeAccount]),
                    {reply, AeAccount, maps:put(NPub, AeAccount, Cache)};
                Error ->
                    ?LOG_DEBUG("Error  ~p", [Error]),
                    {reply, error, Cache}
            end;
        Meta when is_map(Meta) ->
            ?LOG_DEBUG("Cache hit get Meta ~p", [Meta]),
            {reply, Meta, Cache};
        Error ->
            ?LOG_DEBUG("Error  ~p", [Error]),
            {reply, error, Cache}
    end.
decode_npub(Npub) ->
    {ok, #{data := <<PublicKey:64/binary, "00">>}} =
        bech32:decode(
            Npub,
            [
                {
                    converter,
                    fun(Data) ->
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
        {response, fin, _Status, _Headers} ->
            no_data;
        {response, nofin, _Status, _Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            io:format("~s~n", [Body])
    end.

test() ->
    {ok, ConnPid} =
        gun:open(
            "nos.lol",
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

decode_nsec(Nsec) ->
    {ok, #{data := Data}} = bech32:decode(Nsec),
    {ok, RawPrivateKey} = bech32:convertbits(Data, 5, 8, [{padding, false}]),
    RawPrivateKey.
lower_hex(List) when is_list(List) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(list_to_binary(List)))));
lower_hex(Binary) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Binary)))).

construct_event(PubKey, Content, Timestamp, Tags) ->
    #{
        <<"id">> => <<"">>,
        <<"pubkey">> => PubKey,
        <<"created_at">> => Timestamp,
        <<"kind">> => 1,
        <<"tags">> => Tags,
        <<"content">> => Content,
        <<"sig">> => <<"">>
    }.
serialize_event(Event) ->
    Nip0Evt = [
        0,

        maps:get(<<"pubkey">>, Event),
        maps:get(<<"created_at">>, Event),
        maps:get(<<"kind">>, Event),
        maps:get(<<"tags">>, Event),
        maps:get(<<"content">>, Event)
    ],
    ?LOG_DEBUG("Nip 01 event ~p", [Nip0Evt]),
    Json = jsx:encode(Nip0Evt),
    crypto:hash(sha256, Json).
sign_event(PrivateKey, Hash) ->
    {ok, Signature} = nostrlib_schnorr:sign(Hash, PrivateKey),
    Sig = string:lowercase(
        binary:encode_hex(Signature)
        %crypto:sign(ecdsa, sha256, Hash, [PrivateKey, secp256k1]))
    ),
    Sig.
finalize_event(Event, PrivateKey) ->
    Hash = serialize_event(Event),
    Sig = sign_event(PrivateKey, Hash),
    Event#{<<"id">> => lower_hex(Hash), <<"sig">> => Sig}.

sign_note(Nsec, Content) ->
    sign_note(Nsec, Content, []).
sign_note(Nsec, Content, Tags) ->
    PrivateKey = list_to_binary(decode_nsec(Nsec)),
    {ok, <<PublicKey/binary>>} = nostrlib_schnorr:new_publickey(PrivateKey),
    ?LOG_DEBUG("Privatekey PublicKey ~p ~p", [PrivateKey, PublicKey]),

    Timestamp = erlang:system_time(seconds),
    Event = construct_event(lower_hex(PublicKey), Content, Timestamp, Tags),
    finalize_event(Event, PrivateKey).

test_post() ->
    {ok, ConnPid} =
        gun:open(
            "nos.lol",
            443,
            #{transport => tls, tls_opts => [{verify, verify_peer}]}
        ),
    %ProtocolString = <<"nostr">>,
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:ws_upgrade(ConnPid, "/", []),
    {upgrade, [<<"websocket">>], _} = gun:await(ConnPid, StreamRef),
    %% Post a note

    Nsec = damage_utils:pass_get(nostr_nsec_pass_path),
    PostEvent = sign_note(Nsec, <<"Hello from Erlang!">>),
    ?LOG_DEBUG("sending note ~p", [PostEvent]),
    PostData = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_DEBUG("sending note data ~p", [PostData]),
    Frame = {text, PostData},
    gun:ws_send(ConnPid, StreamRef, Frame),
    {ws, Response} = gun:await(ConnPid, StreamRef),
    ?LOG_DEBUG("got response ~p", [Response]),
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
                    fun(Data) ->
                        {ok, Base8} = bech32:convertbits(Data, 5, 8),
                        Binary = erlang:list_to_binary(Base8),
                        Hex = binary:encode_hex(Binary),
                        {ok, Hex}
                    end
                }
            ]
        ).

test_generate_pdf() -> _DataJson = file:open("test/nostr_pdftest.json").
