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
-export([test/0]).
-export([ls/1]).
-export([allowed_methods/2]).

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

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

allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.

to_html(Req, State) ->
  to_text(Req, State).


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
            ls(
                list_to_binary(
                    string:join(
                        [Hash, "reports"],
                        "/"
                    )
                )
            )
        )
        ),
        Req,
        State
    };
Path ->
          Path0 =
                string:join(["reports", binary_to_list(Path)], "/"),
    logger:error("to text ipfs hash ~p ~p", [Hash, Path0]),
          
    {
            cat(
                list_to_binary(
                    Hash
                ),
                Path0
            ),
        Req,
        State
    }
end.


ls(Hash) ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | _Rest]}]
  } = damage_ipfs:ls(Hash),
  logger:info("get ipfs hash ~p ", [Hash]),
  [maps:get(<<"Name">>, M) || M <- Links].

cat(Hash, Path) ->
  {
    ok,
    Data
  } = damage_ipfs:cat(list_to_binary(string:join([binary_to_list(Hash), Path], "/"))),
  logger:info("get ipfs hash ~p ", [Hash]),
  Data.

test() ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | Rest]}]
  } = damage_ipfs:test(),
  logger:info("list ipfs directory ~p ~p ~p", [Hash, Links, Rest]).
