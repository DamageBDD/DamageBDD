%%--------------------------------------------------------------------
%% @doc
%% Bridges OTP Logger events from Damage/ECAI/ERM into ECAI code learning.
%%
%% The Logger callback only forwards raw events. This supervised process does
%% all formatting, redaction, de-duplication and application/module discovery.
%% Severe events enqueue a bounded, cooldown-protected targeted learning hint.
%% Once ECAI is available, each hint refreshes deterministic module learning and
%% enters the durable Ollama-backed runtime-incident learner. Damage never
%% depends on the ECAI application being started: hints remain bounded in memory
%% and are flushed after the ECAI learning pipeline becomes available.
%% @end
%%--------------------------------------------------------------------
-module(damage_ecai_log_bridge).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    child_spec/1,
    status/0,
    recent/0,
    recent/1,
    flush/0,
    ingest/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([
    normalize_event_for_test/2,
    event_target/2,
    level_at_least/2,
    redact/1,
    learning_eligible_module/1
]).
-endif.

-define(SERVER, ?MODULE).
-define(HANDLER_ID, damage_ecai_code_learning).
-define(DEFAULT_APPS, [damage, ecai, erm]).
-define(DEFAULT_CAPTURE_LEVEL, warning).
-define(DEFAULT_LEARNING_LEVEL, error).
-define(DEFAULT_COOLDOWN_MS, 300000).
-define(DEFAULT_RECENT_LIMIT, 64).
-define(DEFAULT_PENDING_LIMIT, 256).
-define(DEFAULT_FLUSH_INTERVAL_MS, 1000).
-define(DEFAULT_FLUSH_BATCH, 8).
-define(DEFAULT_HANDLER_MAX_QUEUE, 1000).
-define(DEFAULT_MAX_TEXT_BYTES, 4096).

-record(state, {
    enabled = true,
    handler_id = ?HANDLER_ID,
    handler_installed = false,
    capture_level = ?DEFAULT_CAPTURE_LEVEL,
    learning_level = ?DEFAULT_LEARNING_LEVEL,
    apps = ?DEFAULT_APPS,
    cooldown_ms = ?DEFAULT_COOLDOWN_MS,
    recent_limit = ?DEFAULT_RECENT_LIMIT,
    pending_limit = ?DEFAULT_PENDING_LIMIT,
    flush_interval_ms = ?DEFAULT_FLUSH_INTERVAL_MS,
    flush_batch = ?DEFAULT_FLUSH_BATCH,
    handler_max_queue = ?DEFAULT_HANDLER_MAX_QUEUE,
    max_text_bytes = ?DEFAULT_MAX_TEXT_BYTES,
    recent = [],
    pending = #{},
    seen = #{},
    counters = #{
        received => 0,
        captured => 0,
        ignored => 0,
        deduplicated => 0,
        learning_enqueued => 0,
        learning_forwarded => 0,
        learning_forward_failed => 0,
        pending_evicted => 0,
        handler_reinstalls => 0
    },
    timer_ref = undefined,
    last_forwarded_at = undefined,
    last_error = undefined,
    opts = #{}
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() -> start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

child_spec(Opts) when is_map(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

status() ->
    safe_call(status, 5000).

recent() ->
    recent(?DEFAULT_RECENT_LIMIT).

recent(Limit) when is_integer(Limit), Limit > 0 ->
    safe_call({recent, Limit}, 5000);
recent(Limit) ->
    {error, {invalid_limit, Limit}}.

flush() ->
    safe_call(flush, 10000).

ingest(LogEvent) when is_map(LogEvent) ->
    case whereis(?SERVER) of
        undefined -> {error, not_started};
        _Pid -> gen_server:cast(?SERVER, {ingest, LogEvent})
    end;
ingest(Other) ->
    {error, {invalid_log_event, Other}}.

safe_call(Request, Timeout) ->
    case whereis(?SERVER) of
        undefined ->
            {error, not_started};
        _Pid ->
            try gen_server:call(?SERVER, Request, Timeout) of
                Reply -> Reply
            catch
                exit:Reason -> {error, Reason}
            end
    end.

%%====================================================================
%% gen_server
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    State0 = state_from_opts(Opts),
    State1 = maybe_install_handler(State0),
    {ok, schedule_flush(State1, State1#state.flush_interval_ms)}.

handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call({recent, Limit}, _From, State) ->
    {reply, lists:sublist(State#state.recent, Limit), State};
handle_call(flush, _From, State0) ->
    State1 = ensure_handler(flush_pending(State0)),
    {reply, status_map(State1), State1};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({ingest, LogEvent}, State0) ->
    State1 = inc_counter(received, State0),
    {noreply, process_log_event(LogEvent, State1)};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({damage_ecai_logger_event, LogEvent}, State0) ->
    State1 = inc_counter(received, State0),
    {noreply, process_log_event(LogEvent, State1)};
handle_info(flush_now, State0) ->
    State1 = ensure_handler(flush_pending(State0)),
    {noreply, State1};
handle_info(flush_pending, State0) ->
    State1 = State0#state{timer_ref = undefined},
    State2 = ensure_handler(flush_pending(State1)),
    {noreply, schedule_flush(State2, State2#state.flush_interval_ms)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cancel_timer(State#state.timer_ref),
    _ = maybe_remove_handler(State#state.handler_id),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Event processing
%%====================================================================

process_log_event(_LogEvent, State = #state{enabled = false}) ->
    inc_counter(ignored, State);
process_log_event(LogEvent, State0) ->
    case normalize_event(LogEvent, State0) of
        ignore ->
            inc_counter(ignored, State0);
        {ok, Event0} ->
            State1 = inc_counter(captured, State0),
            NowMs = maps:get(observed_at_ms, Event0),
            Fingerprint = event_fingerprint(Event0),
            {Duplicate, Seen1, RepeatCount} = seen_event(
                Fingerprint,
                NowMs,
                State1#state.cooldown_ms,
                State1#state.seen
            ),
            Event = Event0#{
                fingerprint => Fingerprint,
                repeat_count => RepeatCount
            },
            {Event1, Recent1} = put_recent(
                Event,
                State1#state.recent,
                State1#state.recent_limit
            ),
            State2 = State1#state{
                recent = Recent1,
                seen = trim_seen(Seen1, State1#state.recent_limit)
            },
            case Duplicate of
                true ->
                    inc_counter(deduplicated, State2);
                false ->
                    maybe_enqueue_learning(Event1, State2)
            end
    end.

normalize_event(#{level := Level, msg := Msg} = LogEvent, State) ->
    case level_at_least(Level, State#state.capture_level) of
        false ->
            ignore;
        true ->
            Meta =
                case maps:get(meta, LogEvent, #{}) of
                    Value when is_map(Value) -> Value;
                    _ -> #{}
                end,
            case maps:get(damage_ecai_internal, Meta, false) of
                true ->
                    ignore;
                false ->
                    case event_target(Meta, State#state.apps) of
                        ignore ->
                            ignore;
                        {ok, App, Module} ->
                            Text0 = message_text(Msg),
                            Text = cap_binary(redact(Text0), State#state.max_text_bytes),
                            case Text of
                                <<>> ->
                                    ignore;
                                _ ->
                                    ObservedAtMs = event_time_ms(Meta),
                                    {ok, #{
                                        schema => <<"damage.ecai-log-event">>,
                                        version => 1,
                                        level => Level,
                                        application => App,
                                        module => Module,
                                        message => Text,
                                        metadata => metadata_summary(Meta),
                                        observed_at_ms => ObservedAtMs,
                                        observed_at => iso8601(ObservedAtMs)
                                    }}
                            end
                    end
            end
    end;
normalize_event(_Other, _State) ->
    ignore.

-ifdef(TEST).
normalize_event_for_test(LogEvent, Opts) when is_map(Opts) ->
    normalize_event(LogEvent, state_from_opts(Opts)).
-endif.

event_target(Meta, Apps) when is_map(Meta), is_list(Apps) ->
    Module = event_module(Meta),
    Candidates = [
        maps:get(application, Meta, undefined),
        app_from_domain(maps:get(domain, Meta, undefined)),
        app_from_module(Module)
    ],
    case first_allowed_app(Candidates, Apps) of
        undefined -> ignore;
        App -> {ok, App, Module}
    end.

event_module(#{mfa := {Module, _Function, _Arity}}) when is_atom(Module) ->
    Module;
event_module(#{module := Module}) when is_atom(Module) ->
    Module;
event_module(_Meta) ->
    undefined.

first_allowed_app([], _Apps) ->
    undefined;
first_allowed_app([App | Rest], Apps) when is_atom(App) ->
    case lists:member(App, Apps) of
        true -> App;
        false -> first_allowed_app(Rest, Apps)
    end;
first_allowed_app([_ | Rest], Apps) ->
    first_allowed_app(Rest, Apps).

app_from_domain([App | _]) when is_atom(App) -> App;
app_from_domain(_) -> undefined.

app_from_module(undefined) ->
    undefined;
app_from_module(Module) when is_atom(Module) ->
    case application:get_application(Module) of
        {ok, App} -> App;
        undefined -> app_from_module_name(atom_to_list(Module))
    end.

app_from_module_name("damage") ->
    damage;
app_from_module_name("ecai") ->
    ecai;
app_from_module_name("erm") ->
    erm;
app_from_module_name(Name) ->
    case lists:prefix("damage_", Name) of
        true ->
            damage;
        false ->
            case lists:prefix("ecai_", Name) of
                true ->
                    ecai;
                false ->
                    case lists:prefix("erm_", Name) of
                        true -> erm;
                        false -> undefined
                    end
            end
    end.

maybe_enqueue_learning(Event, State) ->
    Level = maps:get(level, Event),
    Module = maps:get(module, Event, undefined),
    case
        level_at_least(Level, State#state.learning_level) andalso
            learning_eligible_module(Module)
    of
        false ->
            State;
        true ->
            App = maps:get(application, Event),
            Fingerprint = maps:get(fingerprint, Event),
            Key = {App, Module, Fingerprint},
            Pending0 = (State#state.pending)#{Key => learning_hint(Event)},
            {Pending1, Evicted} = trim_pending(Pending0, State#state.pending_limit),
            State1 = inc_counter(learning_enqueued, State#state{pending = Pending1}),
            State2 = add_counter(pending_evicted, Evicted, State1),
            self() ! flush_now,
            State2
    end.

learning_eligible_module(Module) when not is_atom(Module) ->
    false;
learning_eligible_module(Module) ->
    not lists:member(Module, [
        damage_ecai_log_bridge,
        damage_ecai_logger_handler,
        ecai_codebase_learner,
        ecai_log_learning,
        ecai_health,
        ecai_health_monitor,
        ecai_ollama_pool,
        ecai_ollama_client
    ]).
learning_hint(Event) ->
    maps:with(
        [
            application,
            module,
            level,
            fingerprint,
            message,
            metadata,
            observed_at,
            observed_at_ms,
            first_observed_at,
            repeat_count
        ],
        Event
    ).

%%====================================================================
%% ECAI forwarding
%%====================================================================

flush_pending(State = #state{pending = Pending}) when map_size(Pending) =:= 0 ->
    State;
flush_pending(State0) ->
    case learning_pipeline_available() of
        true ->
            flush_pending_batch(State0);
        {false, Reason} ->
            State0#state{last_error = Reason}
    end.

flush_pending_batch(State0) ->
    Entries = pending_entries(State0#state.pending, State0#state.flush_batch),
    {Forwarded, Failed, Pending1, LastError} = forward_entries(
        Entries,
        State0#state.pending,
        0
    ),
    StateA = add_counter(learning_forward_failed, Failed, State0),
    State1 = add_counter(learning_forwarded, Forwarded, StateA#state{
        pending = Pending1,
        last_forwarded_at =
            case Forwarded > 0 of
                true -> now_iso8601();
                false -> State0#state.last_forwarded_at
            end,
        last_error = LastError
    }),
    case map_size(Pending1) > 0 andalso Forwarded > 0 andalso Failed =:= 0 of
        true -> self() ! flush_now;
        false -> ok
    end,
    State1.

forward_entries([], Pending, Forwarded) ->
    {Forwarded, 0, Pending, undefined};
forward_entries([{Key = {App, Module, _Fingerprint}, Hint} | Rest], Pending0, Forwarded) ->
    case forward_learning(App, Module, Hint) of
        ok ->
            forward_entries(Rest, maps:remove(Key, Pending0), Forwarded + 1);
        {error, Reason} ->
            %% Stop on the first failed durable hand-off. A stalled store or
            %% learner must not multiply a call timeout by the full batch size.
            {Forwarded, 1, Pending0, {App, Module, Reason}}
    end.

learning_pipeline_available() ->
    case {whereis(ecai_codebase_learner), whereis(ecai_log_learning)} of
        {Learner, IncidentLearner} when is_pid(Learner), is_pid(IncidentLearner) ->
            true;
        {undefined, _} ->
            {false, ecai_codebase_learner_unavailable};
        {_, undefined} ->
            {false, ecai_log_learning_unavailable};
        _ ->
            {false, ecai_learning_pipeline_unavailable}
    end.

forward_learning(App, Module, Hint) ->
    try ecai_codebase_learner:module_changed(App, Module) of
        ok ->
            case ecai_log_learning:observe(Hint) of
                ok -> ok;
                {error, Reason} -> {error, {incident_learning_rejected, Reason}};
                Other -> {error, {unexpected_incident_learning_result, Other}}
            end;
        Other ->
            {error, {unexpected_code_learning_result, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

pending_entries(Pending, Limit) ->
    Sorted = lists:sort(
        fun({_KeyA, A}, {_KeyB, B}) ->
            maps:get(observed_at_ms, A, 0) =< maps:get(observed_at_ms, B, 0)
        end,
        maps:to_list(Pending)
    ),
    lists:sublist(Sorted, Limit).

trim_pending(Pending, Limit) when map_size(Pending) =< Limit ->
    {Pending, 0};
trim_pending(Pending, Limit) ->
    SortedNewest = lists:sort(
        fun({_KeyA, A}, {_KeyB, B}) ->
            maps:get(observed_at_ms, A, 0) >= maps:get(observed_at_ms, B, 0)
        end,
        maps:to_list(Pending)
    ),
    Kept = lists:sublist(SortedNewest, Limit),
    {maps:from_list(Kept), map_size(Pending) - length(Kept)}.

%%====================================================================
%% Logger handler lifecycle
%%====================================================================

ensure_handler(State = #state{enabled = false}) ->
    State;
ensure_handler(State) ->
    case handler_present(State#state.handler_id) of
        true ->
            State#state{handler_installed = true};
        false ->
            State1 = inc_counter(handler_reinstalls, State),
            maybe_install_handler(State1)
    end.

maybe_install_handler(State = #state{enabled = false}) ->
    State;
maybe_install_handler(State) ->
    Id = State#state.handler_id,
    _ = maybe_remove_handler(Id),
    Config = #{
        level => State#state.capture_level,
        config => #{
            server => ?SERVER,
            max_queue => State#state.handler_max_queue
        }
    },
    case logger:add_handler(Id, damage_ecai_logger_handler, Config) of
        ok ->
            State#state{handler_installed = true, last_error = undefined};
        {error, Reason} ->
            State#state{
                handler_installed = false,
                last_error = {logger_handler_install_failed, Reason}
            }
    end.

handler_present(Id) ->
    case logger:get_handler_config(Id) of
        {ok, #{module := damage_ecai_logger_handler}} -> true;
        _ -> false
    end.

maybe_remove_handler(Id) ->
    case logger:get_handler_config(Id) of
        {ok, #{module := damage_ecai_logger_handler}} ->
            case logger:remove_handler(Id) of
                ok -> ok;
                {error, _} -> ok
            end;
        _ ->
            ok
    end.

%%====================================================================
%% Message shaping and safety
%%====================================================================

message_text({string, Text}) ->
    safe_unicode(Text);
message_text({report, Report}) ->
    safe_unicode(log_utils:summarize_fmt(Report, summary_opts()));
message_text({Format, Args}) when
    is_list(Args),
    (is_list(Format) orelse is_binary(Format))
->
    SafeArgs = [log_utils:summarize(Arg, summary_opts()) || Arg <- Args],
    safe_format(Format, SafeArgs);
message_text(Other) ->
    safe_unicode(log_utils:summarize_fmt(Other, summary_opts())).

summary_opts() ->
    #{
        depth => 5,
        max_binary => 256,
        max_string => 768,
        max_list => 32,
        max_map => 32,
        max_tuple => 24
    }.

safe_format(Format0, Args) ->
    Format =
        case Format0 of
            Bin when is_binary(Bin) -> unicode:characters_to_list(Bin);
            List -> List
        end,
    try safe_unicode(io_lib:format(Format, Args)) of
        LogBridgeResultBin -> LogBridgeResultBin
    catch
        _:_ -> safe_unicode(io_lib:format("~p args=~p", [Format0, Args]))
    end.

safe_unicode(Value) when is_binary(Value) ->
    Value;
safe_unicode(Value) ->
    try unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) -> Bin;
        Other -> iolist_to_binary(io_lib:format("~p", [Other]))
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Value]))
    end.

redact(Text0) ->
    Text1 = safe_unicode(Text0),
    Patterns = [
        {<<"(?i)(authorization|proxy-authorization)\\s*[:=]\\s*(bearer|basic)?\\s*[^\\s,;}\\]&]+">>,
            <<"authorization=<redacted>">>},
        {<<"(?i)bearer\\s+[a-z0-9._~+/-]+=*">>, <<"Bearer <redacted>">>},
        {<<"(?i)(nsec1|ncryptsec1)[0-9a-z]+">>, <<"nostr-secret=<redacted>">>},
        {<<"(?i)(password|passwd|secret|client[_-]?secret|api[_-]?key|private[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?token|auth[_-]?token)\\s*[=:]\\s*[\"']?[^\\s,;}&\\]]+">>,
            <<"credential=<redacted>">>},
        {<<"(?i)(cookie|set-cookie)\\s*[:=]\\s*[^\\r\\n]+">>, <<"cookie=<redacted>">>}
    ],
    lists:foldl(
        fun({Pattern, Replacement}, Acc) ->
            try
                re:replace(
                    Acc,
                    Pattern,
                    Replacement,
                    [global, unicode, {return, binary}]
                )
            of
                Redacted -> Redacted
            catch
                _:_ -> Acc
            end
        end,
        Text1,
        Patterns
    ).

metadata_summary(Meta) ->
    Keys = [
        application,
        domain,
        mfa,
        module,
        file,
        line,
        pid,
        node,
        request_id,
        req_id,
        trace_id
    ],
    maps:fold(
        fun(Key, Value, Acc) ->
            Acc#{Key => metadata_value(Key, Value)}
        end,
        #{},
        maps:with(Keys, Meta)
    ).

metadata_value(application, Value) when is_atom(Value) -> Value;
metadata_value(module, Value) when is_atom(Value) -> Value;
metadata_value(node, Value) when is_atom(Value) -> Value;
metadata_value(line, Value) when is_integer(Value), Value >= 0 -> Value;
metadata_value(pid, Value) when is_pid(Value) -> Value;
metadata_value(mfa, {Module, Function, Arity}) when
    is_atom(Module), is_atom(Function), is_integer(Arity), Arity >= 0
->
    {Module, Function, Arity};
metadata_value(domain, Value) when is_list(Value) ->
    lists:sublist([Part || Part <- Value, is_atom(Part)], 8);
metadata_value(_Key, Value) ->
    cap_binary(redact(metadata_text(Value)), 512).

metadata_text(Value) when is_binary(Value) ->
    Value;
metadata_text(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) -> Bin;
        _ -> safe_unicode(log_utils:summarize_fmt(Value, summary_opts()))
    catch
        _:_ -> safe_unicode(log_utils:summarize_fmt(Value, summary_opts()))
    end;
metadata_text(Value) ->
    safe_unicode(log_utils:summarize_fmt(Value, summary_opts())).

cap_binary(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
cap_binary(Bin, Max) when is_binary(Bin), Max > 0 ->
    Suffix0 = <<"...<truncated>">>,
    Suffix =
        case byte_size(Suffix0) =< Max of
            true -> Suffix0;
            false -> binary:part(Suffix0, 0, Max)
        end,
    HeadBytes = max(0, Max - byte_size(Suffix)),
    <<(binary:part(Bin, 0, HeadBytes))/binary, Suffix/binary>>.

%%====================================================================
%% De-duplication and recent-event ring
%%====================================================================

event_fingerprint(Event) ->
    Comparable = maps:with([level, application, module, message], Event),
    hex(crypto:hash(sha256, term_to_binary(Comparable, [deterministic]))).

seen_event(Fingerprint, NowMs, CooldownMs, Seen0) ->
    case maps:get(Fingerprint, Seen0, undefined) of
        undefined ->
            Info = #{first_ms => NowMs, last_ms => NowMs, count => 1},
            {false, Seen0#{Fingerprint => Info}, 1};
        Info0 ->
            LastMs = maps:get(last_ms, Info0, 0),
            Count = maps:get(count, Info0, 0) + 1,
            Duplicate = (NowMs - LastMs) < CooldownMs,
            Info = Info0#{last_ms => NowMs, count => Count},
            {Duplicate, Seen0#{Fingerprint => Info}, Count}
    end.

put_recent(Event, Recent0, Limit) ->
    Fingerprint = maps:get(fingerprint, Event),
    {Matching, Others} = lists:partition(
        fun(E) -> maps:get(fingerprint, E, undefined) =:= Fingerprint end,
        Recent0
    ),
    Event1 =
        case Matching of
            [Previous | _] ->
                Event#{
                    first_observed_at => maps:get(
                        first_observed_at,
                        Previous,
                        maps:get(observed_at, Previous, undefined)
                    )
                };
            [] ->
                Event#{first_observed_at => maps:get(observed_at, Event)}
        end,
    {Event1, lists:sublist([Event1 | Others], Limit)}.

trim_seen(Seen, RecentLimit) when map_size(Seen) =< (RecentLimit * 4) ->
    Seen;
trim_seen(Seen, RecentLimit) ->
    Sorted = lists:sort(
        fun({_FpA, A}, {_FpB, B}) ->
            maps:get(last_ms, A, 0) >= maps:get(last_ms, B, 0)
        end,
        maps:to_list(Seen)
    ),
    maps:from_list(lists:sublist(Sorted, RecentLimit * 2)).

hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

%%====================================================================
%% State/configuration/status
%%====================================================================

state_from_opts(Opts) ->
    #state{
        enabled = bool_opt(enabled, Opts, ecai_log_learning_enabled, true),
        capture_level = level_opt(
            capture_level,
            Opts,
            ecai_log_capture_level,
            ?DEFAULT_CAPTURE_LEVEL
        ),
        learning_level = level_opt(
            learning_level,
            Opts,
            ecai_log_learning_level,
            ?DEFAULT_LEARNING_LEVEL
        ),
        apps = apps_opt(Opts),
        cooldown_ms = positive_opt(
            cooldown_ms,
            Opts,
            ecai_log_learning_cooldown_ms,
            ?DEFAULT_COOLDOWN_MS
        ),
        recent_limit = positive_opt(
            recent_limit,
            Opts,
            ecai_log_recent_limit,
            ?DEFAULT_RECENT_LIMIT
        ),
        pending_limit = positive_opt(
            pending_limit,
            Opts,
            ecai_log_pending_limit,
            ?DEFAULT_PENDING_LIMIT
        ),
        flush_interval_ms = positive_opt(
            flush_interval_ms,
            Opts,
            ecai_log_flush_interval_ms,
            ?DEFAULT_FLUSH_INTERVAL_MS
        ),
        flush_batch = positive_opt(
            flush_batch,
            Opts,
            ecai_log_flush_batch,
            ?DEFAULT_FLUSH_BATCH
        ),
        handler_max_queue = positive_opt(
            handler_max_queue,
            Opts,
            ecai_log_handler_max_queue,
            ?DEFAULT_HANDLER_MAX_QUEUE
        ),
        max_text_bytes = positive_opt(
            max_text_bytes,
            Opts,
            ecai_log_max_text_bytes,
            ?DEFAULT_MAX_TEXT_BYTES
        ),
        opts = Opts
    }.

bool_opt(Key, Opts, EnvKey, Default) ->
    case maps:get(Key, Opts, application:get_env(damage, EnvKey, Default)) of
        true -> true;
        false -> false;
        _ -> Default
    end.

positive_opt(Key, Opts, EnvKey, Default) ->
    positive_int(
        maps:get(Key, Opts, application:get_env(damage, EnvKey, Default)),
        Default
    ).

level_opt(Key, Opts, EnvKey, Default) ->
    normalize_level(
        maps:get(Key, Opts, application:get_env(damage, EnvKey, Default)),
        Default
    ).

apps_opt(Opts) ->
    Value = maps:get(
        apps,
        Opts,
        application:get_env(damage, ecai_log_learning_apps, ?DEFAULT_APPS)
    ),
    case Value of
        Apps when is_list(Apps) ->
            Filtered = [App || App <- Apps, is_atom(App)],
            case Filtered of
                [] -> ?DEFAULT_APPS;
                _ -> lists:usort(Filtered)
            end;
        _ ->
            ?DEFAULT_APPS
    end.

normalize_level(Level, _Default) when
    Level =:= debug;
    Level =:= info;
    Level =:= notice;
    Level =:= warning;
    Level =:= error;
    Level =:= critical;
    Level =:= alert;
    Level =:= emergency;
    Level =:= all;
    Level =:= none
->
    Level;
normalize_level(_Level, Default) ->
    Default.

level_at_least(_Level, all) -> true;
level_at_least(_Level, none) -> false;
level_at_least(Level, Threshold) -> level_rank(Level) >= level_rank(Threshold).

level_rank(debug) -> 0;
level_rank(info) -> 1;
level_rank(notice) -> 2;
level_rank(warning) -> 3;
level_rank(error) -> 4;
level_rank(critical) -> 5;
level_rank(alert) -> 6;
level_rank(emergency) -> 7;
level_rank(all) -> -1;
level_rank(none) -> 100;
level_rank(_) -> -1.

status_map(State) ->
    #{
        enabled => State#state.enabled,
        handler_id => State#state.handler_id,
        handler_installed => State#state.handler_installed,
        capture_level => State#state.capture_level,
        learning_level => State#state.learning_level,
        applications => State#state.apps,
        cooldown_ms => State#state.cooldown_ms,
        pending => map_size(State#state.pending),
        recent => length(State#state.recent),
        counters => State#state.counters,
        learner_available => is_pid(whereis(ecai_codebase_learner)),
        incident_learner_available => is_pid(whereis(ecai_log_learning)),
        learning_pipeline_available => learning_pipeline_available() =:= true,
        last_forwarded_at => State#state.last_forwarded_at,
        last_error => State#state.last_error
    }.

inc_counter(Key, State) ->
    add_counter(Key, 1, State).

add_counter(_Key, 0, State) ->
    State;
add_counter(Key, Amount, State) ->
    Counters = maps:update_with(Key, fun(N) -> N + Amount end, Amount, State#state.counters),
    State#state{counters = Counters}.

schedule_flush(State = #state{timer_ref = undefined}, Delay) ->
    Ref = erlang:send_after(Delay, self(), flush_pending),
    State#state{timer_ref = Ref};
schedule_flush(State, _Delay) ->
    State.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

positive_int(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive_int(_Value, Default) -> Default.

event_time_ms(Meta) ->
    case maps:get(time, Meta, undefined) of
        TimeUs when is_integer(TimeUs), TimeUs > 0 -> TimeUs div 1000;
        _ -> erlang:system_time(millisecond)
    end.

iso8601(TimeMs) ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            TimeMs,
            [{unit, millisecond}, {offset, "Z"}]
        )
    ).

now_iso8601() ->
    iso8601(erlang:system_time(millisecond)).
