%% browser_mgr.erl
%% One Chrome per public_key, launched & supervised via erlexec.
%% Provides a DevTools endpoint (host/port) and keeps/restarts it if needed.

-module(browser_mgr).
-include_lib("kernel/include/logger.hrl").
-include_lib("browser_mgr.hrl").

-export([
  ensure_started/0,
  ensure_session/1,            % ensure_session(Ctx|#{public_key:=..., run_dir:=...}) -> {ok, Rec}|{error,Why}
  stop_for_key/1,
  stop_all/0,
  info/1
]).

-define(TAB, cdp_browser_registry).


%%% ───────────────── Public ─────────────────

ensure_started() ->
  %% Start erlexec once (harmless if already started).
  case application:ensure_all_started(erlexec) of
    {ok, _} -> ok;
    {error, {already_started, _}} -> ok;
    Other -> Other
  end,
  ensure_table().

ensure_session(C0) when is_map(C0) ->
  ok = ensure_started(),
  Key0 = maps:get(public_key, C0, <<"default">>),
  Key  = to_bin(Key0),
  RunDir = maps:get(run_dir, C0, "/tmp"),
  case ets:lookup(?TAB, Key) of
    [{_, Rec}] ->
      case devtools_up(Rec#rec.host, Rec#rec.port) of
        true  -> {ok, Rec};
        false ->
          ?LOG_WARNING("Browser for ~p down; relaunching", [Key]),
          launch(Key, RunDir)
      end;
    [] ->
      launch(Key, RunDir)
  end.

stop_for_key(Key0) ->
  ok = ensure_started(),
  Key = to_bin(Key0),
  case ets:take(?TAB, Key) of
    [{_, Rec}] -> kill_rec(Rec), ok;
    [] -> ok
  end.

stop_all() ->
  ok = ensure_started(),
  lists:foreach(fun({_K, Rec}) -> kill_rec(Rec) end, ets:tab2list(?TAB)),
  ets:delete_all_objects(?TAB),
  ok.

info(Key0) ->
  ok = ensure_started(),
  Key = to_bin(Key0),
  case ets:lookup(?TAB, Key) of
    [{_, Rec}] -> Rec;
    [] -> undefined
  end.

%%% ───────────────── Internal ─────────────────

ensure_table() ->
  case ets:info(?TAB) of
    undefined -> ets:new(?TAB, [named_table, public, set]); _ -> ok
  end.

launch(Key, RunDir) ->
  Host = "127.0.0.1",
  Port = pick_free_port(),
  UDir = tmp_profile_dir(),
  Chrome = chrome_bin(),
  Log   = filename:join(RunDir, io_lib:format("chrome_~p.log", [Port])),
  Args  = [
    "--headless=new",
    "--remote-debugging-address=127.0.0.1",
    io_lib:format("--remote-debugging-port=~p", [Port]),
    io_lib:format("--user-data-dir=~s", [UDir]),
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "about:blank"
  ],
  ExecOpts = [
    monitor,
    {kill_group, true},                % kill grandchildren when erlexec stops (:contentReference[oaicite:4]{index=4})
    {cd, RunDir},
    {stdout, {file, Log}},
    {stderr, {file, Log}}
  ],
  case exec:run_link(Chrome, [{args, Args} | ExecOpts]) of
    {ok, ExecPid, OsPid} ->
      case wait_devtools_ready(Host, Port, 10_000) of
        ok ->
          Rec = #rec{key=Key, host=Host, port=Port, os_pid=OsPid, exec_pid=ExecPid,
                     user_data_dir=lists:flatten(UDir), log_file=lists:flatten(Log)},
          ets:insert(?TAB, {Key, Rec}),
          {ok, Rec};
        {error, Why} ->
          exec:kill(ExecPid),
          {error, {chrome_not_ready, Why}}
      end;
    Error ->
      Error
  end.

kill_rec(#rec{exec_pid=ExecPid}) when is_pid(ExecPid) ->
  catch exec:kill(ExecPid), ok;
kill_rec(_) -> ok.

devtools_up(Host, Port) ->
  ok = ensure_inets(),
  Url = lists:flatten(io_lib:format("http://~s:~p/json/version", [Host, Port])),
  case httpc:request(get, {Url, []}, [{timeout, 1500}], []) of
    {ok, {{_,200,_},_,_}} -> true;
    _ -> false
  end.

wait_devtools_ready(Host, Port, TimeoutMs) ->
  Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
  ok = ensure_inets(),
  Url = lists:flatten(io_lib:format("http://~s:~p/json/version", [Host, Port])),
  await_loop(Url, Deadline).

await_loop(Url, Deadline) ->
  case httpc:request(get, {Url, []}, [{timeout, 1500}], []) of
    {ok, {{_,200,_},_,_}} -> ok;
    _ ->
      case erlang:monotonic_time(millisecond) >= Deadline of
        true  -> {error, timeout};
        false -> timer:sleep(120), await_loop(Url, Deadline)
      end
  end.

pick_free_port() ->
  {ok, S} = gen_tcp:listen(0, [binary,{active,false},{reuseaddr,true}]),
  {ok, {_, P}} = inet:sockname(S), gen_tcp:close(S), P.

tmp_profile_dir() ->
  Base = case os:getenv("TMPDIR") of false -> "/tmp"; D0 -> D0 end,
  D = filename:join(Base, io_lib:format("cdp_profile_~p",[erlang:unique_integer([monotonic,positive])])),
  ok = filelib:ensure_dir(filename:join(D,"x")),
  D.

chrome_bin() ->
  case os:getenv("CHROME_BIN") of
    false ->
      First = lists:filter(fun filelib:is_file/1,
        ["/usr/bin/google-chrome","/usr/bin/google-chrome-stable",
         "/usr/bin/chromium","/usr/bin/chromium-browser",
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]),
      case First of [B|_] -> B; [] -> "google-chrome" end;
    B -> B
  end.

ensure_inets() ->
  case application:ensure_all_started(inets) of
    {ok,_} -> ok; {error,{already_started,_}} -> ok
  end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> iolist_to_binary(L);
to_bin(I) when is_integer(I)-> integer_to_binary(I);
to_bin(X)                   -> iolist_to_binary(io_lib:format("~p",[X])).
