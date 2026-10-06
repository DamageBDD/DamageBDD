%https://chatgpt.com/g/g-p-67a58763b6dc8191bafa4da81901910e-damagebdd/c/6902da66-6efc-8322-9ea3-74fdef24f7e0
-module(proc_bw).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-behaviour(gen_server).

-export([start_link/0, stop/0, start_port/0, stop_port/0, rates/0, rate/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {ets, port = undefined, last = #{}, last_ts = 0}).
-define(TICK_MS, 1000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop() -> gen_server:call(?MODULE, stop).
start_port() -> gen_server:call(?MODULE, start_port).
stop_port() -> gen_server:call(?MODULE, stop_port).

rates() ->
    case ets:info(proc_bw_rates) of
        undefined -> #{};
        _ -> maps:from_list(ets:tab2list(proc_bw_rates))
    end.
rate(Pid) when is_integer(Pid) ->
    case ets:lookup(proc_bw_rates, Pid) of
        [{Pid, M}] -> M;
        _ -> undefined
    end.

init([]) ->
    ets:new(proc_bw_rates, [named_table, public, {read_concurrency, true}]),
    {ok, #state{ets = proc_bw_rates, last = #{}, last_ts = erlang:monotonic_time(millisecond)}}.

handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(start_port, _From, S = #state{port = undefined}) ->
    Port = open_bpf_port(),
    {reply, ok, S#state{port = Port}};
handle_call(start_port, _From, S) ->
    {reply, ok, S};
handle_call(stop_port, _From, S = #state{port = P}) when is_port(P) ->
    port_close(P),
    {reply, ok, S#state{port = undefined}};
handle_call(stop_port, _From, S) ->
    {reply, ok, S};
handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info({port, _Port, {data, Bin}}, S0) ->
    {noreply, consume_lines(Bin, S0)};
handle_info({'EXIT', Port, _}, S = #state{port = Port}) ->
    {noreply, S#state{port = undefined}};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _S = #state{port = P}) when is_port(P) ->
    damage_otp_compat:catch_value(fun() -> port_close(P) end),
    ok;
terminate(_, _) ->
    ok.
code_change(_, S, _) -> {ok, S}.

open_bpf_port() ->
    Exec = filename:join(code:priv_dir(?MODULE), "proc_bw"),
    open_port(
        {spawn_executable, Exec},
        [{line, 4096}, exit_status, use_stdio, stderr_to_stdout, binary]
    ).

consume_lines(Bin, S0) ->
    Lines = string:split(binary_to_list(Bin), "\n", all),
    lists:foldl(fun handle_line/2, S0, Lines).

handle_line("--tick--", S = #state{last = Snap, last_ts = PrevTs, ets = Tab}) ->
    Now = erlang:monotonic_time(millisecond),
    Dt = max(1, Now - PrevTs),
    ets:delete_all_objects(Tab),
    _ = maps:map(
        fun(Pid, #{rx := Rx, tx := Tx, comm := C}) ->
            case maps:get(Pid, S#state.last, undefined) of
                #{rx := PRx, tx := PTx} ->
                    RxBps = trunc((Rx - PRx) * 1000 / Dt),
                    TxBps = trunc((Tx - PTx) * 1000 / Dt),
                    ets:insert(
                        Tab, {Pid, #{comm => C, rx_bps => max(0, RxBps), tx_bps => max(0, TxBps)}}
                    );
                _ ->
                    ets:insert(Tab, {Pid, #{comm => C, rx_bps => 0, tx_bps => 0}})
            end,
            ok
        end,
        Snap
    ),
    S#state{last_ts = Now, last = Snap};
handle_line(Line, S = #state{last = Acc}) ->
    case string:tokens(Line, ",") of
        [PidS, Comm | Rest] when length(Rest) >= 2 ->
            [RxS, TxS | _] = Rest,
            case damage_otp_compat:catch_value(fun() -> list_to_integer(PidS) end) of
                Pid when is_integer(Pid) ->
                    Rx = to_int(RxS),
                    Tx = to_int(TxS),
                    Acc1 =
                        case maps:get(Pid, Acc, undefined) of
                            #{comm := _C0, rx := R0, tx := T0} ->
                                maps:put(Pid, #{comm => Comm, rx => R0 + Rx, tx => T0 + Tx}, Acc);
                            _ ->
                                maps:put(Pid, #{comm => Comm, rx => Rx, tx => Tx}, Acc)
                        end,
                    S#state{last = Acc1};
                _ ->
                    S
            end;
        _ ->
            S
    end.

to_int(S) ->
    case string:to_integer(S) of
        {I, _} -> I;
        _ -> 0
    end.
