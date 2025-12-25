%% steps_cdp_web.erl
%% Higher-level web steps on top of cdp_client (CDP Page/Runtime).
%% Context is a map; we store cdp_pid and last CDP result as in steps_cdp.

-module(steps_cdp_web).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-export([step/6, test/0]).
-import(damage_utils, [to_bin/1]).

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
            Error -> Error
        end
    end);
%% Compare element sizes by CSS selectors (exact match)
step(_Cfg, Ctx, <<"Then">>, _N, ["the element", SelA, "should be the same size as", SelB], _Body) ->
    with_client(Ctx, fun(P) -> assert_same_size(P, to_bin(SelA), to_bin(SelB), 0.0) end);
%% Compare element sizes by CSS selectors (allow +/- TolerancePx)
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["the element", SelA, "should be the same size as", SelB, "within", TolPx0, "px"],
    _Body
) ->
    TolPx = list_to_float(TolPx0),
    with_client(Ctx, fun(P) -> assert_same_size(P, to_bin(SelA), to_bin(SelB), TolPx) end);
%% -------------------------------------------------------------------
%% Text alignment (center)
%% -------------------------------------------------------------------

%% Strict: CSS text-align:center
step(_Cfg, Ctx, <<"Then">>, _N, ["the text of element", Sel, "should be center aligned"], _Body) ->
    with_client(Ctx, fun(P) -> assert_text_align_center(P, to_bin(Sel)) end);
%% Practical: "visually centered" for flex/grid/inline (checks computed layout)
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["the text of element", Sel, "should be visually centered within", TolPx0, "px"],
    _Body
) ->
    TolPx = list_to_float(TolPx0),
    with_client(Ctx, fun(P) -> assert_text_visually_centered(P, to_bin(Sel), TolPx) end);
%% -------------------------------------------------------------------
%% Pairwise alignment between elements
%% -------------------------------------------------------------------

%% Horizontal: left/center/right aligned
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["the elements", SelA, "and", SelB, "should be horizontally aligned at", Anchor],
    _Body
) ->
    with_client(Ctx, fun(P) -> assert_halign(P, to_bin(SelA), to_bin(SelB), to_bin(Anchor), 0.0) end);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    [
        "the elements",
        SelA,
        "and",
        SelB,
        "should be horizontally aligned at",
        Anchor,
        "within",
        TolPx0,
        "px"
    ],
    _Body
) ->
    TolPx = list_to_float(TolPx0),
    with_client(Ctx, fun(P) ->
        assert_halign(P, to_bin(SelA), to_bin(SelB), to_bin(Anchor), TolPx)
    end);
%% Vertical: top/center/bottom aligned
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["the elements", SelA, "and", SelB, "should be vertically aligned at", Anchor],
    _Body
) ->
    with_client(Ctx, fun(P) -> assert_valign(P, to_bin(SelA), to_bin(SelB), to_bin(Anchor), 0.0) end);
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    [
        "the elements",
        SelA,
        "and",
        SelB,
        "should be vertically aligned at",
        Anchor,
        "within",
        TolPx0,
        "px"
    ],
    _Body
) ->
    TolPx = list_to_float(TolPx0),
    with_client(Ctx, fun(P) ->
        assert_valign(P, to_bin(SelA), to_bin(SelB), to_bin(Anchor), TolPx)
    end).

%% ========== Public helpers for other step modules ==========
attach(Ctx0) ->
    case steps_cdp:ensure_client(Ctx0) of
        {ok, C1} -> C1;
        {error, Why} -> maps:put(fail, to_bin(io_lib:format("CDP attach failed: ~p", [Why])), Ctx0)
    end.

with_client(Ctx0, Fun) when is_map(Ctx0), is_function(Fun, 1) ->
    case steps_cdp:ensure_client(Ctx0) of
        {ok, C1} ->
            P = maps:get(cdp_pid, C1),
            case Fun(P) of
                ok ->
                    C1;
                {ok, CtxOrVal} when is_map(CtxOrVal) -> CtxOrVal;
                {ok, _Val} ->
                    C1;
                {error, #{
                    <<"id">> := _,
                    <<"result">> :=
                        #{
                            <<"result">> :=
                                #{
                                    <<"type">> := _,
                                    <<"value">> :=
                                        #{
                                            <<"msg">> := Why,
                                            <<"ok">> := false
                                        }
                                }
                        }
                }} ->
                    maps:put(fail, Why, C1);
                {error, Unknown} ->
                    ?LOG_ERROR("Unknown CDP step error ~p", [Unknown]),
                    maps:put(fail, <<"unknown error">>, C1);
                Other ->
                    maps:put(cdp_last, Other, C1)
            end;
        {error, Why} ->
            maps:put(fail, to_bin(io_lib:format("No CDP: ~p", [Why])), Ctx0)
    end.

%% ========== CDP mini-API ==========

call(Pid, Method, Params) ->
    cdp_client:call(Pid, Method, Params).

wait_load(Pid) ->
    call(
        Pid,
        <<"Runtime.evaluate">>,
        #{
            <<"expression">> => <<
                "new Promise(r=>{if(document.readyState==='complete')r(1);"
                "else addEventListener('load',()=>r(1),{once:true});})"
            >>,
            <<"awaitPromise">> => true
        }
    ).

wait_selector(Pid, Sel, TimeoutMs) ->
    Expr = iolist_to_binary([
        "(function(){const sel=",
        jsx:encode(Sel),
        ";",
        "const t=Date.now()+",
        integer_to_binary(TimeoutMs),
        ";",
        "function vis(el){const r=el.getBoundingClientRect();",
        "return r.width>0&&r.height>0;}",
        "return new Promise((res,rej)=>{(function poll(){",
        "let el=document.querySelector(sel);",
        "if(el&&vis(el)) return res(true);",
        "if(Date.now()>t) return rej('timeout');",
        "setTimeout(poll,100);})();});})()"
    ]),
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true})
    of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.
%% wait until body.innerText includes Text (case-sensitive), within TimeoutMs
wait_until_contains(Pid, Text, TimeoutMs) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const t=",
        jsx:encode(Text),
        ";",
        "  const deadline=Date.now()+",
        integer_to_binary(TimeoutMs),
        ";",
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
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true})
    of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.

assert_contains(Pid, Text) ->
    TimeoutMs = 2000,
    Expr = iolist_to_binary([
        "(function(){",
        "  const t=",
        jsx:encode(Text),
        ";",
        "  const deadline=Date.now()+",
        integer_to_binary(TimeoutMs),
        ";",
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
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"awaitPromise">> => true})
    of
        #{<<"result">> := _} -> ok;
        Other -> {error, Other}
    end.

click_by_text(Pid, Text) ->
    Expr = iolist_to_binary([
        "(function(){const t=",
        jsx:encode(Text),
        ";",
        "const qs='button, [role=button], input[type=button], input[type=submit]';",
        "const els=[...document.querySelectorAll(qs)];",
        "const btn=els.find(el=>((el.textContent||'').trim()===t)||((el.value||'').trim()===t));",
        "if(!btn) return {ok:false,msg:'not found'}; btn.click(); return {ok:true};})()"
    ]),
    case
        call(
            Pid,
            <<"Runtime.evaluate">>,
            #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}
        )
    of
        #{<<"result">> := #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}}} -> ok;
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

click_selector(Pid, Sel) ->
    Expr = iolist_to_binary([
        "(function(){const s=",
        jsx:encode(Sel),
        ";",
        "const el=document.querySelector(s); if(!el) return {ok:false, msg: `not found: ${s}`};",
        "el.scrollIntoView({block:'center'}); el.click(); return {ok:true};})()"
    ]),
    case
        call(
            Pid,
            <<"Runtime.evaluate">>,
            #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}
        )
    of
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

type_into(Pid, Sel, Text) ->
    Expr = iolist_to_binary([
        "(function(){const s=",
        jsx:encode(Sel),
        ", v=",
        jsx:encode(Text),
        ";",
        "const el=document.querySelector(s); if(!el) return {ok:false, msg: `not found: ${s}`};",
        "el.focus(); el.value=''; el.dispatchEvent(new Event('input',{bubbles:true}));",
        "el.value=v; el.dispatchEvent(new Event('input',{bubbles:true})); return {ok:true};})()"
    ]),
    ?LOG_DEBUG("type_into: ~p", [Expr]),
    case
        call(
            Pid,
            <<"Runtime.evaluate">>,
            #{<<"expression">> => Expr, <<"returnByValue">> => true, <<"userGesture">> => true}
        )
    of
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        Other -> {error, Other}
    end.

press_enter(Pid) ->
    %% Many sites react to Enter on the active element
    Expr =
        <<"document.activeElement && document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))">>,
    _ = call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"userGesture">> => true}),
    ok.

scroll_into_view(Pid, Sel) ->
    Expr = iolist_to_binary([
        "(function(){const s=",
        jsx:encode(Sel),
        ";",
        "const el=document.querySelector(s); if(!el) return false;",
        "el.scrollIntoView({block:'center'}); return true;})()"
    ]),
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true})
    of
        #{<<"result">> := #{<<"value">> := true}} -> ok;
        _ -> {error, not_found}
    end.

get_text(Pid, Sel) ->
    Expr = iolist_to_binary([
        "(function(){const s=",
        jsx:encode(Sel),
        ";",
        "const el=document.querySelector(s); return el? (el.textContent||'').trim() : null;})()"
    ]),
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true})
    of
        #{<<"result">> := #{<<"value">> := V}} when is_binary(V) -> {ok, V};
        _ -> {error, not_found}
    end.

assert_same_size(Pid, SelA, SelB, TolPx) when is_binary(SelA), is_binary(SelB) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const aSel=",
        jsx:encode(SelA),
        ";",
        "  const bSel=",
        jsx:encode(SelB),
        ";",
        "  const a=document.querySelector(aSel);",
        "  const b=document.querySelector(bSel);",
        "  if(!a) return {ok:false,msg:`not found: ${aSel}`};",
        "  if(!b) return {ok:false,msg:`not found: ${bSel}`};",
        "  const ar=a.getBoundingClientRect();",
        "  const br=b.getBoundingClientRect();",
        "  const aw=Math.round(ar.width*100)/100;",
        "  const ah=Math.round(ar.height*100)/100;",
        "  const bw=Math.round(br.width*100)/100;",
        "  const bh=Math.round(br.height*100)/100;",
        "  return {ok:true,a:{w:aw,h:ah},b:{w:bw,h:bh}};",
        "})()"
    ]),
    case
        call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true})
    of
        #{
            <<"result">> := #{
                <<"value">> := #{
                    <<"ok">> := true,
                    <<"a">> := #{<<"w">> := AW, <<"h">> := AH},
                    <<"b">> := #{<<"w">> := BW, <<"h">> := BH}
                }
            }
        } ->
            DW = abs(float(AW) - float(BW)),
            DH = abs(float(AH) - float(BH)),
            case (DW =< TolPx) andalso (DH =< TolPx) of
                true ->
                    ok;
                false ->
                    {error, #{
                        <<"result">> => #{
                            <<"result">> => #{
                                <<"value">> => #{
                                    <<"ok">> => false,
                                    <<"msg">> =>
                                        iolist_to_binary(
                                            io_lib:format(
                                                "size mismatch ~s vs ~s (A=~.2fx~.2f, B=~.2fx~.2f, tol=~.2f, dw=~.2f, dh=~.2f)",
                                                [
                                                    SelA,
                                                    SelB,
                                                    float(AW),
                                                    float(AH),
                                                    float(BW),
                                                    float(BH),
                                                    TolPx,
                                                    DW,
                                                    DH
                                                ]
                                            )
                                        )
                                }
                            }
                        }
                    }}
            end;
        Other ->
            {error, Other}
    end.
%% ---------- text-align:center (strict CSS) ----------
assert_text_align_center(Pid, Sel) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const sel=",
        jsx:encode(Sel),
        ";",
        "  const el=document.querySelector(sel);",
        "  if(!el) return {ok:false,msg:`not found: ${sel}`};",
        "  const cs=getComputedStyle(el);",
        "  const ta=(cs.textAlign||'').toLowerCase();",
        "  return {ok:true,textAlign:ta};",
        "})()"
    ]),
    case eval_value(Pid, Expr) of
        #{<<"ok">> := true, <<"textAlign">> := <<"center">>} ->
            ok;
        #{<<"ok">> := true, <<"textAlign">> := TA} ->
            fail_msg(
                iolist_to_binary(
                    io_lib:format("expected text-align:center for ~s, got ~p", [Sel, TA])
                )
            );
        #{<<"ok">> := false, <<"msg">> := Msg} ->
            fail_msg(Msg);
        Other ->
            {error, Other}
    end.

%% ---------- visually centered text (layout-based) ----------
%% This checks the center X of the element's rendered text range against the element's content box center.
assert_text_visually_centered(Pid, Sel, TolPx) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const sel=",
        jsx:encode(Sel),
        ";",
        "  const el=document.querySelector(sel);",
        "  if(!el) return {ok:false,msg:`not found: ${sel}`};",
        "  const r=el.getBoundingClientRect();",
        "  const cs=getComputedStyle(el);",
        "  const pl=parseFloat(cs.paddingLeft)||0;",
        "  const pr=parseFloat(cs.paddingRight)||0;",
        "  const contentLeft=r.left+pl;",
        "  const contentRight=r.right-pr;",
        "  const contentCenter=(contentLeft+contentRight)/2;",
        "  let textRect=null;",
        "  try {",
        "    const range=document.createRange();",
        "    range.selectNodeContents(el);",
        "    const rects=range.getClientRects();",
        "    if(rects && rects.length>0){",
        "      let left=Infinity,right=-Infinity,top=Infinity,bottom=-Infinity;",
        "      for(const rr of rects){",
        "        left=Math.min(left, rr.left); right=Math.max(right, rr.right);",
        "        top=Math.min(top, rr.top); bottom=Math.max(bottom, rr.bottom);",
        "      }",
        "      textRect={left,right,top,bottom,center:(left+right)/2};",
        "    }",
        "  } catch(e) {}",
        "  if(!textRect){",
        "    return {ok:false,msg:`no measurable text rect for ${sel}`};",
        "  }",
        "  return {ok:true, contentCenter, textCenter:textRect.center};",
        "})()"
    ]),
    case eval_value(Pid, Expr) of
        #{<<"ok">> := true, <<"contentCenter">> := CC, <<"textCenter">> := TC} ->
            Diff = abs(float(CC) - float(TC)),
            case Diff =< TolPx of
                true ->
                    ok;
                false ->
                    fail_msg(
                        iolist_to_binary(
                            io_lib:format("text not centered for ~s (diff=~.2fpx tol=~.2fpx)", [
                                Sel, Diff, TolPx
                            ])
                        )
                    )
            end;
        #{<<"ok">> := false, <<"msg">> := Msg} ->
            fail_msg(Msg);
        Other ->
            {error, Other}
    end.

%% ---------- horizontal alignment (left/center/right) ----------
assert_halign(Pid, SelA, SelB, Anchor, TolPx) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const aSel=",
        jsx:encode(SelA),
        ";",
        "  const bSel=",
        jsx:encode(SelB),
        ";",
        "  const anchor=",
        jsx:encode(Anchor),
        ";",
        "  const a=document.querySelector(aSel);",
        "  const b=document.querySelector(bSel);",
        "  if(!a) return {ok:false,msg:`not found: ${aSel}`};",
        "  if(!b) return {ok:false,msg:`not found: ${bSel}`};",
        "  const ar=a.getBoundingClientRect();",
        "  const br=b.getBoundingClientRect();",
        "  function x(r){",
        "    if(anchor==='left') return r.left;",
        "    if(anchor==='right') return r.right;",
        "    return (r.left+r.right)/2; /* center */",
        "  }",
        "  return {ok:true, ax:x(ar), bx:x(br)};",
        "})()"
    ]),
    case eval_value(Pid, Expr) of
        #{<<"ok">> := true, <<"ax">> := AX, <<"bx">> := BX} ->
            Diff = abs(float(AX) - float(BX)),
            case Diff =< TolPx of
                true ->
                    ok;
                false ->
                    fail_msg(
                        iolist_to_binary(
                            io_lib:format(
                                "horizontal misalignment (~s) ~s vs ~s (diff=~.2fpx tol=~.2fpx)",
                                [Anchor, SelA, SelB, Diff, TolPx]
                            )
                        )
                    )
            end;
        #{<<"ok">> := false, <<"msg">> := Msg} ->
            fail_msg(Msg);
        Other ->
            {error, Other}
    end.

%% ---------- vertical alignment (top/center/bottom) ----------
assert_valign(Pid, SelA, SelB, Anchor, TolPx) ->
    Expr = iolist_to_binary([
        "(function(){",
        "  const aSel=",
        jsx:encode(SelA),
        ";",
        "  const bSel=",
        jsx:encode(SelB),
        ";",
        "  const anchor=",
        jsx:encode(Anchor),
        ";",
        "  const a=document.querySelector(aSel);",
        "  const b=document.querySelector(bSel);",
        "  if(!a) return {ok:false,msg:`not found: ${aSel}`};",
        "  if(!b) return {ok:false,msg:`not found: ${bSel}`};",
        "  const ar=a.getBoundingClientRect();",
        "  const br=b.getBoundingClientRect();",
        "  function y(r){",
        "    if(anchor==='top') return r.top;",
        "    if(anchor==='bottom') return r.bottom;",
        "    return (r.top+r.bottom)/2; /* center */",
        "  }",
        "  return {ok:true, ay:y(ar), by:y(br)};",
        "})()"
    ]),
    case eval_value(Pid, Expr) of
        #{<<"ok">> := true, <<"ay">> := AY, <<"by">> := BY} ->
            Diff = abs(float(AY) - float(BY)),
            case Diff =< TolPx of
                true ->
                    ok;
                false ->
                    fail_msg(
                        iolist_to_binary(
                            io_lib:format(
                                "vertical misalignment (~s) ~s vs ~s (diff=~.2fpx tol=~.2fpx)",
                                [Anchor, SelA, SelB, Diff, TolPx]
                            )
                        )
                    )
            end;
        #{<<"ok">> := false, <<"msg">> := Msg} ->
            fail_msg(Msg);
        Other ->
            {error, Other}
    end.

%% ---------- shared eval helper ----------
eval_value(Pid, Expr) ->
    Res = call(Pid, <<"Runtime.evaluate">>, #{<<"expression">> => Expr, <<"returnByValue">> => true}),
    case Res of
        #{<<"result">> := #{<<"value">> := Val}} -> Val;
        _ -> Res
    end.

fail_msg(MsgBin) when is_binary(MsgBin) ->
    {error, #{
        <<"result">> => #{
            <<"result">> => #{<<"value">> => #{<<"ok">> => false, <<"msg">> => MsgBin}}
        }
    }}.

%% Record we keep in ETS: {KeyBin, #{host,port,chrome_pid,chrome_os_port,user_data_dir,cdp_pid}}
%% Note: chrome_pid is optional (we primarily health-check via /json/version).

test() ->
    C0 = #{cdp_endpoint => #{host => "127.0.0.1", port => 9222}},
    C1 = step(#{}, C0, <<"Given">>, 1, ["I attach CDP"], <<>>),
    C2 = step(#{}, C1, <<"When">>, 2, ["I open", "https://example.com"], <<>>),
    _C3 = step(#{}, C2, <<"Then">>, 3, ["the page should contain", "Example Domain"], <<>>).
