-module(damage_reports).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export(
  [from_json/2, allowed_methods/2, from_html/2, from_yaml/2, is_authorized/2]
).
-export([test/0]).
-export([ls/1]).
-export([content_types_accepted/2]).
-export([trails/0]).

trails() -> [{"/reports/:hash/[:path]", damage_reports, #{}}].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {
    [
      {{<<"text">>, <<"html">>, '*'}, to_html},
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text}
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

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_html(Req, State) -> to_text(Req, State).

%logger:error("to text ipfs hash ~p ", [Req]),
%Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
%logger:info("get ipfs hash ~p ", [Body]),
%{Body, Req, State}.
to_json(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


to_text(Req, State) ->
  Hash = binary_to_list(cowboy_req:binding(hash, Req)),
  case cowboy_req:binding(path, Req) of
    undefined ->
      logger:error("to text ipfs hash ~p ", [Hash]),
      {
        list_to_binary(
          lists:join(
            <<"\n">>,
            ls(list_to_binary(string:join([Hash, "reports"], "/")))
          )
        ),
        Req,
        State
      };

    Path ->
      Path0 = string:join(["reports", binary_to_list(Path)], "/"),
      logger:error("to text ipfs hash ~p ~p", [Hash, Path0]),
      {cat(list_to_binary(Hash), Path0), Req, State}
  end.


do_query(#{account := Account}) ->
  case
  damage_riak:get_index(
    {<<"Default">>, <<"reports">>},
    <<"account_bin">>,
    Account
  ) of
    [] -> logger:info("no reports for account");

    Found ->
      ?debugFmt(" reports exists data: ~p ", [Found]),
      Found
  end.


do_action(<<"query_from_yaml">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" yaml data: ~p ", [Data]),
  {ok, [Data0]} = fast_yaml:decode(Data, [maps]),
  do_query(Data0);

do_action(<<"create_from_json">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" json data: ~p ", [Data]),
  Data0 = jsx:decode(Data, [return_maps]),
  do_query(Data0);

do_action(<<"create">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt("Form data ~p", [Data]),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  do_query(FormData).


from_html(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Body = damage_utils:load_template("create_account.mustache", Result),
  Resp = cowboy_req:set_resp_body(Body, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_json(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_json">>, Req),
  JsonResult = jsx:encode(Result),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_yaml(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_yaml">>, Req),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


ls(Hash) ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | _Rest]}]
  } = damage_ipfs:ls(Hash),
  logger:info("get ipfs hash ~p ", [Hash]),
  [maps:get(<<"Name">>, M) || M <- Links].


cat(Hash, Path) ->
  {ok, Data} =
    damage_ipfs:cat(
      list_to_binary(string:join([binary_to_list(Hash), Path], "/"))
    ),
  logger:info("get ipfs hash ~p ", [Hash]),
  Data.


test() ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | Rest]}]
  } = damage_ipfs:test(),
  logger:info("list ipfs directory ~p ~p ~p", [Hash, Links, Rest]).
