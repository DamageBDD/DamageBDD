-module(whisper_trigger_srv).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

%% Real-time, local speech-to-text trigger service for whisper.cpp.
%%
%% Arch Linux recommendation (NVIDIA): build whisper.cpp with SDL2, CUDA and
%% the stream example enabled. Current builds install the executable as
%% `whisper-stream`; older source trees called it `stream`.
%%
%% Example:
%%
%%   whisper_trigger_srv:start_link(#{
%%       trigger_phrases => ["thread ripper zero", "threadripper0"],
%%       language => "en",
%%       capture => -1,
%%       beam_size => 5
%%   }).
%%
%% Runtime controls:
%%
%%   whisper_trigger_srv:set_trigger_word("computer").
%%   whisper_trigger_srv:list_input_sources().
%%   whisper_trigger_srv:select_input_source(1).  % SDL capture id
%%   whisper_trigger_srv:cleanup_existing().      % stale same-user processes
%%   whisper_trigger_srv:restart_listening().
%%
%% Raw whisper-stream records are logged by default (`echo_output => true`).
%% Stale processes using the same executable and model are removed before a
%% new listener starts (`cleanup_existing => true`). Both can be disabled.
%% Repeated rolling-window output is suppressed for 3000 ms by default; set
%% `output_dedupe_ms => 0` to log and process every redraw.
%%
%% The large-v3-turbo model, GPU inference and flash attention are preferred.
%% Every setting can still be overridden, including `bin`, `model` and
%% `extra_args`, so the module is not coupled to one Arch workstation.

-export([
    start_link/0,
    start_link/1,
    stop/0,
    start_listening/0,
    stop_listening/0,
    restart_listening/0,
    is_listening/0,
    trigger_phrases/0,
    matches_trigger/1,
    set_trigger_word/1,
    set_trigger_phrases/1,
    list_input_sources/0,
    current_input_source/0,
    select_input_source/1,
    configure/1,
    cleanup_existing/0,
    available/0,
    available/1,
    availability/0,
    availability/1,
    status/0,
    hostname/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    port = undefined,
    os_pid = undefined,
    opts = #{},
    bin = <<>>,
    model = <<>>,
    hostname = <<>>,
    trigger_phrases = [],
    input_sources = [],
    trigger_handler = undefined,
    last_trigger_ms = undefined,
    last_trigger_at_ms = undefined,
    last_error = undefined,
    debounce_ms = 3000,
    recent_output = #{},
    started_at_ms = undefined,
    last_output = undefined,
    last_output_at_ms = undefined,
    last_transcript = undefined,
    last_transcript_at_ms = undefined,
    transcript_count = 0,
    trigger_count = 0,
    buffer = <<>>
}).

-define(DEFAULT_STEP_MS, 500).
-define(DEFAULT_LENGTH_MS, 5000).
-define(DEFAULT_KEEP_MS, 200).
-define(DEFAULT_MAX_TOKENS, 32).
-define(DEFAULT_BEAM_SIZE, 5).
-define(DEFAULT_VAD_THRESHOLD, 0.60).
-define(DEFAULT_FREQ_THRESHOLD, 100.0).
-define(DEFAULT_OUTPUT_DEDUPE_MS, 3000).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:stop(?MODULE).

start_listening() ->
    call_if_started(start_listening).

stop_listening() ->
    call_if_started(stop_listening).

restart_listening() ->
    call_if_started(restart_listening).

is_listening() ->
    call_if_started(is_listening).

trigger_phrases() ->
    call_if_started(trigger_phrases).

matches_trigger(Text) ->
    call_if_started({matches_trigger, Text}).

set_trigger_word(Word) ->
    set_trigger_phrases([Word]).

set_trigger_phrases(Phrases) ->
    call_if_started({set_trigger_phrases, Phrases}).

list_input_sources() ->
    call_if_started(list_input_sources).

current_input_source() ->
    call_if_started(current_input_source).

select_input_source(Source) ->
    call_if_started({select_input_source, Source}).

configure(Options) when is_map(Options) ->
    call_if_started({configure, Options});
configure(Options) ->
    {error, {invalid_configuration, Options}}.

cleanup_existing() ->
    call_if_started(cleanup_existing).

available() ->
    available(#{}).

available(Opts) when is_map(Opts) ->
    case availability(Opts) of
        {ok, _Runtime} -> true;
        {error, _Reason} -> false
    end.

availability() ->
    availability(#{}).

availability(Opts) when is_map(Opts) ->
    try resolve_runtime(Opts) of
        {ok, Bin, Model} ->
            case configure_state(Opts, Bin, Model) of
                {ok, _State} -> {ok, #{bin => Bin, model => Model}};
                {error, ConfigureReason} -> {error, ConfigureReason}
            end;
        {error, RuntimeReason} ->
            {error, RuntimeReason}
    catch
        error:ExceptionReason -> {error, {invalid_configuration, ExceptionReason}}
    end.

status() ->
    call_if_started(status).

hostname() ->
    case inet:gethostname() of
        {ok, Host} -> Host;
        _ -> "unknown-host"
    end.

call_if_started(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?MODULE, Request, infinity)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    case resolve_runtime(Opts) of
        {ok, Bin, Model} ->
            case configure_state(Opts, Bin, Model) of
                {ok, State0} ->
                    case maps:get(auto_start, Opts, true) of
                        true ->
                            case open_stream(State0) of
                                {ok, State1} ->
                                    {ok, State1};
                                {error, Reason} ->
                                    %% Keep the optional supervised service alive
                                    %% even when the audio backend is temporarily
                                    %% unavailable. start_listening/0 can retry it.
                                    {ok, State0#state{last_error = Reason}}
                            end;
                        false ->
                            {ok, State0}
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(start_listening, _From, State = #state{port = Port}) when is_port(Port) ->
    {reply, {ok, already_listening}, State};
handle_call(start_listening, _From, State0) ->
    case open_stream(State0) of
        {ok, State1} -> {reply, ok, State1};
        {error, Reason} -> {reply, {error, Reason}, State0#state{last_error = Reason}}
    end;
handle_call(stop_listening, _From, State = #state{port = Port}) when is_port(Port) ->
    State1 = close_stream(State),
    logger:info("whisper trigger listening stopped"),
    {reply, ok, State1};
handle_call(stop_listening, _From, State) ->
    {reply, {ok, already_stopped}, State};
handle_call(restart_listening, _From, State0) ->
    State1 = close_stream(State0),
    case open_stream(State1) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Reason} ->
            {reply, {error, Reason}, State1#state{last_error = Reason}}
    end;
handle_call(is_listening, _From, State) ->
    {reply, is_port(State#state.port), State};
handle_call(trigger_phrases, _From, State) ->
    {reply, State#state.trigger_phrases, State};
handle_call({matches_trigger, Text0}, _From, State) ->
    Reply =
        try matching_phrase(Text0, State#state.trigger_phrases) of
            Match -> Match
        catch
            error:Reason -> {error, {invalid_text, Reason}}
        end,
    {reply, Reply, State};
handle_call({set_trigger_phrases, Phrases0}, _From, State) ->
    case safe_normalize_phrases(Phrases0) of
        {ok, []} ->
            {reply, {error, no_trigger_phrases}, State};
        {ok, Phrases} ->
            Opts1 = maps:put(trigger_phrases, Phrases, State#state.opts),
            logger:info("whisper trigger phrases changed to ~p", [Phrases]),
            {reply, {ok, Phrases}, State#state{
                opts = Opts1,
                trigger_phrases = Phrases,
                last_trigger_ms = undefined,
                last_trigger_at_ms = undefined,
                %% Re-evaluate the current rolling transcript immediately
                %% against the newly configured phrases.
                recent_output = #{}
            }};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(list_input_sources, _From, State) ->
    {reply, input_sources(State), State};
handle_call(current_input_source, _From, State) ->
    {reply, selected_input_source(State), State};
handle_call({select_input_source, Source0}, _From, State0) ->
    case resolve_input_source(Source0, State0#state.input_sources) of
        {ok, Capture, Selected} ->
            Opts1 = maps:put(capture, Capture, State0#state.opts),
            case reconfigure_stream_if_listening(Opts1, State0) of
                {ok, State1} ->
                    logger:info("whisper input source changed to ~p", [Selected]),
                    {reply, {ok, Selected}, State1};
                {error, Reason, State1} ->
                    {reply, {error, {input_source_restart_failed, Reason}}, State1}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call({configure, Patch}, _From, State0) ->
    case apply_runtime_configuration(Patch, State0) of
        {ok, State1} ->
            {reply, {ok, runtime_configuration(State1)}, State1};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call(cleanup_existing, _From, State) ->
    Excluded =
        case State#state.os_pid of
            Pid when is_integer(Pid) -> [Pid];
            _ -> []
        end,
    Pids = cleanup_matching_processes(State#state.bin, State#state.model, Excluded),
    {reply, {ok, Pids}, State};
handle_call(status, _From, State) ->
    Reply = #{
        backend => whisper_cpp,
        ready => true,
        listening => is_port(State#state.port),
        os_pid => State#state.os_pid,
        last_error => State#state.last_error,
        bin => State#state.bin,
        model => State#state.model,
        hostname => State#state.hostname,
        trigger_phrases => State#state.trigger_phrases,
        input_source => selected_input_source(State),
        input_sources => input_sources(State),
        configuration => runtime_configuration(State),
        echo_output => maps:get(echo_output, State#state.opts, true),
        cleanup_existing => maps:get(cleanup_existing, State#state.opts, true),
        output_dedupe_ms => maps:get(
            output_dedupe_ms, State#state.opts, ?DEFAULT_OUTPUT_DEDUPE_MS
        ),
        debounce_ms => State#state.debounce_ms,
        started_at_ms => State#state.started_at_ms,
        uptime_ms => uptime_ms(State#state.started_at_ms),
        last_output => State#state.last_output,
        last_output_at_ms => State#state.last_output_at_ms,
        last_transcript => State#state.last_transcript,
        last_transcript_at_ms => State#state.last_transcript_at_ms,
        last_trigger_at_ms => State#state.last_trigger_at_ms,
        transcript_count => State#state.transcript_count,
        trigger_count => State#state.trigger_count
    },
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, Data}}, State0 = #state{port = Port, buffer = Buffer0}) ->
    Buffer1 = <<Buffer0/binary, Data/binary>>,
    {Records, Buffer2} = split_records(Buffer1),
    State1 = lists:foldl(fun process_output_record/2, State0, Records),
    {noreply, State1#state{buffer = Buffer2}};
handle_info({Port, {exit_status, Status}}, State = #state{port = Port}) ->
    logger:error("whisper-stream exited with status ~p", [Status]),
    Reason = {whisper_exit, Status},
    {noreply, State#state{
        port = undefined,
        os_pid = undefined,
        recent_output = #{},
        started_at_ms = undefined,
        buffer = <<>>,
        last_error = Reason
    }};
handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    logger:error("whisper-stream port exited: ~p", [Reason]),
    PortReason = {whisper_port_exit, Reason},
    {noreply, State#state{
        port = undefined,
        os_pid = undefined,
        recent_output = #{},
        started_at_ms = undefined,
        buffer = <<>>,
        last_error = PortReason
    }};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = close_stream(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Runtime configuration
%%%===================================================================

resolve_runtime(Opts) ->
    case resolve_executable(maps:get(bin, Opts, auto)) of
        {ok, Bin} ->
            case resolve_model(maps:get(model, Opts, auto)) of
                {ok, Model} -> {ok, Bin, Model};
                Error -> Error
            end;
        Error ->
            Error
    end.

configure_state(Opts, Bin, Model) ->
    _ = boolean_option(auto_start, maps:get(auto_start, Opts, true)),
    _ = boolean_option(echo_output, maps:get(echo_output, Opts, true)),
    _ = boolean_option(cleanup_existing, maps:get(cleanup_existing, Opts, true)),
    _ = non_negative_integer(
        output_dedupe_ms,
        maps:get(output_dedupe_ms, Opts, ?DEFAULT_OUTPUT_DEDUPE_MS)
    ),
    Capture = capture_option(maps:get(capture, Opts, -1)),
    RuntimeOpts = maps:put(capture, Capture, Opts),
    Host = normalize_text(maps:get(hostname, Opts, hostname())),
    Phrases0 = maps:get(trigger_phrases, Opts, [Host]),
    Phrases = normalize_phrases(Phrases0),
    case Phrases of
        [] ->
            {error, no_trigger_phrases};
        _ ->
            Handler = maps:get(trigger_handler, Opts, fun default_trigger_handler/2),
            case is_function(Handler, 2) of
                false ->
                    {error, {invalid_trigger_handler, Handler}};
                true ->
                    {ok, #state{
                        opts = RuntimeOpts,
                        bin = unicode:characters_to_binary(Bin),
                        model = unicode:characters_to_binary(Model),
                        hostname = Host,
                        trigger_phrases = Phrases,
                        trigger_handler = Handler,
                        debounce_ms = non_negative_integer(
                            debounce_ms,
                            maps:get(debounce_ms, Opts, 3000)
                        )
                    }}
            end
    end.

open_stream(
    State = #state{
        opts = Opts,
        bin = Bin0,
        model = Model0,
        trigger_phrases = Phrases
    }
) ->
    Bin = arg(Bin0),
    Model = arg(Model0),
    Args = stream_args(Opts, Model),
    _ = maybe_cleanup_existing(Bin, Model, Opts),
    try
        open_port(
            {spawn_executable, Bin},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                stream,
                use_stdio,
                hide,
                {args, Args}
            ]
        )
    of
        Port ->
            OsPid = port_os_pid(Port),
            logger:info(
                "whisper trigger listening for ~p using ~ts and ~ts (OS pid ~p)",
                [Phrases, Bin, Model, OsPid]
            ),
            {ok, State#state{
                port = Port,
                os_pid = OsPid,
                buffer = <<>>,
                recent_output = #{},
                started_at_ms = erlang:system_time(millisecond),
                last_output = undefined,
                last_output_at_ms = undefined,
                last_transcript = undefined,
                last_transcript_at_ms = undefined,
                last_trigger_ms = undefined,
                last_trigger_at_ms = undefined,
                transcript_count = 0,
                trigger_count = 0,
                input_sources = [],
                last_error = undefined
            }}
    catch
        error:Reason ->
            logger:error("could not start whisper-stream: ~p", [Reason]),
            {error, {whisper_stream_open_failed, Reason}}
    end.

stream_args(Opts, Model) ->
    Base = [
        "--model",
        Model,
        "--step",
        arg(maps:get(step_ms, Opts, ?DEFAULT_STEP_MS)),
        "--length",
        arg(maps:get(length_ms, Opts, ?DEFAULT_LENGTH_MS)),
        "--keep",
        arg(maps:get(keep_ms, Opts, ?DEFAULT_KEEP_MS)),
        "--threads",
        arg(maps:get(threads, Opts, default_threads())),
        "--capture",
        arg(maps:get(capture, Opts, -1)),
        "--max-tokens",
        arg(maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS)),
        "--audio-ctx",
        arg(maps:get(audio_ctx, Opts, 0)),
        "--beam-size",
        arg(maps:get(beam_size, Opts, ?DEFAULT_BEAM_SIZE)),
        "--vad-thold",
        arg(maps:get(vad_threshold, Opts, ?DEFAULT_VAD_THRESHOLD)),
        "--freq-thold",
        arg(maps:get(freq_threshold, Opts, ?DEFAULT_FREQ_THRESHOLD)),
        "--language",
        arg(maps:get(language, Opts, "en"))
    ],
    Gpu =
        case maps:get(use_gpu, Opts, true) of
            true -> [];
            false -> ["--no-gpu"]
        end,
    Flash =
        case maps:get(flash_attention, Opts, true) of
            true -> ["--flash-attn"];
            false -> ["--no-flash-attn"]
        end,
    Fallback =
        case maps:get(temperature_fallback, Opts, true) of
            true -> [];
            false -> ["--no-fallback"]
        end,
    Extra = normalize_extra_args(maps:get(extra_args, Opts, [])),
    Base ++ Gpu ++ Flash ++ Fallback ++ Extra.

resolve_executable(auto) ->
    Candidates = executable_candidates(),
    case first_executable(Candidates) of
        false -> {error, {whisper_stream_not_found, Candidates}};
        Path -> {ok, Path}
    end;
resolve_executable(Path0) ->
    Name = arg(Path0),
    Path =
        case lists:member($/, Name) of
            true -> filename:absname(Name);
            false -> os:find_executable(Name)
        end,
    case Path =/= false andalso is_executable(Path) of
        true -> {ok, Path};
        false -> {error, {whisper_stream_not_executable, Name}}
    end.

resolve_model(auto) ->
    Candidates = model_candidates(),
    case first_regular_file(Candidates) of
        false -> {error, {whisper_model_not_found, Candidates}};
        Path -> {ok, Path}
    end;
resolve_model(Path0) ->
    Path = path(Path0),
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> {error, {whisper_model_not_found, Path}}
    end.

executable_candidates() ->
    lists:filter(
        fun(Value) -> Value =/= false end,
        [
            os:find_executable("whisper-stream"),
            "/usr/bin/whisper-stream",
            "/usr/local/bin/whisper-stream",
            "/opt/whisper.cpp/build/bin/whisper-stream",
            "/opt/whisper.cpp/stream"
        ]
    ).

model_candidates() ->
    Home = home_dir(),
    DataHome = xdg_data_home(Home),
    Names = [
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3.bin",
        "ggml-medium.en.bin",
        "ggml-medium.bin"
    ],
    Dirs = [
        filename:join(DataHome, "whisper.cpp/models"),
        filename:join(DataHome, "whisper-toggle/models"),
        filename:join(Home, ".cache/whisper"),
        "/usr/share/whisper.cpp/models",
        "/usr/local/share/whisper.cpp/models",
        "/opt/whisper.cpp/models"
    ],
    [filename:join(Dir, Name) || Name <- Names, Dir <- Dirs].

first_executable(Paths) ->
    first_match(fun is_executable/1, Paths).

first_regular_file(Paths) ->
    first_match(fun filelib:is_regular/1, Paths).

first_match(_Predicate, []) ->
    false;
first_match(Predicate, [Path | Rest]) ->
    case Predicate(Path) of
        true -> Path;
        false -> first_match(Predicate, Rest)
    end.

is_executable(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            %% owner/group/other execute bits
            Info#file_info.type =:= regular andalso
                (Info#file_info.mode band 8#111) =/= 0;
        _ ->
            false
    end.

home_dir() ->
    case os:getenv("HOME") of
        false -> "/tmp";
        Value -> Value
    end.

xdg_data_home(Home) ->
    case os:getenv("XDG_DATA_HOME") of
        false -> filename:join(Home, ".local/share");
        Value -> Value
    end.

default_threads() ->
    case erlang:system_info(logical_processors_available) of
        unknown -> 4;
        Count when is_integer(Count), Count > 0 -> min(8, Count)
    end.

non_negative_integer(_Name, Value) when is_integer(Value), Value >= 0 ->
    Value;
non_negative_integer(Name, Value) ->
    error({invalid_option, Name, Value}).

boolean_option(_Name, Value) when is_boolean(Value) ->
    Value;
boolean_option(Name, Value) ->
    error({invalid_option, Name, Value}).

apply_runtime_configuration(Patch, State) when is_map(Patch) ->
    Allowed = [echo_output, cleanup_existing, output_dedupe_ms, debounce_ms],
    Unknown = [Key || Key <- maps:keys(Patch), not lists:member(Key, Allowed)],
    case Unknown of
        [] ->
            try
                Echo = boolean_option(
                    echo_output,
                    maps:get(echo_output, Patch, maps:get(echo_output, State#state.opts, true))
                ),
                Cleanup = boolean_option(
                    cleanup_existing,
                    maps:get(
                        cleanup_existing,
                        Patch,
                        maps:get(cleanup_existing, State#state.opts, true)
                    )
                ),
                DedupeMs = non_negative_integer(
                    output_dedupe_ms,
                    maps:get(
                        output_dedupe_ms,
                        Patch,
                        maps:get(
                            output_dedupe_ms,
                            State#state.opts,
                            ?DEFAULT_OUTPUT_DEDUPE_MS
                        )
                    )
                ),
                DebounceMs = non_negative_integer(
                    debounce_ms,
                    maps:get(debounce_ms, Patch, State#state.debounce_ms)
                ),
                Opts1 = maps:merge(State#state.opts, #{
                    echo_output => Echo,
                    cleanup_existing => Cleanup,
                    output_dedupe_ms => DedupeMs,
                    debounce_ms => DebounceMs
                }),
                {ok, State#state{
                    opts = Opts1,
                    debounce_ms = DebounceMs,
                    recent_output = #{}
                }}
            catch
                error:Reason -> {error, {invalid_configuration, Reason}}
            end;
        _ ->
            {error, {unsupported_configuration_options, Unknown}}
    end;
apply_runtime_configuration(Patch, _State) ->
    {error, {invalid_configuration, Patch}}.

runtime_configuration(State) ->
    #{
        echo_output => maps:get(echo_output, State#state.opts, true),
        cleanup_existing => maps:get(cleanup_existing, State#state.opts, true),
        output_dedupe_ms => maps:get(
            output_dedupe_ms, State#state.opts, ?DEFAULT_OUTPUT_DEDUPE_MS
        ),
        debounce_ms => State#state.debounce_ms
    }.

uptime_ms(undefined) ->
    undefined;
uptime_ms(StartedAtMs) ->
    max(0, erlang:system_time(millisecond) - StartedAtMs).

capture_option(default) ->
    -1;
capture_option(Value) when is_integer(Value), Value >= -1 ->
    Value;
capture_option(Value) ->
    error({invalid_option, capture, Value}).

arg(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
arg(Value) when is_list(Value) ->
    Value;
arg(Value) when is_integer(Value) ->
    integer_to_list(Value);
arg(Value) when is_float(Value) ->
    lists:flatten(io_lib:format("~.3f", [Value]));
arg(Value) when is_atom(Value) ->
    atom_to_list(Value).

normalize_extra_args([]) ->
    [];
normalize_extra_args([Char | _] = OneArg) when is_integer(Char) ->
    [OneArg];
normalize_extra_args(Args) when is_list(Args) ->
    [arg(Value) || Value <- Args];
normalize_extra_args(OneArg) ->
    [arg(OneArg)].

path(Value) ->
    filename:absname(arg(Value)).

%%%===================================================================
%%% Transcript handling
%%%===================================================================

process_output_record(Record0, State0) ->
    Record = string:trim(strip_ansi(unicode:characters_to_binary(Record0))),
    case deduplicate_output_record(Record, State0) of
        {skip, State1} ->
            State1;
        {process, State1} ->
            maybe_echo_output(Record, State1#state.opts),
            handle_output_record(Record, State1#state{
                last_output = Record,
                last_output_at_ms = erlang:system_time(millisecond)
            })
    end.

deduplicate_output_record(<<>>, State) ->
    {skip, State};
deduplicate_output_record(Record, State = #state{opts = Opts, recent_output = Recent0}) ->
    DedupeMs = maps:get(output_dedupe_ms, Opts, ?DEFAULT_OUTPUT_DEDUPE_MS),
    case DedupeMs of
        0 ->
            {process, State#state{recent_output = #{}}};
        _ ->
            Now = erlang:monotonic_time(millisecond),
            Recent1 = maps:filter(
                fun(_Key, SeenAt) -> Now - SeenAt =< DedupeMs end,
                Recent0
            ),
            Key = output_dedupe_key(Record),
            Recent2 = maps:put(Key, Now, Recent1),
            State1 = State#state{recent_output = Recent2},
            case maps:is_key(Key, Recent1) of
                true -> {skip, State1};
                false -> {process, State1}
            end
    end.

%% Timestamp ranges move on every whisper-stream redraw, so transcript text
%% itself is the stable key. Non-transcript diagnostics use their cleaned line.
output_dedupe_key(Record) ->
    case transcript_text(Record) of
        {ok, Text} -> {transcript, normalize_text(Text)};
        ignore -> {output, re:replace(Record, "\\s+", " ", [global, {return, binary}])}
    end.

handle_output_record(Record, State) ->
    case capture_device(Record) of
        {ok, Source} ->
            remember_input_source(Source, State);
        ignore ->
            case transcript_text(Record) of
                {ok, Text} -> handle_transcript(Text, State);
                ignore -> State
            end
    end.

capture_device(Record0) ->
    Record = strip_ansi(unicode:characters_to_binary(Record0)),
    Pattern = "Capture device #([0-9]+):\\s*'(.*)'\\s*$",
    case re:run(Record, Pattern, [{capture, [1, 2], binary}, unicode]) of
        {match, [Id, Name]} ->
            {ok, #{id => binary_to_integer(Id), name => Name}};
        _ ->
            ignore
    end.

remember_input_source(Source = #{id := Id}, State) ->
    Sources0 = State#state.input_sources,
    Sources1 = [Existing || Existing = #{id := ExistingId} <- Sources0, ExistingId =/= Id],
    State#state{input_sources = lists:sort(fun source_order/2, [Source | Sources1])}.

source_order(#{id := Left}, #{id := Right}) ->
    Left < Right.

%% Sliding-window mode forces no-timestamp output in current whisper.cpp, while
%% VAD mode emits timestamped records. stderr is merged into the port so input
%% devices remain discoverable; reject its known diagnostic/control prefixes
%% before accepting a plain transcript.
transcript_text(Record0) ->
    Record = string:trim(strip_ansi(unicode:characters_to_binary(Record0))),
    Pattern = "^\\s*\\[[0-9:.]+\\s+-->\\s+[0-9:.]+\\]\\s*(.*?)\\s*$",
    case re:run(Record, Pattern, [{capture, [1], binary}, unicode]) of
        {match, [Text]} when Text =/= <<>> -> {ok, Text};
        _ -> plain_transcript_text(Record)
    end.

plain_transcript_text(<<>>) ->
    ignore;
plain_transcript_text(Record) when byte_size(Record) =< 1024 ->
    DiagnosticPattern =
        "^(\\[|###|capture device|whisper|ggml|main\\s*:|init\\s*:|"
        "system_info\\s*:|audio|error\\s*:|warning\\s*:|info\\s*:|alsa|"
        "jack|pipewire|pulseaudio|cuda|metal|openvino|coreml|using\\s+|"
        "loading\\s+|loaded\\s+|found\\s+|processing\\s+|timings\\s*:|/)",
    case re:run(Record, DiagnosticPattern, [caseless, unicode]) of
        nomatch -> {ok, Record};
        _ -> ignore
    end;
plain_transcript_text(_Record) ->
    ignore.

handle_transcript(
    Text0,
    State = #state{
        hostname = Hostname,
        trigger_phrases = Phrases,
        trigger_handler = Handler,
        last_trigger_ms = LastTrigger,
        debounce_ms = DebounceMs
    }
) ->
    Text = normalize_text(Text0),
    %logger:notice("speech detected: ~ts", [Text]),
    State1 = State#state{
        last_transcript = Text,
        last_transcript_at_ms = erlang:system_time(millisecond),
        transcript_count = State#state.transcript_count + 1
    },
    logger:debug("case-folded trigger check: text=~tp phrases=~tp", [Text, Phrases]),
    case matching_phrase(Text, Phrases) of
        nomatch ->
            State1;
        {match, Phrase} ->
            Now = erlang:monotonic_time(millisecond),
            case debounce_elapsed(LastTrigger, Now, DebounceMs) of
                true ->
                    run_handler(Handler, Text, Hostname),
                    logger:notice("speech trigger matched (case-insensitive): ~ts", [Phrase]),
                    State1#state{
                        last_trigger_ms = Now,
                        last_trigger_at_ms = erlang:system_time(millisecond),
                        trigger_count = State1#state.trigger_count + 1
                    };
                false ->
                    State1
            end
    end.

matching_phrase(Text0, Phrases) ->
    matching_normalized_phrase(normalize_text(Text0), Phrases).

matching_normalized_phrase(_Text, []) ->
    nomatch;
matching_normalized_phrase(Text, [Phrase0 | Rest]) ->
    Phrase = normalize_text(Phrase0),
    case Phrase of
        <<>> ->
            matching_normalized_phrase(Text, Rest);
        _ ->
            case binary:match(Text, Phrase) of
                nomatch -> matching_normalized_phrase(Text, Rest);
                _ -> {match, Phrase}
            end
    end.

debounce_elapsed(undefined, _Now, _DebounceMs) ->
    true;
debounce_elapsed(Last, Now, DebounceMs) ->
    Now - Last >= DebounceMs.

run_handler(Handler, Text, Hostname) ->
    _ = spawn(fun() ->
        try Handler(Text, Hostname) of
            _ -> ok
        catch
            Class:Reason:Stacktrace ->
                logger:error(
                    "speech trigger handler failed: ~p:~p~n~p",
                    [Class, Reason, Stacktrace]
                )
        end
    end),
    ok.

default_trigger_handler(Text, Host) ->
    logger:notice("hostname ~ts detected in speech: ~ts", [Host, Text]).

safe_normalize_phrases(Phrases) ->
    try normalize_phrases(Phrases) of
        Normalized -> {ok, Normalized}
    catch
        error:Reason -> {error, {invalid_trigger_phrases, Reason}}
    end.

input_sources(State = #state{input_sources = Sources}) ->
    Capture = selected_capture(State),
    Default = #{
        id => -1,
        name => <<"System default">>,
        default => true,
        selected => Capture < 0
    },
    [Default | [Source#{selected => maps:get(id, Source) =:= Capture} || Source <- Sources]].

selected_input_source(State = #state{input_sources = Sources}) ->
    Capture = selected_capture(State),
    case Capture < 0 of
        true ->
            #{id => -1, name => <<"System default">>, default => true};
        false ->
            case find_input_source(Capture, Sources) of
                {ok, Source} -> Source#{default => false};
                error -> #{id => Capture, name => undefined, default => false}
            end
    end.

selected_capture(#state{opts = Opts}) ->
    maps:get(capture, Opts, -1).

resolve_input_source(default, _Sources) ->
    {ok, -1, #{id => -1, name => <<"System default">>, default => true}};
resolve_input_source(-1, Sources) ->
    resolve_input_source(default, Sources);
resolve_input_source(#{id := Id}, Sources) ->
    resolve_input_source(Id, Sources);
resolve_input_source(Id, Sources) when is_integer(Id), Id >= 0 ->
    case find_input_source(Id, Sources) of
        {ok, Source} -> {ok, Id, Source#{default => false}};
        error when Sources =:= [] -> {error, input_sources_not_discovered};
        error -> {error, {unknown_input_source, Id}}
    end;
resolve_input_source(Name0, Sources) when is_binary(Name0); is_list(Name0) ->
    Name = normalize_text(Name0),
    case Name of
        <<"default">> ->
            resolve_input_source(default, Sources);
        _ ->
            Matches = [
                Source
             || Source = #{name := SourceName} <- Sources,
                normalize_text(SourceName) =:= Name
            ],
            case Matches of
                [Source | _] ->
                    {ok, maps:get(id, Source), Source#{default => false}};
                [] when Sources =:= [] ->
                    {error, input_sources_not_discovered};
                [] ->
                    {error, {unknown_input_source, Name0}}
            end
    end;
resolve_input_source(Source, _Sources) ->
    {error, {invalid_input_source, Source}}.

find_input_source(Id, Sources) ->
    case [Source || Source = #{id := SourceId} <- Sources, SourceId =:= Id] of
        [Source | _] -> {ok, Source};
        [] -> error
    end.

reconfigure_stream_if_listening(Opts, State0 = #state{port = Port}) ->
    State1 = State0#state{opts = Opts, input_sources = []},
    case is_port(Port) of
        false ->
            {ok, State1};
        true ->
            State2 = close_stream(State1),
            case open_stream(State2) of
                {ok, State3} -> {ok, State3};
                {error, Reason} -> {error, Reason, State2#state{last_error = Reason}}
            end
    end.

normalize_phrases([]) ->
    [];
normalize_phrases([Char | _] = Phrase) when is_integer(Char) ->
    normalize_phrases([unicode:characters_to_binary(Phrase)]);
normalize_phrases(Phrases) when is_list(Phrases) ->
    lists:usort([
        Phrase
     || Phrase0 <- Phrases,
        Phrase <- [normalize_text(Phrase0)],
        Phrase =/= <<>>
    ]);
normalize_phrases(Phrase) ->
    normalize_phrases([Phrase]).

normalize_text(Text) ->
    %% NFKC plus full Unicode case folding makes matching independent of case
    %% and compatibility forms while preserving a stable UTF-8 binary.
    Bin = unicode:characters_to_nfkc_binary(Text),
    Folded = unicode:characters_to_binary(string:casefold(Bin)),
    Stripped = re:replace(
        Folded,
        "[^\\p{L}\\p{N}\\-_. ]+",
        " ",
        [global, unicode, {return, binary}]
    ),
    string:trim(re:replace(Stripped, "\\s+", " ", [global, {return, binary}])).

strip_ansi(Bin) ->
    re:replace(
        Bin,
        <<27, "\\[[0-?]*[ -/]*[@-~]">>,
        <<>>,
        [global, {return, binary}]
    ).

%% whisper-stream redraws live output with carriage returns and terminates
%% committed segments with newlines. Treat both as record boundaries while
%% preserving the final partial record across port messages.
split_records(Bin) ->
    Parts = re:split(Bin, "[\\r\\n]+", [{return, binary}]),
    case ends_with_record_separator(Bin) of
        true ->
            {[Part || Part <- Parts, Part =/= <<>>], <<>>};
        false when length(Parts) =:= 1 ->
            {[], Bin};
        false ->
            Complete = lists:sublist(Parts, length(Parts) - 1),
            Rest = lists:last(Parts),
            {[Part || Part <- Complete, Part =/= <<>>], Rest}
    end.

ends_with_record_separator(<<>>) ->
    false;
ends_with_record_separator(Bin) ->
    case binary:last(Bin) of
        $\n -> true;
        $\r -> true;
        _ -> false
    end.

maybe_echo_output(Record, Opts) ->
    case maps:get(echo_output, Opts, false) of
        true ->
            logger:notice("whisper-stream: ~ts", [Record]);
        false ->
            ok
    end.

port_os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid) -> Pid;
        _ -> undefined
    end.

maybe_cleanup_existing(Bin, Model, Opts) ->
    case maps:get(cleanup_existing, Opts, true) of
        true -> cleanup_matching_processes(Bin, Model, []);
        false -> []
    end.

cleanup_matching_processes(Bin0, Model0, Excluded) ->
    Bin = arg(Bin0),
    Model = arg(Model0),
    case {current_uid(), file:list_dir("/proc")} of
        {{ok, Uid}, {ok, Entries}} ->
            Pids = [
                Pid
             || Entry <- Entries,
                {ok, Pid} <- [parse_pid(Entry)],
                not lists:member(Pid, Excluded),
                process_matches(Pid, Uid, Bin, Model)
            ],
            lists:foreach(fun terminate_os_process/1, Pids),
            case Pids of
                [] -> ok;
                _ -> logger:notice("cleaned up stale whisper-stream processes: ~p", [Pids])
            end,
            Pids;
        _ ->
            []
    end.

current_uid() ->
    case file:read_file_info("/proc/self") of
        {ok, Info} -> {ok, Info#file_info.uid};
        Error -> Error
    end.

parse_pid(Name) ->
    try list_to_integer(Name) of
        Pid when Pid > 0 -> {ok, Pid};
        _ -> error
    catch
        error:badarg -> error
    end.

process_matches(Pid, Uid, Bin, Model) ->
    ProcDir = "/proc/" ++ integer_to_list(Pid),
    ExePath = filename:join(ProcDir, "exe"),
    CmdlinePath = filename:join(ProcDir, "cmdline"),
    case
        {
            file:read_file_info(ProcDir),
            file:read_link(ExePath),
            file:read_file(CmdlinePath)
        }
    of
        {{ok, Info}, {ok, Exe}, {ok, Cmdline}} ->
            Args = binary:split(Cmdline, <<0>>, [global]),
            Info#file_info.uid =:= Uid andalso
                filename:basename(Exe) =:= filename:basename(Bin) andalso
                lists:member(unicode:characters_to_binary(Model), Args);
        _ ->
            false
    end.

terminate_os_process(undefined) ->
    ok;
terminate_os_process(Pid) when is_integer(Pid), Pid > 0 ->
    signal_process(Pid, "TERM"),
    case wait_for_process_exit(Pid, 25) of
        true ->
            ok;
        false ->
            logger:warning("whisper-stream pid ~p ignored SIGTERM; sending SIGKILL", [Pid]),
            signal_process(Pid, "KILL"),
            _ = wait_for_process_exit(Pid, 25),
            ok
    end.

signal_process(Pid, Signal) ->
    Kill =
        case filelib:is_regular("/usr/bin/kill") of
            true -> "/usr/bin/kill";
            false -> "/bin/kill"
        end,
    Command = Kill ++ " -" ++ Signal ++ " -- " ++ integer_to_list(Pid),
    _ = os:cmd(Command),
    ok.

wait_for_process_exit(_Pid, 0) ->
    false;
wait_for_process_exit(Pid, Attempts) ->
    case process_running(Pid) of
        false ->
            true;
        true ->
            timer:sleep(20),
            wait_for_process_exit(Pid, Attempts - 1)
    end.

%% A dead child may remain in /proc as a zombie until the Erlang port driver
%% reaps it. Treat that state as exited instead of escalating to SIGKILL.
process_running(Pid) ->
    StatPath = "/proc/" ++ integer_to_list(Pid) ++ "/stat",
    case file:read_file(StatPath) of
        {error, enoent} ->
            false;
        {ok, Stat} ->
            case re:run(Stat, "\\)\\s+Z\\s", []) of
                nomatch -> true;
                _ -> false
            end;
        {error, _Reason} ->
            true
    end.

close_stream(State = #state{port = Port, os_pid = OsPid}) when is_port(Port) ->
    ok = terminate_os_process(OsPid),
    ok = close_port(Port),
    State#state{
        port = undefined,
        os_pid = undefined,
        recent_output = #{},
        started_at_ms = undefined,
        buffer = <<>>
    };
close_stream(State) ->
    State#state{
        port = undefined,
        os_pid = undefined,
        recent_output = #{},
        started_at_ms = undefined,
        buffer = <<>>
    }.

close_port(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        error:badarg -> ok
    end.
