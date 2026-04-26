-module(damage_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

%% API

-export([start_link/1, stop/1]).
-export([subscribe/1, getinfo/1, reply_event/4]).
-export([handle_continue/2]).
-export([
    service_pubkey_hex/0,
    public_key_hex/0,
    create_signed_event/3,
    nwc_decode_request/1,
    nwc_encode_response/3
]).

%% gen_server callbacks

-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3,
        test_nip05/0,
        test_generate_pdf/0,
        test_simple/0,
        test_nip800/0,
        test_get_recent_posts/0,
        test_get_posts_since/0,
        test_zap_note/0,
        test_nwc_roundtrip/0
    ]
).
-export([get_posts_since/3]).
-export([get_posts_since/2]).
-export([get_public_keys/1]).
-export([get_nostr_json/0]).
-export([get_metadata/2]).
-export([nsec_to_npub/1]).
-export([decode_npub/1]).
-export([decode_nsec/1]).
-export([xclip_post/2]).
-export([post_note/2]).
-export([post_bdd/1]).
-export([post_note/4]).
-export([zap_note/3]).
-export([zap_note/4]).
-export([post_bdd/2]).
-export([get_recent_posts/2]).
-export([
    parse_nostrconnect_uri/1,
    nip46_connect/2,
    nip46_send/3,
    nip04_encrypt/3,
    nip04_decrypt/4,
    nip04_decrypt_content/3,
    construct_event/5,
    finalize_event/2,
    parse_kv_query/1
]).
-export([
    construct_zap_receipt/5,
    construct_http_auth/5,
    publish_zap_receipt/3,
    parse_zap_request/1,
    construct_nip56_report/6,
    post_report/6,
    fetch_event_by_id/2,
    npub_or_hex_to_lower_hex64/1
]).
-export([pp_event/1, pp_event/2, pp_events/1]).
-export([
    generate_nsec/0,
    generate_nostr_keypair/0
]).
-export([
    relay_profile/1,
    relay_ws_headers/2,
    open_relay_ws/2,
    open_best_relay_ws/2,
    default_relays/0,
    configured_relays/0,
    normalize_relay/1,
    normalize_relays/1
]).
-export([
    score_relays/1,
    parse_ws_url/1,
    relay_score/1
]).
-export([relay_proxy/1]).
-import(damage_utils, [to_bin/1]).

%% Define the record to store state

-record(state, {
    conn_pid = undefined,
    streamref = undefined,
    heartbeat_timer = undefined,
    public_key,
    private_key,
    npub_cache = #{},
    reconnect_ms = 5000,
    retry_count = 0,
    max_retries = 10,
    relay = undefined,
    stopped = false
}).

-define(NOSTR_PROC(Nsec), {?MODULE, Nsec}).
-define(NOSTR_DEFAULT_TIMEOUT, 300000).
-define(NOSTR_DEFAULT_FANOUT, 3).
-define(NOSTR_DEFAULT_EVENT_LIMIT, 50).
-define(SECP256K1_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).
-define(SECP256K1_GX, 16#79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798).
-define(SECP256K1_GY, 16#483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8).

-record(point, {
    x = 0 :: pos_integer(),
    y = 0 :: pos_integer()
}).

has_even_y_local(#point{y = Y}) -> (Y rem 2) =:= 0;
has_even_y_local(_) -> false.

normalize_bip340_scalar(PrivKey32) ->
    D0 = binary:decode_unsigned(PrivKey32),
    G = #point{x = ?SECP256K1_GX, y = ?SECP256K1_GY},
    case nostrlib_schnorr:point_mul(G, D0) of
        infinity ->
            erlang:error(invalid_private_key_point);
        P ->
            case has_even_y_local(P) of
                true -> D0;
                false -> ?SECP256K1_N - D0
            end
    end.
-spec schnorr_ecdh_xonly(binary(), binary()) -> {ok, binary()} | {error, term()}.
schnorr_ecdh_xonly(PrivKey32, XOnly32) when
    is_binary(PrivKey32),
    byte_size(PrivKey32) =:= 32,
    is_binary(XOnly32),
    byte_size(XOnly32) =:= 32
->
    try
        D = normalize_bip340_scalar(PrivKey32),
        case nostrlib_schnorr:lift_x(binary:decode_unsigned(XOnly32)) of
            infinity ->
                {error, invalid_remote_point};
            RemotePoint ->
                SharedPoint = nostrlib_schnorr:point_mul(RemotePoint, D),
                case SharedPoint of
                    infinity ->
                        {error, invalid_shared_point};
                    _ ->
                        SharedX = nostrlib_schnorr:point_to_bitstring(SharedPoint),
                        {ok, SharedX}
                end
        end
    catch
        C:R:S ->
            {error, {ecdh_failed, C, R, S}}
    end.

%%% API Functions
%% Start the gen_server

start_link(NsecKey) -> gen_server:start_link(?MODULE, [NsecKey], []).

%% Stop the gen_server

stop(NsecKey) ->
    {ok, Pid} = gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
    gen_server:call(Pid, stop).

%% Subscribe to the relay

subscribe(NsecKey) -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), subscribe).

getinfo(NsecKey) -> gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), getinfo).
get_metadata(NsecKey, Npub) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), {get_metadata, Npub}).

get_posts_since(NsecKey, Npub, Since) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
        {get_posts_since, Npub, Since},
        ?NOSTR_DEFAULT_TIMEOUT
    ).

get_posts_since(Npub, Since) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(damage_nostr_nsec)), {get_posts_since, Npub, Since}
    ).
fetch_event_by_id(NsecKey, EventId) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), {fetch_event_by_id, EventId}).
post_note(NsecKey, Note) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), {post_note, Note, [], ""}).

post_note(NsecKey, Note, Tags, ImageURL) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)), {post_note, Note, Tags, ImageURL}
    ).
zap_note(NsecKey, NoteId, Amount) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
        {zap_note, NoteId, Amount},
        ?NOSTR_DEFAULT_TIMEOUT
    ).
zap_note(NsecKey, NoteId, Author, Amount) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
        {zap_note, NoteId, Author, Amount},
        ?NOSTR_DEFAULT_TIMEOUT
    ).
post_bdd(BDD) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(nostr_nsec)), {post_bdd, BDD, []}).
post_bdd(BDD, Tags) ->
    gen_server:call(gproc:lookup_local_name(?NOSTR_PROC(nostr_nsec)), {post_bdd, BDD, Tags}).

get_recent_posts(NsecKey, Limit) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(damage_nostr_nsec)), {get_recent_posts, NsecKey, Limit}
    ).
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
nip46_connect(NsecKey, Uri) ->
    M = parse_nostrconnect_uri(Uri),
    AppHex = maps:get(app_pubkey, M),
    Secret = maps:get(secret, M),
    nip46_send(NsecKey, AppHex, #{
        method => <<"connect">>,
        params => [npub_or_hex_to_lower_hex64(public_key()), Secret]
    }).

%% Low-level: build & encrypt a NIP-46 request to a remote app pubkey (hex)
nip46_send(NsecKey, RemoteHexPubKey, Payload) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
        {nip46_send, RemoteHexPubKey, Payload}
    ).
nsec_to_npub(Nsec) ->
    PrivateKey = iolist_to_binary(decode_nsec(Nsec)),
    {ok, <<PublicKey/binary>>} = nostrlib_schnorr:new_publickey(PrivateKey),
    {PublicKey, PrivateKey}.

%%% gen_server Callbacks
%% Initialize the server and open a WebSocket connection

init([NsecKey]) ->
    Relay = first_configured_relay(),
    case secrets:retrieve_decrypt(NsecKey) of
        {ok, Nsec} ->
            {PublicKey, PrivateKey} = nsec_to_npub(Nsec),
            gproc:reg_other({n, l, ?NOSTR_PROC(NsecKey)}, self()),
            cln:register_listener(invoice_paid),
            State0 = #state{
                public_key = PublicKey,
                private_key = PrivateKey,
                npub_cache = #{},
                relay = Relay,
                reconnect_ms = 5000,
                max_retries = 10
            },
            {ok, State0, {continue, connect}};
        _ ->
            ?LOG_INFO("!!!! Nostr Integration disabled, set `~p` secret.", [NsecKey]),
            {ok, #state{stopped = true}}
    end.
handle_continue(connect, State) ->
    case application:get_env(damage, api_url) of
        {ok, DamageApi} ->
            NewState =
                try
                    maybe_connect(State, DamageApi)
                catch
                    C:R:S ->
                        ?LOG_ERROR("nostr connect crash ~p", [
                            #{class => C, reason => R, stack => S}
                        ]),
                        schedule_reconnect(State)
                end,
            {noreply, NewState};
        _ ->
            {noreply, State}
    end.
open_nostr_ws(Relay, DamageApi) ->
    Headers = [
        {<<"origin">>, list_to_binary(DamageApi)}
    ],
    case open_relay_ws(Relay, #{ws_headers => Headers, connect_timeout => 15000}) of
        {ok, ConnPid, StreamRef} ->
            {ok, ConnPid, StreamRef};
        {error, Reason} ->
            ?LOG_ERROR("Nostr websocket open failed relay=~p proxy=~p reason=~p", [
                Relay,
                damage_gun:proxy(),
                Reason
            ]),
            {error, Reason}
    end.
maybe_connect(#state{stopped = true} = State, _DamageApi) ->
    State;
maybe_connect(#state{conn_pid = ConnPid} = State, _DamageApi) when is_pid(ConnPid) ->
    State;
maybe_connect(#state{retry_count = Retry, max_retries = Max} = State, _DamageApi) when
    Retry >= Max
->
    ?LOG_ERROR("Nostr reconnect limit reached (~p/~p). Stopping reconnects.", [Retry, Max]),
    State#state{stopped = true, conn_pid = undefined, streamref = undefined};
maybe_connect(#state{relay = Relay, retry_count = Retry} = State, DamageApi) ->
    case open_nostr_ws(Relay, DamageApi) of
        {ok, ConnPid, StreamRef} ->
            HeartbeatTimer = erlang:send_after(10000, self(), heartbeat),
            State#state{
                conn_pid = ConnPid,
                streamref = StreamRef,
                heartbeat_timer = HeartbeatTimer,
                retry_count = 0,
                stopped = false
            };
        {error, Reason} ->
            Retry1 = Retry + 1,
            ?LOG_WARNING("Nostr connect failed host=~p attempt ~p/~p reason=~p", [
                Relay, Retry1, State#state.max_retries, Reason
            ]),
            schedule_reconnect(
                State#state{
                    conn_pid = undefined,
                    streamref = undefined,
                    retry_count = Retry1
                }
            )
    end.

schedule_reconnect(#state{stopped = true} = State) ->
    State;
schedule_reconnect(#state{retry_count = Retry, max_retries = Max} = State) when Retry >= Max ->
    ?LOG_ERROR("Nostr reconnect suppressed after ~p/~p failures.", [Retry, Max]),
    State#state{stopped = true};
schedule_reconnect(#state{reconnect_ms = ReconnectMs} = State) ->
    erlang:send_after(ReconnectMs, self(), reconnect),
    State.

clear_connection(State) ->
    State#state{
        conn_pid = undefined,
        streamref = undefined,
        heartbeat_timer = undefined
    }.

%% Handle synchronous calls (stop request)
handle_call(
    {post_report, ReportedPubKey, MaybeEventId, ReportType, Content, Opts},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    Unsigned =
        construct_nip56_report(
            PublicKey,
            ReportedPubKey,
            MaybeEventId,
            ReportType,
            Content,
            Opts
        ),
    Signed = finalize_event(Unsigned, PrivateKey),
    EventJson = jsx:encode([<<"EVENT">>, Signed]),
    ?LOG_INFO("Nostr Sending NIP-56 report: ~p", [EventJson]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, EventJson}),
    {ws, {text, Response}} = gun:await(ConnPid, StreamRef),
    {reply, Response, State};
handle_call(
    {get_posts_since, Npub, Since},
    _From,
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Filter = #{
        %% Kind 1 = text note
        kinds => [1],
        %% Posts authored by pubkey
        authors => [npub_or_hex_to_lower_hex64(Npub)],
        since => Since,
        %% relay may cap; callers can slice further
        limit => ?NOSTR_DEFAULT_EVENT_LIMIT
    },

    SubRand = crypto:strong_rand_bytes(4),
    SubscriptionId = <<"since_", (binary:encode_hex(SubRand))/binary>>,

    RequestJson = jsx:encode([<<"REQ">>, SubscriptionId, Filter]),
    ?LOG_INFO("Fetching posts since ~p for ~p: ~p", [Since, Npub, RequestJson]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, RequestJson}),

    %% Await all events until EOSE (or timeout)
    Reply = await_events_or_eose(ConnPid, StreamRef, SubscriptionId, ?NOSTR_DEFAULT_TIMEOUT),
    %?LOG_INFO("Fetche posts since ~p for ~p: ~p", [Since, Npub, Reply]),
    QueriedAuthor = npub_or_hex_to_lower_hex64(Npub),

    Reply1 =
        case Reply of
            {ok, Events0} when is_list(Events0) ->
                {ok, filter_events_by_authors(Events0, [QueriedAuthor])};
            Other ->
                Other
        end,

    %% Always close subscription (best practice)
    _ = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode([<<"CLOSE">>, SubscriptionId])}),

    {reply, Reply1, State};
handle_call(
    {get_recent_posts, Npub, Limit},
    _From,
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Now = erlang:system_time(seconds),
    Filter = #{
        %% Kind 1 = text note
        kinds => [1],
        %% Filter by author pubkey
        '#p' => [npub_or_hex_to_lower_hex64(Npub)],
        %% Reverse chronological fetch starts from now
        until => Now,
        limit => Limit
    },
    SubRand = crypto:strong_rand_bytes(4),
    SubscriptionId = <<"recent_", (binary:encode_hex(SubRand))/binary>>,
    RequestJson = jsx:encode([<<"REQ">>, SubscriptionId, Filter]),
    ?LOG_INFO("Fetching recent posts for ~p: ~p", [Npub, RequestJson]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, RequestJson}),
    %% Await all events until EOSE (or timeout)
    Reply = await_events_or_eose(ConnPid, StreamRef, SubscriptionId, 15000),

    %% Always close subscription (best practice)
    _ = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode([<<"CLOSE">>, SubscriptionId])}),

    {reply, Reply, State};
handle_call(
    {fetch_event_by_id, EventId},
    _From,
    #state{conn_pid = ConnPid, streamref = StreamRef} = State
) ->
    Filter = #{
        ids => [EventId],
        limit => 1
    },

    %% printable sub id
    SubRand = crypto:strong_rand_bytes(4),
    SubscriptionId = <<"recent_", (binary:encode_hex(SubRand))/binary>>,

    RequestJson = jsx:encode([<<"REQ">>, SubscriptionId, Filter]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, RequestJson}),

    Reply = await_event_or_eose(ConnPid, StreamRef, SubscriptionId, 8000),

    %% always close sub (best practice)
    _ = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode([<<"CLOSE">>, SubscriptionId])}),

    {reply, Reply, State};
handle_call(
    {zap_note, OriginalEventId, OriginalAuthorPubKey, AmountSats},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    AmountMsats = cln:sats_to_msat(AmountSats),

    %% 1) Fetch author lud16/lud06 via kind:0 on THIS relay
    %{ok, Lud} = fetch_author_lud_ws(ConnPid, StreamRef, OriginalAuthorPubKey),

    %% however you store it
    DefaultRelays = default_relays(),

    AuthorRelays = fetch_author_relays(OriginalAuthorPubKey),
    ?LOG_DEBUG("AuthorRelays ~p", [AuthorRelays]),
    RelaysForTag = merge_relays(DefaultRelays, AuthorRelays),

    {ok, Lud} = fetch_author_lud(OriginalAuthorPubKey),

    %% 2) Build lnurlp url + lnurl bech32
    {ok, LnurlpUrlStr} = lud_to_lnurlp_url(Lud),
    LnurlBech32 = encode_lnurl_bech32(LnurlpUrlStr),

    %% 3) Fetch lnurlp info to get callback and ensure allowsNostr
    {ok, #{callback := CallbackUrlStr, allowsNostr := Allows}} = fetch_lnurlp_info(LnurlpUrlStr),
    case Allows of
        true -> ok;
        false -> exit({lnurl_does_not_allow_nostr, LnurlpUrlStr})
    end,

    %% 4) Relay hints: you can keep your merge_relays logic
    %% If you don’t want nostr_pool, replace DefaultRelays with what you store in State/config.

    %% your existing function
    AuthorRelays = fetch_author_relays(OriginalAuthorPubKey),
    RelaysForTag = merge_relays(DefaultRelays, AuthorRelays),

    %% 5) Build + sign zap request (kind 9734)
    Tags = [
        [<<"relays">> | RelaysForTag],
        [<<"lnurl">>, LnurlBech32],
        [<<"amount">>, integer_to_binary(AmountMsats)],
        [<<"e">>, OriginalEventId],
        [<<"p">>, OriginalAuthorPubKey]
    ],
    Timestamp = erlang:system_time(seconds),
    Event0 = construct_event(PublicKey, 9734, <<"Zap !">>, Timestamp, Tags),
    ZapReq = finalize_event(Event0, PrivateKey),

    %% 6) LNURL callback -> get invoice
    {ok, Invoice} = request_zap_invoice(CallbackUrlStr, AmountMsats, ZapReq, LnurlBech32),

    %% 7) Pay invoice with CLN
    PayRes = cln:pay_invoice(Invoice),

    %% 8) Optional: publish zap request to relay (some clients like seeing it)
    _ = gun:ws_send(ConnPid, StreamRef, {text, jsx:encode([<<"EVENT">>, ZapReq])}),
    %% Best-effort await OK (don’t crash if something else arrives)
    _ = catch gun:await(ConnPid, StreamRef, 2000),

    {reply, #{invoice => Invoice, pay => PayRes, zap_request => ZapReq}, State};
handle_call(
    {post_note, Content, Tags, ImageURL},
    _From,
    #state{
        conn_pid = ConnPid, streamref = StreamRef, public_key = PublicKey, private_key = PrivateKey
    } = State
) ->
    Timestamp = erlang:system_time(seconds),
    Event = construct_note(PublicKey, Content, Timestamp, Tags, ImageURL),
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
    Event = construct_bdd(PublicKey, BDD, Timestamp, Tags),
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
            #{kinds => [0], <<"authors">> => [npub_or_hex_to_lower_hex64(Npub)]}
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
    WalletPubHex = damage_nostr:npub_or_hex_to_lower_hex64(PublicKey),
    Timestamp = erlang:system_time(seconds),

    MentionSub = jsx:encode([
        <<"REQ">>,
        <<"damagebdd">>,
        #{kinds => [1], since => Timestamp, '#p' => [WalletPubHex]}
    ]),

    case catch damage_nwc_wallet:subscribe_request(WalletPubHex) of
        NwcSub when is_list(NwcSub); is_binary(NwcSub) ->
            ok = gun:ws_send(State#state.conn_pid, State#state.streamref, {text, MentionSub}),
            ok = gun:ws_send(State#state.conn_pid, State#state.streamref, {text, NwcSub});
        Error ->
            ?LOG_WARNING("NWC subscription setup failed ~p", [Error])
    end,
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
    Event0 = construct_event(PubKey, 24133, CipherB64, TS, Tags),

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
    ?LOG_DEBUG("Nostr invoice_paid message: ~p~n", [Invoice]),
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
    self() ! do_subscribe,
    {noreply, State#state{conn_pid = ConnPid, retry_count = 0, stopped = false}};
handle_info({gun_ws, _ConnPid, _, {text, Message}}, State) ->
    ok = handle_event(jsx:decode(Message, [{labels, atom}]), State),
    {noreply, State};
handle_info(reconnect, #state{stopped = true} = State) ->
    {noreply, State};
handle_info(reconnect, State) ->
    {ok, DamageApi} = application:get_env(damage, api_url),
    {noreply, maybe_connect(State, DamageApi)};
handle_info({gun_down, ConnPid, _, _, _}, #state{conn_pid = ConnPid} = State) ->
    ?LOG_WARNING("Nostr WebSocket connection down, scheduling reconnect.", []),
    {noreply, schedule_reconnect(clear_connection(State))};
handle_info({gun_up, ConnPid, _StreamRef}, State) ->
    ?LOG_INFO("Nostr info gun_up ~p", [ConnPid]),
    {noreply, State};
handle_info({gun_response, _ConnPid, _, nofin, _, _Headers} = Any, State) ->
    ?LOG_INFO("Nostr gun_response info ~p", [Any]),
    {noreply, State};
handle_info(reward, State) ->
    {noreply, State};
handle_info(do_subscribe, State) ->
    _ = catch handle_call(subscribe, self(), State),
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
    ?LOG_INFO("Nostr WebSocket connection terminating ~p", [Reason]),
    maybe_close_gun(State#state.conn_pid),
    ok.
maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
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
                            Config = damage_config:get_default_config([
                                {public_key, AeAccount}, {concurrency, 1}
                            ]),
                            jsx:encode(
                                execute_bdd(
                                    Config,
                                    damage_context:get_context(
                                        maps:put(feature, Feature, Context)
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

handle_event(
    [<<"EVENT">>, <<"nwc_wallet">>, Event],
    State
) when is_map(Event) ->
    damage_nwc_wallet:handle_event(Event, State);
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
        #{id := _OriginalEventId, tags := _Tags, content := Content, pubkey := _Npub} =
            Event
    ],
    State
) ->
    ?LOG_INFO("Got event ~p", [Event]),
    handle_event_payload(
        string:str(string:to_lower(binary_to_list(Content)), "damagebdd"),
        Event,
        State
    );
handle_event(Event, _State) ->
    ?LOG_INFO("Got unhandled event ~p", [Event]).
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
    Event = construct_note(npub_or_hex_to_lower_hex64(PublicKey), ReplyContent, Timestamp, Tags),
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
generate_nsec() ->
    PrivateKey = crypto:strong_rand_bytes(32),
    {ok, Data5} = bech32:convertbits(binary_to_list(PrivateKey), 8, 5, [{padding, true}]),
    {ok, Nsec} = bech32:encode("nsec", Data5),
    list_to_binary(Nsec).

generate_nostr_keypair() ->
    Nsec = generate_nsec(),
    {PublicKey, PrivateKey} = nsec_to_npub(Nsec),
    #{
        nsec => Nsec,
        npub => encode_npub(PublicKey),
        npub_hex => lower_hex(PublicKey),
        private_key => PrivateKey
    }.
encode_npub(PublicKey) when is_binary(PublicKey) ->
    {ok, Data5} = bech32:convertbits(binary_to_list(PublicKey), 8, 5, [{padding, true}]),
    {ok, Npub} = bech32:encode("npub", Data5),
    list_to_binary(Npub).

decode_nsec(Nsec) ->
    {ok, #{data := Data}} = bech32:decode(Nsec),
    {ok, RawPrivateKey} = bech32:convertbits(Data, 5, 8, [{padding, false}]),
    RawPrivateKey.

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
    try jsx:decode(DescBin) of
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

service_pubkey_hex() ->
    public_key_hex().

public_key_hex() ->
    case secrets:retrieve_decrypt(damage_nostr_nsec) of
        {ok, Nsec} ->
            {PublicKey, _PrivateKey} = nsec_to_npub(Nsec),
            npub_or_hex_to_lower_hex64(PublicKey);
        Error ->
            erlang:error({nostr_key_unavailable, Error})
    end.

service_private_key() ->
    case get(test_service_priv) of
        Priv when is_binary(Priv), byte_size(Priv) =:= 32 ->
            Priv;
        _ ->
            case secrets:retrieve_decrypt(damage_nostr_nsec) of
                {ok, Nsec} ->
                    {_PublicKey, PrivateKey} = nsec_to_npub(Nsec),
                    PrivateKey;
                Error ->
                    erlang:error({nostr_key_unavailable, Error})
            end
    end.

create_signed_event(Kind, Content, Tags) ->
    PrivKey = service_private_key(),
    PubKey = public_key_hex(),
    TS = erlang:system_time(seconds),
    Event0 = construct_event(PubKey, Kind, to_bin(Content), TS, Tags),
    {ok, finalize_event(Event0, PrivKey)}.

nwc_decode_request(#{<<"content">> := Content, <<"pubkey">> := ClientPubKey} = Event) ->
    PrivKey = service_private_key(),
    case nip04_decrypt_content(Content, PrivKey, ClientPubKey) of
        {ok, Plain} ->
            try jsx:decode(Plain, [return_maps]) of
                Req when is_map(Req) ->
                    {ok,
                        maps:merge(Req, #{
                            <<"client_pubkey">> => ClientPubKey,
                            <<"request_event_id">> => maps:get(<<"id">>, Event, <<>>)
                        })}
            catch
                _:Reason ->
                    {error, {invalid_request_json, Reason, Plain}}
            end;
        Err ->
            {error, {request_decrypt_failed, Err}}
    end;
nwc_decode_request(Other) ->
    {error, {invalid_request_event, Other}}.

nwc_encode_response(
    #{<<"pubkey">> := ClientPubKey, <<"id">> := RequestId},
    Payload,
    Kind
) ->
    PrivKey = service_private_key(),
    PubKey = public_key_hex(),
    TS = erlang:system_time(seconds),
    Plain = jsx:encode(normalize_nwc_payload(Payload)),
    PeerPubKey = npub_or_hex_to_lower_hex64(ClientPubKey),
    case nip04_encrypt(Plain, PrivKey, PeerPubKey) of
        {ok, CipherB64, IvB64} ->
            Content = <<CipherB64/binary, "?iv=", IvB64/binary>>,
            Tags = [
                [<<"e">>, RequestId],
                [<<"p">>, PeerPubKey]
            ],
            Event0 = construct_event(PubKey, Kind, Content, TS, Tags),
            {ok, finalize_event(Event0, PrivKey)};
        Error ->
            Error
    end;
nwc_encode_response(Other, _Payload, _Kind) ->
    {error, {invalid_response_target, Other}}.

normalize_nwc_payload(Map) when is_map(Map) ->
    maps:from_list([{normalize_nwc_key(K), normalize_nwc_payload(V)} || {K, V} <- maps:to_list(Map)]);
normalize_nwc_payload(List) when is_list(List) ->
    case io_lib:printable_list(List) of
        true -> unicode:characters_to_binary(List);
        false -> [normalize_nwc_payload(I) || I <- List]
    end;
normalize_nwc_payload(V) when is_atom(V) -> atom_to_binary(V, utf8);
normalize_nwc_payload(V) ->
    V.

normalize_nwc_key(K) when is_binary(K) -> K;
normalize_nwc_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
normalize_nwc_key(K) when is_list(K) -> unicode:characters_to_binary(K);
normalize_nwc_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).

public_key() ->
    %% Your state keeps PubKey; expose a quick accessor via getinfo if you like.
    %% Here we just return a placeholder. Replace with your own if needed.
    %% Since this helper is called inside gen_server (nip46_send), we pass PubKey there.
    error(not_used).

%% --- NIP-04 encryption/decryption key handling -------------------------------

nip04_encrypt(PlainJson0, PrivKey0, RemotePub0) ->
    try
        PlainJson = to_bin(PlainJson0),
        PrivKey32 = normalize_privkey(PrivKey0),
        RemotePub = normalize_pubkey(RemotePub0),
        case ecdh_shared_secret(PrivKey32, RemotePub) of
            {ok, Secret} ->
                ok_encrypt(Secret, PlainJson);
            Error ->
                Error
        end
    catch
        C:R:S ->
            {error, {encrypt_crash, C, R, S}}
    end.

-spec nip04_decrypt(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, term()}.
nip04_decrypt(CipherB64, IvB64, PrivKey0, RemotePub0) ->
    try
        PrivKey32 = normalize_privkey(PrivKey0),
        case ecdh_shared_secret(PrivKey32, RemotePub0) of
            {ok, SharedSecret} ->
                ok_decrypt(SharedSecret, CipherB64, IvB64);
            Error ->
                Error
        end
    catch
        C:R:S ->
            {error, {C, R, S}}
    end.

normalize_privkey(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    Bin;
normalize_privkey(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    case is_hex_ascii(Bin) of
        true -> binary:decode_hex(Bin);
        false -> erlang:error({invalid_private_key_hex, Bin})
    end;
normalize_privkey(List) when is_list(List) ->
    normalize_privkey(list_to_binary(List));
normalize_privkey(Other) ->
    erlang:error({invalid_private_key, Other}).

-spec ecdh_shared_secret(binary(), binary() | list()) ->
    {ok, binary()} | {error, term()}.
ecdh_shared_secret(PrivKey32, RemotePub0) ->
    try
        Pub = normalize_pubkey(RemotePub0),
        case normalize_remote_xonly(Pub) of
            {ok, XOnly32} ->
                schnorr_ecdh_xonly(PrivKey32, XOnly32);
            Error ->
                Error
        end
    catch
        C:R:S ->
            {error, {ecdh_shared_secret_failed, C, R, S}}
    end.

-spec normalize_remote_xonly(binary()) -> {ok, binary()} | {error, term()}.
normalize_remote_xonly(Pub) when is_binary(Pub) ->
    case classify_pubkey(Pub) of
        xonly_hex ->
            {ok, binary:decode_hex(Pub)};
        xonly_raw ->
            {ok, Pub};
        compressed_hex ->
            compressed_hex_to_xonly(Pub);
        compressed_raw ->
            compressed_raw_to_xonly(Pub);
        invalid ->
            {error, {invalid_remote_pubkey, Pub}}
    end.

-spec classify_pubkey(binary()) ->
    compressed_hex | compressed_raw | xonly_hex | xonly_raw | invalid.
classify_pubkey(Pub) when is_binary(Pub) ->
    case {byte_size(Pub), is_hex_ascii(Pub)} of
        {66, true} ->
            case Pub of
                <<"02", _:64/binary>> -> compressed_hex;
                <<"03", _:64/binary>> -> compressed_hex;
                _ -> invalid
            end;
        {64, true} ->
            xonly_hex;
        {33, false} ->
            case binary:at(Pub, 0) of
                16#02 -> compressed_raw;
                16#03 -> compressed_raw;
                _ -> invalid
            end;
        {32, false} ->
            xonly_raw;
        _ ->
            invalid
    end.

compressed_hex_to_xonly(<<"02", X:64/binary>>) ->
    {ok, binary:decode_hex(X)};
compressed_hex_to_xonly(<<"03", X:64/binary>>) ->
    {ok, binary:decode_hex(X)};
compressed_hex_to_xonly(Other) ->
    {error, {invalid_compressed_hex_pubkey, Other}}.

compressed_raw_to_xonly(<<16#02, X:32/binary>>) ->
    {ok, X};
compressed_raw_to_xonly(<<16#03, X:32/binary>>) ->
    {ok, X};
compressed_raw_to_xonly(Other) ->
    {error, {invalid_compressed_raw_pubkey, Other}}.

ok_encrypt(SharedSecret, PlainJson) ->
    %% 32 bytes
    Key = crypto:hash(sha256, SharedSecret),
    Iv = crypto:strong_rand_bytes(16),
    Cipher = crypto:crypto_one_time(aes_256_cbc, Key, Iv, pkcs_padding(PlainJson), true),
    {ok, base64:encode(Cipher), base64:encode(Iv)}.

pkcs_padding(Bin) when is_binary(Bin) ->
    Block = 16,
    Rem = byte_size(Bin) rem Block,
    PadLen =
        case Rem of
            0 -> Block;
            _ -> Block - Rem
        end,
    Pad = binary:copy(<<PadLen>>, PadLen),
    <<Bin/binary, Pad/binary>>.

lower_hex(List) when is_list(List) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(list_to_binary(List)))));
lower_hex(Binary) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Binary)))).

-spec npub_or_hex_to_lower_hex64(binary() | list()) -> binary().
npub_or_hex_to_lower_hex64(In0) ->
    In = to_bin(In0),
    case In of
        <<"npub1", _/binary>> ->
            Hex0 = to_bin(decode_npub(In)),
            lower_hex_ascii64(Hex0);
        _ ->
            case classify_key(In) of
                {hex, 64} ->
                    lower_hex_ascii64(In);
                {raw, 32} ->
                    lower_hex(In);
                Other ->
                    erlang:error({invalid_pubkey, Other, In})
            end
    end.
-spec classify_key(binary()) ->
    {hex, non_neg_integer()}
    | {raw, non_neg_integer()}
    | invalid.
classify_key(Bin) when is_binary(Bin) ->
    case is_hex_ascii(Bin) of
        true ->
            {hex, byte_size(Bin)};
        false ->
            case byte_size(Bin) of
                32 -> {raw, 32};
                _ -> invalid
            end
    end.

%% --- helpers ---

-spec lower_hex_ascii64(binary()) -> binary().
lower_hex_ascii64(Bin) ->
    %% Bin is ASCII hex. Just lowercase; DO NOT encode_hex again.
    list_to_binary(string:lowercase(binary_to_list(Bin))).

-spec is_hex_ascii(binary()) -> boolean().
is_hex_ascii(Bin) when is_binary(Bin) ->
    (byte_size(Bin) band 1) =:= 0 andalso
        bin_all_hex(Bin).

bin_all_hex(<<>>) -> true;
bin_all_hex(<<C, Rest/binary>>) -> is_hex_byte(C) andalso bin_all_hex(Rest).

is_hex_byte(C) when C >= $0, C =< $9 -> true;
is_hex_byte(C) when C >= $a, C =< $f -> true;
is_hex_byte(C) when C >= $A, C =< $F -> true;
is_hex_byte(_) -> false.

construct_event(PubKey, Kind, Content, Timestamp, Tags) ->
    #{
        <<"id">> => <<"">>,
        <<"pubkey">> => npub_or_hex_to_lower_hex64(PubKey),
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
    %?LOG_DEBUG("Nip 01 event ~p", [Nip0Evt]),
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

xclip_post(NsecKey, AltText) ->
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
    post_note(NsecKey, Content, Tags, ImageURL).

reward_mention(Npub) ->
    AmountSats = 100,
    case throttle:check(damage_nostr_mention_reward, Npub) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("Npub ~p exceeded reward limit", [Npub]),
            {429, <<"Reward Claim Limit Exceeded">>};
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
    Metadata = self() ! {get_metadata, Npub},
    extract_lnurl(Metadata).

%% Extract LNURL from metadata
extract_lnurl(Content) ->
    case jsx:decode(Content) of
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
            case jsx:decode(Body) of
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
            UnsignedEvent = Builder(PubKey),

            %% Sign and publish
            Signed = finalize_event(UnsignedEvent, PrivKey),
            publish_zap_receipt(State, Signed, ZapReq),
            ok;
        {error, Reason} ->
            ?LOG_DEBUG("Invoice paid but no valid zap request in description: ~p", [Reason]),
            ok
    end.
%% -------------------------------------------------------------------
%% NIP-56 Reporting (kind 1984)
%% -------------------------------------------------------------------

%% Allowed report types per NIP-56 (mirror you pasted)
valid_report_type(<<"nudity">>) -> true;
valid_report_type(<<"malware">>) -> true;
valid_report_type(<<"profanity">>) -> true;
valid_report_type(<<"illegal">>) -> true;
valid_report_type(<<"spam">>) -> true;
valid_report_type(<<"impersonation">>) -> true;
valid_report_type(<<"other">>) -> true;
valid_report_type("nudity") -> true;
valid_report_type("malware") -> true;
valid_report_type("profanity") -> true;
valid_report_type("illegal") -> true;
valid_report_type("spam") -> true;
valid_report_type("impersonation") -> true;
valid_report_type("other") -> true;
valid_report_type(_) -> false.

%% construct_nip56_report/6
%% Builds an *unsigned* kind=1984 report event map.
%%
%% Params:
%% - ReporterPubKeyLowerHex : binary() (our pubkey as lower-hex)
%% - ReportedPubKeyHex      : binary() | list() (pubkey being reported, hex or npub)
%% - MaybeEventIdHex        : <<>> | binary() | list() (optional event id being reported)
%% - ReportType             : "spam"|"illegal"|... (string or binary)
%% - Content                : binary() (optional extra info)
%% - Opts                   : map() with optional extras:
%%     #{l => <<"NS-nud">>, L => <<"social.nos.ontology">>}
%%
construct_nip56_report(
    ReporterPubKeyLowerHex, ReportedPubKey0, MaybeEventId0, ReportType0, Content0, Opts
) ->
    ReportType = to_bin(ReportType0),
    valid_report_type(ReportType) orelse erlang:error({invalid_report_type, ReportType}),

    %% normalize pubkey(s)
    ReportedPubKeyHex =
        case ReportedPubKey0 of
            Bin when is_binary(Bin) ->
                %% accept npub or hex
                try
                    list_to_binary(decode_npub(binary_to_list(Bin)))
                catch
                    _:_ ->
                        Bin
                end;
            List when is_list(List) ->
                try
                    list_to_binary(decode_npub(List))
                catch
                    _:_ ->
                        list_to_binary(List)
                end
        end,

    MaybeEventId =
        case MaybeEventId0 of
            undefined -> <<>>;
            <<>> -> <<>>;
            Bin2 when is_binary(Bin2) -> Bin2;
            L2 when is_list(L2) -> list_to_binary(L2);
            _ -> <<>>
        end,

    %% Required p-tag. NIP-56 wants report-type as 3rd entry on the tag being reported.
    PTag = [<<"p">>, ReportedPubKeyHex, ReportType],

    %% Optional e-tag if reporting a note
    ETag =
        case MaybeEventId of
            <<>> -> [];
            _ -> [[<<"e">>, MaybeEventId, ReportType]]
        end,

    %% Optional ontology qualification tags (NIP-32 style)
    ExtraTags =
        case Opts of
            M when is_map(M) ->
                LT =
                    case maps:get('L', M, maps:get(<<"L">>, M, undefined)) of
                        undefined -> [];
                        V -> [[<<"L">>, to_bin(V)]]
                    end,
                lT =
                    case maps:get(l, M, maps:get(<<"l">>, M, undefined)) of
                        undefined ->
                            [];
                        V2 ->
                            [
                                [
                                    <<"l">>,
                                    to_bin(V2),
                                    to_bin(maps:get('L', M, maps:get(<<"L">>, M, <<"">>)))
                                ]
                            ]
                    end,
                LT ++ lT;
            _ ->
                []
        end,

    Tags = [PTag] ++ ETag ++ ExtraTags,
    TS = erlang:system_time(seconds),
    construct_event(ReporterPubKeyLowerHex, 1984, to_bin(Content0), TS, Tags).

%% post_report/6
%% Signs + publishes a kind 1984 report, using the existing websocket connection.
%%
%% post_report(NsecKey, ReportedPubKey, MaybeEventId, ReportType, Content, Opts) -> relay response
post_report(NsecKey, ReportedPubKey, MaybeEventId, ReportType, Content, Opts) ->
    gen_server:call(
        gproc:lookup_local_name(?NOSTR_PROC(NsecKey)),
        {post_report, ReportedPubKey, MaybeEventId, ReportType, Content, Opts}
    ).
%% Await multiple EVENT frames for a given subscription id until EOSE.
%% Returns {ok, [EventMap,...]} (chronological) or {error, timeout}.
await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs) ->
    await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs, []).

await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs, Acc) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case jsx:decode(Msg, [{return_maps, true}]) of
                [<<"EVENT">>, SubId, Event] when is_map(Event) ->
                    await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs, [Event | Acc]);
                [<<"EOSE">>, SubId] ->
                    {ok, lists:reverse(Acc)};
                [<<"NOTICE">>, _] ->
                    await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs, Acc);
                _Other ->
                    %% ignore unrelated frames
                    await_events_or_eose(ConnPid, StreamRef, SubId, TimeoutMs, Acc)
            end
    after TimeoutMs ->
        {error, timeout}
    end.

await_event_or_eose(ConnPid, StreamRef, SubId, TimeoutMs) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case jsx:decode(Msg, [{return_maps, true}]) of
                [<<"EVENT">>, SubId, Event] when is_map(Event) ->
                    {ok, Event};
                [<<"EOSE">>, SubId] ->
                    {error, not_found};
                [<<"NOTICE">>, _] ->
                    await_event_or_eose(ConnPid, StreamRef, SubId, TimeoutMs);
                _Other ->
                    %% ignore unrelated frames
                    await_event_or_eose(ConnPid, StreamRef, SubId, TimeoutMs)
            end
    after TimeoutMs ->
        {error, timeout}
    end.
lud_to_lnurlp_url(Lud) ->
    case Lud of
        <<"http://", _/binary>> ->
            {ok, binary_to_list(Lud)};
        <<"https://", _/binary>> ->
            {ok, binary_to_list(Lud)};
        <<"lnurl1", _/binary>> ->
            %% decode lnurl bech32 into URL
            case bech32:decode(Lud) of
                {ok, #{data := Data5}} ->
                    {ok, Bytes8} = bech32:convertbits(Data5, 5, 8, [{padding, false}]),
                    {ok, binary_to_list(list_to_binary(Bytes8))};
                Other ->
                    {error, {bad_lnurl_bech32, Other}}
            end;
        _ ->
            %% lud16 name@domain => https://domain/.well-known/lnurlp/name
            case binary:split(Lud, <<"@">>, [global]) of
                [Name, Domain] ->
                    {ok,
                        "https://" ++ binary_to_list(Domain) ++ "/.well-known/lnurlp/" ++
                            binary_to_list(Name)};
                _ ->
                    {error, bad_lud16}
            end
    end.

encode_lnurl_bech32(UrlStr) when is_list(UrlStr) ->
    UrlBin = list_to_binary(UrlStr),
    Bytes8 = binary_to_list(UrlBin),
    {ok, Data5} = bech32:convertbits(Bytes8, 8, 5, [{padding, true}]),
    {ok, Enc} = bech32:encode("lnurl", Data5),
    list_to_binary(Enc).

fetch_lnurlp_info(UrlStr) ->
    case httpc:request(get, {UrlStr, []}, [], []) of
        {ok, {{_, 200, _}, _Hdrs, Body}} ->
            J = jsx:decode(iolist_to_binary(Body)),
            {ok, #{
                callback => binary_to_list(maps:get(<<"callback">>, J)),
                allowsNostr => maps:get(<<"allowsNostr">>, J, false)
            }};
        {ok, {{_, Code, _}, _Hdrs, Body}} ->
            {error, {lnurlp_http_error, Code, Body}};
        Err ->
            {error, {lnurlp_http_failed, Err}}
    end.

request_zap_invoice(CallbackUrlStr, AmountMsat, ZapReqEvent, LnurlBech32) ->
    ZapJson = jsx:encode(ZapReqEvent),
    Full =
        CallbackUrlStr ++
            "?amount=" ++ integer_to_list(AmountMsat) ++
            "&nostr=" ++ uri_string:quote(binary_to_list(ZapJson)) ++
            "&lnurl=" ++ uri_string:quote(binary_to_list(LnurlBech32)),
    case httpc:request(get, {Full, []}, [], []) of
        {ok, {{_, 200, _}, _Hdrs, Body}} ->
            J = jsx:decode(iolist_to_binary(Body)),
            case J of
                #{<<"pr">> := Invoice} -> {ok, Invoice};
                _ -> {error, {bad_invoice_response, J}}
            end;
        {ok, {{_, Code, _}, _Hdrs, Body}} ->
            {error, {callback_http_error, Code, Body}};
        Err ->
            {error, {callback_http_failed, Err}}
    end.

-spec fetch_author_lud(PubHex :: binary()) ->
    {ok, binary()} | {error, term()}.
fetch_author_lud(PubHex) ->
    Filter = #{<<"kinds">> => [0], <<"authors">> => [PubHex], <<"limit">> => 1},
    case nostr_pool:req_one(Filter, ?NOSTR_DEFAULT_TIMEOUT, ?NOSTR_DEFAULT_FANOUT) of
        {ok, MetaEvt} ->
            Content = maps:get(<<"content">>, MetaEvt, <<>>),
            extract_lud_from_kind0(Content);
        Err ->
            Err
    end.

extract_lud_from_kind0(ContentBin) ->
    try
        M = jsx:decode(ContentBin),
        case M of
            #{<<"lud16">> := Lud16} when is_binary(Lud16), Lud16 =/= <<>> -> {ok, Lud16};
            #{<<"lud06">> := Lud06} when is_binary(Lud06), Lud06 =/= <<>> -> {ok, Lud06};
            _ -> {error, no_lud_in_metadata}
        end
    catch
        _:E -> {error, {bad_kind0_json, E}}
    end.
-spec fetch_author_relays(PubHex :: binary()) -> [binary()].
fetch_author_relays(PubHex) ->
    Filter = #{<<"kinds">> => [10002], <<"authors">> => [PubHex], <<"limit">> => 1},
    case nostr_pool:req_one(Filter, ?NOSTR_DEFAULT_TIMEOUT, ?NOSTR_DEFAULT_FANOUT) of
        {ok, Evt} ->
            Tags = maps:get(<<"tags">>, Evt, []),
            RelayUrls = [R || [<<"r">>, R | _] <- Tags, is_binary(R)],
            RelayUrls;
        _ ->
            []
    end.

-spec merge_relays([binary()], [binary()]) -> [binary()].
merge_relays(Default, Author) ->
    %% dedupe + cap
    All = Default ++ Author,
    Unique = lists:usort(All),
    take(10, Unique).

take(0, _) -> [];
take(_, []) -> [];
take(N, [H | T]) -> [H | take(N - 1, T)].

normalize_pubkey(Pub0) when is_binary(Pub0); is_list(Pub0) ->
    Pub = to_bin(Pub0),
    case Pub of
        <<"npub1", _/binary>> ->
            lower_hex_ascii64(npub_to_hex(Pub));
        _ ->
            ensure_32byte_hex(lower_hex_ascii64(Pub))
    end.

-spec npub_to_hex(binary()) -> binary().
npub_to_hex(Npub0) ->
    list_to_binary(decode_npub(to_bin(Npub0))).
ensure_32byte_hex(Hex) ->
    case byte_size(Hex) of
        64 -> Hex;
        _ -> error({invalid_pubkey_length, Hex})
    end.
%% -------------------------------------------------------------------
%% NIP-04 decrypt helpers (for NIP-46 / NIP-47)
%%
%% Content is "base64(ciphertext)?iv=base64(iv)"
%% Key is sha256(ecdh_shared_secret)
%% Cipher is AES-256-CBC with PKCS7 padding
%% -------------------------------------------------------------------

-spec nip04_decrypt_content(binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
nip04_decrypt_content(Content0, PrivKey0, RemotePub0) ->
    try
        Content = to_bin(Content0),
        PrivKey32 = normalize_privkey(PrivKey0),
        RemotePub = normalize_pubkey(RemotePub0),
        case binary:split(Content, <<"?iv=">>) of
            [CipherB64, IvB64] ->
                nip04_decrypt(CipherB64, IvB64, PrivKey32, RemotePub);
            _ ->
                {error, {bad_content_format, Content}}
        end
    catch
        C:R:S ->
            {error, {decrypt_crash, C, R, S}}
    end.

ok_decrypt(SharedSecret, CipherB64, IvB64) ->
    Key = crypto:hash(sha256, SharedSecret),
    Iv = base64:decode(to_bin(IvB64)),
    Cipher = base64:decode(to_bin(CipherB64)),
    PlainPadded = crypto:crypto_one_time(aes_256_cbc, Key, Iv, Cipher, false),
    case pkcs7_unpad(PlainPadded) of
        {ok, Plain} -> {ok, Plain};
        {error, Why} -> {error, Why}
    end.

%% PKCS7 unpad (block size 16)
pkcs7_unpad(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    PadLen = binary:last(Bin),
    Sz = byte_size(Bin),
    case (PadLen > 0) andalso (PadLen =< 16) andalso (PadLen =< Sz) of
        true ->
            DataLen = Sz - PadLen,
            <<Data:DataLen/binary, Pad:PadLen/binary>> = Bin,
            Expected = binary:copy(<<PadLen>>, PadLen),
            case Pad =:= Expected of
                true -> {ok, Data};
                false -> {error, bad_padding}
            end;
        false ->
            {error, bad_padding_len}
    end;
pkcs7_unpad(_) ->
    {error, bad_padding_len}.

test_get_recent_posts() ->
    Posts = get_recent_posts(
        <<"e8b93582d5cd2085cbbd90794af81430866d1934ef26cde980f07c58ad7d4eaf">>, 20
    ),
    Posts.

test_get_posts_since() ->
    {ok, Posts} = get_posts_since(
        <<"e8b93582d5cd2085cbbd90794af81430866d1934ef26cde980f07c58ad7d4eaf">>, 1768395600
    ),
    ?LOG_INFO("Got posts ~p", [length(Posts)]),
    {ok, Posts} = get_posts_since(
        <<"npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz">>, 1768395600
    ),
    ?LOG_INFO("Got posts ~p", [length(Posts)]),
    pp_events(Posts).
test_zap_note() ->
    %post_note(damage_nostr_nsec, <<"Hello from Erlang!">>).
    NoteId =
        <<"b685f2b08104835b49a4ae183ec9037a8bb7e23506696724360903c9903e948d">>,

    {ok, #{
        <<"pubkey">> :=
            Author
    }} = fetch_event_by_id(damage_nostr_nsec, NoteId),
    zap_note(damage_nostr_nsec, NoteId, Author, 100).
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
%% -------------------------------------------------------------------
%% Nostr event pretty printer
%% -------------------------------------------------------------------

pp_events(Events) when is_list(Events) ->
    lists:foreach(
        fun(E) ->
            pp_event(E),
            io:format("~n", [])
        end,
        Events
    ),
    ok.

%% default: show tags but truncate content to 280 chars
pp_event(E) ->
    pp_event(E, #{show_tags => true, max_content => 280}).

pp_event(E, Opts) when is_map(E), is_map(Opts) ->
    Id = mget_bin(<<"id">>, E, <<"-">>),
    PubKey = mget_bin(<<"pubkey">>, E, <<"-">>),
    Kind = mget_int(<<"kind">>, E, -1),
    CA = mget_int(<<"created_at">>, E, 0),
    TsStr = ts_utc_string(CA),
    Content0 = mget_bin(<<"content">>, E, <<>>),
    Content = maybe_truncate(Content0, maps:get(max_content, Opts, 280)),

    io:format("Nostr Event~n", []),
    io:format("  id:         ~ts~n", [Id]),
    io:format("  pubkey:     ~ts~n", [PubKey]),
    io:format("  kind:       ~p~n", [Kind]),
    io:format("  created_at: ~p (~ts)~n", [CA, TsStr]),

    case maps:get(<<"sig">>, E, undefined) of
        undefined ->
            ok;
        Sig when is_binary(Sig) ->
            io:format("  sig:        ~ts~n", [Sig])
    end,

    io:format("  content:~n", []),
    io:format("    ~ts~n", [indent_lines(Content, 4)]),

    case maps:get(show_tags, Opts, true) of
        true ->
            Tags = maps:get(<<"tags">>, E, []),
            io:format("  tags (~p):~n", [safe_len(Tags)]),
            pp_tags(Tags);
        false ->
            ok
    end,
    ok;
pp_event(Other, _Opts) ->
    io:format("Not an event map: ~p~n", [Other]),
    ok.

pp_tags(Tags) when is_list(Tags) ->
    lists:foreach(
        fun(Tag) ->
            io:format("    - ~ts~n", [tag_to_iolist(Tag)])
        end,
        Tags
    ),
    ok;
pp_tags(_) ->
    ok.

tag_to_iolist(Tag) when is_list(Tag) ->
    %% Tag is often a list of binaries: [<<"p">>, <<"hex">>, <<"relay">>, <<"petname">>]
    Parts = [to_ts(P) || P <- Tag],
    iolist_join(Parts, <<" ">>);
tag_to_iolist(Tag) ->
    to_ts(Tag).

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

mget_bin(K, M, D) ->
    case maps:get(K, M, D) of
        V when is_binary(V) -> V;
        V when is_list(V) -> list_to_binary(V);
        V when is_atom(V) -> atom_to_binary(V, utf8);
        V when is_integer(V) -> integer_to_binary(V);
        V -> to_bin(V)
    end.

mget_int(K, M, D) ->
    case maps:get(K, M, D) of
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            case catch binary_to_integer(B) of
                I when is_integer(I) -> I;
                _ -> D
            end;
        L when is_list(L) ->
            case catch list_to_integer(L) of
                I when is_integer(I) -> I;
                _ -> D
            end;
        _ ->
            D
    end.

to_ts(V) ->
    %% for io:format "~ts"
    to_bin(V).

safe_len(L) when is_list(L) -> length(L);
safe_len(_) -> 0.

maybe_truncate(Bin, Max) when is_integer(Max), Max > 0, is_binary(Bin) ->
    case byte_size(Bin) =< Max of
        true ->
            Bin;
        false ->
            <<Prefix:Max/binary, _/binary>> = Bin,
            <<Prefix/binary, "..."/utf8>>
    end;
maybe_truncate(Bin, _) ->
    Bin.

indent_lines(Bin, Spaces) ->
    Ind = lists:duplicate(Spaces, $\s),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    list_to_binary(
        iolist_join([[Ind, L] || L <- Lines], <<"\n">>)
    ).

iolist_join([], _Sep) -> [];
iolist_join([One], _Sep) -> One;
iolist_join([H | T], Sep) -> [H | [[Sep, X] || X <- T]].

ts_utc_string(Seconds) when is_integer(Seconds), Seconds > 0 ->
    %% Uses calendar to render roughly; if you already have time utils, swap in.
    try
        {{Y, M, D}, {HH, MM, SS}} = calendar:system_time_to_universal_time(Seconds, second),
        list_to_binary(
            io_lib:format(
                "~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B UTC",
                [Y, M, D, HH, MM, SS]
            )
        )
    catch
        _:_ -> <<"-">>
    end;
ts_utc_string(_) ->
    <<"-">>.
%% Normalize a hex pubkey (lowercase, binary)
norm_hex_pk(Pk) when is_binary(Pk) ->
    list_to_binary(string:lowercase(binary_to_list(Pk)));
norm_hex_pk(Pk) when is_list(Pk) ->
    norm_hex_pk(list_to_binary(Pk));
norm_hex_pk(Pk) when is_atom(Pk) ->
    norm_hex_pk(atom_to_binary(Pk, utf8));
norm_hex_pk(Pk) ->
    norm_hex_pk(iolist_to_binary(io_lib:format("~p", [Pk]))).

event_author_hex(Event) when is_map(Event) ->
    norm_hex_pk(maps:get(<<"pubkey">>, Event, <<>>));
event_author_hex(_) ->
    <<>>.

filter_events_by_authors(Events, AuthorHexes0) ->
    AuthorHexes = [norm_hex_pk(A) || A <- AuthorHexes0],
    [
        E
     || E <- Events,
        is_map(E),
        lists:member(event_author_hex(E), AuthorHexes)
    ].

generate_nsec_test() ->
    %% Generate new key
    Nsec = generate_nsec(),

    %% Basic shape check
    ?assertMatch(<<"nsec", _/binary>>, Nsec),

    %% Decode back to private key
    Priv = iolist_to_binary(decode_nsec(Nsec)),
    ?assertEqual(32, byte_size(Priv)),

    %% Derive pubkey using existing function
    {Pub1, Priv1} = nsec_to_npub(Nsec),

    %% Ensure private keys match
    ?assertEqual(Priv, Priv1),

    %% Derive pubkey directly again (sanity)
    {Pub2, _} = nsec_to_npub(Nsec),
    ?assertEqual(Pub1, Pub2),

    ok.
generate_nostr_keypair_test() ->
    #{nsec := Nsec, npub := Npub} = generate_nostr_keypair(),

    %% Ensure prefixes
    ?assertMatch(<<"nsec", _/binary>>, Nsec),
    ?assertMatch(<<"npub", _/binary>>, Npub),

    %% Decode and re-derive
    {Pub, _Priv} = nsec_to_npub(Nsec),
    Npub2 = encode_npub(Pub),

    %% Ensure deterministic encoding
    ?assertEqual(Npub, Npub2),

    ok.
relay_profile(#{profile := P}) ->
    P;
relay_profile(Relay0) ->
    Relay = normalize_relay(Relay0),
    Url = maps:get(url, Relay),
    Host = relay_host(Url),
    case Host of
        "relay.damus.io" -> cloudflare_browser;
        "relay.primal.net" -> primal;
        "nostr-01.yakihonne.com" -> yakihonne;
        "nostr-02.yakihonne.com" -> yakihonne;
        _ -> default
    end.

open_relay_ws(Relay0, ExtraOpts0) ->
    Relay = normalize_relay(Relay0),
    Url = maps:get(url, Relay),

    {Host, Port, Path, Tls} = parse_ws_url(Url),

    BaseOpts =
        case Tls of
            true ->
                #{
                    transport => tls,
                    protocols => [http],
                    tls_opts => damage_gun:tls_opts(Host)
                };
            false ->
                #{
                    transport => tcp,
                    protocols => [http]
                }
        end,

    Proxy = relay_proxy(Relay),
    ExtraHeaders = maps:get(ws_headers, ExtraOpts0, []),
    Headers = relay_ws_headers(Relay, ExtraHeaders),

    ExtraOpts = maps:without([ws_headers], ExtraOpts0),

    Opts =
        maps:merge(
            BaseOpts,
            ExtraOpts#{
                proxy => Proxy,
                ws_headers => Headers,
                connect_timeout => maps:get(connect_timeout, ExtraOpts0, 15000)
            }
        ),

    ?LOG_INFO("Opening relay url=~p profile=~p proxy=~p score=~p", [
        Url,
        relay_profile(Relay),
        Proxy,
        relay_score(Relay)
    ]),

    damage_gun:open_ws(Host, Port, Path, Opts).
relay_ws_headers(Relay0, ExtraHeaders) ->
    Host = relay_host(Relay0),
    Base =
        case relay_profile(Relay0) of
            cloudflare_browser ->
                [
                    {<<"user-agent">>,
                        <<"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36">>},
                    {<<"accept">>, <<"*/*">>},
                    {<<"accept-language">>, <<"en-US,en;q=0.9">>},
                    {<<"cache-control">>, <<"no-cache">>},
                    {<<"pragma">>, <<"no-cache">>}
                ];
            primal ->
                [
                    {<<"user-agent">>,
                        <<"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36">>},
                    {<<"accept">>, <<"*/*">>}
                ];
            yakihonne ->
                [
                    {<<"user-agent">>, <<"damagebdd/1.0">>},
                    {<<"accept">>, <<"*/*">>}
                ];
            _ ->
                [
                    {<<"user-agent">>, <<"damagebdd/1.0">>},
                    {<<"accept">>, <<"*/*">>}
                ]
        end,
    merge_headers(Base, ExtraHeaders).
relay_proxy(#{proxy := direct}) ->
    none;
relay_proxy(#{proxy := none}) ->
    none;
relay_proxy(#{proxy := proxy}) ->
    damage_gun:proxy();
relay_proxy(#{proxy := auto}) ->
    damage_gun:proxy();
relay_proxy(Relay0) ->
    Relay = normalize_relay(Relay0),
    case maps:get(proxy, Relay, undefined) of
        direct -> none;
        none -> none;
        false -> none;
        proxy -> damage_gun:proxy();
        auto -> damage_gun:proxy();
        undefined -> relay_proxy_from_policy(relay_profile(Relay));
        _ -> relay_proxy_from_policy(relay_profile(Relay))
    end.

relay_proxy_from_policy(Profile) ->
    Policy =
        case application:get_env(damage, nostr_relay_proxy_policy) of
            {ok, M} when is_map(M) ->
                maps:get(Profile, M, maps:get(default, M, auto));
            _ ->
                auto
        end,
    case Policy of
        direct -> none;
        none -> none;
        false -> none;
        proxy -> damage_gun:proxy();
        auto -> damage_gun:proxy();
        _ -> damage_gun:proxy()
    end.

open_best_relay_ws(Relays, ExtraOpts) ->
    Sorted = score_relays(normalize_relays(Relays)),
    try_relays(Sorted, ExtraOpts, []).

try_relays([], _ExtraOpts, Errors) ->
    {error, {all_relays_failed, lists:reverse(Errors)}};
try_relays([Relay | Rest], ExtraOpts, Errors) ->
    case open_relay_ws(Relay, ExtraOpts) of
        {ok, ConnPid, StreamRef} ->
            {ok, Relay, ConnPid, StreamRef};
        {error, Reason} ->
            ?LOG_WARNING("Relay failed relay=~p score=~p reason=~p", [
                Relay,
                relay_score(Relay),
                Reason
            ]),
            try_relays(Rest, ExtraOpts, [{Relay, Reason} | Errors])
    end.

score_relays(Relays) ->
    lists:sort(
        fun(A, B) -> relay_score(A) >= relay_score(B) end,
        damage_nostr:normalize_relays(Relays)
    ).

relay_score(Relay0) ->
    Relay = normalize_relay(Relay0),
    Url = maps:get(url, Relay),

    Profile = relay_profile(Relay),

    Base =
        case Profile of
            plain -> 100;
            yakihonne -> 90;
            default -> 80;
            cloudflare_browser -> 65;
            primal -> 60;
            _ -> 50
        end,

    HostPenalty =
        case relay_host(Url) of
            "relay.damus.io" -> 20;
            "relay.primal.net" -> 10;
            _ -> 0
        end,

    ProxyPenalty =
        case {relay_proxy(Relay), Profile} of
            {none, cloudflare_browser} -> 0;
            {none, primal} -> 0;
            {_, cloudflare_browser} -> 80;
            {_, primal} -> 80;
            _ -> 0
        end,

    Base - HostPenalty - ProxyPenalty.

relay_host(Relay0) ->
    Relay = normalize_relay(Relay0),
    Url = maps:get(url, Relay),
    case nostr_relay_worker:parse_wss_url(to_bin(Url)) of
        {ok, #{host := Host}} ->
            host_to_list(Host);
        _ ->
            {Host, _Port, _Path, _Tls} = parse_ws_url(Url),
            host_to_list(Host)
    end.

host_to_list(H) when is_binary(H) ->
    binary_to_list(H);
host_to_list(H) when is_list(H) ->
    H.
merge_headers(Base, Extra) ->
    maps:to_list(
        maps:merge(
            maps:from_list(Base),
            maps:from_list(Extra)
        )
    ).
default_relays() ->
    normalize_relays([
        #{url => "wss://relay.damus.io", profile => cloudflare_browser, proxy => direct},
        #{url => "wss://relay.primal.net", profile => primal, proxy => direct},
        #{url => "wss://nostr-01.yakihonne.com", profile => yakihonne},
        #{url => "wss://nos.lol"},
        #{url => "wss://offchain.pub"}
    ]).

first_configured_relay() ->
    case configured_relays() of
        [Relay | _] -> Relay;
        [] -> hd(default_relays())
    end.
-spec configured_relays() -> [map()].
configured_relays() ->
    case application:get_env(damage, nostr_relays) of
        {ok, Relays} when is_list(Relays), Relays =/= [] ->
            normalize_relays(Relays);
        _ ->
            default_relays()
    end.
normalize_relays(Relays) when is_list(Relays) ->
    lists:filtermap(
        fun(R) ->
            case normalize_relay(R) of
                #{url := Url} = Relay when is_binary(Url), Url =/= <<>> ->
                    {true, Relay};
                _ ->
                    false
            end
        end,
        Relays
    ).

normalize_relay(#{url := #{url := _} = Nested} = M) ->
    maps:merge(normalize_relay(Nested), maps:remove(url, M));
normalize_relay(#{<<"url">> := Url} = M) ->
    normalize_relay(maps:put(url, Url, maps:remove(<<"url">>, M)));
normalize_relay(#{url := Url} = M0) when is_list(Url); is_binary(Url) ->
    M1 = M0#{url => to_bin(Url)},
    M2 = normalize_relay_key(<<"proxy">>, proxy, M1),
    M3 = normalize_relay_key(<<"profile">>, profile, M2),
    M4 =
        case maps:get(proxy, M3, undefined) of
            <<"direct">> -> M3#{proxy => direct};
            "direct" -> M3#{proxy => direct};
            <<"none">> -> M3#{proxy => none};
            "none" -> M3#{proxy => none};
            <<"proxy">> -> M3#{proxy => proxy};
            "proxy" -> M3#{proxy => proxy};
            <<"auto">> -> M3#{proxy => auto};
            "auto" -> M3#{proxy => auto};
            Other -> M3#{proxy => Other}
        end,
    case maps:get(profile, M4, undefined) of
        <<"cloudflare_browser">> -> M4#{profile => cloudflare_browser};
        <<"primal">> -> M4#{profile => primal};
        <<"yakihonne">> -> M4#{profile => yakihonne};
        <<"default">> -> M4#{profile => default};
        _ -> M4
    end;
normalize_relay(Url) when is_list(Url); is_binary(Url) ->
    #{url => to_bin(Url)};
normalize_relay(Other) ->
    erlang:error({bad_relay_spec, Other}).

normalize_relay_key(Old, New, M) ->
    case maps:take(Old, M) of
        {V, M1} -> M1#{New => V};
        error -> M
    end.
-spec test_nwc_roundtrip() -> ok | {error, term()}.
test_nwc_roundtrip() ->
    try
        ClientNsec = generate_nsec(),
        ServiceNsec = generate_nsec(),

        {ClientPub, ClientPriv} = nsec_to_npub(ClientNsec),
        {ServicePub, ServicePriv} = nsec_to_npub(ServiceNsec),

        ClientPubHex = npub_or_hex_to_lower_hex64(ClientPub),
        ServicePubHex = npub_or_hex_to_lower_hex64(ServicePub),
        ?LOG_INFO(
            "test_nwc_roundtrip ClientPubHex:~p  ServicePubHex: ~p ClientPriv: ~p ServicePriv: ~p",
            [
                ClientPubHex,
                ServicePubHex,
                ClientPriv,
                ServicePriv
            ]
        ),

        Payload = #{
            <<"method">> => <<"pay_invoice">>,
            <<"params">> => #{<<"invoice">> => <<"lnbc1testinvoice">>}
        },
        Plain = jsx:encode(Payload),

        {ok, CipherB64, IvB64} =
            nip04_encrypt(Plain, ClientPriv, ServicePubHex),

        Content = <<CipherB64/binary, "?iv=", IvB64/binary>>,

        Event = #{
            <<"pubkey">> => ClientPubHex,
            <<"content">> => Content,
            <<"kind">> => 23194,
            <<"created_at">> => erlang:system_time(seconds),
            <<"tags">> => [[<<"p">>, ServicePubHex]]
        },

        put(test_service_priv, ServicePriv),

        Res =
            case nwc_decode_request(Event) of
                {ok, Decoded} ->
                    Method = maps:get(<<"method">>, Decoded),
                    Invoice = maps:get(<<"invoice">>, maps:get(<<"params">>, Decoded)),
                    case {Method, Invoice} of
                        {<<"pay_invoice">>, <<"lnbc1testinvoice">>} ->
                            ok;
                        Other ->
                            {error, {mismatch, Other, Decoded}}
                    end;
                Error ->
                    {error, {decode_failed, Error}}
            end,

        erase(test_service_priv),
        Res
    catch
        C:R:S ->
            erase(test_service_priv),
            {error, {crash, C, R, S}}
    end.

-spec parse_ws_url(binary() | list()) ->
    {string(), inet:port_number(), string(), boolean()}.

parse_ws_url(#{url := Url}) ->
    parse_ws_url(Url);
parse_ws_url(#{<<"url">> := Url}) ->
    parse_ws_url(Url);
parse_ws_url(Url0) ->
    Url = binary_to_list(to_bin(Url0)),
    case uri_string:parse(Url) of
        #{host := Host} = M ->
            Scheme = maps:get(scheme, M, "wss"),
            Tls = (Scheme =:= "wss") orelse (Scheme =:= "https"),
            Port =
                case maps:get(port, M, undefined) of
                    undefined when Tls -> 443;
                    undefined -> 80;
                    P -> P
                end,
            Path0 =
                case maps:get(path, M, "/") of
                    "" -> "/";
                    P0 -> P0
                end,
            Path =
                case maps:get(query, M, undefined) of
                    undefined -> Path0;
                    "" -> Path0;
                    Q -> Path0 ++ "?" ++ Q
                end,
            {Host, Port, Path, Tls};
        Bad ->
            erlang:error({bad_relay_url, Url0, Bad})
    end.
