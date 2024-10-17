-module(steps_fail2ban).

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
    start_link/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).

-include_lib("kernel/include/logger.hrl").

hook(Data) ->
  case re:match("^<HOST>.*\"(GET|POST).*\" (404|444|403|400) .*$", Data) of
    {ok, Start} -> ok;
    _ -> ok
  end.


step(
  _Config,
  Context,
  _,
  _N,
  ["the IP has not been seen in the last", SinceSeconds, "seconds"],
  _
) ->
  Id = "nginx_journal",
  Pid = get_fail2ban_proc("nginx", Context),
  Context.


start_link() -> gen_server:start_link(?MODULE, [], []).

init([Service, Context]) ->
  process_flag(trap_exit, true),
  Timer = erlang:send_after(10000, self(), tic),
  Context = #{heartbeat_timer => Timer, service => Service},
  {ok, Context}.


handle_call({add_jail}, _From, Context) -> {reply, ok, Context};

handle_call(Event, _From, Context) ->
  ?LOG_DEBUG("handle_call ~p : ~p", [Event, Context]),
  {reply, ok, Context}.


handle_cast(Event, Context) ->
  ?LOG_DEBUG("handle_cast ~p : ~p", [Event, Context]),
  {noreply, Context}.


handle_info(Info, Context) ->
  ?LOG_DEBUG("handle_info ~p : ~p", [Info, Context]),
  {noreply, Context}.


terminate(Reason, _Context) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, Context, _Extra) -> {ok, Context}.

get_fail2ban_proc(Service, Context) ->
  Id = Service ++ "_journal",
  case gproc:lookup_local_name({?MODULE, Id}) of
    undefined ->
      case supervisor:start_child(
        damage_sup,
        #{
          % mandatory
          id => Id,
          % mandatory
          start => {steps_fail2ban, start_link, [Service, Context]},
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
