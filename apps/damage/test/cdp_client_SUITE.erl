-module(cdp_client_SUITE).
-compile([export_all, nowarn_export_all]).
-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/logger.hrl").

all() -> [basic_connectivity, trace_handle_call].

-record(ctx, {port, chrome_port, chrome_os_port, cdp_pid}).

%% ---- in init_per_suite/1 ----
init_per_suite(Cfg) ->
    try
        Priv = ?config(priv_dir, Cfg),
        ChromeBin = chrome_bin(),
        UD = filename:join(Priv, "cdp_profile"),
        ok = filelib:ensure_dir(filename:join(UD, "x")),

        {Port, _ChromePort} = start_chrome(ChromeBin, UD),
        ok = wait_ready("127.0.0.1", Port, 8000),
        %% ... start Chrome, wait_ready/3 ...
        {ok, Pid} = cdp_client:start_link(#{host => "127.0.0.1", port => Port, type => <<"page">>}),

        ok = cdp_client:enable_console(Pid),

        Config = [{ctx, #ctx{port = Port, cdp_pid = Pid}} | Cfg],
        ?LOG_INFO("Config ~p", [Config]),
        Config
    catch
        Class:Reason:Stack ->
            ct:pal(
                "INIT_CRASH ~p:~p~nSTACK:~n~ts",
                [Class, Reason, io_lib:format("~p", [Stack])]
            ),
            erlang:raise(Class, Reason, Stack)
    end.

end_per_suite(Cfg) ->
    Ctx = ?config(ctx, Cfg),
    catch cdp_client:stop(maps:get(cdp_pid, Ctx)),
    stop_chrome(maps:get(chrome_port, Ctx)),
    ok.

basic_connectivity(Cfg) ->
    #ctx{cdp_pid = Pid} = get_ctx(Cfg),
    R = cdp_client:call(
        Pid,
        <<"Runtime.evaluate">>,
        #{<<"expression">> => <<"40+2">>, <<"returnByValue">> => true}
    ),
    42 = maps:get(<<"value">>, maps:get(<<"result">>, R)),
    ok.

trace_handle_call(Cfg) ->
    #ctx{cdp_pid = Pid} = get_ctx(Cfg),
    erlang:trace(Pid, true, [call, timestamp]),
    erlang:trace_pattern({cdp_client, handle_call, 3}, [{'_', [], [{return_trace}]}], [local]),
    _ = cdp_client:call(Pid, <<"Runtime.enable">>, #{}),
    Traces = collect_traces(erlang:monotonic_time(millisecond) + 1000, []),
    erlang:trace(Pid, false, [call]),
    erlang:trace_pattern({cdp_client, handle_call, 3}, false, [local]),
    true = lists:any(fun(E) -> match_call(E) end, Traces),
    true = lists:any(fun(E) -> match_return(E) end, Traces),
    ok.

%% ---------- helpers ----------

get_ctx(Config) -> element(2, lists:keyfind(ctx, 1, Config)).

chrome_bin() ->
    case os:getenv("CHROME_BIN") of
        false ->
            %% adjust order if you use Brave/Edge etc.
            First = lists:filter(
                fun filelib:is_file/1,
                [
                    "/usr/bin/google-chrome",
                    "/usr/bin/google-chrome-stable",
                    "/usr/bin/chromium",
                    "/usr/bin/chromium-browser",
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ]
            ),
            case First of
                [B | _] -> B;
                [] -> ct:fail(no_chrome)
            end;
        B ->
            B
    end.

%% ---- start Chrome, let it choose a port, parse it from stdout
start_chrome(Bin, UserDataDir) ->
    Cmd = io_lib:format(
        "~s --headless=new --remote-debugging-port=0 "
        "--remote-debugging-address=127.0.0.1 "
        "--user-data-dir=~s --no-first-run --no-default-browser-check "
        "--disable-gpu about:blank",
        [Bin, UserDataDir]
    ),
    Port = open_port(
        {spawn, lists:flatten(Cmd)},
        [exit_status, use_stdio, stderr_to_stdout, binary]
    ),
    {ok, DevToolsPort} = await_ws_port(Port, 8000),
    ct:pal("Chrome devtools port detected: ~p", [DevToolsPort]),
    {DevToolsPort, Port}.

stop_chrome(Port) ->
    catch port_close(Port),
    ok.

%% ---- read "DevTools listening on ws://127.0.0.1:<port>/..." from Chrome output
await_ws_port(Port, TimeoutMs) ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {Port, {data, Bin}} ->
            case
                re:run(
                    Bin,
                    <<"DevTools listening on ws:\\/\\/127\\.0\\.0\\.1:(\\d+)">>,
                    [{capture, [1], binary}]
                )
            of
                {match, [PortBin]} ->
                    {ok, list_to_integer(binary_to_list(PortBin))};
                nomatch ->
                    await_ws_port(Port, TimeoutMs - (erlang:monotonic_time(millisecond) - T0))
            end;
        {Port, {exit_status, Code}} ->
            {error, {chrome_exited, Code}}
    after TimeoutMs ->
        {error, timeout}
    end.

%% deadline-based, no guards with time BIFs
wait_ready(Host, Port, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_ready_deadline(Host, Port, Deadline).

wait_ready_deadline(Host, Port, Deadline) ->
    case http_get(Host, Port, "/json/version") of
        {200, _} ->
            ok;
        _ ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true ->
                    {error, timeout};
                false ->
                    timer:sleep(100),
                    wait_ready_deadline(Host, Port, Deadline)
            end
    end.

http_get(Host, Port, Path) ->
    {ok, Conn} = gun:open(Host, Port, #{protocols => [http]}),
    {ok, _} = gun:await_up(Conn, 1000),
    Ref = gun:get(Conn, Path, #{}),
    {response, _Fin, Status, _Hdrs} = gun:await(Conn, Ref),
    {ok, Body} = gun:await_body(Conn, Ref),
    ?LOG_INFO("Response ~p", [Body]),
    ok = gun:close(Conn),
    {Status, Body}.

pick_free_port() ->
    {ok, S} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw}, {reuseaddr, true}]),
    {ok, {_, P}} = inet:sockname(S),
    ok = gen_tcp:close(S),
    P.

collect_traces(DeadlineMs, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Rem = DeadlineMs - Now,
    if
        Rem =< 0 ->
            lists:reverse(Acc);
        true ->
            receive
                M = {trace, _Pid, _Tag, _Info} ->
                    collect_traces(DeadlineMs, [M | Acc]);
                M = {trace, _Pid, _Tag, _Info, _More} ->
                    collect_traces(DeadlineMs, [M | Acc]);
                M = {trace_ts, _Pid, _Tag, _Info, _Ts} ->
                    collect_traces(DeadlineMs, [M | Acc]);
                M = {trace_ts, _Pid, _Tag, _Info, _Ret, _Ts} ->
                    collect_traces(DeadlineMs, [M | Acc])
            after Rem -> lists:reverse(Acc)
            end
    end.

match_call({trace, _Pid, call, {cdp_client, handle_call, _}}) -> true;
match_call({trace_ts, _Pid, call, {cdp_client, handle_call, _}, _}) -> true;
match_call(_) -> false.

match_return({trace, _Pid, return_from, {cdp_client, handle_call, _}, _}) -> true;
match_return({trace_ts, _Pid, return_from, {cdp_client, handle_call, _}, _Ret, _Ts}) -> true;
match_return(_) -> false.
