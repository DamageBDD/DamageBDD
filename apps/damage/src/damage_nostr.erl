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
        test_nip800/0
    ]
).
-export([get_posts_since/2]).
-export([get_public_keys/1]).
-export([get_nostr_json/0]).
-export([get_metadata/1]).
-export([decode_npub/1]).
-export([decode_nsec/1]).
-export([xclip_post/1]).
-export([post_note/1]).
-export([post_bdd/1]).
-export([post_note/3]).
-export([post_bdd/2]).
-export([get_recent_posts/2]).
-export([
    parse_nostrconnect_uri/1,
    nip46_connect/1,
    nip46_send/2,
    nip04_encrypt/3
]).
-export([
    construct_zap_receipt/5,
    construct_http_auth/5,
    publish_zap_receipt/3,
    parse_zap_request/1
]).

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
get_metadata(Npub) -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {get_metadata, Npub}).

get_posts_since(Npub, Since) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC),
        {get_posts_since, Npub, Since}
    ).

post_note(Note) -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {post_note, Note, [], ""}).

post_note(Note, Tags, ImageURL) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {post_note, Note, Tags, ImageURL}).
post_bdd(BDD) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {post_bdd, BDD, []}).
post_bdd(BDD, Tags) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {post_bdd, BDD, Tags}).

get_recent_posts(Npub, Limit) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC), {get_recent_posts, Npub, Limit}).
%% Parse a nostrconnect:// URI into a map
parse_nostrconnect_uri(Uri0) ->
    Uri = to_bin(Uri0),
    <<"nostrconnect://", Rest/binary>> = Uri,
    %% split "<hexpubkey>?query"
    [HexPubKeyBin, QueryBin] = binary:split(Rest, <<"?">>),
    Params = parse_kv_query(QueryBin),
    #{
        % hex-encoded x-only pubkey (32 bytes -> 64 hex)
        app_pubkey => HexPubKeyBin,
        url => maps:get(<<"url">>, Params, <<>>),
        name => maps:get(<<"name">>, Params, <<>>),
        image => maps:get(<<"image">>, Params, <<>>),
        perms => maps:get(<<"perms">>, Params, <<>>),
        secret => maps:get(<<"secret">>, Params, <<>>),
        relays => maps:get(<<"relay">>, Params, [])
    }.

%% Kick off NIP-46 pairing: send {"method":"connect","params":[<our-pubkey>,<secret>]}
%% Returns the signed event you should publish to the listed relays.
nip46_connect(Uri) ->
    M = parse_nostrconnect_uri(Uri),
    AppHex = maps:get(app_pubkey, M),
    Secret = maps:get(secret, M),
    nip46_send(AppHex, #{
        method => <<"connect">>,
        params => [lower_hex(public_key()), Secret]
    }).

%% Low-level: build & encrypt a NIP-46 request to a remote app pubkey (hex)
nip46_send(RemoteHexPubKey, Payload) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC),
        {nip46_send, RemoteHexPubKey, Payload}
    ).

%%% gen_server Callbacks
%% Initialize the server and open a WebSocket connection

init([]) ->
    {ok, Host} = application:get_env(damage, nostr_relay),
    case secrets:retrieve_decrypt(nostr_nsec) of
        {ok, Nsec} ->
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
            %% <- LISTEN TO CLN EVENTS
            cln:register_listener(invoice_paid),
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
            };
        _Error ->
            ?LOG_INFO("!!!! Nostr Integration disabled, set `nostr_nsec` secret."),
            {ok, #state{}}
    end.

%% Handle synchronous calls (stop request)
handle_call(
    {get_recent_posts, Npub, Limit},
    _From,
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Now = erlang:system_time(seconds),
    Filter = #{
        %% Kind 1 = text note
        kinds => [1],
        %% Filter by pubkey
        p => [lower_hex(Npub)],
        %% Reverse chronological fetch starts from now
        until => Now,
        limit => Limit
    },
    SubscriptionId = <<"recent_", (crypto:strong_rand_bytes(4))/binary>>,
    RequestJson = jsx:encode([<<"REQ">>, SubscriptionId, Filter]),
    ?LOG_INFO("Fetching recent posts for ~p: ~p", [Npub, RequestJson]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, RequestJson}),
    {reply, ok, State};
handle_call(
    {zap_note, OriginalEventId, OriginalAuthorPubKey, Amount},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    Tags = [
        %["relays", "wss://nostr-pub.wellorder.com", "wss://anotherrelay.example.com"],
        %["lnurl", "lnurl1dp68gurn8ghj7um5v93kketj9ehx2amn9uh8wetvdskkkmn0wahz7mrww4excup0dajx2mrv92x9xp"],
        ["amount", integer_to_list(Amount)],
        %% Tag for event ID being replied to
        [<<"e">>, OriginalEventId],
        %% Tag for public key of original author
        [<<"p">>, OriginalAuthorPubKey]
    ],

    Timestamp = erlang:system_time(seconds),
    Event = construct_event(lower_hex(PublicKey), 9734, <<"Zap !">>, Timestamp, Tags),
    PostEvent = finalize_event(Event, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_INFO("Nostr Sending message: ~p ~p", [State, EventJson]),
    ok =
        gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
    {ws, {text, Response}} =
        gun:await(ConnPid, StreamRef),
    ?LOG_DEBUG("got response ~p", [Response]),
    {reply, Response, State};
handle_call(
    {post_note, Content, Tags, ImageURL},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    Timestamp = erlang:system_time(seconds),
    Event = construct_note(lower_hex(PublicKey), Content, Timestamp, Tags, ImageURL),
    PostEvent = finalize_event(Event, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_INFO("Nostr Sending message: ~p ~p", [State, EventJson]),
    gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
    {ws, {text, Response}} =
        gun:await(ConnPid, StreamRef),
    ?LOG_DEBUG("got response ~p", [Response]),
    {reply, Response, State};
handle_call(
    {post_bdd, BDD, Tags},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    Timestamp = erlang:system_time(seconds),
    Event = construct_bdd(lower_hex(PublicKey), BDD, Timestamp, Tags),
    PostEvent = finalize_event(Event, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_INFO("Nostr Sending bdd: ~p ~p", [State, EventJson]),
    gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
    {ws, {text, Response}} =
        gun:await(ConnPid, StreamRef),
    ?LOG_DEBUG("got response ~p", [Response]),
    {reply, Response, State};
handle_call(stop, _From, State) ->
    ?LOG_INFO("Nostr handle_call stop: ~p ", [State]),
    gun:shutdown(State#state.conn_pid),
    {stop, normal, ok, State};
handle_call(
    {get_metadata, Npub},
    _From,
    #state{public_key = _PublicKey} = State
) ->
    ProfileRequest =
        jsx:encode([
            <<"REQ">>,
            <<"kind">>,
            #{kinds => [0], <<"authors">> => [lower_hex(Npub)]}
        ]),
    ?LOG_INFO("Nostr Sending profile request: ~p ~p", [State, ProfileRequest]),
    ok =
        gun:ws_send(
            State#state.conn_pid,
            State#state.streamref,
            {text, ProfileRequest}
        ),
    gun:flush(State#state.conn_pid),
    {reply, ok, State};
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
handle_call(
    {nip46_send, RemoteHex, Payload},
    _From,
    #state{public_key = PubKey, private_key = PrivKey} = State
) ->
    TS = erlang:system_time(seconds),

    %% 1) Encrypt JSON payload with NIP-04 using ECDH(PrivKey, RemotePubKey)
    Plain = jsx:encode(Payload),
    {ok, CipherB64, _IvB64} = nip04_encrypt(Plain, PrivKey, RemoteHex),

    %% 2) Build kind 24133 event with required tags:
    %%    ["p", <receiver-pubkey>] and (optionally) one or more ["relay", <wss://...>]
    Tags = [[<<"p">>, RemoteHex]],
    Event0 = construct_event(lower_hex(PubKey), 24133, CipherB64, TS, Tags),

    %% 3) Sign as usual (you already have finalize_event/2)
    Event = finalize_event(Event0, PrivKey),

    {reply, #{event => Event}, State};
handle_call(Any, _From, State) ->
    ?LOG_INFO("Nostr handle_call unknown: ~p ~p", [State, Any]),
    %gun:shutdown(State#state.conn_pid),
    {reply, ok, State}.

handle_cast(Any, State) ->
    ?LOG_INFO("Nostr got cast message: ~s~n", [Any]),
    {noreply, State}.

handle_info({cln_event, invoice_paid, Invoice}, State) ->
    try
        zap_receipt_for_invoice(Invoice, State)
    catch
        _:Reason ->
            ?LOG_WARNING("Failed to send zap receipt: ~p", [Reason])
    end,
    {noreply, State};
% Handle messages from the WebSocket (gun events)
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
handle_info(reward, State) ->
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
    FeatureRe = <<"[^\"]Feature.*?">>,
    case re:run(Content, FeatureRe) of
        {match, Matched} ->
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
                            Context = #{npub => Npub, public_key => AeAccount},
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
        Notmatched ->
            reward_mention(Npub),
            ?LOG_INFO("Nostr Received invalid message from: ~s ~p ~p~n", [
                Npub, Content, Notmatched
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

get_public_keys(<<"coordinator">>) ->
    {ok, Npub} = application:get_env(bop, nostr_npub),
    [decode_npub(Npub)];
get_public_keys(<<"asyncmind">>) ->
    {ok, Npub} = application:get_env(damage, nostr_npub),
    [decode_npub(Npub)];
get_public_keys(_) ->
    [].
get_nostr_json() ->
    {ok, BopNpub} = application:get_env(bop, nostr_npub),
    {ok, DamageNpub} = application:get_env(damage, nostr_npub),
    #{
        names => #{
            asyncmind => list_to_binary(decode_npub(DamageNpub)),
            damage => list_to_binary(decode_npub(DamageNpub)),
            coordinator => list_to_binary(decode_npub(BopNpub))
        }
    }.

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
    Event = construct_note(lower_hex(PublicKey), ReplyContent, Timestamp, Tags),
    PostEvent = finalize_event(Event, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, PostEvent]),
    ?LOG_INFO("Nostr Sending message: ~p ~p", [State, EventJson]),
    ok =
        gun:ws_send(State#state.conn_pid, State#state.streamref, {text, EventJson}),
    gun:flush(State#state.conn_pid).

resolve_npub(NPub, Cache) ->
    case catch maps:get(NPub, Cache, undefined) of
        undefined ->
            case identity_server:get_account_by_npub(NPub) of
                #{decodedResult := EncryptedMetaJson} ->
                    AeAccount = secrets:decrypt(EncryptedMetaJson),
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

decode_nsec(Nsec) ->
    {ok, #{data := Data}} = bech32:decode(Nsec),
    {ok, RawPrivateKey} = bech32:convertbits(Data, 5, 8, [{padding, false}]),
    RawPrivateKey.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(Else) -> iolist_to_binary(Else).

hash_sha256_hex(Bin) ->
    lower_hex(crypto:hash(sha256, Bin)).

%% NIP-98: HTTP Auth event
%% kind: 27235
%% tags:
%%   ["u", "<URL>"]
%%   ["method", "<METHOD>"]
%%   ["payload", "<sha256-hex>"]   %% only if body present
construct_http_auth(PubKey, Url, Method, Timestamp, Body) ->
    BaseTags = [
        [<<"u">>, Url],
        [<<"method">>, Method]
    ],
    Tags1 =
        case Body of
            <<>> -> BaseTags;
            _ -> BaseTags ++ [[<<"payload">>, hash_sha256_hex(Body)]]
        end,
    construct_event(PubKey, 27235, <<>>, Timestamp, Tags1).

%% ---- Zap receipt helpers ----------------------------------------------------

%% Parse the zap request JSON (stored in the BOLT11 description) into a map.
%% Returns {ok, #{...}} or {error, Reason}.
parse_zap_request(DescBin) when is_binary(DescBin) ->
    try jsone:decode(DescBin) of
        M when is_map(M) -> {ok, M}
    catch
        _:E -> {error, {invalid_zap_request_json, E}}
    end.

%% Fetch the first tag value by name, e.g. <<"p">>, <<"e">>, <<"a">>, <<"relays">>.
%% Tags are the Nostr "tags" array from the zap request event.
find_tag_value(Tags, Name) ->
    case lists:filter(fun([N | _]) -> N =:= Name end, Tags) of
        [[_N, V | _Rest] | _] -> {ok, V};
        _ -> not_found
    end.

%% Fetch *all* values in a tag after its name, useful for ["relays", R1, R2, ...].
find_tag_values(Tags, Name) ->
    case lists:filter(fun([N | _]) -> N =:= Name end, Tags) of
        [[_N | Vs] | _] -> {ok, Vs};
        _ -> not_found
    end.

%% Optional: verify SHA256(description) matches the BOLT11 description hash.
%% If you have a bolt11 decoder exposing description hash, plug it here.
verify_description_hash(_Bolt11, DescBin) ->
    %% TODO: replace with real BOLT11 description_hash extraction if available.
    %% For now we just compute SHA256(description) and return it for the caller
    %% to compare against their own BOLT11 parser if wired up elsewhere.
    {ok, crypto:hash(sha256, DescBin)}.

%% Build the tags for the zap receipt from the zap request event.
%% Ensures required ["p", ...], includes optional ["e", ...], ["a", ...], ["P", <sender-pubkey>],
%% plus ["bolt11", ...], ["description", <json>], and optional ["preimage", ...].
zap_receipt_tags(ZapReq, Bolt11, ZapReqJsonBin, MaybePreimage) ->
    Tags = maps:get(<<"tags">>, ZapReq, []),
    %% Required p-tag (zap recipient)
    PTag =
        case find_tag_value(Tags, <<"p">>) of
            {ok, P} -> [[<<"p">>, P]];
            _ -> erlang:error(missing_p_tag)
        end,
    %% Optional tags from zap request
    ETag =
        case find_tag_value(Tags, <<"e">>) of
            {ok, E} -> [[<<"e">>, E]];
            _ -> []
        end,
    ATag =
        case find_tag_value(Tags, <<"a">>) of
            {ok, A} -> [[<<"a">>, A]];
            _ -> []
        end,
    %% Capital P tag is the zap sender public key (from zap request's pubkey field)
    PcapTag =
        case maps:get(<<"pubkey">>, ZapReq, undefined) of
            undefined -> [];
            SenderPub -> [[<<"P">>, SenderPub]]
        end,
    Core =
        PTag ++ ETag ++ ATag ++ PcapTag ++
            [
                [<<"bolt11">>, Bolt11],
                [<<"description">>, ZapReqJsonBin]
            ],
    case MaybePreimage of
        <<>> -> Core;
        undefined -> Core;
        Bin when is_binary(Bin) -> Core ++ [[<<"preimage">>, Bin]]
    end.

%% Construct an *unsigned* zap receipt event (kind 9735). You still need to finalize_event/2.
%% PaidAt: integer (invoice paid_at UTC seconds)
%% Bolt11: binary
%% ZapReq: map (decoded zap request event)
%% ZapReqJsonBin: original JSON blob for the "description" tag
%% MaybePreimage: <<>> | undefined | <<preimage-hex-or-bin>>
construct_zap_receipt(PaidAt, Bolt11, ZapReq, ZapReqJsonBin, MaybePreimage) ->
    %% Pubkey is filled by the caller (we sign with our node key)
    Tags = zap_receipt_tags(ZapReq, Bolt11, ZapReqJsonBin, MaybePreimage),
    %% content MUST be empty, created_at SHOULD be invoice paid_at
    fun(PubKeyLowerHex) ->
        construct_event(PubKeyLowerHex, 9735, <<>>, PaidAt, Tags)
    end.

%% Publish a signed zap receipt to relays declared in the zap request, if present.
%% Falls back to the currently-connected relay if none were provided.
publish_zap_receipt(
    #state{conn_pid = ConnPid, streamref = StreamRef} = _State,
    SignedEvent,
    ZapReq
) ->
    Tags = maps:get(<<"tags">>, ZapReq, []),
    Relays =
        case find_tag_values(Tags, <<"relays">>) of
            {ok, Rs} -> Rs;
            _ -> []
        end,
    EventJson = jsx:encode([<<"EVENT">>, SignedEvent]),
    case Relays of
        [] ->
            %% No relays tag -> send to our current connection
            ok = gun:ws_send(ConnPid, StreamRef, {text, EventJson}),
            ok;
        _Some ->
            %% You can extend this to multiplex connections.
            %% For now, also send to the current connection (best effort).
            ok = gun:ws_send(ConnPid, StreamRef, {text, EventJson}),
            ok
    end.

%% --- Query parsing and misc ---

parse_kv_query(QsBin) ->
    Pairs = [binary:split(KV, <<"=">>) || KV <- binary:split(QsBin, <<"&">>, [global])],
    lists:foldl(
        fun
            ([K, V], Acc) ->
                DecK = uri_string:percent_decode(K),
                DecV = uri_string:percent_decode(V),
                case DecK of
                    <<"relay">> ->
                        %% accumulate multiple relay keys into a list
                        maps:update_with(
                            <<"relay">>,
                            fun(List) -> [DecV | List] end,
                            [DecV],
                            Acc
                        );
                    _ ->
                        maps:put(DecK, DecV, Acc)
                end;
            (_Other, Acc) ->
                Acc
        end,
        #{},
        Pairs
    ).

public_key() ->
    %% Your state keeps PubKey; expose a quick accessor via getinfo if you like.
    %% Here we just return a placeholder. Replace with your own if needed.
    %% Since this helper is called inside gen_server (nip46_send), we pass PubKey there.
    error(not_used).

%% --- NIP-04 encryption (AES-256-CBC with base64 result + iv) ---

nip04_encrypt(PlainJson, PrivKey, RemoteHex) ->
    %% Derive shared secret with ECDH(secp256k1).
    %% RemoteHex is 64-hex x-only. We don't know parity; try 02 then 03.
    RemoteX = hex_to_bin(RemoteHex),
    case try_ecdh(RemoteX, PrivKey, 16#02) of
        {ok, Secret} ->
            ok_encrypt(Secret, PlainJson);
        error ->
            case try_ecdh(RemoteX, PrivKey, 16#03) of
                {ok, Secret2} -> ok_encrypt(Secret2, PlainJson);
                error -> {error, ecdh_failed}
            end
    end.

ok_encrypt(SharedSecret, PlainJson) ->
    %% 32 bytes
    Key = crypto:hash(sha256, SharedSecret),
    Iv = crypto:strong_rand_bytes(16),
    Cipher = crypto:crypto_one_time(aes_256_cbc, Key, Iv, pkcs_padding(PlainJson), true),
    {ok, base64:encode(Cipher), base64:encode(Iv)}.

pkcs_padding(Bin) ->
    %% crypto:crypto_one_time/5 with 'true' already handles PKCS#7, but some OTPs expect raw block input.
    %% Keep as-is; Erlang/OTP >= 25 handles pkcs padding with the boolean flag.
    Bin.

hex_to_bin(Hex) -> list_to_binary(binary:decode_hex(Hex)).

%% Compose a compressed SEC pubkey (02/03 + X) and do ECDH
try_ecdh(RemoteX32, PrivKey32, Prefix) ->
    case
        catch crypto:compute_key(
            ecdh,
            <<Prefix, RemoteX32/binary>>,
            PrivKey32,
            ec_secp256k1
        )
    of
        Secret when is_binary(Secret) -> {ok, Secret};
        _ -> error
    end.

lower_hex(List) when is_list(List) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(list_to_binary(List)))));
lower_hex(Binary) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Binary)))).

construct_event(PubKey, Kind, Content, Timestamp, Tags) ->
    #{
        <<"id">> => <<"">>,
        <<"pubkey">> => PubKey,
        <<"created_at">> => Timestamp,
        <<"kind">> => Kind,
        <<"tags">> => Tags,
        <<"content">> => Content,
        <<"sig">> => <<"">>
    }.
construct_bdd(PubKey, BddContent, Timestamp, Tags) ->
    construct_event(PubKey, 800, BddContent, Timestamp, Tags).
construct_note(PubKey, Content, Timestamp, Tags, "") ->
    construct_event(PubKey, 1, Content, Timestamp, Tags);
construct_note(PubKey, Content, Timestamp, Tags, ImageURL) ->
    maps:put(<<"image">>, ImageURL, construct_event(PubKey, 1, Content, Timestamp, Tags)).
construct_note(PubKey, Content, Timestamp, Tags) ->
    construct_event(PubKey, 1, Content, Timestamp, Tags).
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

test() ->
    post_note(<<"Hello from Erlang!">>).
test_nip800() ->
    post_bdd(file:read_file("features/jsontest.feature")).

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
xclip_post(AltText) ->
    {ok, [{stdout, Stdout}]} = exec:run("xclip -o -selection clipboard \n", [stdout, sync]),
    {ok, [{stdout, ImageFile}]} = exec:run(
        "rofi -show filebrowser -filebrowser-command 'echo' -modes filebrowser \n", [stdout, sync]
    ),
    {ok, Hash} = damage_ipfs:add({file, ImageFile}),
    ImageURL = "https://damagebdd.com/ipfs/" ++ Hash,
    ImageURLBin = list_to_binary(ImageURL),
    Content = unicode:characters_to_binary(string:trim(Stdout)),
    ContentType = <<"image/webp">>,
    BlurHash = <<"eVF$^OI:${M{o#*0-nNFxakD-?xVM}WEWB%iNKxvR-oetmo#R-aen$">>,
    Dimensions = <<"3024x4032">>,
    ImgHash = lower_hex(file:read_file(ImageFile)),
    Fallback1 = <<"https://nostrcheck.me/alt1.jpg">>,
    Fallback2 = <<"https://void.cat/alt1.jpg">>,
    Tags = [
        [<<"t">>, <<"ECAI">>],
        [<<"t">>, <<"Curve Encoding">>],
        [<<"t">>, <<"Dark Matter">>],
        [<<"t">>, <<"Astrophysics">>],
        [
            <<"imeta">>,
            <<"url ", ImageURLBin/binary>>,
            <<"m ", ContentType/binary>>,
            <<"blurhash", BlurHash/binary>>,
            <<"dim ", Dimensions/binary>>,
            <<"alt ", AltText/binary>>,
            <<"x ", ImgHash/binary>>,
            <<"fallback ", Fallback1/binary>>,
            <<"fallback ", Fallback2/binary>>
        ]
    ],
    post_note(Content, Tags, ImageURL).

reward_mention(Npub) ->
    AmountSats = 100,
    case throttle:check(damage_nostr_mention_reward, Npub) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("Npub ~p exceeded reward limit", [Npub]),
            {429, <<"throttled">>};
        _ ->
            get_ln_invoice(Npub, AmountSats)
    end.
get_ln_invoice(Npub, AmountSats) ->
    case get_lnurl_from_npub(Npub) of
        {ok, LnUrl} ->
            fetch_ln_invoice(LnUrl, AmountSats);
        {error, Reason} ->
            {error, Reason}
    end.

%% Query a relay for the npub's metadata and extract LNURL
get_lnurl_from_npub(Npub) ->
    extract_lnurl(get_metadata(Npub)).

%% Extract LNURL from metadata
extract_lnurl(Content) ->
    case jsone:decode(Content) of
        #{<<"lud16">> := LightningAddress} ->
            {ok, "https://" ++ LightningAddress ++ "/.well-known/lnurlp/"};
        #{<<"lud06">> := LnUrlEncoded} ->
            {ok, bech32:decode(LnUrlEncoded)};
        _ ->
            {error, "LNURL not found"}
    end.

%% Fetch a Lightning invoice from LNURL
fetch_ln_invoice(LnUrl, AmountSats) ->
    InvoiceRequestUrl = LnUrl ++ "?amount=" ++ integer_to_list(AmountSats * 1000),
    case httpc:request(get, {InvoiceRequestUrl, []}, [], []) of
        {ok, {_, _, Body}} ->
            case jsone:decode(Body) of
                #{<<"pr">> := Invoice} -> {ok, Invoice};
                _ -> {error, "Invalid response"}
            end;
        Error ->
            Error
    end.
%% Given a CLN invoice-paid payload, build and publish a zap-receipt (kind 9735)
%% when the BOLT11 description contains a zap request event (kind 9734).
zap_receipt_for_invoice(Invoice, #state{public_key = PubKey, private_key = PrivKey} = State) ->
    %% Expected keys from CLN: bolt11, description, paid_at, payment_preimage (names vary by plugin)
    Bolt11 = maps:get(bolt11, Invoice, <<>>),
    DescBin = maps:get(description, Invoice, <<>>),
    PaidAt = maps:get(paid_at, Invoice, erlang:system_time(seconds)),
    Preimage = maps:get(payment_preimage, Invoice, undefined),

    case parse_zap_request(DescBin) of
        {ok, ZapReq} ->
            %% (Optional) verify SHA256(description) == description_hash(BOLT11)
            _ = verify_description_hash(Bolt11, DescBin),

            %% Build unsigned event with the correct created_at and tags
            Builder = construct_zap_receipt(PaidAt, Bolt11, ZapReq, DescBin, Preimage),
            UnsignedEvent = Builder(lower_hex(PubKey)),

            %% Sign and publish
            Signed = finalize_event(UnsignedEvent, PrivKey),
            publish_zap_receipt(State, Signed, ZapReq),
            ok;
        {error, Reason} ->
            ?LOG_WARNING("Invoice paid but no valid zap request in description: ~p", [Reason]),
            ok
    end.
