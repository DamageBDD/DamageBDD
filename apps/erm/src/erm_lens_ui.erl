%%%-------------------------------------------------------------------
%%% @doc GTKGS-only frontend for ERM Lens.
%%%
%%% External I/O and decoding use separate workers. UI construction is
%%% deferred until gtkgs/gtknode4 are ready and is retried without taking down
%%% the Lens supervision tree. A page is a stable snapshot: updates do not
%%% reorder cards under a finger.
%%%-------------------------------------------------------------------
-module(erm_lens_ui).

-ifdef(TEST).
-export([compact_term/1, render/1, action/2]).
-endif.
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, show/0, status/0, acknowledge_wallet_check/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TICK_MS, 2000).
-define(SYNC_TIMEOUT, 5000).

start_link(C) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).

show() ->
    gen_server:call(?MODULE, show, 10000).

status() ->
    gen_server:call(?MODULE, status, 3000).

%% Explicit operator acknowledgment only; status() never clears an uncertain
%% payment. This session interlock is not a durable transaction ledger.
acknowledge_wallet_check() -> gen_server:call(?MODULE, acknowledge_wallet_check, 3000).

init(C) ->
    process_flag(trap_exit, true),
    ShowOnStart = maps:get(show_on_start, C, false),
    ?LOG_INFO(
        "ERM Lens UI initialized show_on_start=~p gtkgs=~p gtknode4=~p",
        [ShowOnStart, whereis(gtkgs), whereis(gtknode4)]
    ),
    Timer = erlang:start_timer(0, self(), tick),
    {ok, #{
        config => C,
        window => undefined,
        gui_monitor => undefined,
        closed => false,
        want_visible => ShowOnStart,
        cards => [],
        photos => #{},
        rows => [],
        snapshot_loaded => false,
        page => 0,
        mode => popular,
        generation => 0,
        revision => -1,
        job => undefined,
        pending_tip => undefined,
        message => <<"Browsing without a wallet">>,
        timer => Timer,
        wallet_outcome_unknown => false,
        build_failures => 0,
        next_build_mono => undefined,
        last_ui_error => undefined,
        ui_capabilities => #{}
    }}.

handle_call(show, _From, S0) ->
    ?LOG_DEBUG("ERM Lens show requested window=~p", [maps:get(window, S0, undefined)]),
    S = S0#{closed := false, want_visible := true},
    case show_now(S) of
        {ok, S1} ->
            {reply, {ok, visible}, clear_ui_error(S1)};
        {error, Reason, S1} ->
            %% Store/log the root cause directly. Wrapping the same cause as
            %% show_failed/build_failed made the periodic retry look like a
            %% different failure and produced duplicate, very large warnings.
            S2 = note_ui_error(Reason, S1),
            {reply, {error, Reason}, S2}
    end;
handle_call(acknowledge_wallet_check, _From, S = #{job := undefined}) ->
    {reply, ok, S#{wallet_outcome_unknown := false}};
handle_call(acknowledge_wallet_check, _From, S) ->
    {reply, {error, operation_in_progress}, S};
handle_call(status, _From, S) ->
    {reply, status_snapshot(S), S};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.

%% Backwards-compatible cast; erm_lens:show/0 now uses the synchronous call.
handle_cast(show, S) ->
    self() ! async_show,
    {noreply, S#{closed := false, want_visible := true}};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(async_show, S) ->
    case show_now(S) of
        {ok, S1} -> {noreply, clear_ui_error(S1)};
        {error, Reason, S1} -> {noreply, note_ui_error(Reason, S1)}
    end;
handle_info({timeout, Ref, tick}, S0 = #{timer := Ref}) ->
    S1 = update_safe(S0),
    Timer = erlang:start_timer(?TICK_MS, self(), tick),
    {noreply, S1#{timer := Timer}};
handle_info({gtkgs, lens_window, destroy, _, _}, S) ->
    ?LOG_INFO("ERM Lens window closed by user", []),
    demonitor_ref(maps:get(gui_monitor, S, undefined)),
    Gen = erlang:unique_integer([monotonic, positive]),
    erm_lens_media:cancel_before(self(), Gen),
    {noreply, S#{
        gui_monitor := undefined,
        generation := Gen,
        pending_tip := undefined,
        closed := true,
        want_visible := false,
        window := undefined,
        cards := [],
        photos := #{}
    }};
handle_info({gtkgs, lens_confirm, destroy, _, _}, S) ->
    {noreply, S#{pending_tip := undefined}};
handle_info({gtkgs, _, click, Action, _}, S) ->
    try action(Action, S) of
        S1 -> {noreply, S1}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "ERM Lens action failed action=~p error=~p:~p stack=~p",
                [
                    compact_term(Action),
                    Class,
                    compact_term(Reason),
                    erm_lens_diagnostics:stack(Stacktrace)
                ]
            ),
            {noreply, message(<<"Action could not be completed; check configuration.">>, S)}
    end;
handle_info({lens_media, {Gen, Id, Index}, Result}, S = #{generation := Gen}) ->
    case maps:get(Id, maps:get(photos, S), undefined) of
        #{picture := Pic, detail := Label, index := Index, image := Image} ->
            case Result of
                {ok, Path} ->
                    safe(fun() -> gtkgs:config(Pic, [{file, Path}]) end),
                    safe(fun() -> gtkgs:config(Label, [{text, maps:get(alt, Image, <<>>)}]) end);
                {error, Why} ->
                    ?LOG_DEBUG("ERM Lens image unavailable id=~p reason=~p", [Id, Why]),
                    safe(fun() ->
                        gtkgs:config(Label, [{text, fmt("Image unavailable: ~p", [Why])}])
                    end)
            end;
        _ ->
            ok
    end,
    {noreply, S};
handle_info(
    {action_result, Pid, Result}, S = #{job := #{pid := Pid, mon := Mon, timer := T, kind := Kind}}
) ->
    erlang:demonitor(Mon, [flush]),
    erlang:cancel_timer(T),
    S1 = S#{job := undefined},
    try finish(Kind, Result, S1) of
        S2 -> {noreply, S2}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "ERM Lens result rendering failed kind=~p result=~p error=~p:~p stack=~p",
                [
                    Kind,
                    compact_term(Result),
                    Class,
                    compact_term(Reason),
                    erm_lens_diagnostics:stack(Stacktrace)
                ]
            ),
            {noreply, message(<<"Result could not be displayed.">>, S1)}
    end;
handle_info({action_timeout, Pid}, S = #{job := #{pid := Pid, mon := Mon, kind := Kind}}) ->
    exit(Pid, kill),
    erlang:demonitor(Mon, [flush]),
    ?LOG_WARNING("ERM Lens action timed out pid=~p", [Pid]),
    {noreply,
        message(
            <<"Timed out. A payment may still have been submitted; check the wallet before retrying.">>,
            mark_uncertain(Kind, S#{job := undefined})
        )};
handle_info({'DOWN', Mon, process, Pid, Reason}, S = #{gui_monitor := Mon}) ->
    ?LOG_WARNING("ERM Lens GTKGS server went down pid=~p reason=~p", [Pid, Reason]),
    {noreply,
        note_ui_error(
            {gtkgs_down, Reason},
            S#{window := undefined, cards := [], photos := #{}, gui_monitor := undefined}
        )};
handle_info({'DOWN', Mon, process, _, _}, S = #{job := #{mon := Mon, timer := T, kind := Kind}}) ->
    erlang:cancel_timer(T),
    {noreply,
        message(
            <<"Operation stopped. Check wallet transaction history before retrying a payment.">>,
            mark_uncertain(Kind, S#{job := undefined})
        )};
handle_info(Info, S) ->
    ?LOG_DEBUG("ERM Lens UI ignored message: ~p", [compact_term(Info)]),
    {noreply, S}.

terminate(Reason, S) ->
    ?LOG_INFO("Stopping ERM Lens UI reason=~p", [Reason]),
    case maps:get(timer, S, undefined) of
        undefined -> ok;
        T -> erlang:cancel_timer(T)
    end,
    case maps:get(job, S, undefined) of
        undefined -> ok;
        #{pid := P} -> exit(P, shutdown)
    end,
    lists:foreach(fun destroy/1, [
        lens_window, lens_compose, lens_wallet, lens_tip, lens_confirm, lens_comment
    ]),
    ok.

code_change(_, S, _) ->
    case maps:get(timer, S, undefined) of
        Ref when is_reference(Ref) -> erlang:cancel_timer(Ref);
        _ -> ok
    end,
    {ok, S#{
        timer => erlang:start_timer(?TICK_MS, self(), tick),
        snapshot_loaded => maps:get(snapshot_loaded, S, false),
        wallet_outcome_unknown => maps:get(wallet_outcome_unknown, S, false),
        build_failures => maps:get(build_failures, S, 0),
        next_build_mono => maps:get(next_build_mono, S, undefined)
    }}.

%%%===================================================================
%%% UI lifecycle
%%%===================================================================

show_now(S = #{window := undefined}) ->
    build(S);
show_now(S) ->
    case ui_config(lens_window, [{map, true}]) of
        ok ->
            case sync_ui() of
                ok -> {ok, S#{closed := false, want_visible := true}};
                {error, Reason} -> {error, Reason, S}
            end;
        {error, _} = Error ->
            %% The logical window disappeared underneath us. Clear the stale
            %% state and perform one immediate rebuild for the caller.
            ?LOG_DEBUG("ERM Lens existing window could not be shown: ~p; rebuilding", [Error]),
            build(S#{window := undefined, cards := [], photos := #{}})
    end.

update_safe(S) ->
    try update(S) of
        S1 -> S1
    catch
        Class:Reason:Stacktrace ->
            note_ui_error({tick_failed, Class, Reason, Stacktrace}, S)
    end.

update(S = #{window := undefined, closed := false, want_visible := true}) ->
    Next = maps:get(next_build_mono, S, undefined),
    case is_integer(Next) andalso Next > erlang:monotonic_time(millisecond) of
        true ->
            S;
        false ->
            case build(S) of
                {ok, S1} -> clear_ui_error(S1);
                {error, Reason, S1} -> note_ui_error(Reason, S1)
            end
    end;
update(S = #{window := undefined}) ->
    S;
update(S) ->
    case safe_read_shown() of
        {error, Reason} ->
            ?LOG_DEBUG("ERM Lens window no longer readable: ~p", [Reason]),
            destroy(lens_window),
            S#{window := undefined, cards := [], photos := #{}};
        _Shown ->
            Info = gen_server:call(erm_lens_feed, status, 1000),
            SyncStatus = gen_server:call(erm_lens_sync, status, 1000),
            Stats = fmt(
                "~p verified events cached · ~p rejected · ~p relay samples\n~ts",
                [
                    maps:get(events, Info),
                    maps:get(rejected, Info),
                    map_size(SyncStatus),
                    maps:get(message, S)
                ]
            ),
            case ui_config(lens_status, [{text, Stats}]) of
                ok -> ok;
                {error, Why} -> error({status_update_failed, Why})
            end,
            case
                maps:get(rows, S) =:= [] andalso
                    {maps:get(epoch, Info, undefined), maps:get(revision, Info)} =/=
                        maps:get(revision, S)
            of
                true ->
                    render(S#{
                        snapshot_loaded := false,
                        revision := {maps:get(epoch, Info, undefined), maps:get(revision, Info)}
                    });
                false ->
                    S
            end
    end.

build(S) ->
    case backend_status() of
        {ok, Caps} ->
            log_backend_profile(Caps, S),
            do_build(S#{ui_capabilities := Caps});
        {error, Reason} ->
            {error, Reason, S}
    end.

do_build(S) ->
    ?LOG_DEBUG(
        "Building ERM Lens UI gtkgs=~p gtknode4=~p visible=~p",
        [whereis(gtkgs), whereis(gtknode4), maps:get(want_visible, S, false)]
    ),
    try
        Server = gtkgs:server(),
        Tree = lens_tree(S),
        case gtkgs:create_tree(Server, Tree) of
            {ok, [Window]} ->
                demonitor_ref(maps:get(gui_monitor, S, undefined)),
                Mon = erlang:monitor(process, Server),
                S0 = S#{window := Window, gui_monitor := Mon, cards := [], photos := #{}},
                try
                    S1 = render(S0),
                    Visible = maps:get(want_visible, S1, false),
                    ok = expect_ok(gtkgs:config(Window, [{map, Visible}]), map_window),
                    ok = expect_ok(sync_ui(), sync_window),
                    ?LOG_INFO("ERM Lens UI built successfully visible=~p window=~p", [
                        Visible, Window
                    ]),
                    {ok, S1}
                catch
                    Class1:Reason1:Stack1 ->
                        ?LOG_WARNING(
                            "ERM Lens UI post-build setup failed: ~p:~p stack=~p",
                            [Class1, compact_term(Reason1), erm_lens_diagnostics:stack(Stack1)]
                        ),
                        safe(fun() -> gtkgs:destroy(Window) end),
                        demonitor_ref(Mon),
                        {error, {post_build_failed, Class1, Reason1, Stack1}, S#{
                            window := undefined, gui_monitor := undefined
                        }}
                end;
            {ok, Other} ->
                {error, {unexpected_create_tree_result, Other}, S};
            {error, Reason} ->
                {error, {create_tree_failed, Reason}, S};
            Other ->
                {error, {create_tree_failed, Other}, S}
        end
    catch
        Class:Reason0:Stacktrace ->
            {error, {ui_build_exception, Class, Reason0, Stacktrace}, S}
    end.

lens_tree(S) ->
    [
        {window, lens_window, [{title, "ERM Lens"}, {width, 480}, {height, 840}, {map, false}], [
            {frame, lens_root, [{orient, vertical}, {spacing, 8}, {margin, 12}, {expand, true}], [
                {label, lens_title, [{text, "ERM Lens"}, {align, start}, {class, 'title-1'}]},
                {label, lens_scope, [
                    {text,
                        fmt("Pictures from your relay sample · last ~p hours", [
                            maps:get(window_seconds, maps:get(config, S), 172800) div 3600
                        ])},
                    {wrap, true}
                ]},
                {frame, lens_modes, [{orient, horizontal}, {spacing, 6}, {homogeneous, true}], [
                    button(lens_popular, "Popular", popular),
                    button(lens_newest, "Newest", newest),
                    button(lens_following, "Following", following)
                ]},
                {frame, lens_tools, [{orient, horizontal}, {spacing, 6}, {homogeneous, true}], [
                    button(lens_refresh, "Refresh", refresh),
                    button(lens_new, "Compose", compose),
                    button(lens_account, "Wallet", wallet)
                ]},
                lens_body_node(S),
                {frame, lens_pages, [{orient, horizontal}, {spacing, 8}, {homogeneous, true}], [
                    button(lens_prev, "Previous", previous), button(lens_next, "Next", next)
                ]},
                {label, lens_status, [
                    {text, "Connecting to relays…"}, {wrap, true}, {align, start}
                ]}
            ]}
        ]}
    ].

backend_status() ->
    case {whereis(gtknode4), whereis(gtkgs)} of
        {undefined, undefined} ->
            {error, {gtk_backend_not_started, gtknode4_and_gtkgs}};
        {undefined, _} ->
            {error, gtknode4_not_started};
        {_, undefined} ->
            {error, gtkgs_not_started};
        {_GtkNode, _GtkGs} ->
            try gtknode4:await_ready(0) of
                ok -> widget_profile();
                {error, timeout} -> {error, gtknode4_not_ready};
                Other -> {error, {gtknode4_not_ready, Other}}
            catch
                Class:Reason:Stacktrace ->
                    {error, {gtknode4_status_failed, Class, Reason, lists:sublist(Stacktrace, 6)}}
            end
    end.

%% Keep a small hard core of widgets required to present a functional Lens.
%% Rich media/scrolling are optional and have deterministic fallbacks, so an
%% older but otherwise compatible C-node can still show a usable window.
widget_profile() ->
    Core = [window, box, button, label, entry],
    Optional = [picture, scrolled_box],
    case safe_gtknode4_status() of
        #{ready := true, capabilities := Caps} ->
            Widgets = maps:get(widgets, Caps, []),
            MissingCore = [W || W <- Core, not lists:member(W, Widgets)],
            MissingOptional = [W || W <- Optional, not lists:member(W, Widgets)],
            case MissingCore of
                [] ->
                    {ok, #{
                        widgets => Widgets,
                        picture => lists:member(picture, Widgets),
                        scrolled => lists:member(scrolled_box, Widgets),
                        degraded => MissingOptional =/= [],
                        missing_optional => MissingOptional
                    }};
                _ ->
                    {error, {gtk_backend_missing_core_widgets, MissingCore, Widgets}}
            end;
        #{ready := false} = Status ->
            {error, {gtknode4_not_ready, Status}};
        {error, Reason} ->
            {error, {gtknode4_status_failed, Reason}};
        Other ->
            {error, {unexpected_gtknode4_status, Other}}
    end.

lens_body_node(S) ->
    Body = {frame, lens_body, [{orient, vertical}, {spacing, 16}, {expand, true}], []},
    case ui_capability(scrolled, S) of
        true -> {scrolled, lens_scroll, [{orient, vertical}, {expand, true}], [Body]};
        false -> Body
    end.

ui_capability(Key, S) ->
    maps:get(Key, maps:get(ui_capabilities, S, #{}), false).

log_backend_profile(Caps, S) ->
    Old = maps:get(ui_capabilities, S, #{}),
    case {maps:get(degraded, Caps, false), Caps =:= Old} of
        {true, false} ->
            ?LOG_WARNING(
                "ERM Lens using degraded GTK profile missing_optional=~p widgets=~p",
                [maps:get(missing_optional, Caps, []), maps:get(widgets, Caps, [])]
            );
        {false, false} when Old =/= #{} ->
            ?LOG_INFO("ERM Lens GTK capabilities upgraded to full profile widgets=~p", [
                maps:get(widgets, Caps, [])
            ]);
        _ ->
            ok
    end.

sync_ui() ->
    try gtkgs:sync(?SYNC_TIMEOUT) of
        ok -> ok;
        {error, _} = Error -> Error;
        Other -> {error, {unexpected_sync_result, Other}}
    catch
        error:undef ->
            %% Older gtkgs builds exposed sync/0 only.
            try gtkgs:sync() of
                ok -> ok;
                {error, _} = Error2 -> Error2;
                Other2 -> {error, {unexpected_sync_result, Other2}}
            catch
                Class2:Reason2 -> {error, {sync_failed, Class2, Reason2}}
            end;
        Class:Reason ->
            {error, {sync_failed, Class, Reason}}
    end.

ui_config(Ref, Options) ->
    try gtkgs:config(Ref, Options) of
        ok -> ok;
        {error, _} = Error -> Error;
        Other -> {error, {unexpected_config_result, Other}}
    catch
        Class:Reason -> {error, {config_failed, Class, Reason}}
    end.

safe_read_shown() ->
    try gtkgs:read(lens_window, shown) of
        {error, _} = Error -> Error;
        Value -> Value
    catch
        Class:Reason -> {error, {read_failed, Class, Reason}}
    end.

status_snapshot(S) ->
    %% Status must not depend on GTK/feed/relay gen_servers replying. Report
    %% cached logical visibility explicitly rather than probing a hung backend.
    #{
        pid => self(),
        window => maps:get(window, S, undefined),
        shown => maps:get(window, S, undefined) =/= undefined andalso
            maps:get(want_visible, S, false) andalso not maps:get(closed, S, false),
        shown_is_cached => true,
        closed => maps:get(closed, S, false),
        want_visible => maps:get(want_visible, S, false),
        last_ui_error => maps:get(last_ui_error, S, undefined),
        ui_capabilities => maps:get(ui_capabilities, S, #{}),
        backend => not_probed,
        gtkgs => whereis(gtkgs),
        gtknode4 => whereis(gtknode4),
        gtknode4_status => not_probed,
        feed => whereis(erm_lens_feed),
        sync => whereis(erm_lens_sync),
        media => whereis(erm_lens_media),
        wallet_outcome_unknown => maps:get(wallet_outcome_unknown, S, false),
        operation =>
            case maps:get(job, S, undefined) of
                undefined -> idle;
                #{kind := Kind} -> Kind
            end
    }.

safe_gtknode4_status() ->
    case whereis(gtknode4) of
        undefined ->
            not_started;
        _ ->
            try gtknode4:status() of
                Status -> Status
            catch
                Class:Reason -> {error, {Class, Reason}}
            end
    end.

note_ui_error(Reason, S) ->
    Summary = ui_error_summary(Reason),
    Previous = maps:get(last_ui_error, S, undefined),
    case Previous of
        Summary ->
            ?LOG_DEBUG("ERM Lens UI still unavailable reason=~p", [Summary]);
        _ ->
            ?LOG_WARNING(
                "ERM Lens UI unavailable reason=~p previous=~p",
                [Summary, ui_error_summary(Previous)]
            )
    end,
    Failures = maps:get(build_failures, S, 0) + 1,
    Delay = min(30000, 1000 * (1 bsl min(5, Failures - 1))),
    S#{
        last_ui_error => Summary,
        build_failures => Failures,
        next_build_mono => erlang:monotonic_time(millisecond) + Delay
    }.

ui_error_summary(undefined) ->
    undefined;
ui_error_summary({create_tree_failed, Reason}) ->
    {create_tree_failed, compact_term(Reason)};
ui_error_summary({post_build_failed, Class, Reason, _Stack}) ->
    {post_build_failed, Class, compact_term(Reason)};
ui_error_summary({ui_build_exception, Class, Reason, _Stack}) ->
    {ui_build_exception, Class, compact_term(Reason)};
ui_error_summary({tick_failed, Class, Reason, _Stack}) ->
    {tick_failed, Class, compact_term(Reason)};
ui_error_summary(Reason) ->
    compact_term(Reason).

compact_term(Term) -> erm_lens_diagnostics:summary(Term).

clear_ui_error(S) ->
    case maps:get(last_ui_error, S, undefined) of
        undefined ->
            S;
        Previous ->
            ?LOG_INFO("ERM Lens UI recovered from: ~p", [Previous]),
            S#{last_ui_error => undefined, build_failures => 0, next_build_mono => undefined}
    end.

expect_ok(ok, _Op) -> ok;
expect_ok({error, Reason}, Op) -> error({Op, Reason});
expect_ok(Other, Op) -> error({Op, Other}).

demonitor_ref(undefined) ->
    ok;
demonitor_ref(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref, [flush]),
    ok;
demonitor_ref(_) ->
    ok.

button(Name, Text, Data) ->
    {button, Name, [{label, Text}, {data, Data}, {min_height, 48}, {expand, true}]}.

new(Type, Parent, Options) ->
    case gtkgs:create(Type, Parent, Options) of
        {gtkgs_ref, _, _} = Ref -> Ref;
        Other -> error({widget_failed, Type, Parent, Other})
    end.

render(S) ->
    try
        Rows =
            case maps:get(snapshot_loaded, S, false) of
                true -> maps:get(rows, S);
                false -> gen_server:call(erm_lens_feed, {snapshot, maps:get(mode, S)}, 1000)
            end,
        true = is_list(Rows),
        render_rows(Rows, S)
    catch
        _:_ -> message(<<"Feed unavailable; the previous page is preserved.">>, S)
    end.

render_rows(Rows, S) ->
    MaxPageSize =
        case ui_capability(scrolled, S) of
            true -> 12;
            false -> 1
        end,
    Configured = erm_lens_config:integer(page_size, maps:get(config, S), 6, 1, 12),
    PageSize = min(MaxPageSize, Configured),
    Page = min(maps:get(page, S), max(0, (length(Rows) - 1) div PageSize)),
    Visible = lists:sublist(lists:nthtail(min(Page * PageSize, length(Rows)), Rows), PageSize),
    %% Fresh across failed builds and process restarts: a delayed image from an
    %% abandoned page must never match a later page's generation.
    Gen = erlang:unique_integer([monotonic, positive]),
    PageRoot = new(frame, lens_body, [{orient, vertical}, {spacing, 16}, {map, false}]),
    try
        Photos = lists:foldl(
            fun(P, Acc) ->
                {_Card, Photo} = card(P, maps:get(ui_capabilities, S, #{}), PageRoot),
                Acc#{maps:get(id, P) => Photo}
            end,
            #{},
            Visible
        ),
        case Visible of
            [] ->
                new(label, PageRoot, [
                    {text, "No pictures yet. Refresh after the relay sample completes."},
                    {wrap, true}
                ]);
            _ ->
                ok
        end,
        ok = expect_ok(gtkgs:config(PageRoot, [{map, true}]), map_page),
        lists:foreach(fun destroy/1, maps:get(cards, S)),
        erm_lens_media:cancel_before(self(), Gen),
        %% Queue decoding only after the logical page has been installed.
        maps:foreach(
            fun(Id, Photo) ->
                safe(fun() ->
                    maybe_request_image(
                        maps:get(picture, Photo),
                        maps:get(detail, Photo),
                        Gen,
                        Id,
                        1,
                        maps:get(image, Photo),
                        maps:get(config, S)
                    )
                end)
            end,
            Photos
        ),
        S#{
            rows := Rows,
            page := Page,
            generation := Gen,
            cards := [PageRoot],
            photos := Photos,
            snapshot_loaded := true
        }
    catch
        _:_ ->
            destroy(PageRoot),
            message(<<"Could not render this page; the previous page is preserved.">>, S)
    end.

card(P, Caps, Parent) ->
    Id = maps:get(id, P),
    Author = maps:get(author, P),
    Card = new(frame, Parent, [{orient, vertical}, {spacing, 8}, {margin, 4}]),
    _ = new(label, Card, [
        {text, <<"nostr:", (binary:part(Author, 0, 16))/binary, "…"/utf8>>}, {align, start}
    ]),
    Image = hd(maps:get(images, P)),
    {Pic, Detail} =
        case maps:get(picture, Caps, false) of
            true ->
                {
                    new(picture, Card, [{min_height, 280}, {tooltip, "Post image"}]),
                    new(label, Card, [{text, "Loading image…"}, {wrap, true}])
                };
            false ->
                {undefined,
                    new(label, Card, [
                        {text, fallback_image_text(Image)},
                        {wrap, true},
                        {align, start}
                    ])}
        end,
    _ = new(label, Card, [
        {text, shorten(maps:get(caption, P), 600)}, {wrap, true}, {align, start}, {width_chars, 28}
    ]),
    _ = new(label, Card, [
        {text,
            fmt("~p likes · ~p commenters · ~p reposts", [
                maps:get(likes, P), maps:get(comments, P), maps:get(reposts, P)
            ])},
        {align, start}
    ]),
    action_row(Card, [{"Like", {like, Id}}, {"Comment", {comment, Id}}, {"Tip", {tip, Id}}]),
    action_row(Card, [
        {"Follow", {follow, Author}}, {"Mute", {mute, Author}}, {"Next image", {image, Id}}
    ]),
    {Card, #{picture => Pic, detail => Detail, index => 1, image => Image, post => P}}.

maybe_request_image(undefined, Detail, _Gen, _Id, _Index, Image, _C) ->
    gtkgs:config(Detail, [{text, fallback_image_text(Image)}]);
maybe_request_image(Pic, Detail, Gen, Id, Index, Image, C) ->
    case maps:get(load_images, C, true) of
        true -> erm_lens_media:request({Gen, Id, Index}, Image, self());
        false -> gtkgs:config(Detail, [{text, "Images disabled in configuration"}])
    end,
    _ = Pic,
    ok.

fallback_image_text(Image) ->
    Alt = maps:get(alt, Image, <<>>),
    Url = maps:get(url, Image, <<>>),
    case Alt of
        <<>> -> fmt("Image: ~ts", [Url]);
        _ -> fmt("Image: ~ts\n~ts", [Url, Alt])
    end.

action_row(Parent, Actions) ->
    Row = new(frame, Parent, [{orient, horizontal}, {spacing, 6}, {homogeneous, true}]),
    [
        new(button, Row, [{label, L}, {data, A}, {min_height, 48}, {expand, true}])
     || {L, A} <- Actions
    ].

action(Mode, S) when Mode =:= popular; Mode =:= newest; Mode =:= following ->
    change_view(#{mode => Mode, page => 0, snapshot_loaded => false}, S);
action(refresh, S) ->
    erm_lens_sync:refresh(),
    render(
        message(<<"Sampling relays; press Refresh to re-rank when ready.">>, S#{
            page := 0, snapshot_loaded := false
        })
    );
action(next, S) ->
    change_view(#{page => maps:get(page, S) + 1}, S);
action(previous, S) ->
    change_view(#{page => max(0, maps:get(page, S) - 1)}, S);
action({mute, Pub}, S) ->
    erm_lens_feed:mute(Pub),
    render(message(<<"Muted locally for this session.">>, S#{snapshot_loaded := false}));
action({follow, Pub}, S) ->
    erm_lens_feed:follow(Pub),
    message(<<"Following locally for this session.">>, S);
action({image, Id}, S) ->
    Photo = maps:get(Id, maps:get(photos, S)),
    P = maps:get(post, Photo),
    Images = maps:get(images, P),
    Index = maps:get(index, Photo) rem length(Images) + 1,
    Image = lists:nth(Index, Images),
    Pic = maps:get(picture, Photo, undefined),
    Detail = maps:get(detail, Photo),
    case Pic of
        undefined ->
            gtkgs:config(Detail, [{text, fallback_image_text(Image)}]);
        _ ->
            gtkgs:config(Pic, [{file, <<>>}]),
            maybe_request_image(
                Pic, Detail, maps:get(generation, S), Id, Index, Image, maps:get(config, S)
            )
    end,
    S#{photos := (maps:get(photos, S))#{Id := Photo#{index := Index, image := Image}}};
action({like, Id}, S) ->
    E = event(Id, S),
    C = maps:get(config, S),
    run(
        publish, fun() -> erm_lens_wallet:sign_publish(erm_lens_nostr:reaction(pub(C), E), C) end, S
    );
action(compose, S) ->
    panel(lens_compose, "New picture", [
        label("Paste an already-uploaded HTTPS image URL. Uploading is not included yet."),
        entry(lens_picture_title, "Picture title"),
        entry(lens_image_url, "https://…"),
        entry(lens_mime, "image/jpeg"),
        entry(lens_alt, "Image description for accessibility"),
        entry(lens_caption, "Caption"),
        button(lens_publish, "Sign and publish", publish_picture)
    ]),
    S;
action(publish_picture, S) ->
    C = maps:get(config, S),
    U = read(lens_image_url),
    M = read(lens_mime),
    Alt = read(lens_alt),
    Caption = read(lens_caption),
    Title = read(lens_picture_title),
    run(
        publish,
        fun() ->
            case erm_lens_nostr:picture(pub(C), U, M, Alt, Caption, Title) of
                {ok, D} -> erm_lens_wallet:sign_publish(D, C);
                Err -> Err
            end
        end,
        S
    );
action({comment, Id}, S) ->
    panel(lens_comment, "Comment", [
        label("Write a public comment"),
        entry(lens_comment_text, ""),
        button(lens_comment_send, "Sign and publish", {send_comment, Id})
    ]),
    S;
action({send_comment, Id}, S) ->
    C = maps:get(config, S),
    E = event(Id, S),
    Text = read(lens_comment_text),
    run(
        publish,
        fun() -> erm_lens_wallet:sign_publish(erm_lens_nostr:comment(pub(C), E, Text), C) end,
        S
    );
action(wallet, S) ->
    panel(lens_wallet, "Wallet and account", [
        {label, lens_wallet_info, [{text, "Requesting wallet status…"}, {wrap, true}]},
        label("Nostr owns the profile. Aeternity owns settlement. Linking is optional."),
        button(lens_link, "Link Nostr account", link_account)
    ]),
    C = maps:get(config, S),
    run(wallet_status, fun() -> erm_lens_wallet:status(C) end, S);
action(link_account, S) ->
    C = maps:get(config, S),
    run(link, fun() -> erm_lens_wallet:link_account(C) end, S);
action({tip, Id}, S) ->
    Tokens = maps:get(tokens, maps:get(config, S), []),
    Token =
        case Tokens of
            [T | _] -> T;
            [] -> <<>>
        end,
    panel(lens_tip, "AEX9 tip", [
        label("Allowlisted AEX9 contract"),
        entry(lens_tip_token, Token),
        label("Token amount (not AE gas)"),
        entry(lens_tip_amount, "1"),
        label("The recipient must have a verified Nostr ↔ wallet link."),
        button(lens_tip_preview, "Preview payment", {preview_tip, Id})
    ]),
    S;
action({preview_tip, Id}, S) ->
    C = maps:get(config, S),
    E = event(Id, S),
    Token = read(lens_tip_token),
    Amount = read(lens_tip_amount),
    run(preview_tip, fun() -> erm_lens_wallet:prepare_tip(E, Token, Amount, C) end, S);
action(
    {confirm_tip, RequestId},
    S = #{
        job := undefined,
        wallet_outcome_unknown := false,
        pending_tip := Prepared = #{request := #{request_id := RequestId}}
    }
) ->
    C = maps:get(config, S),
    destroy(lens_confirm),
    run(payment, fun() -> erm_lens_wallet:submit_tip(Prepared, C) end, S#{pending_tip := undefined});
action(_, S) ->
    S.

finish(preview_tip, {ok, Prepared = #{request := Req, fee_aettos := Fee}}, S) ->
    Text = fmt(
        "Send ~ts ~ts\nNetwork: ~ts\nFrom: ~ts\nTo: ~ts\nToken: ~ts\nEstimated gas: ~ts AE\nPost: ~ts\nThe external wallet must approve the actual transaction.",
        [
            erm_lens_wallet:format_amount(
                maps:get(amount_base_units, Req), maps:get(decimals, Req)
            ),
            maps:get(symbol, Req),
            maps:get(network, Req),
            maps:get(sender, Req),
            maps:get(recipient, Req),
            maps:get(token, Req),
            erm_lens_wallet:format_amount(Fee, 18),
            maps:get(post_id, Req)
        ]
    ),
    panel(lens_confirm, "Review token payment", [
        label(Text),
        button(lens_confirm_send, "Continue to wallet", {confirm_tip, maps:get(request_id, Req)})
    ]),
    S#{pending_tip := Prepared};
finish(wallet_status, Result, S) ->
    safe(fun() -> gtkgs:config(lens_wallet_info, [{text, fmt("~p", [Result])}]) end),
    message(<<"Wallet status received. No transaction submitted.">>, S);
finish(Kind, {error, _}, S) when Kind =:= payment; Kind =:= link ->
    message(
        <<"Wallet operation failed or is uncertain. Check wallet history before retrying.">>,
        mark_uncertain(Kind, S)
    );
finish(payment, {ok, Result}, S) ->
    message(fmt("Wallet result: ~p. Submission is not final confirmation.", [Result]), S);
finish(_, Result, S) ->
    message(shorten(fmt("~p", [Result]), 500), S).
run(Kind, _, S = #{wallet_outcome_unknown := true}) when Kind =:= payment; Kind =:= link ->
    message(
        <<"Wallet outcome is uncertain. Check wallet history, then explicitly acknowledge that check.">>,
        S
    );
run(_, _, S = #{job := Job}) when Job =/= undefined ->
    message(<<"An operation is already awaiting a result.">>, S);
run(Kind, Fun, S) ->
    {Pid, Mon} = erm_lens_worker:start(action_result, fun() ->
        Result =
            try
                Fun()
            catch
                _:_ -> {error, operation_failed}
            end,
        Result
    end),
    Timer = erlang:send_after(120000, self(), {action_timeout, Pid}),
    message(
        <<"Operation in progress; wallet signing may need your approval.">>,
        S#{job := #{pid => Pid, mon => Mon, timer => Timer, kind => Kind}}
    ).
event(Id, S) -> maps:get(event, hd([P || P <- maps:get(rows, S), maps:get(id, P) =:= Id])).
pub(C) ->
    P = maps:get(nostr_pubkey, C),
    true = erm_lens_nostr:is_hex(P, 64),
    P.
panel(Name, Title, Children) ->
    destroy(Name),
    {ok, [_]} = gtkgs:create_tree(gtkgs:server(), [
        {window, Name, [{title, Title}, {width, 420}, {height, 440}, {map, true}], [
            {frame, undefined, [{orient, vertical}, {spacing, 10}, {margin, 16}], Children}
        ]}
    ]),
    ok.
entry(Name, Text) -> {entry, Name, [{text, Text}, {min_height, 48}, {expand, true}]}.
label(Text) -> {label, undefined, [{text, Text}, {wrap, true}, {width_chars, 32}, {align, start}]}.
read(Name) ->
    case gtkgs:read(Name, text) of
        B when is_binary(B) -> B;
        L when is_list(L) -> unicode:characters_to_binary(L);
        _ -> error(read_failed)
    end.
message(Text, S) ->
    safe(fun() -> gtkgs:config(lens_status, [{text, Text}]) end),
    S#{message := Text}.
destroy(Ref) -> safe(fun() -> gtkgs:destroy(Ref) end).
safe(F) ->
    try F() of
        Result -> Result
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(
                "ERM Lens best-effort UI operation failed error=~p:~p stack=~p",
                [Class, compact_term(Reason), erm_lens_diagnostics:stack(Stacktrace)]
            ),
            ok
    end.
fmt(Format, Args) -> unicode:characters_to_binary(io_lib:format(Format, Args)).
shorten(Text, N) ->
    L = unicode:characters_to_list(Text),
    unicode:characters_to_binary(
        case length(L) > N of
            true -> lists:sublist(L, N) ++ "…";
            false -> L
        end
    ).

mark_uncertain(Kind, S) when Kind =:= payment; Kind =:= link ->
    S#{wallet_outcome_unknown := true};
mark_uncertain(_, S) ->
    S.

change_view(Changes, S) ->
    Next = render(maps:merge(S, Changes)),
    case maps:get(generation, Next) =:= maps:get(generation, S) of
        false ->
            Next;
        true ->
            %% A failed render must not advance navigation metadata while old
            %% cards are still on screen.
            maps:merge(Next, maps:with([mode, page, snapshot_loaded, revision], S))
    end.
