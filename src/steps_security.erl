-module(steps_security).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).
-export([scan_ports/2]).

step(_Config, Context, <<"When">>, _N, ["I request a port scan"], _) ->
  Host = maps:get(host, Context),
  Result = scan_ports(Host),
  ?debugFmt("Result ~p", [Result]),
  Open = lists:filter(fun ({_, <<"open">>}) -> true; (_) -> false end, Result),
  ?debugFmt("Open ~p", [Open]),
  maps:put(
    response,
    maps:put(num_open, length(Open), #{results => Result}),
    Context
  ).


scan_ports(Host) ->
  Command = "nmap  " ++ Host,
  PortDescriptors = os:cmd(Command),
  io:format(
    "Scanning ports on host ~s Result ~p ...~n",
    [Host, PortDescriptors]
  ),
  ProcessOutput = string:tokens(PortDescriptors, "\n"),
  lists:filtermap(fun parse_status/1, ProcessOutput).


scan_ports(Host, Ports) ->
  PortStrings = lists:flatten([integer_to_list(Port) ++ "," || Port <- Ports]),
  Command = "nmap -p " ++ PortStrings ++ " " ++ Host,
  {ok, PortDescriptors} = os:cmd(Command),
  io:format("Scanning ports ~w on host ~s ...~n", [Ports, Host]),
  ProcessOutput = string:tokens(PortDescriptors, "\n"),
  lists:map(fun parse_status/1, ProcessOutput).


parse_status(Text) ->
  ?debugFmt("Result line ~p", [Text]),
  case re:split(Text, "([0-9]+)/[a-z]+[ ]+([a-z]+)") of
    [<<>>, Port, Status, _Service] -> {true, {binary_to_integer(Port), Status}};
    _ -> false
  end.
