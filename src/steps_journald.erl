-module(steps_journald).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-behaviour(gen_server).

-export([step/6]).
-export([test/0]).
-export(
  [
    init/1,
    start_link/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).
-export([get_journal_proc/2]).

-include_lib("kernel/include/logger.hrl").

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  _,
  _N,
  ["I am monitoring", Service, "journal"],
  _
) ->
  case steps_utils:is_admin(AeAccount) of
    true ->
      % initialize journald hooks ...
      Proc = get_journal_proc(Service, Context),
      ?LOG_DEBUG("Started journald monitor ~p : ~p", [Service, Proc]),
      Context;

    false ->
      Message = damage_utils:strf("Account not an admin. ~p", [AeAccount]),
      maps:put(fail, Message, Context)
  end.


start_link(Service, Context) ->
  gen_server:start_link(?MODULE, [Service, Context], []).

init([Service, Context]) ->
  process_flag(trap_exit, true),
  Timer = erlang:send_after(10000, self(), tic),
  {ok, Pid, _} =
    exec:run(
      "journalctl -p 5 -f -o cat -u " ++ Service,
      [{stdout, self()}, monitor]
    ),
  ?LOG_DEBUG("tail pid ~p", [Pid]),
  {ok, maps:merge(Context, #{heartbeat_timer => Timer, journald_hooks => []})}.


handle_call({add_hook, Id, HookFun} = Event, _From, Context) ->
  ?LOG_DEBUG("handle_call ~p : ~p", [Event, Context]),
  Hooks = maps:get(journald_hooks, Context, []),
  maps:put(journald_hooks, lists:append(Hooks, [{Id, HookFun}]), Context),
  {reply, ok, Context};

handle_call(Event, _From, Context) ->
  ?LOG_DEBUG("handle_call ~p : ~p", [Event, Context]),
  {reply, ok, Context}.


handle_cast(Event, Context) ->
  ?LOG_DEBUG("handle_cast ~p : ~p", [Event, Context]),
  {noreply, Context}.


handle_info({stdout, _Pid, Data}, Context) ->
  Hooks = maps:get(journald_hooks, Context, []),
  ?LOG_DEBUG("calling journal hooks ~p ", [Hooks]),
  [HookFun(Data) || {_Id, HookFun} <- Hooks],
  {noreply, Context};

handle_info(Info, Context) ->
  ?LOG_DEBUG("handle_info ~p : ~p", [Info, Context]),
  {noreply, Context}.


terminate(Reason, _Context) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, Context, _Extra) -> {ok, Context}.

get_journal_proc(Service, Context) ->
  Id = Service ++ "_journal",
  case gproc:lookup_local_name({?MODULE, Id}) of
    undefined ->
      case supervisor:start_child(
        damage_sup,
        #{
          % mandatory
          id => Id,
          % mandatory
          start => {steps_journald, start_link, [Service, Context]},
          % optional
          restart => permanent,
          % optional
          shutdown => 60,
          % optional
          type => worker,
          modules => [steps_journald]
        }
      ) of
        {ok, Pid} ->
          gproc:reg_other({n, l, {?MODULE, Id}}, Pid),
          Pid;

        {error, {already_started, Pid}} ->
          gproc:reg_other({n, l, {?MODULE, Id}}, Pid),
          Pid
      end;

    Pid -> Pid
  end.


test() -> ok.
