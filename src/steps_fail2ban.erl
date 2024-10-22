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
-export([hook/1]).

-include_lib("kernel/include/logger.hrl").

hook(Data) ->
  case gproc:lookup_local_name({?MODULE, "nginx_journald"}) of
    undefined -> ?LOG_ERROR("nginx journald missing", []);
    Pid -> ok = gen_server:call(Pid, {check_ban, Data})
  end.


unban(Ip) ->
  Result =
    exec:run("sudo iptables -D INPUT -s " ++ Ip ++ " -j DROP", [stdout, sync]),
  ?LOG_INFO("Banned Ip ~p ~p", [Ip, Result]),
  {true, Result}.


ban(Ip, BanTime) ->
  Result =
    exec:run(
      "sudo iptables -A INPUT -s "
      ++
      Ip
      ++
      " -j DROP -m comment --comment \"DamageBDD Fail2ban Ban\"",
      [stdout, sync]
    ),
  ?LOG_INFO("Banned Ip ~p ~p", [Ip, Result]),
  _Timer = erlang:send_after(BanTime, self(), [unban, Ip]),
  {true, Result}.


step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["the IP must be banned for", BanTime, "seconds"],
  _
) ->
  Ips = maps:get(fail2ban_selected_ips, Context, []),
  Results = [ban(Ip, BanTime) || Ip <- Ips],
  case lists:all(fun ({true, _}) -> true end, Results) of
    true -> Context;

    _ ->
      maps:put(fail, damage_utils:strf("Failed to ban ~p", [Results]), Context)
  end;

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  _,
  _N,
  [
    "the IP has made more than",
    NumRequests,
    "requests with status",
    Status,
    "in the last",
    SinceSeconds,
    "seconds"
  ],
  _
) ->
  true = steps_utils:is_admin(AeAccount),
  Pid = get_fail2ban_proc("nginx", Context),
  ok =
    gen_server:call(
      Pid,
      {add_jail, NumRequests, Status, list_to_integer(SinceSeconds)}
    ),
  Context.


start_link() -> gen_server:start_link(?MODULE, [], []).

init([Service, Context]) ->
  process_flag(trap_exit, true),
  Timer = erlang:send_after(10000, self(), tic),
  Context = #{heartbeat_timer => Timer, service => Service},
  {ok, Context}.


handle_call({unban, Ip}, _From, Context) ->
  ok = unban(Ip),
  {reply, ok, Context};

handle_call({check_ban, Data}, _From, Context) ->
  ?LOG_DEBUG("check_ban ~p", [Data]),
  Result =
    case
    re:match("^<HOST>.*\"(GET|POST).*\" <STATUS>(404|444|403|400) .*$", Data) of
      {match, [Ip, Status]} ->
        Cache = maps:get(context, fail2ban_cache, #{}),
        Now = date_util:seconds_since_epoch(),
        case maps:get(Ip, Cache, undefined) of
          #{last_seen := LastSeen, status := Status} ->
            Jails = maps:get(fail2ban_jails, Context, sets:set([])),
            lists:map(
              fun
                (#{status := Status0, since := Since} = _Jail) ->
                  SinceLastSeen = Now - LastSeen,
                  Status0 = Status,
                  SinceLastSeen > Since
              end,
              Jails
            );

          undefined -> 0
        end;

      _ -> ok
    end,
  {reply, Result, Context};

handle_call({add_jail, NumRequests, Status, SinceSeconds}, _From, Context) ->
  Id = "fail2ban",
  Pid = steps_journald:get_journal_proc("nginx", Context),
  ok = gen_server:call(Pid, {add_hook, Id, fun hook/1}),
  Jails = maps:get(fail2ban_jails, Context, sets:set([])),
  {
    reply,
    ok,
    maps:put(
      fail2ban_jails,
      sets:add_element(
        #{num_requests => NumRequests, since => SinceSeconds, status => Status},
        Jails
      ),
      Context
    )
  };

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
