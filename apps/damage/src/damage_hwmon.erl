%%%-------------------------------------------------------------------
%%% damage_hwmon.erl - Continuous hardware monitor (Linux focused)
%%% https://chatgpt.com/c/698d43f7-1c18-839a-81d9-6e00415bce37
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

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL_MS :: pos_integer(),
    timeout_ms = ?DEFAULT_TIMEOUT_MS :: pos_integer(),
    last = #{} :: map(),
    subs = [] :: [pid()],
    use_ets = true :: boolean(),
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

    Interval = maps:get(interval_ms, Opts, ?DEFAULT_INTERVAL_MS),
    Timeout = maps:get(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    UseEts = maps:get(use_ets, Opts, true),
    SinkFun = maps:get(sink, Opts, fun default_sink/1),

    case UseEts of
        true ->
            ensure_ets(),
            ok;
        false ->
            ok
    end,

    %% Start immediate sample
    self() ! sample,

    {ok, #state{
        interval_ms = Interval,
        timeout_ms = Timeout,
        use_ets = UseEts,
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
    %% Collect metrics in a bounded way
    Sample = collect(State0),
    State = State0#state{last = Sample},

    maybe_store_ets(State, Sample),
    notify_subs(State, Sample),
    safe_sink(State, Sample),

    erlang:send_after(Interval, self(), sample),
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, State = #state{subs = Subs}) ->
    %% subscriber died
    {noreply, State#state{subs = lists:delete(Pid, Subs)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%========================
%%% Collection
%%%========================

collect(#state{timeout_ms = Timeout}) ->
    Ts = erlang:system_time(millisecond),

    %% CPU: loadavg + basic freq + core count
    LoadAvg = cmd_kv("cat /proc/loadavg | awk '{print $1\" \"$2\" \"$3}'", Timeout),
    CpuMhz = cmd_kv(
        "awk -F': ' '/cpu MHz/{sum+=$2;n++} END{if(n>0)print sum/n; else print 0}' /proc/cpuinfo",
        Timeout
    ),
    Cores = cmd_kv("nproc", Timeout),

    %% RAM: MemAvailable / MemTotal
    MemTotalKb = cmd_kv("awk '/MemTotal:/{print $2}' /proc/meminfo", Timeout),
    MemAvailKb = cmd_kv("awk '/MemAvailable:/{print $2}' /proc/meminfo", Timeout),

    %% Disk: root usage (feel free to change mount)
    RootUsePct = cmd_kv("df -P / | awk 'NR==2{gsub(/%/,\"\",$5); print $5}'", Timeout),

    %% GPU (NVIDIA optional)
    NvPresent = has_cmd("nvidia-smi"),
    Nv =
        case NvPresent of
            true -> collect_nvidia(Timeout);
            false -> #{present => false}
        end,

    %% Miner detection (optional, quick)
    Miner = detect_miner(Timeout),

    #{
        ts_ms => Ts,
        cpu => #{
            loadavg => LoadAvg,
            avg_mhz => parse_float(CpuMhz),
            cores => parse_int(Cores)
        },
        mem => #{
            total_kb => parse_int(MemTotalKb),
            avail_kb => parse_int(MemAvailKb),
            used_pct => mem_used_pct(MemTotalKb, MemAvailKb)
        },
        disk => #{
            root_used_pct => parse_int(RootUsePct)
        },
        gpu => Nv,
        processes => #{
            miner_hint => Miner
        }
    }.

collect_nvidia(Timeout) ->
    %% Single GPU summary (can extend to multiple GPUs)
    %% queries: util.gpu, power.draw, memory.used, memory.total, temperature.gpu
    Cmd =
        "nvidia-smi --query-gpu=utilization.gpu,power.draw,memory.used,memory.total,temperature.gpu "
        "--format=csv,noheader,nounits | head -n 1",
    Line = cmd_kv(Cmd, Timeout),
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

detect_miner(Timeout) ->
    %% Very lightweight: look for gminer/miner processes
    %% If you want more, integrate with procfs reading instead.
    Out = cmd_kv("ps -eo comm | grep -i 'gminer|minerd|miner' | head -n 3", Timeout),
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
            ets:new(?ETS_TABLE, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            ok
    end.

maybe_store_ets(#state{use_ets = true}, Sample) ->
    ets:insert(?ETS_TABLE, {last, Sample}),
    ok;
maybe_store_ets(#state{use_ets = false}, _Sample) ->
    ok.

notify_subs(#state{subs = Subs}, Sample) ->
    %% Fire-and-forget. Subscribers handle it.
    lists:foreach(fun(P) -> P ! {damage_hwmon, sample, Sample} end, Subs).

safe_sink(#state{sink = SinkFun}, Sample) ->
    %% Never let sink crash the monitor
    _ = (catch SinkFun(Sample)),
    ok.

default_sink(Sample) ->
    %% Replace with DamageBDD event emitter
    %% e.g. damage_events:emit(hw_sample, Sample).
    error_logger:info_msg("damage_hwmon sample: ~p~n", [Sample]),
    ok.

%%%========================
%%% Command helpers (bounded)
%%%========================

has_cmd(Cmd) ->
    %% `command -v` is POSIX.
    case os:cmd("sh -lc 'command -v " ++ Cmd ++ " >/dev/null 2>&1; echo $?'") of
        "0\n" -> true;
        _ -> false
    end.

cmd_kv(Command, TimeoutMs) ->
    %% Execute via port to avoid long hangs (bounded by our kill timer)
    %% Uses sh -lc to allow pipes/awk.
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [
            {args, ["-lc", Command]},
            exit_status,
            use_stdio,
            stderr_to_stdout,
            binary
        ]
    ),
    Ref = make_ref(),
    TRef = erlang:send_after(TimeoutMs, self(), {kill_port, Ref, Port}),
    Res = recv_port(Port, Ref, TRef, <<>>),
    Res.

recv_port(Port, Ref, TRef, Acc) ->
    receive
        {kill_port, Ref, Port} ->
            catch port_close(Port),
            erlang:cancel_timer(TRef),
            binary_to_list(Acc);
        {Port, {data, Bin}} ->
            recv_port(Port, Ref, TRef, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, _}} ->
            erlang:cancel_timer(TRef),
            binary_to_list(Acc)
    after 5000 ->
        %% hard backstop; shouldn't happen if TimeoutMs is small
        catch port_close(Port),
        erlang:cancel_timer(TRef),
        binary_to_list(Acc)
    end.

%%%========================
%%% Parsing helpers
%%%========================

split_csv(S) ->
    %% Accepts "10, 250.5, 7312, 24576, 67"
    Parts = string:split(string:trim(S), ",", all),
    [string:trim(P) || P <- Parts, P =/= ""].

parse_int(S) when is_list(S) ->
    case string:to_integer(string:trim(S)) of
        {I, _} -> I;
        error -> 0
    end;
parse_int(_) ->
    0.

parse_float(S) when is_list(S) ->
    %% Some outputs are integer-like; allow both.
    Str = string:trim(S),
    case string:to_float(Str) of
        {F, _} ->
            F;
        error ->
            case string:to_integer(Str) of
                {I, _} -> float(I);
                _ -> 0.0
            end
    end;
parse_float(_) ->
    0.0.

mem_used_pct(TotalKbS, AvailKbS) ->
    T = parse_int(TotalKbS),
    A = parse_int(AvailKbS),
    case T > 0 andalso A >= 0 of
        true ->
            Used = T - A,
            trunc((Used * 100) div T);
        false ->
            0
    end.
