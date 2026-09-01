%%%-------------------------------------------------------------------
%%% damage_hwmon.erl - Continuous hardware monitor (Linux focused)
%%%
%%% Hardware monitoring is observational only. Collection, command,
%%% parsing, cache and sink failures must never terminate the monitor.
%%%
%%% External commands are managed by erlexec rather than raw ports so
%%% timeouts can terminate the OS process group cleanly.
%%%-------------------------------------------------------------------
-module(damage_hwmon).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-behaviour(gen_server).

-export([start_link/0, start_link/1, stop/0]).
-export([get_last/0, get_last/1, subscribe/0, unsubscribe/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_INTERVAL_MS, 5000).
-define(DEFAULT_TIMEOUT_MS, 2000).
-define(ETS_TABLE, damage_hwmon_last).
-define(MAX_CMD_OUTPUT_BYTES, 65536).
-define(MAX_LOG_OUTPUT_BYTES, 1024).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL_MS :: pos_integer(),
    timeout_ms = ?DEFAULT_TIMEOUT_MS :: pos_integer(),
    last = #{} :: map(),
    subs = [] :: [pid()],
    use_ets = true :: boolean(),
    exec_available = false :: boolean(),
    sink = fun default_sink/1 :: fun((map()) -> any())
}).

%%%========================
%%% Public API
%%%========================

start_link() ->
    start_link(#{}).

%% Opts:
%%  #{interval_ms => 5000,
%%    timeout_ms  => 2000,
%%    use_ets     => true,
%%    sink        => Fun/1 }.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:call(?MODULE, stop).

get_last() ->
    get_last(2000).

get_last(Timeout) ->
    gen_server:call(?MODULE, get_last, Timeout).

subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

%%%========================
%%% gen_server callbacks
%%%========================

init(Opts) ->
    process_flag(trap_exit, true),

    Interval = positive_int(
        maps:get(interval_ms, Opts, ?DEFAULT_INTERVAL_MS),
        ?DEFAULT_INTERVAL_MS
    ),
    Timeout = positive_int(
        maps:get(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
        ?DEFAULT_TIMEOUT_MS
    ),
    UseEts = maps:get(use_ets, Opts, true),
    SinkFun = maps:get(sink, Opts, fun default_sink/1),

    case UseEts of
        true ->
            ensure_ets();
        false ->
            ok
    end,

    %% erlexec is best-effort for hwmon. Failure to load/start it degrades
    %% external-command metrics but must not fail the Damage supervisor.
    ExecAvailable = ensure_erlexec_started(),

    %% Start immediate sample.
    self() ! sample,

    {ok, #state{
        interval_ms = Interval,
        timeout_ms = Timeout,
        use_ets = UseEts,
        exec_available = ExecAvailable,
        sink = SinkFun
    }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(get_last, _From, State = #state{last = Last}) ->
    {reply, {ok, Last}, State};
handle_call({subscribe, Pid}, _From, State = #state{subs = Subs}) ->
    link(Pid),
    {reply, ok, State#state{subs = lists:usort([Pid | Subs])}};
handle_call({unsubscribe, Pid}, _From, State = #state{subs = Subs}) ->
    unlink(Pid),
    {reply, ok, State#state{subs = lists:delete(Pid, Subs)}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sample, State0 = #state{interval_ms = Interval}) ->
    %% Hardware monitoring is observational only. Any failure becomes a
    %% degraded sample rather than a supervisor-visible process crash.
    Sample = safe_collect(State0),
    State = State0#state{last = Sample},

    maybe_store_ets(State, Sample),
    notify_subs(State, Sample),
    safe_sink(State, Sample),

    _ = erlang:send_after(Interval, self(), sample),
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, State = #state{subs = Subs}) when is_pid(Pid) ->
    %% Linked subscriber died.
    {noreply, State#state{subs = lists:delete(Pid, Subs)}};
handle_info({'DOWN', _OsPid, process, _ExecPid, _Reason}, State) ->
    %% A DOWN can arrive after cmd_kv/3 timed out and returned. The command
    %% has already been stopped, so discard this late monitor notification.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%========================
%%% Collection
%%%========================

safe_collect(State) ->
    try
        collect(State)
    catch
        Class:Reason:Stacktrace ->
            logger:warning(
                "damage_hwmon collection failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            #{
                ts_ms => erlang:system_time(millisecond),
                degraded => true,
                error => #{
                    class => Class,
                    reason => Reason
                }
            }
    end.

collect(#state{timeout_ms = Timeout, exec_available = ExecAvailable}) ->
    Ts = erlang:system_time(millisecond),

    %% CPU: loadavg + basic freq + core count.
    LoadAvg = cmd_kv(
        "cat /proc/loadavg | awk '{print $1\" \"$2\" \"$3}'",
        Timeout,
        ExecAvailable
    ),
    CpuMhz = cmd_kv(
        "awk -F': ' '/cpu MHz/{sum+=$2;n++} END{if(n>0)print sum/n; else print 0}' /proc/cpuinfo",
        Timeout,
        ExecAvailable
    ),
    Cores = cmd_kv("nproc", Timeout, ExecAvailable),

    %% RAM: MemAvailable / MemTotal.
    MemTotalKb = cmd_kv(
        "awk '/MemTotal:/{print $2}' /proc/meminfo",
        Timeout,
        ExecAvailable
    ),
    MemAvailKb = cmd_kv(
        "awk '/MemAvailable:/{print $2}' /proc/meminfo",
        Timeout,
        ExecAvailable
    ),

    %% Disk: root usage.
    RootUsePct = cmd_kv(
        "df -P / | awk 'NR==2{gsub(/%/,\"\",$5); print $5}'",
        Timeout,
        ExecAvailable
    ),

    %% GPU (NVIDIA optional).
    NvPresent = has_cmd("nvidia-smi"),
    Nv =
        case NvPresent of
            true -> collect_nvidia(Timeout, ExecAvailable);
            false -> #{present => false}
        end,

    %% Miner detection (optional, quick).
    Miner = detect_miner(Timeout, ExecAvailable),

    MemTotal = parse_int(MemTotalKb),
    MemAvail = parse_int(MemAvailKb),

    #{
        ts_ms => Ts,
        cpu => #{
            loadavg => LoadAvg,
            avg_mhz => parse_float(CpuMhz),
            cores => parse_int(Cores)
        },
        mem => #{
            total_kb => MemTotal,
            avail_kb => MemAvail,
            used_pct => mem_used_pct(MemTotal, MemAvail)
        },
        disk => #{
            root_used_pct => parse_int(RootUsePct)
        },
        gpu => Nv,
        processes => #{
            miner_hint => Miner
        }
    }.

collect_nvidia(Timeout, ExecAvailable) ->
    %% Single GPU summary (can extend to multiple GPUs).
    Cmd =
        "nvidia-smi --query-gpu=utilization.gpu,power.draw,memory.used,memory.total,temperature.gpu "
        "--format=csv,noheader,nounits | head -n 1",
    Line = cmd_kv(Cmd, Timeout, ExecAvailable),
    case split_csv(Line) of
        [Util, Power, MemUsed, MemTot, Temp] ->
            #{
                present => true,
                util_pct => parse_int(Util),
                power_w => parse_float(Power),
                mem_used_mib => parse_int(MemUsed),
                mem_total_mib => parse_int(MemTot),
                temp_c => parse_int(Temp)
            };
        _ ->
            #{present => true, error => <<"parse_failed">>, raw => Line}
    end.

detect_miner(Timeout, ExecAvailable) ->
    %% Very lightweight: look for gminer/miner processes.
    Out = cmd_kv(
        "ps -eo comm | grep -i 'gminer|minerd|miner' | head -n 3",
        Timeout,
        ExecAvailable
    ),
    case string:trim(Out) of
        "" -> none;
        S -> S
    end.

%%%========================
%%% Notifications / storage / sink
%%%========================

ensure_ets() ->
    case ets:info(?ETS_TABLE) of
        undefined ->
            _ = ets:new(?ETS_TABLE, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

maybe_store_ets(#state{use_ets = true}, Sample) ->
    %% Losing the metrics cache must not kill the monitor.
    try
        _ = ets:insert(?ETS_TABLE, {last, Sample}),
        ok
    catch
        Class:Reason:Stacktrace ->
            logger:warning(
                "damage_hwmon ETS write failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            ok
    end;
maybe_store_ets(#state{use_ets = false}, _Sample) ->
    ok.

notify_subs(#state{subs = Subs}, Sample) ->
    %% Fire-and-forget. Sending to a dead pid is harmless.
    lists:foreach(fun(P) -> P ! {damage_hwmon, sample, Sample} end, Subs).

safe_sink(#state{sink = SinkFun}, Sample) ->
    %% Never let a telemetry/event sink crash the monitor.
    try
        _ = SinkFun(Sample),
        ok
    catch
        Class:Reason:Stacktrace ->
            logger:warning(
                "damage_hwmon sink failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            ok
    end.

default_sink(Sample) ->
    logger:debug("damage_hwmon sample: ~p", [Sample]),
    ok.

%%%========================
%%% erlexec command helpers
%%%========================

ensure_erlexec_started() ->
    try
        case application:ensure_all_started(erlexec) of
            {ok, _Apps} ->
                true;
            {error, Reason} ->
                logger:warning(
                    "damage_hwmon erlexec unavailable reason=~p; external metrics disabled",
                    [Reason]
                ),
                false
        end
    catch
        Class:Reason0:Stacktrace ->
            logger:warning(
                "damage_hwmon erlexec startup failed class=~p reason=~p stack=~p; external metrics disabled",
                [Class, Reason0, Stacktrace]
            ),
            false
    end.

has_cmd(Cmd) when is_list(Cmd) ->
    os:find_executable(Cmd) =/= false;
has_cmd(Cmd) when is_binary(Cmd) ->
    has_cmd(binary_to_list(Cmd));
has_cmd(_) ->
    false.

cmd_kv(_Command, _TimeoutMs, false) ->
    "";
cmd_kv(Command0, TimeoutMs, true) ->
    Command = command_to_list(Command0),
    Timeout = positive_int(TimeoutMs, ?DEFAULT_TIMEOUT_MS),
    try
        %% A private process group plus kill_group ensures that timing out the
        %% shell also cleans up children created by pipes (awk/grep/head/etc.).
        case
            exec:run(
                Command,
                [
                    stdout,
                    stderr,
                    monitor,
                    {group, 0},
                    kill_group,
                    {kill_timeout, 1}
                ]
            )
        of
            {ok, ExecPid, OsPid} when is_pid(ExecPid), is_integer(OsPid) ->
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                collect_exec(ExecPid, OsPid, Deadline, <<>>, <<>>);
            {error, Reason} ->
                logger:warning(
                    "damage_hwmon command start failed command=~p reason=~p",
                    [Command, Reason]
                ),
                "";
            Other ->
                logger:warning(
                    "damage_hwmon unexpected erlexec start result command=~p result=~p",
                    [Command, Other]
                ),
                ""
        end
    catch
        Class:Reason0:Stacktrace ->
            logger:warning(
                "damage_hwmon command failed command=~p class=~p reason=~p stack=~p",
                [Command, Class, Reason0, Stacktrace]
            ),
            ""
    end.

collect_exec(ExecPid, OsPid, Deadline, Stdout0, Stderr0) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            command_timeout(ExecPid, OsPid, Stdout0, Stderr0);
        false ->
            receive
                {stdout, OsPid, Bin} when is_binary(Bin) ->
                    Stdout = append_bounded(Stdout0, Bin, ?MAX_CMD_OUTPUT_BYTES),
                    collect_exec(ExecPid, OsPid, Deadline, Stdout, Stderr0);
                {stderr, OsPid, Bin} when is_binary(Bin) ->
                    Stderr = append_bounded(Stderr0, Bin, ?MAX_CMD_OUTPUT_BYTES),
                    collect_exec(ExecPid, OsPid, Deadline, Stdout0, Stderr);
                {'DOWN', OsPid, process, ExecPid, normal} ->
                    maybe_log_stderr(OsPid, Stderr0),
                    binary_to_list(Stdout0);
                {'DOWN', OsPid, process, ExecPid, Reason} ->
                    logger:warning(
                        "damage_hwmon command exited pid=~p reason=~p stderr=~p",
                        [OsPid, Reason, truncate_binary(Stderr0, ?MAX_LOG_OUTPUT_BYTES)]
                    ),
                    ""
            after Remaining ->
                command_timeout(ExecPid, OsPid, Stdout0, Stderr0)
            end
    end.

command_timeout(_ExecPid, OsPid, _Stdout, Stderr) ->
    logger:warning(
        "damage_hwmon command timed out pid=~p stderr=~p",
        [OsPid, truncate_binary(Stderr, ?MAX_LOG_OUTPUT_BYTES)]
    ),
    safe_exec_stop(OsPid),
    "".

safe_exec_stop(OsPid) ->
    try
        case exec:stop(OsPid) of
            ok ->
                ok;
            {error, Reason} ->
                logger:warning(
                    "damage_hwmon failed to stop timed-out command pid=~p reason=~p",
                    [OsPid, Reason]
                ),
                ok;
            _Other ->
                ok
        end
    catch
        Class:Reason0:Stacktrace ->
            logger:warning(
                "damage_hwmon exception stopping command pid=~p class=~p reason=~p stack=~p",
                [OsPid, Class, Reason0, Stacktrace]
            ),
            ok
    end.

maybe_log_stderr(_OsPid, <<>>) ->
    ok;
maybe_log_stderr(OsPid, Stderr) ->
    logger:debug(
        "damage_hwmon command stderr pid=~p stderr=~p",
        [OsPid, truncate_binary(Stderr, ?MAX_LOG_OUTPUT_BYTES)]
    ).

append_bounded(Acc, Bin, MaxBytes) when is_binary(Acc), is_binary(Bin) ->
    Remaining = MaxBytes - byte_size(Acc),
    case Remaining > 0 of
        false ->
            Acc;
        true when byte_size(Bin) =< Remaining ->
            <<Acc/binary, Bin/binary>>;
        true ->
            <<Prefix:Remaining/binary, _/binary>> = Bin,
            <<Acc/binary, Prefix/binary>>
    end.

truncate_binary(Bin, MaxBytes) when is_binary(Bin), byte_size(Bin) =< MaxBytes ->
    Bin;
truncate_binary(Bin, MaxBytes) when is_binary(Bin), MaxBytes >= 0 ->
    binary:part(Bin, 0, MaxBytes);
truncate_binary(_, _) ->
    <<>>.

command_to_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
command_to_list(List) when is_list(List) ->
    List;
command_to_list(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

%%%========================
%%% Parsing helpers
%%%========================

split_csv(S) when is_binary(S) ->
    split_csv(binary_to_list(S));
split_csv(S) when is_list(S) ->
    %% Accepts "10, 250.5, 7312, 24576, 67".
    Parts = string:split(string:trim(S), ",", all),
    [string:trim(P) || P <- Parts, P =/= ""];
split_csv(_) ->
    [].

parse_int(I) when is_integer(I) ->
    I;
parse_int(S) when is_binary(S) ->
    parse_int(binary_to_list(S));
parse_int(S) when is_list(S) ->
    try
        case string:to_integer(string:trim(S)) of
            {I, _Rest} when is_integer(I) ->
                I;
            _ ->
                0
        end
    catch
        _:_ ->
            0
    end;
parse_int(_) ->
    0.

parse_float(F) when is_float(F) ->
    F;
parse_float(I) when is_integer(I) ->
    float(I);
parse_float(S) when is_binary(S) ->
    parse_float(binary_to_list(S));
parse_float(S) when is_list(S) ->
    %% Some outputs are integer-like; allow both.
    try
        Str = string:trim(S),
        case string:to_float(Str) of
            {F, _Rest} when is_float(F) ->
                F;
            _ ->
                case string:to_integer(Str) of
                    {I, _Rest} when is_integer(I) ->
                        float(I);
                    _ ->
                        0.0
                end
        end
    catch
        _:_ ->
            0.0
    end;
parse_float(_) ->
    0.0.

mem_used_pct(Total, Avail) when
    is_integer(Total),
    Total > 0,
    is_integer(Avail),
    Avail >= 0
->
    %% MemAvailable should normally be <= MemTotal. Clamp because procfs or
    %% container namespace data can transiently be inconsistent.
    Used = erlang:max(0, Total - Avail),
    erlang:min(100, (Used * 100) div Total);
mem_used_pct(TotalKbS, AvailKbS) ->
    mem_used_pct(parse_int(TotalKbS), parse_int(AvailKbS)).

positive_int(V, _Default) when is_integer(V), V > 0 ->
    V;
positive_int(V, Default) when is_binary(V) ->
    try
        positive_int(binary_to_integer(V), Default)
    catch
        _:_ -> Default
    end;
positive_int(V, Default) when is_list(V) ->
    try
        positive_int(list_to_integer(V), Default)
    catch
        _:_ -> Default
    end;
positive_int(_, Default) ->
    Default.
