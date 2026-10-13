%%%-------------------------------------------------------------------
%%%  steps_herbstluftwm.erl
%%%  DamageBDD step module for herbstluftwm behaviour as BDD
%%%-------------------------------------------------------------------
-module(steps_herbstluftwm).
-author("DamageBDD").
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-behaviour(gen_server).

-export([step/6]).
-export([
    start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3
]).

%% Public helpers
-export([hook/1, restart/0]).

%%--------------------------------------------------------------------
%% Hook that is called by hlwm_events whenever a parsed event arrives.
%% We keep a small ring buffer of recent events in the process state and
%% also allow other modules to subscribe via gproc hooks if needed later.
%%--------------------------------------------------------------------

hook(Evt = #{type := _Type}) ->
    case gproc:lookup_local_name({?MODULE, monitor}) of
        undefined -> ?LOG_WARNING("hlwm monitor not started ~p", [Evt]);
        Pid -> ok = gen_server:call(Pid, {push_event, Evt})
    end.

restart() ->
    case gproc:lookup_local_name({?MODULE, monitor}) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end.

start_link(Context) -> gen_server:start_link(?MODULE, [Context], []).

init([Context]) ->
    process_flag(trap_exit, true),
    %% Lazily start the event reader (hlwm_events) and register hook
    Id = hlwm,
    Pid = hlwm_events:get_or_start(Context),
    ok = gen_server:call(Pid, {add_hook, Id, fun ?MODULE:hook/1}),
    gproc:reg({n, l, {?MODULE, monitor}}),
    {ok, maps:merge(#{events => [], max_events => 256}, Context)}.

handle_call({push_event, Evt}, _From, #{events := Evts, max_events := Max} = S) ->
    Evts1 =
        case length(Evts) < Max of
            true -> [Evt | Evts];
            false -> [Evt | lists:sublist(Evts, Max - 1)]
        end,
    {reply, ok, S#{events := Evts1}};
handle_call(_Any, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(Reason, _S) ->
    ?LOG_INFO("steps_herbstluftwm terminating ~p", [Reason]),
    ok.
code_change(_V, S, _E) -> {ok, S}.

%%--------------------------------------------------------------------
%% Step definitions
%%--------------------------------------------------------------------

%% Boot the event monitor and stash the pid in context
step(_Cfg, Ctx, _Kw, _N, ["I start herbstluftwm event monitor"], _Body) ->
    {ok, Pid} =
        case gproc:lookup_local_name({?MODULE, monitor}) of
            undefined -> start_link(Ctx);
            P -> {ok, P}
        end,
    maps:put(hlwm_monitor, Pid, Ctx);
%% Assert: last event type equals X
step(_Cfg, Ctx, <<"Then">>, _N, ["the last hlwm event type should be", Type], _Body) ->
    Pid = ensure_monitor(),
    Events = gen_server:call(Pid, {get, events}, 5000) orelse [],
    case Events of
        [#{type := Type} | _] -> Ctx;
        [H | _] -> maps:put(fail, damage_utils:strf("last event ~p not ~p", [H, Type]), Ctx);
        [] -> maps:put(fail, "no events captured", Ctx)
    end;
%% Assert: within N seconds an event TYPE occurs (polling the ring buffer)
step(_Cfg, Ctx, <<"Then">>, _N, ["within", Secs, "seconds hlwm should see event", Type], _Body) ->
    Pid = ensure_monitor(),
    Timeout = list_to_integer(Secs),
    case
        wait_for_event(
            Pid,
            fun
                (#{type := T}) -> T =:= Type;
                (_) -> false
            end,
            Timeout
        )
    of
        ok -> Ctx;
        timeout -> maps:put(fail, damage_utils:strf("no %s within %s s", [Type, Secs]), Ctx)
    end;
%% Assert: the focused title contains text
step(_Cfg, Ctx, <<"Then">>, _N, ["the focused window title must contain", Text], _Body) ->
    Pid = ensure_monitor(),
    Title = query(Pid, focused_title),
    case string:find(Title, Text) of
        nomatch ->
            maps:put(fail, damage_utils:strf("title ~p does not contain ~p", [Title, Text]), Ctx);
        _ ->
            Ctx
    end;
%% Example: switch to a tag using herbstclient
step(_Cfg, Ctx, <<"When">>, _N, ["I switch hlwm to tag", Tag], _Body) ->
    ok = os:cmd("herbstclient use " ++ Tag),
    Ctx;
%% Capture: store the latest event in a context variable
step(_Cfg, Ctx, <<"Then">>, _N, ["I store the last hlwm event in", Var], _Body) ->
    Pid = ensure_monitor(),
    [Last | _] = gen_server:call(Pid, {get, events}, 5000),
    maps:put(list_to_atom(Var), Last, Ctx).

ensure_monitor() ->
    case gproc:lookup_local_name({?MODULE, monitor}) of
        undefined -> exit({error, monitor_not_started});
        Pid -> Pid
    end.

wait_for_event(Pid, Pred, TimeoutSecs) ->
    Deadline = erlang:monotonic_time(second) + TimeoutSecs,
    wait_loop(Pid, Pred, Deadline).

wait_loop(Pid, Pred, Deadline) ->
    Events = gen_server:call(Pid, {get, events}, 5000),
    case lists:any(Pred, Events) of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(second) >= Deadline of
                true ->
                    timeout;
                false ->
                    timer:sleep(200),
                    wait_loop(Pid, Pred, Deadline)
            end
    end.

query(Pid, focused_title) ->
    case gen_server:call(Pid, {query, focused_title}) of
        {ok, T} -> T;
        _ -> ""
    end.
