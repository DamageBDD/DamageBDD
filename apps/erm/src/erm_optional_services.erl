%%%-------------------------------------------------------------------
%%% @doc
%%% Non-fatal bootstrap/reconciliation for optional ERM subsystems.
%%%
%%% Optional UI services must never prevent the ERM application supervisor
%%% from starting. This worker starts after erm_sup is alive, reconciles the
%%% configured GTK/Lens children dynamically, and retries failures with bounded
%%% exponential backoff. Manual sync requests can bypass the retry delay.
%%%-------------------------------------------------------------------
-module(erm_optional_services).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, sync/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(INITIAL_DELAY_MS, 100).
-define(RETRY_MIN_MS, 1000).
-define(RETRY_MAX_MS, 60000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

sync() ->
    gen_server:call(?SERVER, sync, 15000).

status() ->
    case whereis(?SERVER) of
        undefined -> not_started;
        _ -> gen_server:call(?SERVER, status, 3000)
    end.

init([]) ->
    Timer = erlang:send_after(?INITIAL_DELAY_MS, self(), reconcile),
    {ok, #{
        timer => Timer,
        retry_ms => ?RETRY_MIN_MS,
        last => #{},
        last_sync_at => undefined
    }}.

handle_call(sync, _From, S0) ->
    cancel(maps:get(timer, S0, undefined)),
    {Results, S1} = reconcile(S0#{timer := undefined}, manual),
    {reply, Results, S1};
handle_call(status, _From, S) ->
    {reply, S, S};
handle_call(_Request, _From, S) ->
    {reply, {error, unsupported_call}, S}.

handle_cast(sync, S) ->
    self() ! reconcile,
    {noreply, S};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(reconcile, S0) ->
    {_Results, S1} = reconcile(S0#{timer := undefined}, scheduled),
    {noreply, S1};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    cancel(maps:get(timer, S, undefined)),
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

reconcile(S0, Trigger) ->
    Gtk = safe_sync(gtknode4, fun erm_sup:sync_gtknode4/0),
    Lens = safe_sync(lens, fun erm_sup:sync_lens/0),
    Results = #{gtknode4 => Gtk, lens => Lens},
    Previous = maps:get(last, S0, #{}),
    log_changes(Results, Previous, Trigger),

    NeedsRetry = needs_retry(gtknode4, Gtk) orelse needs_retry(lens, Lens),
    Retry0 = maps:get(retry_ms, S0, ?RETRY_MIN_MS),
    {Timer, Retry1} =
        case NeedsRetry of
            true ->
                Delay = Retry0,
                {erlang:send_after(Delay, self(), reconcile), min(?RETRY_MAX_MS, Retry0 * 2)};
            false ->
                {undefined, ?RETRY_MIN_MS}
        end,
    {Results, S0#{
        timer := Timer,
        retry_ms := Retry1,
        last := Results,
        last_sync_at := erlang:system_time(millisecond)
    }}.

safe_sync(Name, Fun) ->
    try Fun() of
        Result -> Result
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Optional ERM service reconcile crashed service=~p error=~p:~p stack=~p",
                [Name, Class, Reason, Stacktrace]
            ),
            {error, {Class, Reason}}
    end.

needs_retry(gtknode4, Result) ->
    configured(gtknode4) andalso not successful(Result);
needs_retry(lens, Result) ->
    configured(lens) andalso not successful(Result).

configured(gtknode4) ->
    C = options_map(application:get_env(erm, gtknode4, #{})),
    maps:get(enabled, C, false) =:= true;
configured(lens) ->
    C = options_map(application:get_env(erm, lens, #{})),
    maps:get(enabled, C, true) =:= true.

successful(ok) -> true;
successful({ok, Pid}) when is_pid(Pid) -> true;
successful({ok, Pid, _}) when is_pid(Pid) -> true;
successful(_) -> false.

log_changes(Results, Previous, Trigger) ->
    maps:foreach(
        fun(Service, Result) ->
            Prev = maps:get(Service, Previous, undefined),
            case {Result, Result =:= Prev} of
                {{error, _}, false} ->
                    ?LOG_WARNING(
                        "Optional ERM service unavailable service=~p trigger=~p result=~p",
                        [Service, Trigger, Result]
                    );
                {{error, _}, true} ->
                    ?LOG_DEBUG(
                        "Optional ERM service still unavailable service=~p result=~p",
                        [Service, Result]
                    );
                {_, false} ->
                    ?LOG_INFO(
                        "Optional ERM service reconciled service=~p trigger=~p result=~p",
                        [Service, Trigger, Result]
                    );
                {_, true} ->
                    ?LOG_DEBUG(
                        "Optional ERM service unchanged service=~p result=~p",
                        [Service, Result]
                    )
            end
        end,
        Results
    ).

cancel(undefined) -> ok;
cancel(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(undefined) -> #{};
options_map(_) -> #{}.
