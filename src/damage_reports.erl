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
  Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
  {Body, Req, State}.


to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req0, State}.


to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
