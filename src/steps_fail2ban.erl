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
    start_link/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).
-export([hook/1]).
-export([unban/1]).
-export([restart/1]).

-include_lib("kernel/include/logger.hrl").

hook(Data) ->
  ?LOG_INFO("fail2ban_nginx hook ~p", [Data]),
  case gproc:lookup_local_name({?MODULE, "fail2ban_nginx"}) of
    undefined -> ?LOG_ERROR("fail2ban_nginx process missing", []);
    Pid -> ok = gen_server:call(Pid, {check_ban, Data})
  end.


unban(Ip) ->
  Result = exec:run("sudo iptables -D INPUT -s " ++ Ip, [stdout, sync]),
  ?LOG_INFO("Banned Ip ~p ~p", [Ip, Result]),
  {true, Result}.


ban(Ip, BanTime) ->
  Cmd =
    "sudo iptables -A INPUT -s "
    ++
    Ip
    ++
    " -j DROP -m comment --comment \"DamageBDD Fail2ban Ban\"",
  ?LOG_INFO("Banning Ip ~p for ~p \n~p", [Ip, BanTime, Cmd]),
  case exec:run(Cmd, [stdout, sync]) of
    {error, Error} ->
      ?LOG_ERROR("Error Banning Ip ~p ~p", [Ip, Error]),
      {true, error};

    Result ->
      ?LOG_INFO("Banned Ip ~p ~p", [Ip, Result]),
      _Timer = erlang:send_after(BanTime, self(), [unban, Ip]),
      {true, Result}
  end.


step(
  _Config,
  #{ae_account := AeAccount} = Context,
  _,
  _N,
  ["I set the IP exclusion list to"],
  Body
) ->
  true = steps_utils:is_admin(AeAccount),
  Pid = get_fail2ban_proc("nginx", Context),
  Exclusions = string:split(string:strip(binary_to_list(Body), both, $\n), ","),
  ?LOG_INFO("Set exclusions ~p", [Exclusions]),
  ok = gen_server:call(Pid, {set_exclusions, Exclusions}),
  Context;

step(
  _Config,
  #{ae_account := AeAccount} = Context,
  <<"Then">>,
  _N,
  ["the IP must be banned for", BanTime, "seconds"],
  _
) ->
  true = steps_utils:is_admin(AeAccount),
  DefaultJail = #{num_requests => 3, status_code => 400, since_seconds => 30},
  Pid = get_fail2ban_proc("nginx", Context),
  Jail =
    maps:put(
      ban_time,
      list_to_integer(BanTime),
      maps:get(fail2ban_nginx_jail, Context, DefaultJail)
    ),
  ok = gen_server:call(Pid, {add_jail, Jail}),
  Context;

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
  Jail =
    #{
      num_requests => list_to_integer(NumRequests),
      status_code => list_to_integer(Status),
      since_seconds => list_to_integer(SinceSeconds)
    },
  maps:put(fail2ban_nginx_jail, Jail, Context).


start_link(Service, Context) ->
  gen_server:start_link(?MODULE, [Service, Context], []).

init([Service, Context]) ->
  process_flag(trap_exit, true),
  Timer = erlang:send_after(10000, self(), tic),
  {ok, maps:merge(Context, #{heartbeat_timer => Timer, service => Service})}.


handle_call({set_exclusions, Exclusions}, _From, Context) ->
  {reply, ok, maps:put(fail2ban_exclusions, Exclusions, Context)};

handle_call({unban, Ip}, _From, Context) ->
  ok = unban(Ip),
  {reply, ok, Context};

handle_call(
  {check_ban, Data},
  _From,
  #{fail2ban_exclusions := Exclusions} = Context
) ->
  Now = date_util:epoch(),
  case catch parse_log(Data) of
    {ok, #{client_ip := Ip, status_code := Status}} ->
      Cache = maps:get(fail2ban_cache, Context, #{}),
      case lists:member(Ip, Exclusions) of
        true ->
          ?LOG_DEBUG("Excluded Ip ~p", [Ip]),
          {
            reply,
            ok,
            maps:put(
              fail2ban_cache,
              maps:put(Ip, #{last_seen => Now, status_code => Status}, Cache),
              Context
            )
          };

        false ->
          case maps:get(Ip, Cache, undefined) of
            #{last_seen := LastSeen, status_code := Status} ->
              Jails =
                sets:to_list(maps:get(fail2ban_jails, Context, sets:new())),
              lists:map(
                fun
                  (
                    #{
                      status_code := Status0,
                      since_seconds := Since,
                      ban_time := BanTime
                    } = _Jail
                  )
                  when Status =:= Status0, (Now - LastSeen) > Since ->
                    ban(Ip, BanTime);

                  (Other) ->
                    ?LOG_ERROR("checkban matchin failed ~p Since:  status: ~p ip: ~p", [Other, Status, Ip])
                end,
                Jails
              ),
              {
                reply,
                ok,
                maps:put(
                  fail2ban_cache,
                  maps:put(
                    Ip,
                    #{last_seen => Now, status_code => Status},
                    Cache
                  ),
                  Context
                )
              };

            undefined ->
              {
                reply,
                ok,
                maps:put(
                  fail2ban_cache,
                  maps:put(
                    Ip,
                    #{last_seen => Now, status_code => Status},
                    Cache
                  ),
                  Context
                )
              };

            Other ->
              ?LOG_ERROR("checkban failed ip ~p matching ~p", [Ip, Other]),
              {
                reply,
                ok,
                maps:put(
                  fail2ban_cache,
                  maps:put(
                    Ip,
                    #{last_seen => Now, status_code => Status},
                    Cache
                  ),
                  Context
                )
              }
          end
      end;

    Fail ->
      ?LOG_ERROR("checkban failed parsing ~p", [Fail]),
      {reply, ok, Context}
  end;

handle_call(
  {
    add_jail,
    #{
      num_requests := NumRequests,
      status_code := Status,
      since_seconds := SinceSeconds,
      ban_time := BanTime
    }
  },
  _From,
  Context
) ->
  Id = "fail2ban",
  Pid = steps_journald:get_journal_proc("nginx", Context),
  ok = gen_server:call(Pid, {add_hook, Id, fun hook/1}),
  Jails = maps:get(fail2ban_jails, Context, sets:new()),
  {
    reply,
    ok,
    maps:put(
      fail2ban_jails,
      sets:add_element(
        #{
          num_requests => NumRequests,
          since_seconds => SinceSeconds,
          status_code => Status,
          ban_time => BanTime
        },
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


handle_info(tic, Context) ->
  ?LOG_DEBUG("tok", []),
  {noreply, Context};

handle_info(Info, Context) ->
  ?LOG_DEBUG("handle_info ~p : ~p", [Info, Context]),
  {noreply, Context}.


terminate(Reason, _Context) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, Context, _Extra) -> {ok, Context}.

get_fail2ban_proc(Service, Context) ->
  Id = "fail2ban_" ++ Service,
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


parse_log(Log) ->
  % Convert binary to a list (string) if necessary
  LogList = binary_to_list(Log),
  % Regular expression to extract the components of the log
  Regex =
    "([\\w\\d]+)\\s+nginx:\\s+([\\d.]+)\\s+-\\s+-\\s+\\[(\\d{2})/([A-Z][a-z]{2})/(\\d{4}):(\\d{2}:\\d{2}:\\d{2})\\s+([+-]\\d{4})\\]\\s+\"(\\w+)\\s+([^\"]+)\\s+HTTP/[^\"]+\"\\s+(\\d{3})\\s+(\\d+)\\s+\"[^\"]*\"\\s+\"([^\"]+)\"",
  % Match the log line with the regex and extract groups
  case re:run(LogList, Regex, [{capture, all_but_first, list}]) of
    {
      match,
      [
        Server,
        ClientIp,
        LogDay,
        LogMonth,
        LogYear,
        LogTime,
        LogTimezone,
        Method,
        Request,
        StatusCode,
        ResponseSize,
        UserAgent
      ]
    } ->
      {
        ok,
        #{
          server => Server,
          client_ip => ClientIp,
          log_day => LogDay,
          log_month => LogMonth,
          log_year => LogYear,
          log_time => LogTime,
          log_timezone => LogTimezone,
          method => Method,
          request => Request,
          status_code => list_to_integer(StatusCode),
          response_size => ResponseSize,
          user_agent => UserAgent
        }
      };

    nomatch -> {error, "No match found"}
  end.


restart(Service) ->
  Id = "fail2ban_" ++ Service,
  case gproc:lookup_local_name({?MODULE, Id}) of
    undefined -> ok;
    Pid -> exit(Pid)
  end.


test() ->
  parse_log(
    <<
      "threadripper0 nginx: 192.168.1.1 - - [23/Oct/2024:11:29:03 +1100] \"GET /security.txt HTTP/1.1\" 404 146 \"-\" \"curl/8.9.0\""
    >>
  ).
