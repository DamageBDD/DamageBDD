%%%-------------------------------------------------------------------
%%% @doc
%%% Responsive gtkgs control surface for whisper_trigger_srv.
%%%
%%% The UI owns presentation only. whisper_trigger_srv remains the source of
%%% truth and owns the native whisper-stream process. A narrow-window
%%% breakpoint converts horizontal action rows to vertical rows for touch and
%%% phone-sized displays.
%%%-------------------------------------------------------------------
-module(whisper_trigger_ui).
-behaviour(gen_server).

-export([
    start/0,
    start_link/0,
    start_link/1,
    child_spec/1,
    show/0,
    stop/0,
    refresh/0,
    status/0
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
-define(DEFAULT_REFRESH_MS, 500).
-define(COMPACT_WIDTH, 520).
-define(ACTION_TIMEOUT_MS, 10000).

-record(state, {
    window = undefined,
    refresh_ms = ?DEFAULT_REFRESH_MS,
    refresh_timer = undefined,
    compact = false,
    page = dashboard,
    pending = undefined,
    input_sources = [],
    selected_source = undefined,
    last_status = #{},
    form_initialized = false
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start() ->
    case whereis(?SERVER) of
        undefined ->
            try gtkgs:start() of
                _GtkServer -> gen_server:start({local, ?SERVER}, ?MODULE, #{}, [])
            catch
                Class:Reason -> {error, {gtkgs_start_failed, Class, Reason}}
            end;
        Pid ->
            {ok, Pid}
    end.

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

child_spec(Opts) when is_map(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

show() ->
    case whereis(?SERVER) of
        undefined -> start();
        _Pid -> call_if_started(show)
    end.

stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _Pid -> gen_server:stop(?SERVER)
    end.

refresh() ->
    call_if_started(refresh).

status() ->
    call_if_started(status).

call_if_started(Request) ->
    case whereis(?SERVER) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?SERVER, Request, 2000)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    RefreshMs = refresh_interval(maps:get(refresh_ms, Opts, ?DEFAULT_REFRESH_MS)),
    case whereis(gtkgs) of
        undefined ->
            {stop, gtkgs_not_started};
        GtkServer ->
            try build_ui(GtkServer) of
                Window ->
                    State0 = #state{window = Window, refresh_ms = RefreshMs},
                    State1 = refresh_status(State0),
                    {ok, schedule_refresh(State1)}
            catch
                Class:Reason:Stacktrace ->
                    _ = safe_destroy(main_window),
                    {stop, {ui_build_failed, Class, Reason, Stacktrace}}
            end
    end.

handle_call(refresh, _From, State0) ->
    State1 = refresh_status(State0),
    {reply, ok, State1};
handle_call(show, _From, State) ->
    safe_config(main_window, [{show, true}, {present, true}]),
    {reply, ok, State};
handle_call(status, _From, State) ->
    {reply,
        #{
            compact => State#state.compact,
            page => State#state.page,
            pending => pending_action(State#state.pending),
            selected_source => State#state.selected_source,
            backend => State#state.last_status
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(refresh_status, State0) ->
    State1 = refresh_status(State0#state{refresh_timer = undefined}),
    {noreply, schedule_refresh(State1)};
handle_info(
    {backend_action_result, Ref, Action, Result},
    State0 = #state{pending = #{ref := Ref}}
) ->
    State1 = clear_pending(State0),
    set_feedback(action_feedback(Action, Result), result_kind(Result)),
    {noreply, refresh_status(State1)};
handle_info(
    {backend_action_timeout, Ref},
    State0 = #state{pending = #{ref := Ref, worker := Worker, action := Action}}
) ->
    exit(Worker, kill),
    State1 = clear_pending(State0),
    set_feedback([action_name(Action), " timed out."], error),
    {noreply, refresh_status(State1)};
handle_info({backend_action_result, _Ref, _Action, _Result}, State) ->
    {noreply, State};
handle_info({backend_action_timeout, _Ref}, State) ->
    {noreply, State};
handle_info({gtkgs, main_window, destroy, _Data, _Args}, State) ->
    {stop, normal, State};
handle_info({gtkgs, main_window, configure, _Data, Args}, State0) ->
    {noreply, apply_responsive_layout(event_width(Args), State0)};
handle_info({gtkgs, dashboard_button, click, _Data, _Args}, State) ->
    {noreply, switch_page(dashboard, State)};
handle_info({gtkgs, inputs_button, click, _Data, _Args}, State) ->
    {noreply, switch_page(inputs, State)};
handle_info({gtkgs, settings_button, click, _Data, _Args}, State) ->
    {noreply, switch_page(settings, State)};
handle_info({gtkgs, start_button, click, _Data, _Args}, State) ->
    {noreply, run_action(start, fun whisper_trigger_srv:start_listening/0, State)};
handle_info({gtkgs, stop_button, click, _Data, _Args}, State) ->
    {noreply, run_action(stop, fun whisper_trigger_srv:stop_listening/0, State)};
handle_info({gtkgs, restart_button, click, _Data, _Args}, State) ->
    {noreply, run_action(restart, fun whisper_trigger_srv:restart_listening/0, State)};
handle_info({gtkgs, cleanup_button, click, _Data, _Args}, State) ->
    {noreply, run_action(cleanup, fun whisper_trigger_srv:cleanup_existing/0, State)};
handle_info({gtkgs, refresh_button, click, _Data, _Args}, State0) ->
    set_feedback(<<"Status refreshed">>, info),
    {noreply, refresh_status(State0)};
handle_info({gtkgs, input_list, select, _Data, Args}, State0) ->
    case selected_source(Args, State0#state.input_sources) of
        {ok, Source} ->
            safe_config(selected_input_label, [
                {text, ["Selected: ", source_name(Source)]}
            ]),
            {noreply, State0#state{selected_source = Source}};
        error ->
            {noreply, State0}
    end;
handle_info({gtkgs, apply_source_button, click, _Data, _Args}, State) ->
    {noreply, apply_selected_source(State)};
handle_info({gtkgs, apply_triggers_button, click, _Data, _Args}, State) ->
    {noreply, apply_trigger_phrases(State)};
handle_info({gtkgs, trigger_entry, keypress, _Data, ['Return' | _]}, State) ->
    {noreply, apply_trigger_phrases(State)};
handle_info({gtkgs, apply_timing_button, click, _Data, _Args}, State) ->
    {noreply, apply_timing(State)};
handle_info({gtkgs, echo_button, click, _Data, _Args}, State) ->
    {noreply, toggle_configuration(echo_output, echo, State)};
handle_info({gtkgs, auto_cleanup_button, click, _Data, _Args}, State) ->
    {noreply, toggle_configuration(cleanup_existing, auto_cleanup, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_refresh(State#state.refresh_timer),
    cancel_pending(State#state.pending),
    _ = safe_destroy(State#state.window),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% UI construction
%%%===================================================================

build_ui(GtkServer) ->
    Window = widget(window, main_window, GtkServer, [
        {title, "Whisper Trigger"},
        {width, 560},
        {height, 720},
        {min_width, 360},
        {min_height, 520},
        {show, false}
    ]),
    _Root = widget(frame, root, Window, box_opts(vertical, 14, 16)),

    _Header = widget(frame, header, root, box_opts(vertical, 4, 0)),
    _Title = widget(label, title_label, header, [
        {text, "Whisper Trigger"}, {xalign, 0.0}, {css_class, title}
    ]),
    _Subtitle = widget(label, subtitle_label, header, [
        {text, "Local speech control · whisper.cpp"},
        {xalign, 0.0},
        {wrap, true},
        {css_class, dim_label}
    ]),

    _StatusCard = widget(frame, status_card, root, card_opts()),
    _StatusHeading = widget(label, status_heading, status_card, [
        {text, "STATUS"}, {xalign, 0.0}, {css_class, section_heading}
    ]),
    _StatusLabel = widget(label, status_label, status_card, [
        {text, "● Checking service…"},
        {xalign, 0.0},
        {wrap, true},
        {css_class, status_pending}
    ]),
    _StatusDetail = widget(label, status_detail, status_card, [
        {text, "Waiting for runtime status"},
        {xalign, 0.0},
        {wrap, true},
        {selectable, true}
    ]),
    _ActivityHeading = widget(label, activity_heading, status_card, [
        {text, "Latest activity"}, {xalign, 0.0}, {css_class, dim_label}
    ]),
    _Activity = widget(label, activity_label, status_card, [
        {text, "No speech activity yet"},
        {xalign, 0.0},
        {wrap, true},
        {selectable, true},
        {lines, 3},
        {ellipsize, 'end'}
    ]),
    _Metrics = widget(label, metrics_label, status_card, [
        {text, "Transcripts 0  ·  Triggers 0"},
        {xalign, 0.0},
        {wrap, true},
        {css_class, dim_label}
    ]),

    _Navigation = widget(frame, navigation, root, box_opts(horizontal, 8, 0)),
    _DashboardButton = touch_button(
        dashboard_button, navigation, "Dashboard", suggested_action
    ),
    _InputsButton = touch_button(inputs_button, navigation, "Inputs", flat),
    _SettingsButton = touch_button(settings_button, navigation, "Settings", flat),

    _Pages = widget(frame, pages, root, box_opts(vertical, 0, 0)),
    _DashboardPage = widget(
        frame, dashboard_page, pages, [{show, true} | box_opts(vertical, 12, 0)]
    ),
    _InputPage = widget(
        frame, input_page, pages, [{show, false} | box_opts(vertical, 12, 0)]
    ),
    _SettingsPage = widget(
        frame, settings_page, pages, [{show, false} | box_opts(vertical, 12, 0)]
    ),

    _Primary = widget(
        frame, primary_actions, dashboard_page, box_opts(horizontal, 10, 0)
    ),
    _Start = touch_button(start_button, primary_actions, "Start listening", suggested_action),
    _Stop = touch_button(stop_button, primary_actions, "Stop", destructive_action),
    _Secondary = widget(
        frame, secondary_actions, dashboard_page, box_opts(horizontal, 10, 0)
    ),
    _Restart = touch_button(restart_button, secondary_actions, "Restart", normal),
    _Cleanup = touch_button(cleanup_button, secondary_actions, "Clean stale", normal),
    _Refresh = touch_button(refresh_button, secondary_actions, "Refresh", flat),

    _InputCard = widget(frame, input_card, input_page, card_opts()),
    _InputHeading = widget(label, input_heading, input_card, [
        {text, "INPUT SOURCE"}, {xalign, 0.0}, {css_class, section_heading}
    ]),
    _InputHelp = widget(label, input_help, input_card, [
        {text, "Select a microphone, then apply. Changing input restarts listening safely."},
        {xalign, 0.0},
        {wrap, true},
        {css_class, dim_label}
    ]),
    _InputList = widget(listbox, input_list, input_card, [
        {items, ["System default"]},
        {height_request, 120},
        {hexpand, true},
        {vexpand, false},
        {single_selection, true}
    ]),
    _SelectedInput = widget(label, selected_input_label, input_card, [
        {text, "Selected: System default"}, {xalign, 0.0}, {wrap, true}
    ]),
    _ApplySource = touch_button(
        apply_source_button, input_card, "Use selected input", suggested_action
    ),

    _ConfigCard = widget(frame, config_card, settings_page, card_opts()),
    _ConfigHeading = widget(label, config_heading, config_card, [
        {text, "CONFIGURATION"}, {xalign, 0.0}, {css_class, section_heading}
    ]),
    _TriggerLabel = widget(label, trigger_label, config_card, [
        {text, "Trigger phrases · case-insensitive"}, {xalign, 0.0}
    ]),
    _TriggerEntry = widget(entry, trigger_entry, config_card, [
        {placeholder, "computer, thread ripper zero"},
        {hexpand, true},
        {tooltip, "Separate phrases with commas"}
    ]),
    _ApplyTriggers = touch_button(
        apply_triggers_button, config_card, "Apply trigger phrases", normal
    ),

    _TimingRow = widget(frame, timing_row, config_card, box_opts(horizontal, 10, 0)),
    _DedupeGroup = widget(frame, dedupe_group, timing_row, box_opts(vertical, 4, 0)),
    _DedupeLabel = widget(label, dedupe_label, dedupe_group, [
        {text, "Repeat filter (ms)"}, {xalign, 0.0}
    ]),
    _DedupeEntry = widget(entry, dedupe_entry, dedupe_group, [
        {text, "3000"}, {input_purpose, digits}, {hexpand, true}
    ]),
    _DebounceGroup = widget(frame, debounce_group, timing_row, box_opts(vertical, 4, 0)),
    _DebounceLabel = widget(label, debounce_label, debounce_group, [
        {text, "Trigger cooldown (ms)"}, {xalign, 0.0}
    ]),
    _DebounceEntry = widget(entry, debounce_entry, debounce_group, [
        {text, "3000"}, {input_purpose, digits}, {hexpand, true}
    ]),
    _ApplyTiming = touch_button(apply_timing_button, config_card, "Apply timing", normal),

    _ToggleRow = widget(frame, toggle_row, config_card, box_opts(horizontal, 10, 0)),
    _Echo = touch_button(echo_button, toggle_row, "Output logs: On", normal),
    _AutoCleanup = touch_button(
        auto_cleanup_button, toggle_row, "Auto-clean stale: On", normal
    ),

    _RuntimeCard = widget(frame, runtime_card, dashboard_page, card_opts()),
    _RuntimeHeading = widget(label, runtime_heading, runtime_card, [
        {text, "RUNTIME"}, {xalign, 0.0}, {css_class, section_heading}
    ]),
    _RuntimeDetail = widget(label, runtime_detail, runtime_card, [
        {text, "Runtime information unavailable"},
        {xalign, 0.0},
        {wrap, true},
        {selectable, true},
        {css_class, monospace}
    ]),

    _Feedback = widget(label, feedback_label, root, [
        {text, "Ready"},
        {xalign, 0.0},
        {wrap, true},
        {css_class, dim_label},
        {accessible_role, status}
    ]),
    ok = expect_ok(gtkgs:sync()),
    ok = expect_ok(gtkgs:config(Window, [{show, true}])),
    ok = expect_ok(gtkgs:sync()),
    Window.

widget(Type, Name, Parent, Options) ->
    case gtkgs:create(Type, Name, Parent, Options) of
        {gtkgs_ref, _, _} = Ref -> Ref;
        {error, Reason} -> error({widget_create_failed, Name, Reason})
    end.

touch_button(Name, Parent, Label, CssClass) ->
    widget(button, Name, Parent, [
        {label, Label},
        {min_height, 48},
        {hexpand, true},
        {css_class, CssClass},
        {focusable, true}
    ]).

box_opts(Orientation, Spacing, Margin) ->
    [
        {orient, Orientation},
        {spacing, Spacing},
        {margin, Margin},
        {hexpand, true}
    ].

card_opts() ->
    [
        {orient, vertical},
        {spacing, 8},
        {margin, 12},
        {hexpand, true},
        {css_class, card}
    ].

expect_ok(ok) -> ok;
expect_ok({ok, _}) -> ok;
expect_ok({error, Reason}) -> error({gtk_sync_failed, Reason}).

%%%===================================================================
%%% Backend status and actions
%%%===================================================================

refresh_status(State0) ->
    case backend_status() of
        {ok, Status} -> update_available_status(Status, State0);
        {error, Reason} -> update_unavailable_status(Reason, State0)
    end.

backend_status() ->
    case whereis(whisper_trigger_srv) of
        undefined ->
            {error, not_started};
        _Pid ->
            try gen_server:call(whisper_trigger_srv, status, 1000) of
                Status when is_map(Status) -> {ok, Status};
                Other -> {error, {unexpected_status, Other}}
            catch
                exit:Reason -> {error, Reason}
            end
    end.

update_available_status(Status, State0) ->
    Listening = maps:get(listening, Status, false),
    LastError = maps:get(last_error, Status, undefined),
    safe_config(status_label, [
        {text, status_title(Listening, LastError)},
        {css_class, status_class(Listening, LastError)}
    ]),
    safe_config(status_detail, [{text, status_detail(Status)}]),
    safe_config(activity_label, [{text, activity_text(Status)}]),
    safe_config(metrics_label, [{text, metrics_text(Status)}]),
    safe_config(runtime_detail, [{text, runtime_text(Status)}]),
    update_action_sensitivity(Listening, State0#state.pending),
    update_toggle_labels(Status),
    Sources = maps:get(input_sources, Status, []),
    State1 = update_source_list(Sources, State0),
    State2 = initialize_form(Status, State1),
    State2#state{last_status = Status}.

update_unavailable_status(Reason, State0) ->
    safe_config(status_label, [
        {text, "● Service unavailable"}, {css_class, status_error}
    ]),
    safe_config(status_detail, [{text, ["whisper_trigger_srv: ", format_term(Reason)]}]),
    safe_config(activity_label, [{text, "Start the supervised speech service to continue."}]),
    safe_config(metrics_label, [{text, "No live telemetry"}]),
    safe_config(runtime_detail, [{text, "Backend unavailable"}]),
    update_action_sensitivity(false, unavailable),
    State0#state{last_status = #{error => Reason}}.

status_title(true, _LastError) -> "● Listening";
status_title(false, undefined) -> "○ Ready · listening stopped";
status_title(false, _LastError) -> "● Listener needs attention".

status_class(true, _LastError) -> status_ok;
status_class(false, undefined) -> status_idle;
status_class(false, _LastError) -> status_error.

status_detail(Status) ->
    Source = maps:get(input_source, Status, #{}),
    [
        "Input: ",
        source_name(Source),
        "  ·  PID: ",
        value_text(maps:get(os_pid, Status, undefined)),
        "  ·  Uptime: ",
        duration_text(maps:get(uptime_ms, Status, undefined)),
        error_detail(maps:get(last_error, Status, undefined))
    ].

error_detail(undefined) -> [];
error_detail(Reason) -> ["\nLast error: ", format_term(Reason)].

activity_text(Status) ->
    case maps:get(last_transcript, Status, undefined) of
        undefined ->
            case maps:get(last_output, Status, undefined) of
                undefined ->
                    "Waiting for speech…";
                Output ->
                    [
                        Output, "\n", age_text(maps:get(last_output_at_ms, Status, undefined))
                    ]
            end;
        Transcript ->
            [
                Transcript,
                "\n",
                age_text(maps:get(last_transcript_at_ms, Status, undefined))
            ]
    end.

metrics_text(Status) ->
    [
        "Transcripts ",
        value_text(maps:get(transcript_count, Status, 0)),
        "  ·  Triggers ",
        value_text(maps:get(trigger_count, Status, 0)),
        "  ·  Last trigger ",
        age_text(maps:get(last_trigger_at_ms, Status, undefined))
    ].

runtime_text(Status) ->
    [
        "Model: ",
        filename:basename(to_list(maps:get(model, Status, <<"unknown">>))),
        "\n",
        "Executable: ",
        to_list(maps:get(bin, Status, <<"unknown">>)),
        "\n",
        "Host trigger: ",
        to_list(maps:get(hostname, Status, <<"unknown">>))
    ].

update_toggle_labels(Status) ->
    Config = maps:get(configuration, Status, Status),
    safe_config(echo_button, [
        {label,
            toggle_label(
                "Output logs", maps:get(echo_output, Config, true)
            )}
    ]),
    safe_config(auto_cleanup_button, [
        {label,
            toggle_label(
                "Auto-clean stale", maps:get(cleanup_existing, Config, true)
            )}
    ]).

toggle_label(Label, true) -> [Label, ": On"];
toggle_label(Label, false) -> [Label, ": Off"].

update_source_list(Sources, State = #state{input_sources = Sources}) ->
    State;
update_source_list(Sources, State) ->
    Items = [source_list_text(Source) || Source <- Sources],
    safe_config(input_list, [{items, Items}]),
    Current = current_source(Sources),
    safe_config(selected_input_label, [{text, ["Current: ", source_name(Current)]}]),
    State#state{
        input_sources = Sources,
        selected_source = Current
    }.

initialize_form(_Status, State = #state{form_initialized = true}) ->
    State;
initialize_form(Status, State) ->
    Phrases = maps:get(trigger_phrases, Status, []),
    Config = maps:get(configuration, Status, Status),
    safe_config(trigger_entry, [{text, join_binary(Phrases, <<", ">>)}]),
    safe_config(dedupe_entry, [
        {text,
            value_text(
                maps:get(output_dedupe_ms, Config, 3000)
            )}
    ]),
    safe_config(debounce_entry, [
        {text,
            value_text(
                maps:get(debounce_ms, Config, 3000)
            )}
    ]),
    State#state{form_initialized = true}.

run_action(_Action, _Fun, State = #state{pending = Pending}) when Pending =/= undefined ->
    set_feedback("Please wait for the current action to finish.", warning),
    State;
run_action(Action, Fun, State0) ->
    Parent = self(),
    Ref = make_ref(),
    Worker = spawn(fun() ->
        Result =
            try Fun() of
                Value -> Value
            catch
                Class:Reason:Stacktrace -> {error, {Class, Reason, Stacktrace}}
            end,
        Parent ! {backend_action_result, Ref, Action, Result}
    end),
    Timer = erlang:send_after(?ACTION_TIMEOUT_MS, self(), {backend_action_timeout, Ref}),
    Pending = #{action => Action, ref => Ref, worker => Worker, timer => Timer},
    set_feedback(action_pending_text(Action), info),
    set_pending(Pending, State0).

clear_pending(State = #state{pending = Pending}) ->
    cancel_pending(Pending),
    update_action_sensitivity(
        maps:get(listening, State#state.last_status, false), undefined
    ),
    State#state{pending = undefined}.

set_pending(Pending, State) ->
    update_action_sensitivity(
        maps:get(listening, State#state.last_status, false), Pending
    ),
    State#state{pending = Pending}.

pending_action(undefined) -> undefined;
pending_action(#{action := Action}) -> Action.

cancel_pending(undefined) ->
    ok;
cancel_pending(#{timer := Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

update_action_sensitivity(_Listening, unavailable) ->
    set_enabled(
        [
            start_button,
            stop_button,
            restart_button,
            cleanup_button,
            apply_source_button,
            apply_triggers_button,
            apply_timing_button,
            echo_button,
            auto_cleanup_button
        ],
        false
    ),
    safe_config(refresh_button, [{enable, true}]);
update_action_sensitivity(_Listening, Pending) when Pending =/= undefined ->
    set_enabled(
        [
            start_button,
            stop_button,
            restart_button,
            cleanup_button,
            apply_source_button,
            apply_triggers_button,
            apply_timing_button,
            echo_button,
            auto_cleanup_button
        ],
        false
    );
update_action_sensitivity(Listening, undefined) ->
    safe_config(start_button, [{enable, not Listening}]),
    safe_config(stop_button, [{enable, Listening}]),
    set_enabled(
        [
            restart_button,
            cleanup_button,
            apply_source_button,
            apply_triggers_button,
            apply_timing_button,
            echo_button,
            auto_cleanup_button,
            refresh_button
        ],
        true
    ).

set_enabled(Names, Enabled) ->
    lists:foreach(fun(Name) -> safe_config(Name, [{enable, Enabled}]) end, Names).

apply_selected_source(State = #state{selected_source = undefined}) ->
    set_feedback("Select an input source first.", warning),
    State;
apply_selected_source(State = #state{selected_source = Source}) ->
    Id = maps:get(id, Source, -1),
    run_action(input_source, fun() -> whisper_trigger_srv:select_input_source(Id) end, State).

apply_trigger_phrases(State) ->
    case read_text(trigger_entry) of
        {ok, Text} ->
            case parse_phrases(Text) of
                [] ->
                    set_feedback("Enter at least one trigger phrase.", warning),
                    State;
                Phrases ->
                    run_action(
                        trigger_phrases,
                        fun() -> whisper_trigger_srv:set_trigger_phrases(Phrases) end,
                        State
                    )
            end;
        {error, Reason} ->
            set_feedback(["Could not read trigger phrases: ", format_term(Reason)], error),
            State
    end.

apply_timing(State) ->
    case {read_non_negative(dedupe_entry), read_non_negative(debounce_entry)} of
        {{ok, DedupeMs}, {ok, DebounceMs}} ->
            Patch = #{output_dedupe_ms => DedupeMs, debounce_ms => DebounceMs},
            run_action(timing, fun() -> whisper_trigger_srv:configure(Patch) end, State);
        _ ->
            set_feedback("Timing values must be non-negative whole milliseconds.", warning),
            State
    end.

toggle_configuration(Key, Action, State) ->
    Config = maps:get(configuration, State#state.last_status, State#state.last_status),
    Current = maps:get(Key, Config, true),
    run_action(Action, fun() -> whisper_trigger_srv:configure(#{Key => not Current}) end, State).

%%%===================================================================
%%% Responsive layout and events
%%%===================================================================

switch_page(Page, State) when
    Page =:= dashboard;
    Page =:= inputs;
    Page =:= settings
->
    safe_config(dashboard_page, [{show, Page =:= dashboard}]),
    safe_config(input_page, [{show, Page =:= inputs}]),
    safe_config(settings_page, [{show, Page =:= settings}]),
    safe_config(dashboard_button, [{css_class, navigation_class(Page, dashboard)}]),
    safe_config(inputs_button, [{css_class, navigation_class(Page, inputs)}]),
    safe_config(settings_button, [{css_class, navigation_class(Page, settings)}]),
    State#state{page = Page}.

navigation_class(Page, Page) -> suggested_action;
navigation_class(_Current, _Button) -> flat.

apply_responsive_layout(undefined, State) ->
    State;
apply_responsive_layout(Width, State = #state{compact = Compact0}) ->
    Compact = Width < ?COMPACT_WIDTH,
    case Compact =:= Compact0 of
        true ->
            State;
        false ->
            Orientation =
                case Compact of
                    true -> vertical;
                    false -> horizontal
                end,
            lists:foreach(
                fun(Name) -> safe_config(Name, [{orient, Orientation}]) end,
                [primary_actions, secondary_actions, timing_row, toggle_row]
            ),
            State#state{compact = Compact}
    end.

event_width([Width, _Height | _]) when is_integer(Width), Width > 0 -> Width;
event_width([#{width := Width} | _]) when is_integer(Width), Width > 0 -> Width;
event_width(_) -> undefined.

selected_source([Index, Text, Selected | _], Sources) when
    is_integer(Index), Selected =/= false
->
    case source_by_text(Text, Sources) of
        {ok, _Source} = Found -> Found;
        error -> source_by_index(Index, Sources)
    end;
selected_source([Index | _], Sources) when is_integer(Index) ->
    source_by_index(Index, Sources);
selected_source(_, _Sources) ->
    error.

source_by_index(Index, Sources) when Index >= 0, Index < length(Sources) ->
    {ok, lists:nth(Index + 1, Sources)};
source_by_index(_Index, _Sources) ->
    error.

source_by_text(Text, Sources) ->
    TextBin = to_binary(Text),
    case [Source || Source <- Sources, to_binary(source_list_text(Source)) =:= TextBin] of
        [Source | _] -> {ok, Source};
        [] -> error
    end.

%%%===================================================================
%%% Formatting and safe GTK helpers
%%%===================================================================

schedule_refresh(State = #state{refresh_timer = undefined, refresh_ms = RefreshMs}) ->
    State#state{refresh_timer = erlang:send_after(RefreshMs, self(), refresh_status)};
schedule_refresh(State) ->
    State.

cancel_refresh(undefined) ->
    ok;
cancel_refresh(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

refresh_interval(Value) when is_integer(Value), Value >= 250 -> Value;
refresh_interval(Value) -> error({invalid_refresh_ms, Value}).

safe_config(Name, Options) ->
    try gtkgs:config(Name, Options) of
        _ -> ok
    catch
        _:_ -> ok
    end.

safe_destroy(undefined) ->
    ok;
safe_destroy(Object) ->
    try gtkgs:destroy(Object) of
        _ -> ok
    catch
        _:_ -> ok
    end.

set_feedback(Text, Kind) ->
    safe_config(feedback_label, [{text, Text}, {css_class, feedback_class(Kind)}]).

feedback_class(info) -> dim_label;
feedback_class(ok) -> status_ok;
feedback_class(warning) -> status_warning;
feedback_class(error) -> status_error.

read_text(Name) ->
    try gtkgs:read(Name, text) of
        {ok, Value} -> {ok, to_binary(Value)};
        {error, _} = Error -> Error;
        Value -> {ok, to_binary(Value)}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

read_non_negative(Name) ->
    case read_text(Name) of
        {ok, Text0} ->
            Text = string:trim(Text0),
            try binary_to_integer(Text) of
                Value when Value >= 0 -> {ok, Value};
                _ -> {error, negative}
            catch
                error:badarg -> {error, not_an_integer}
            end;
        Error ->
            Error
    end.

parse_phrases(Text) ->
    [
        Phrase
     || Part <- re:split(Text, "[,\\n]+", [{return, binary}]),
        Phrase <- [string:trim(Part)],
        Phrase =/= <<>>
    ].

current_source(Sources) ->
    case [Source || Source <- Sources, maps:get(selected, Source, false)] of
        [Source | _] -> Source;
        [] -> #{id => -1, name => <<"System default">>, default => true}
    end.

source_list_text(Source) ->
    Prefix =
        case maps:get(selected, Source, false) of
            true -> "✓ ";
            false -> "  "
        end,
    [Prefix, source_name(Source)].

source_name(Source) when is_map(Source) ->
    case maps:get(name, Source, undefined) of
        undefined -> ["Input #", value_text(maps:get(id, Source, "?"))];
        Name -> Name
    end;
source_name(_) ->
    "Unknown input".

age_text(undefined) ->
    "never";
age_text(TimestampMs) when is_integer(TimestampMs) ->
    AgeMs = max(0, erlang:system_time(millisecond) - TimestampMs),
    [duration_text(AgeMs), " ago"];
age_text(_) ->
    "unknown".

duration_text(undefined) ->
    "—";
duration_text(Milliseconds) when is_integer(Milliseconds), Milliseconds < 1000 ->
    [integer_to_list(Milliseconds), " ms"];
duration_text(Milliseconds) when is_integer(Milliseconds) ->
    Seconds = Milliseconds div 1000,
    case Seconds of
        Value when Value < 60 -> [integer_to_list(Value), " s"];
        Value when Value < 3600 ->
            [integer_to_list(Value div 60), "m ", integer_to_list(Value rem 60), "s"];
        Value ->
            [integer_to_list(Value div 3600), "h ", integer_to_list((Value rem 3600) div 60), "m"]
    end;
duration_text(_) ->
    "—".

action_pending_text(start) -> "Starting listener…";
action_pending_text(stop) -> "Stopping listener…";
action_pending_text(restart) -> "Restarting listener…";
action_pending_text(cleanup) -> "Cleaning stale processes…";
action_pending_text(input_source) -> "Changing input source…";
action_pending_text(trigger_phrases) -> "Updating trigger phrases…";
action_pending_text(timing) -> "Updating timing…";
action_pending_text(echo) -> "Changing output logging…";
action_pending_text(auto_cleanup) -> "Changing automatic cleanup…".

action_feedback(cleanup, {ok, []}) ->
    "No stale whisper-stream processes found.";
action_feedback(cleanup, {ok, Pids}) when is_list(Pids) ->
    ["Cleaned stale processes: ", format_term(Pids)];
action_feedback(Action, Result) ->
    case result_kind(Result) of
        ok -> [action_name(Action), " complete."];
        error -> [action_name(Action), " failed: ", format_term(Result)]
    end.

action_name(start) -> "Start";
action_name(stop) -> "Stop";
action_name(restart) -> "Restart";
action_name(cleanup) -> "Cleanup";
action_name(input_source) -> "Input change";
action_name(trigger_phrases) -> "Trigger update";
action_name(timing) -> "Timing update";
action_name(echo) -> "Output logging update";
action_name(auto_cleanup) -> "Cleanup policy update".

result_kind(ok) -> ok;
result_kind({ok, _}) -> ok;
result_kind(_) -> error.

join_binary([], _Separator) ->
    <<>>;
join_binary(Values, Separator) ->
    iolist_to_binary(lists:join(Separator, [to_binary(Value) || Value <- Values])).

value_text(undefined) -> "—";
value_text(Value) when is_binary(Value) -> Value;
value_text(Value) when is_list(Value) -> Value;
value_text(Value) when is_integer(Value) -> integer_to_list(Value);
value_text(Value) when is_atom(Value) -> atom_to_list(Value);
value_text(Value) -> format_term(Value).

format_term(Value) ->
    io_lib:format("~tp", [Value]).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) -> iolist_to_binary(format_term(Value)).

to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_atom(Value) -> atom_to_list(Value);
to_list(Value) -> lists:flatten(format_term(Value)).
