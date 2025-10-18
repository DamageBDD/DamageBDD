%% steps_cdp_web.erl
%% Higher-level web steps on top of cdp_client (CDP Page/Runtime).
%% Context is a map; we store cdp_pid and last CDP result as in steps_cdp.

-module(steps_cdp_web).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-export([step/6, test/0]).

%% ========== Step dispatcher ==========

step(_Cfg, Ctx, <<"Given">>, _N, ["I attach CDP"], _Body) ->
    attach(Ctx);

%% Open a URL and wait for load
step(_Cfg, Ctx, <<"When">>, _N, ["I open", Url], _Body) ->
    with_client(Ctx, fun(P) ->
        _ = call(P, <<"Page.enable">>, #{}),
        _ = call(P, <<"Runtime.enable">>, #{}),
        _ = call(P, <<"Page.navigate">>, #{<<"url">> => to_bin(Url)}),
        wait_load(P),
        ok
    end);

%% Wait for CSS selector to exist (and be visible-ish)
step(_Cfg, Ctx, <<"When">>, _N, ["I wait for", Sel], _Body) ->
    with_client(Ctx, fun(P) -> wait_selector(P, to_bin(Sel), 8000) end);

%% Click element by visible text (button/input submit supported)
step(_Cfg, Ctx, <<"When">>, _N, ["I click text", Text], _Body) ->
    with_client(Ctx, fun(P) -> click_by_text(P, to_bin(Text)) end);

%% Click by CSS selector
step(_Cfg, Ctx, <<"When">>, _N, ["I click", Sel], _Body) ->
    with_client(Ctx, fun(P) -> click_selector(P, to_bin(Sel)) end);

%% Type into CSS selector (set value + dispatch input events)
step(_Cfg, Ctx, <<"When">>, _N, ["I type", Text, "into", Sel], _Body) ->
    with_client(Ctx, fun(P) -> type_into(P, to_bin(Sel), to_bin(Text)) end);

%% Press Enter on focused element
step(_Cfg, Ctx, <<"When">>, _N, ["I press Enter"], _Body) ->
    with_client(Ctx, fun(P) -> press_enter(P) end);

%% Scroll element into view
step(_Cfg, Ctx, <<"When">>, _N, ["I scroll", Sel, "into view"], _Body) ->
    with_client(Ctx, fun(P) -> scroll_into_view(P, to_bin(Sel)) end);

%% Assert page contains text (case-sensitive)
step(_Cfg, Ctx, <<"Then">>, _N, ["the page should contain", Text], _Body) ->
    with_client(Ctx, fun(P) -> assert_contains(P, to_bin(Text)) end);
%% Wait until the page contains <Text> (polls until timeout)
step(_Cfg, Ctx, <<"When">>, _N, ["I wait until the page contains", Text], _Body) ->
    with_client(Ctx, fun(P) -> wait_until_contains(P, to_bin(Text), 8000) end);

%% Extract text of first element and stash in context as {var,Name}
step(_Cfg, Ctx, <<"When">>, _N, ["I save text of", Sel, "as", Name], _Body) ->
    with_client(Ctx, fun(P) ->
        case get_text(P, to_bin(Sel)) of
            {ok, V} -> {ok, maps:put({var, to_bin(Name)}, V, Ctx)};
            Error   -> Error
        end
    end).


%% ========== Public helpers for other step modules ==========

attach(Ctx0) ->
    case ensure_client(Ctx0) of
        {ok, C1} -> C1;
        {error, Why} -> maps:put(fail, to_bin(io_lib:format("CDP attach failed: ~p",[Why])), Ctx0)
    end.

with_client(Ctx0, Fun) when is_map(Ctx0), is_function(Fun, 1) ->
    case ensure_client(Ctx0) of
        {ok, C1} ->
            P = maps:get(cdp_pid, C1),
            case Fun(P) of
                ok                -> C1;
                {ok, CtxOrVal} when is_map(CtxOrVal) -> CtxOrVal;
                {ok, _Val}        -> C1;
                {error, Why}      -> maps:put(fail, to_bin(io_lib:format("CDP op failed: ~p",[Why])), C1);
                Other             -> maps:put(cdp_last, Other, C1)
            end;
        {error, Why} ->
            maps:put(fail, to_bin(io_lib:format("No CDP: ~p",[Why])), Ctx0)
    end.

%% ========== CDP mini-API ==========

call(Pid, Method, Params) ->
    cdp_client:call(Pid, Method, Params).

wait_load(Pid) ->
    call(Pid, <<"Runtime.evaluate">>,
         #{<<"expression">> => <<
              "new Promise(r=>{if(document.readyState==='complete')r(1);"
              "else addEventListener('load',()=>r(1),{once:true});})">>,
           <<"awaitPromise">> => true}).

wait_selector(Pid, Sel, TimeoutMs) ->
    Expr = iolist_to_binary([
      "(function(){const sel=", jsx:encode(Sel), ";",
      "const t=Date.now()+", integer_to_binary(TimeoutMs), ";",
      "function vis(el){const r=el.getBoundingClientRect();",
      "return r.width>0&&r.height>0;}",
      "return new Promise((res,rej)=>{(function poll(){",
      "let el=document.querySelector(sel);",
      "if(el&&vis(el)) return res(true);",
      "if(Date.now()>t) return rej('timeout');",
      "setTimeout(poll,100);})();});})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true}) of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.
%% wait until body.innerText includes Text (case-sensitive), within TimeoutMs
wait_until_contains(Pid, Text, TimeoutMs) ->
    Expr = iolist_to_binary([
      "(function(){",
      "  const t=", jsx:encode(Text), ";",
      "  const deadline=Date.now()+", integer_to_binary(TimeoutMs), ";",
      "  function has(){ return (document.body.innerText||'').includes(t); }",
      "  return new Promise((res,rej)=>{",
      "    (function poll(){",
      "      if(has()) return res(true);",
      "      if(Date.now()>deadline) return rej('timeout');",
      "      setTimeout(poll, 120);",
      "    })();",
      "  });",
      "})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true}) of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.

assert_contains(Pid, Text) ->
    TimeoutMs = 2000,
    Expr = iolist_to_binary([
      "(function(){",
      "  const t=", jsx:encode(Text), ";",
      "  const deadline=Date.now()+", integer_to_binary(TimeoutMs), ";",
      "  function has(){ return (document.body.innerText||'').includes(t); }",
      "  return new Promise((res,rej)=>{",
      "    (function poll(){",
      "      if(has()) return res(true);",
      "      if(Date.now()>deadline) return rej('timeout');",
      "      setTimeout(poll, 120);",
      "    })();",
      "  });",
      "})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true}) of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.

click_by_text(Pid, Text) ->
    Expr = iolist_to_binary([
      "(function(){const t=", jsx:encode(Text), ";",
      "const qs='button, [role=button], input[type=button], input[type=submit]';",
      "const els=[...document.querySelectorAll(qs)];",
      "const btn=els.find(el=>((el.textContent||'').trim()===t)||((el.value||'').trim()===t));",
      "if(!btn) return {ok:false,msg:'not found'}; btn.click(); return {ok:true};})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>,
              #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}) of
        #{<<"result">> := #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}}} -> ok;
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

click_selector(Pid, Sel) ->
    Expr = iolist_to_binary([
      "(function(){const s=", jsx:encode(Sel), ";",
      "const el=document.querySelector(s); if(!el) return {ok:false};",
      "el.scrollIntoView({block:'center'}); el.click(); return {ok:true};})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>,
              #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}) of
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

type_into(Pid, Sel, Text) ->
    Expr = iolist_to_binary([
      "(function(){const s=", jsx:encode(Sel), ", v=", jsx:encode(Text), ";",
      "const el=document.querySelector(s); if(!el) return {ok:false};",
      "el.focus(); el.value=''; el.dispatchEvent(new Event('input',{bubbles:true}));",
      "el.value=v; el.dispatchEvent(new Event('input',{bubbles:true})); return {ok:true};})()"
    ]),
    ?LOG_DEBUG("type_into: ~p",[Expr]),
    case call(Pid, <<"Runtime.evaluate">>,
              #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}) of
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

press_enter(Pid) ->
    %% Many sites react to Enter on the active element
    Expr = <<"document.activeElement && document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))">>,
    _ = call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"userGesture">> => true}),
    ok.

scroll_into_view(Pid, Sel) ->
    Expr = iolist_to_binary([
      "(function(){const s=", jsx:encode(Sel), ";",
      "const el=document.querySelector(s); if(!el) return false;",
      "el.scrollIntoView({block:'center'}); return true;})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true}) of
        #{<<"result">> := #{<<"value">> := true}} -> ok;
        _ -> {error, not_found}
    end.

get_text(Pid, Sel) ->
    Expr = iolist_to_binary([
      "(function(){const s=", jsx:encode(Sel), ";",
      "const el=document.querySelector(s); return el? (el.textContent||'').trim() : null;})()"
    ]),
    case call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true}) of
        #{<<"result">> := #{<<"value">> := V}} when is_binary(V) -> {ok, V};
        _ -> {error, not_found}
    end.


start_client_with_chrome(C0) ->

    Host = "127.0.0.1",
    Port = pick_free_high_port(),
    UDir = tmp_profile_dir(),
    ChromeBin = chrome_bin(),
    Cmd = io_lib:format("~s --headless=new --remote-debugging-address=127.0.0.1 "
                        "--remote-debugging-port=~p --user-data-dir=~s "
                        "--no-first-run --no-default-browser-check --disable-gpu about:blank",
                        [ChromeBin, Port, UDir]),
    ChromePort = open_port({spawn, lists:flatten(Cmd)}, [exit_status, hide]),
    case wait_devtools_ready(Host, Port, 8000) of
        ok ->
            case cdp_client:discover_ws(#{host => Host, port => Port, type => <<"page">>}) of
                {ok, WS} ->
                    case cdp_client:start_link(#{ws_url => WS, host => Host, port => Port}) of
                        {ok, Pid} ->
                            ok = cdp_client:enable_console(Pid),
                            {ok,
                             C0#{
                               cdp_pid => Pid,
                               cdp_endpoint => #{host => Host, port => Port},
                               chrome_os_port => ChromePort,
                               chrome_user_data_dir => UDir
                              }};
                        E -> {error, E}
                    end;
                E -> {error, E}
            end;
        {error, Why} ->
            catch port_close(ChromePort),
            {error, {chrome_not_ready, Why}}
    end.
%% ───────────────── Registry & constants ─────────────────
-define(CDP_REG, cdp_browser_registry).

ensure_reg() ->
    case ets:info(?CDP_REG) of
        undefined -> ets:new(?CDP_REG, [named_table, public, set]);
        _ -> ok
    end.

%% Record we keep in ETS: {KeyBin, #{host,port,chrome_pid,chrome_os_port,user_data_dir,cdp_pid}}
%% Note: chrome_pid is optional (we primarily health-check via /json/version).

%% ───────────────── Public API ─────────────────
ensure_client(C0) ->
    P = maps:get(cdp_pid, C0, undefined),
    case is_alive(P) of
        true  -> {ok, C0};
        false ->
            case maps:get(public_key, C0, undefined) of
                undefined -> start_client_with_chrome(C0);
                PubKey0   -> start_or_get_browser_for_key(to_bin(PubKey0), C0)
            end
    end.


%% ───────────────── Core logic ─────────────────
start_or_get_browser_for_key(PubKey, C0) ->
    ensure_reg(),
    case ets:lookup(?CDP_REG, PubKey) of
        [{_, Rec}] ->
            reuse_or_fix_session(PubKey, Rec, C0);
        [] ->
            %% First time for this public_key → launch browser + client
            launch_browser_and_client(PubKey, C0)
    end.

reuse_or_fix_session(PubKey, Rec, C0) ->
    Host = maps:get(host, Rec, "127.0.0.1"),
    Port = maps:get(port, Rec),
    case devtools_up(Host, Port) of
        true ->
            P0 = maps:get(cdp_pid, Rec, undefined),
            case is_alive(P0) of
                true ->
                    {ok, add_ctx_from_rec(C0, Rec)};
                false ->
                    case attach_cdp_client(Host, Port) of
                        {ok, Pid2} ->
                            Rec2 = Rec#{cdp_pid => Pid2},
                            ets:insert(?CDP_REG, {PubKey, Rec2}),
                            {ok, add_ctx_from_rec(C0, Rec2)};
                        E -> {error, E}
                    end
            end;
        false ->
            launch_browser_and_client(PubKey, C0)
    end.


launch_browser_and_client(PubKey, C0) ->
    Host = "127.0.0.1",
    Port = pick_free_high_port(),
    UDir = tmp_profile_dir(),
    ChromeBin = chrome_bin(),
    Cmd = io_lib:format("~s --headless=new --remote-debugging-address=127.0.0.1 "
                        "--remote-debugging-port=~p --user-data-dir=~s "
                        "--no-first-run --no-default-browser-check --disable-gpu about:blank",
                        [ChromeBin, Port, UDir]),
    ChromePort = open_port({spawn, lists:flatten(Cmd)}, [exit_status, hide]),
    case wait_devtools_ready(Host, Port, 10_000) of
        ok ->
            case attach_cdp_client(Host, Port) of
                {ok, Pid} ->
                    Rec = #{host => Host, port => Port,
                            chrome_os_port => ChromePort,
                            user_data_dir => UDir,
                            cdp_pid => Pid},
                    ets:insert(?CDP_REG, {PubKey, Rec}),
                    {ok, add_ctx_from_rec(C0, Rec)};
                E ->
                    catch port_close(ChromePort),
                    {error, E}
            end;
        {error, Why} ->
            catch port_close(ChromePort),
            {error, {chrome_not_ready, Why}}
    end.

attach_cdp_client(Host, Port) ->
    case cdp_client:discover_ws(#{host => Host, port => Port, type => <<"page">>}) of
        {ok, WS} ->
            case cdp_client:start_link(#{ws_url => WS, host => Host, port => Port}) of
                {ok, Pid} ->
                    ok = cdp_client:enable_console(Pid),
                    {ok, Pid};
                E -> E
            end;
        E -> E
    end.


add_ctx_from_rec(C0, Rec) ->
    C0#{
      cdp_pid => maps:get(cdp_pid, Rec),
      cdp_endpoint => #{host => maps:get(host, Rec), port => maps:get(port, Rec)},
      chrome_os_port => maps:get(chrome_os_port, Rec, undefined),
      chrome_user_data_dir => maps:get(user_data_dir, Rec, undefined)
    }.

%% ───────────────── Utilities ─────────────────
pick_free_high_port() ->
    {ok, S} = gen_tcp:listen(0, [binary,{active,false},{reuseaddr,true}]),
    {ok, {_, P}} = inet:sockname(S),
    ok = gen_tcp:close(S), P.

tmp_profile_dir() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    Dir  = filename:join(Base, io_lib:format("cdp_profile_~p", [erlang:unique_integer([monotonic, positive])])),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    lists:flatten(Dir).

chrome_bin() ->
    case os:getenv("CHROME_BIN") of
        false ->
            First = lists:filter(fun filelib:is_file/1,
                                 ["/usr/bin/google-chrome",
                                  "/usr/bin/google-chrome-stable",
                                  "/usr/bin/chromium",
                                  "/usr/bin/chromium-browser",
                                  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]),
            case First of [B|_] -> B; [] -> "google-chrome" end;
        B -> B
    end.

devtools_up(Host, Port) ->
    ok = ensure_inets(),
    Url = lists:flatten(io_lib:format("http://~s:~p/json/version", [Host, Port])),
    case httpc:request(get, {Url, []}, [{timeout, 2000}], []) of
        {ok, {{_,200,_},_,_}} -> true;
        _ -> false
    end.

wait_devtools_ready(Host, Port, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    ok = ensure_inets(),
    Url = io_lib:format("http://~s:~p/json/version", [Host, Port]),
    wait_loop(lists:flatten(Url), Deadline).

wait_loop(Url, Deadline) ->
    case httpc:request(get, {Url, []}, [{timeout, 2000}], []) of
        {ok, {{_,200,_},_,_}} -> ok;
        _ ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true  -> {error, timeout};
                false -> timer:sleep(150), wait_loop(Url, Deadline)
            end
    end.

ensure_inets() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> iolist_to_binary(L);
to_bin(I) when is_integer(I)-> integer_to_binary(I);
to_bin(Other)               -> iolist_to_binary(io_lib:format("~p",[Other])).
%% Safe liveness check without guards (and without badarg)
is_alive(P) ->
    case is_pid(P) of
        true  -> erlang:is_process_alive(P);
        false -> false
    end.


%% ========== quick smoke ==========
test() ->
    C0 = #{cdp_endpoint => #{host => "127.0.0.1", port => 9222}},
    C1 = step(#{}, C0, <<"Given">>, 1, ["I attach CDP"], <<>>),
    C2 = step(#{}, C1, <<"When">>, 2, ["I open","https://example.com"], <<>>),
    _C3 = step(#{}, C2, <<"Then">>, 3, ["the page should contain","Example Domain"], <<>>).
