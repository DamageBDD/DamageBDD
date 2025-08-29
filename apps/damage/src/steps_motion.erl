%% file: steps_motion.erl
%% Motion-detection steps for DAMAGE/BDD
%% Depends on wifi_motion.erl (the gen_server shared earlier)

-module(steps_motion).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

-define(DEFAULT_IFACE, "wlan0").
-define(DEFAULT_INTERVAL, 500).
-define(DEFAULT_ALPHA, 0.2).
-define(DEFAULT_KSIGMA, 3.0).
-define(TAG_KEEP, keep_for_asserts).

%% ------------- Public Step Entry -------------

%% step(Config, Context, PhaseBin, Nth, Tokens, Line)
step(_Cfg, Ctx, <<"Given">>, _N, ["I enable wifi motion on", Iface], _) ->
    start_motion(Ctx, #{iface => Iface});
step(_Cfg, Ctx, <<"Given">>, _N, ["I enable wifi motion"], _) ->
    start_motion(Ctx, #{}); % defaults

step(_Cfg, Ctx, <<"Given">>, _N,
     ["I enable wifi motion on", Iface, "with interval", IntervalMsStr,
      "alpha", AlphaStr, "k-sigma", KSigmaStr], _) ->
    {IntervalMs, Alpha, KSigma} =
        {list_to_integer(IntervalMsStr), list_to_float(AlphaStr), list_to_float(KSigmaStr)},
    start_motion(Ctx, #{iface => Iface, interval_ms => IntervalMs, alpha => Alpha, k_sigma => KSigma});

step(_Cfg, Ctx, <<"When">>, _N, ["I wait for motion for", MsStr, "ms"], _) ->
    wait_for_motion(Ctx, list_to_integer(MsStr), false);

step(_Cfg, Ctx, <<"Then">>, _N, ["motion must be detected within", MsStr, "ms"], _) ->
    wait_for_motion(Ctx, list_to_integer(MsStr), true);

step(_Cfg, Ctx, <<"Then">>, _N, ["no motion must be detected within", MsStr, "ms"], _) ->
    wait_for_no_motion(Ctx, list_to_integer(MsStr));

step(_Cfg, Ctx, <<"When">>, _N, ["I clear motion events"], _) ->
    maps:remove(motion_last, Ctx);

step(_Cfg, Ctx, <<"Then">>, _N, ["the last motion mac must be", Mac], _) ->
    case maps:get(motion_last, Ctx, undefined) of
        undefined ->
            fail(Ctx, "No motion captured; cannot assert MAC");
        #{mac := Mac} ->
            Ctx;
        #{mac := Other} ->
            fail(Ctx, damage_utils:strf("Expected MAC ~p but got ~p", [Mac, Other]))
    end;

step(_Cfg, Ctx, <<"Then">>, _N, ["the last motion rssi must be >=", RssiStr], _) ->
    RssiMin = list_to_integer(RssiStr),
    case maps:get(motion_last, Ctx, undefined) of
        undefined ->
            fail(Ctx, "No motion captured; cannot assert RSSI");
        #{rssi := Rssi} when Rssi >= RssiMin ->
            Ctx;
        #{rssi := Rssi} ->
            fail(Ctx, damage_utils:strf("Expected RSSI >= ~p but got ~p", [RssiMin, Rssi]))
    end;

%% Fallback (unhandled)
step(_Cfg, Ctx, _Phase, _N, _Tokens, _Line) ->
    Ctx.

%% ------------- Helpers -------------

start_motion(Ctx, Opts0) ->
    Iface    = maps:get(iface, Opts0, ?DEFAULT_IFACE),
    Interval = maps:get(interval_ms, Opts0, ?DEFAULT_INTERVAL),
    Alpha    = maps:get(alpha, Opts0, ?DEFAULT_ALPHA),
    KSigma   = maps:get(k_sigma, Opts0, ?DEFAULT_KSIGMA),

    %% Ensure singleton per test context
    case maps:get(wifi_motion_pid, Ctx, undefined) of
        Pid when is_pid(Pid) ->
            ok = wifi_motion:subscribe(),
            Ctx;
        _ ->
            case whereis(wifi_motion) of
                undefined ->
                    case wifi_motion:start_link(#{
                           iface => Iface, interval_ms => Interval,
                           alpha => Alpha, k_sigma => KSigma
                       }) of
                        {ok, _Pid} ->
                            ok = wifi_motion:subscribe(),
                            Ctx#{wifi_motion_pid => whereis(wifi_motion),
                                 wifi_motion_iface => Iface};
                        Error ->
                            fail(Ctx, damage_utils:strf("wifi_motion start failed: ~p", [Error]))
                    end;
                _Pid ->
                    ok = wifi_motion:subscribe(),
                    Ctx#{wifi_motion_pid => whereis(wifi_motion),
                         wifi_motion_iface => Iface}
            end
    end.

wait_for_motion(Ctx, TimeoutMs, MustAssert) ->
    Ref = make_ref(),
    Self = self(),
    %% transient mailbox cleaner for stale motion so tests can choose to clear or not
    AfterFun = fun(Event) ->
        %% Keep last event in Context for later assertions
        EvMap = event_to_map(Event),
        Self ! {?TAG_KEEP, Ref, EvMap}
    end,
    Motion = receive
                 {motion, ?TAG_KEEP}=Ev -> AfterFun(Ev), Ev
             after TimeoutMs ->
                 timeout
             end,
    case {MustAssert, Motion} of
        {true, timeout} ->
            fail(Ctx, damage_utils:strf("No motion within ~p ms", [TimeoutMs]));
        {false, timeout} ->
            Ctx;
        {_, {motion, _}} ->
            %% pull back the stored EvMap for persistence
            EvMap = receive {?TAG_KEEP, Ref, M} -> M end,
            Ctx#{motion_last => EvMap}
    end.

wait_for_no_motion(Ctx, TimeoutMs) ->
    case wait_for_motion(Ctx, TimeoutMs, false) of
        #{motion_last := _Ev} = _Ctx1 ->
            fail(Ctx, damage_utils:strf("Unexpected motion within ~p ms", [TimeoutMs]));
        CtxNoEv ->
            CtxNoEv
    end.

event_to_map({motion, Map}) when is_map(Map) ->
    Map;
event_to_map(Other) ->
    %% be defensive in case upstream format changes
    #{raw => Other, at => os:system_time(millisecond)}.

fail(Ctx, Msg) ->
    ?LOG_DEBUG("steps_motion fail: ~ts", [Msg]),
    maps:put(fail, Msg, Ctx).
