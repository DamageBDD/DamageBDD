-module(damage_ssh).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(ssh_server_channel).

-record(state, {n, id, cm}).

-export([init/2]).
-export([content_types_provided/2]).
-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2]).
-export([start/0]).
-export([to_html/2]).
-export([to_json/2]).
-export(
  [from_json/2, allowed_methods/2, from_html/2, from_yaml/2, is_authorized/2]
).
-export([content_types_accepted/2]).
-export([trails/0]).

-define(TRAILS_TAG, ["Account Management"]).
-define(SSH_USERDIR, "/var/lib/damagebdd/sshtest_user/.ssh").
-define(SSH_KEYS_BUCKET, {<<"Default">>, <<"SSHKeys">>}).

connect_func(User, PeerAddr, Method) ->
  logger:debug("user connecte ~p ~p ~p", [User, PeerAddr, Method]),
  ok.


trails() ->
  [
    trails:trail(
      "/accounts/ssh_keys",
      damage_accounts,
      #{action => create},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to create an account on this DamageBDD server.",
          produces => ["text/html"]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
      %{{<<"text">>, <<"plain">>, '*'}, to_text},
      {{<<"text">>, <<"html">>, '*'}, to_html}
    ],
    Req,
    State
  }.


content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_html(Req, #{action := create} = State) ->
  Body = <<"Not implemented">>,
  {Body, Req, State}.


to_json(Req, #{action := balance} = State) ->
  Body = <<"Not implemented">>,
  {Body, Req, State}.


write_ssh_public_key(Key) ->
  FilePath = filename:join(?SSH_USERDIR, "known_hosts"),
  file:write_file(FilePath, Key, [append, raw]).


remove_ssh_key(Key) ->
  {ok, File} = file:read_file(?SSH_USERDIR ++ "/known_hosts"),
  Lines = string:tokens(binary_to_list(File), "\n"),
  NewLines =
    lists:filter(fun (Line) -> not lists:member(Line, [Key]) end, Lines),
  NewContents = string:join(NewLines, "\n"),
  file:write_file(?SSH_USERDIR ++ "/known_hosts", list_to_binary(NewContents)).


do_post_action(ssh_key, Data) -> write_ssh_public_key(Data).

from_html(Req = #{method := <<"DELETE">>}, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} = remove_ssh_key(Data),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(jsx:encode(Response0), Req)
    ),
    State
  };

from_html(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  {Status0, Response0} = do_post_action(Action, FormData),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(jsx:encode(Response0), Req)
    ),
    State
  }.


from_json(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case catch jsx:decode(Data, [return_maps]) of
      badarg ->
        {400, #{status => <<"failed">>, message => <<"Json decode error.">>}};

      Data0 -> do_post_action(Action, Data0)
    end,
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(jsx:encode(Response0), Req)
    ),
    State
  }.


from_yaml(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Result = do_post_action(Action, Data),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


start() ->
  {ok, _SSHPid} =
    ssh:daemon(
      8989,
      [
        {system_dir, "/var/lib/damagebdd/ssh_daemon"},
        {user_dir, ?SSH_USERDIR},
        {subsystems, [{"damage_ssh", {damage_ssh, [0]}}]},
        {shell, disabled},
        {tcpip_tunnel_out, true},
        {tcpip_tunnel_in, true},
        {exec, disabled},
        {connectfun, fun connect_func/3}
      ]
    ).

init([N]) ->
  logger:debug("starting ssh_server_channel ~p ", [N]),
  {ok, #state{n = N}}.

%% Function to find a free port in a given range
%% Arguments: Start port and End port
%% Returns: A free port within the range or 'undefined' if no port is available

find_free_port(StartPort, EndPort) ->
  case lists:seq(StartPort, EndPort) of
    [] -> undefined;
    Ports -> find_free_port_helper(Ports)
  end.

%% Helper function to find a free port

find_free_port_helper([Port | T]) ->
  case gen_tcp:listen(Port, [binary, {active, false}]) of
    {ok, _} -> {ok, Port};
    {error, _} -> find_free_port_helper(T)
  end;

find_free_port_helper([]) -> undefined.


handle_msg({ssh_channel_up, ChannelId, ConnectionRef}, State) ->
  logger:debug("starting tunnel ~p ~p", [ConnectionRef, State]),
  StartPort = 8080,
  EndPort = 9000,
  ListenPort =
    case find_free_port(StartPort, EndPort) of
      undefined -> io:format("No free port available.~n");

      {ok, Port} ->
        io:format("Found a free port: ~p.~n", [Port]),
        Port
    end,
  {ok, _TrueListenPort} =
    ssh:tcpip_tunnel_from_server(
      ConnectionRef,
      "localhost",
      ListenPort,
      "localhost",
      8080
    ),
  {ok, State#state{id = ChannelId, cm = ConnectionRef}}.


handle_ssh_msg({ssh_cm, CM, {data, ChannelId, 0, Data}}, #state{n = N} = State) ->
  M = N - size(Data),
  case M > 0 of
    true ->
      ssh_connection:send(CM, ChannelId, Data),
      {ok, State#state{n = M}};

    false ->
      <<SendData:N/binary, _/binary>> = Data,
      ssh_connection:send(CM, ChannelId, SendData),
      ssh_connection:send_eof(CM, ChannelId),
      {stop, ChannelId, State}
  end;

handle_ssh_msg({ssh_cm, _ConnectionManager, {data, _ChannelId, 1, Data}}, State) ->
  error_logger:format(standard_error, " ~p~n", [binary_to_list(Data)]),
  {ok, State};

handle_ssh_msg({ssh_cm, _ConnectionManager, {eof, _ChannelId}}, State) ->
  {ok, State};

handle_ssh_msg({ssh_cm, _, {signal, _, _}}, State) ->
  %% Ignore signals according to RFC 4254 section 6.9.
  {ok, State};

handle_ssh_msg({ssh_cm, _, {exit_signal, ChannelId, _, _Error, _}}, State) ->
  {stop, ChannelId, State};

handle_ssh_msg({ssh_cm, _, {exit_status, ChannelId, _Status}}, State) ->
  {stop, ChannelId, State}.


terminate(_Reason, _State) -> ok.
