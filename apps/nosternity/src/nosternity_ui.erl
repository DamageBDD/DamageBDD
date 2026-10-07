%%%-------------------------------------------------------------------
%%% Nosternity GS UI integration
%%%
%%% Drop-in direction:
%%% - add this module as a managed process under nosternity supervision
%%% - use nostr_pool as the relay boundary
%%% - use nostrlib_schnorr for signing when a private key is configured
%%%
%%% Why this shape:
%%% - nostr_pool/nostr_relay_worker already gives persistent relay workers,
%%%   reconnects, fanout queries, and publish support. fileciteturn1file0 fileciteturn1file6
%%% - nosternity_app currently boots Cowboy and websocket routes, so the UI
%%%   should be an additional local process, not a replacement. fileciteturn1file1
%%% - the older nosternity_relay_client is not the right integration point.
%%%   It registers relay URLs as atoms and does not fit the worker/pool model. fileciteturn1file2
%%%-------------------------------------------------------------------

%%%===================================================================
%%% File 1: nosternity_ui.erl
%%%===================================================================
-module(nosternity_ui).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    publish_text_note/1,
    refresh_feed/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(post, {
    id = <<>>,
    pubkey = <<>>,
    created_at = 0,
    kind = 1,
    content = <<>>,
    relay = <<>>
}).

-record(state, {
    gs,
    win,
    relay_entry,
    status_lbl,
    feed_list,
    compose_editor,
    connect_btn,
    refresh_btn,
    send_btn,
    relays = [],
    posts = [],
    privkey = undefined,
    pubkey = undefined,
    title = "Nosternity"
}).

-define(SERVER, ?MODULE).
-define(DEFAULT_TIMEOUT_MS, 4000).
-define(DEFAULT_FANOUT, 3).

%%%-------------------------------------------------------------------
%%% Public API
%%%-------------------------------------------------------------------

start_link() ->
    start_link(#{}).

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

publish_text_note(Content) ->
    gen_server:cast(?SERVER, {publish_text_note, Content}).

refresh_feed() ->
    gen_server:cast(?SERVER, refresh_feed).

%%%-------------------------------------------------------------------
%%% gen_server
%%%-------------------------------------------------------------------

init(Opts) ->
    process_flag(trap_exit, true),

    Relays0 = maps:get(relays, Opts, default_relays()),
    Relays = normalize_relays(Relays0),
    ok = nostr_pool:ensure_started(Relays),

    PrivKey = maps:get(privkey, Opts, read_privkey()),
    PubKey = derive_pubkey(PrivKey),

    GS = gs:start(),
    Win = gs:create(window, GS, [
        {width, 920},
        {height, 680},
        {title, maps:get(title, Opts, "Nosternity")},
        {map, true},
        {destroy, true},
        {configure, true}
    ]),

    RelayEntry = gs:create(entry, relay_entry, Win, [
        {x, 10},
        {y, 10},
        {width, 570},
        {text, relay_text(Relays)},
        {keypress, true}
    ]),

    ConnectBtn = gs:create(button, connect_btn, Win, [
        {x, 590},
        {y, 10},
        {width, 90},
        {height, 28},
        {label, {text, "Connect"}}
    ]),

    RefreshBtn = gs:create(button, refresh_btn, Win, [
        {x, 690},
        {y, 10},
        {width, 90},
        {height, 28},
        {label, {text, "Refresh"}}
    ]),

    StatusLbl = gs:create(label, status_lbl, Win, [
        {x, 10},
        {y, 42},
        {width, 890},
        {height, 20},
        {align, w},
        {label, {text, initial_status(PubKey)}}
    ]),

    FeedList = gs:create(listbox, feed_list, Win, [
        {x, 10},
        {y, 72},
        {width, 890},
        {height, 360},
        {vscroll, right},
        {hscroll, bottom},
        {click, true},
        {doubleclick, true},
        {selectmode, single}
    ]),

    _ComposeLbl = gs:create(label, Win, [
        {x, 10},
        {y, 445},
        {width, 180},
        {height, 20},
        {align, w},
        {label, {text, "Compose note"}}
    ]),

    ComposeEditor = gs:create(editor, compose_editor, Win, [
        {x, 10},
        {y, 470},
        {width, 890},
        {height, 150},
        {vscroll, right},
        {hscroll, bottom}
    ]),

    SendBtn = gs:create(button, send_btn, Win, [
        {x, 800},
        {y, 630},
        {width, 100},
        {height, 28},
        {label, {text, "Send"}}
    ]),

    State0 = #state{
        gs = GS,
        win = Win,
        relay_entry = RelayEntry,
        status_lbl = StatusLbl,
        feed_list = FeedList,
        compose_editor = ComposeEditor,
        connect_btn = ConnectBtn,
        refresh_btn = RefreshBtn,
        send_btn = SendBtn,
        relays = Relays,
        privkey = PrivKey,
        pubkey = PubKey,
        title = maps:get(title, Opts, "Nosternity")
    },

    self() ! do_initial_refresh,
    {ok, State0}.

handle_call(_Req, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(refresh_feed, State) ->
    {noreply, do_refresh(State)};
handle_cast({publish_text_note, Content}, State) ->
    {noreply, do_publish(Content, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(do_initial_refresh, State) ->
    {noreply, do_refresh(State)};
handle_info({gs, connect_btn, click, _, _}, State) ->
    {noreply, do_connect(State)};
handle_info({gs, refresh_btn, click, _, _}, State) ->
    {noreply, do_refresh(State)};
handle_info({gs, send_btn, click, _, _}, State) ->
    Content = editor_text(State#state.compose_editor),
    {noreply, do_publish(Content, State)};
handle_info({gs, relay_entry, keypress, _, ['Return' | _]}, State) ->
    {noreply, do_connect(State)};
handle_info({gs, feed_list, click, _, [Index, _Text | _]}, State) ->
    {noreply, select_post(Index, State)};
handle_info({gs, _Win, destroy, _, _}, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%%% Actions
%%%-------------------------------------------------------------------

do_connect(State = #state{relay_entry = RelayEntry}) ->
    Text = gs:read(RelayEntry, text),
    Relays = parse_relay_text(Text),
    ok = nostr_pool:ensure_started(Relays),
    set_status(State, io_lib:format("Connected relay set (~p)", [length(Relays)])),
    State#state{relays = Relays}.

do_refresh(State = #state{relays = Relays}) ->
    set_status(State, "Refreshing feed..."),
    Filter = #{<<"kinds">> => [1], <<"limit">> => 25},
    case
        nosternity_otp_compat:catch_value(fun() ->
            nostr_pool:req_one(Filter, Relays, ?DEFAULT_TIMEOUT_MS, ?DEFAULT_FANOUT)
        end)
    of
        {ok, Event} ->
            Posts = merge_posts([event_to_post(Event, hd(Relays))], State#state.posts),
            NewState = render_posts(State#state{posts = Posts}),
            set_status(NewState, "Feed updated"),
            NewState;
        {error, Reason} ->
            set_status(State, io_lib:format("Refresh failed: ~p", [Reason])),
            State;
        {'EXIT', Reason} ->
            set_status(State, io_lib:format("Refresh crash: ~p", [Reason])),
            State
    end.

do_publish(_Content0, State = #state{privkey = undefined}) ->
    set_status(State, "No private key configured; cannot sign note"),
    State;
do_publish(Content0, State = #state{privkey = PrivKey, pubkey = PubKey, relays = Relays}) ->
    Content = trim_bin(to_bin(Content0)),
    case Content of
        <<>> ->
            set_status(State, "Cannot send empty note"),
            State;
        _ ->
            Event0 = unsigned_text_note(Content, PubKey),
            case sign_event(Event0, PrivKey) of
                {ok, Event} ->
                    ok = nostr_pool:publish(Event, Relays, ?DEFAULT_TIMEOUT_MS),
                    clear_compose(State#state.compose_editor),
                    set_status(State, "Published text note"),
                    State;
                {error, Reason} ->
                    set_status(State, io_lib:format("Sign failed: ~p", [Reason])),
                    State
            end
    end.

select_post(Index0, State = #state{posts = Posts}) ->
    case safe_nth(Index0 + 1, Posts) of
        undefined ->
            State;
        #post{pubkey = Pubkey, relay = Relay, content = Content} ->
            set_status(
                State,
                io_lib:format("~s via ~s :: ~s", [
                    short_hex(Pubkey), short_hex(Relay), truncate(binary_to_list(Content), 120)
                ])
            ),
            State
    end.

%%%-------------------------------------------------------------------
%%% Render helpers
%%%-------------------------------------------------------------------

render_posts(State = #state{feed_list = FeedList, posts = Posts}) ->
    gs:config(FeedList, clear),
    gs:config(FeedList, {items, [render_post_line(P) || P <- Posts]}),
    State.

render_post_line(#post{pubkey = Pubkey, content = Content, relay = Relay}) ->
    lists:flatten(
        io_lib:format("[~s] ~s @ ~s", [
            short_hex(Pubkey),
            truncate(one_line(binary_to_list(Content)), 96),
            short_hex(Relay)
        ])
    ).

set_status(#state{status_lbl = Label}, Text) ->
    gs:config(Label, {label, {text, flatten_text(Text)}}).

clear_compose(Editor) ->
    gs:config(Editor, clear).

editor_text(Editor) ->
    iolist_to_binary(gs:read(Editor, {get, {0, 0}, 'end'})).

%%%-------------------------------------------------------------------
%%% Nostr event helpers
%%%-------------------------------------------------------------------

unsigned_text_note(Content, PubKey) ->
    #{
        %% NIP-01 event fields
        id => <<>>,
        pubkey => PubKey,
        created_at => erlang:system_time(second),
        kind => 1,
        tags => [],
        content => Content,
        sig => <<>>
    }.

sign_event(Event0, PrivKey) ->
    Enc = nostr_event_serialize(Event0),
    Id = crypto:hash(sha256, Enc),
    case nostrlib_schnorr:sign(Id, PrivKey) of
        {ok, Sig} ->
            {ok, Event0#{id => Id, sig => Sig}};
        Error ->
            Error
    end.

nostr_event_serialize(#{
    pubkey := PubKey, created_at := CreatedAt, kind := Kind, tags := Tags, content := Content
}) ->
    jsx:encode([0, hex(PubKey), CreatedAt, Kind, Tags, bin_to_list(Content)]).

derive_pubkey(undefined) ->
    undefined;
derive_pubkey(PrivKey) ->
    case nostrlib_schnorr:new_publickey(PrivKey) of
        {ok, PubKey} -> PubKey;
        _ -> undefined
    end.

event_to_post(Event, Relay) ->
    #post{
        id = maps:get(<<"id">>, Event, maps:get(id, Event, <<>>)),
        pubkey = maps:get(<<"pubkey">>, Event, maps:get(pubkey, Event, <<>>)),
        created_at = maps:get(<<"created_at">>, Event, maps:get(created_at, Event, 0)),
        kind = maps:get(<<"kind">>, Event, maps:get(kind, Event, 1)),
        content = maps:get(<<"content">>, Event, maps:get(content, Event, <<>>)),
        relay = Relay
    }.

merge_posts(NewPosts, Existing) ->
    lists:sort(
        fun(A, B) -> A#post.created_at >= B#post.created_at end,
        dedupe_posts(NewPosts ++ Existing, #{})
    ).

dedupe_posts([], _Seen) ->
    [];
dedupe_posts([P = #post{id = Id} | Rest], Seen) ->
    case maps:is_key(Id, Seen) of
        true -> dedupe_posts(Rest, Seen);
        false -> [P | dedupe_posts(Rest, maps:put(Id, true, Seen))]
    end.

%%%-------------------------------------------------------------------
%%% Config + utility
%%%-------------------------------------------------------------------

default_relays() ->
    case application:get_env(nosternity, relays) of
        {ok, Relays} when is_list(Relays), Relays =/= [] -> normalize_relays(Relays);
        _ ->
            [
                <<"wss://nostr-01.yakihonne.com">>,
                <<"wss://nostr-02.yakihonne.com">>,
                <<"wss://nos.lol">>
            ]
    end.

read_privkey() ->
    case application:get_env(nosternity, nostr_private_key_hex) of
        {ok, Hex} -> hex_to_bin(to_bin(Hex));
        _ -> undefined
    end.

normalize_relays(Relays) ->
    [to_bin(R) || R <- Relays, to_bin(R) =/= <<>>].

parse_relay_text(Text) when is_list(Text) ->
    [list_to_binary(string:trim(P)) || P <- string:tokens(Text, ","), string:trim(P) =/= ""].

relay_text(Relays) ->
    string:join([binary_to_list(R) || R <- Relays], ", ").

initial_status(undefined) ->
    "Ready. No signing key configured.";
initial_status(PubKey) ->
    lists:flatten(io_lib:format("Ready as ~s", [short_hex(PubKey)])).

safe_nth(N, _List) when N =< 0 -> undefined;
safe_nth(_N, []) -> undefined;
safe_nth(1, [H | _]) -> H;
safe_nth(N, [_ | T]) -> safe_nth(N - 1, T).

short_hex(Bin) when is_binary(Bin) -> truncate(hex(Bin), 12);
short_hex(Other) -> truncate(flatten_text(Other), 12).

hex(Bin) when is_binary(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

hex_to_bin(HexBin) when is_binary(HexBin) ->
    hex_to_bin(binary_to_list(HexBin), <<>>).
hex_to_bin([], Acc) ->
    Acc;
hex_to_bin([A, B | T], Acc) ->
    Byte = list_to_integer([A, B], 16),
    hex_to_bin(T, <<Acc/binary, Byte>>).

trim_bin(Bin) when is_binary(Bin) -> list_to_binary(string:trim(binary_to_list(Bin))).

one_line(Str) -> lists:flatten(string:replace(Str, "\n", " ", all)).
truncate(Str, N) when length(Str) =< N -> Str;
truncate(Str, N) -> lists:sublist(Str, N) ++ "...".
flatten_text(Text) when is_binary(Text) -> binary_to_list(Text);
flatten_text(Text) when is_list(Text) -> lists:flatten(Text);
flatten_text(Text) -> lists:flatten(io_lib:format("~p", [Text])).

bin_to_list(B) when is_binary(B) -> binary_to_list(B);
bin_to_list(L) when is_list(L) -> L.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> list_to_binary(integer_to_list(I));
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%%%===================================================================
%%% File 2: nosternity_sup patch
%%%===================================================================
%%% Add this child under your supervisor if you want the desktop UI to
%%% launch with the app:
%%%
%%% {nosternity_ui,
%%%   {nosternity_ui, start_link, [#{}]},
%%%   permanent, 5000, worker, [nosternity_ui]}

%%%===================================================================
%%% File 3: nosternity_app.erl patch notes
%%%===================================================================
%%% Keep Cowboy/WebSocket boot as-is, but there is one route mismatch to fix:
%%%
%%% Current route uses:
%%%   {"/nostr", nostr_websocket, #{}}
%%%
%%% Uploaded module name is:
%%%   nosternity_websocket
%%%
%%% So this should become:
%%%   {"/nostr", nosternity_websocket, #{}}
%%%
%%% Otherwise the websocket endpoint will point at a missing module. fileciteturn1file1 fileciteturn1file4

%%%===================================================================
%%% File 4: recommended cleanup notes
%%%===================================================================
%%% 1. Prefer nostr_pool + nostr_relay_worker over nosternity_relay_client.
%%%    The older client is brittle and has a bad relay registry pattern. fileciteturn1file2
%%%
%%% 2. nosternity_websocket currently talks to nostr_relay, not nosternity_relay.
%%%    The uploaded storage relay module is named nosternity_relay, so either:
%%%      - rename calls in nosternity_websocket, or
%%%      - rename the module itself for consistency. fileciteturn1file3 fileciteturn1file4
%%%
%%% 3. nostr_relay_worker already has proper websocket upgrade, ping, reconnect,
%%%    and request/response handling. That should remain the upstream relay spine. fileciteturn1file0
