-module(damage_tests).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

-define(TRAILS_TAG, ["Test Endpoints"]).

trails() ->
  Metadata =
    #{
      get
      =>
      #{
        tags => ?TRAILS_TAG,
        description => "Get some test value",
        produces => ["text/plain"]
      },
      put
      =>
      #{
        tags => ?TRAILS_TAG,
        description => "Do some action on the server",
        produces => ["text/plain"],
        parameters
        =>
        [
          #{
            name => <<"echo">>,
            description => <<"Echo message">>,
            in => <<"path">>,
            required => false,
            type => <<"string">>
          }
        ]
      }
    },
  [trails:trail("/tests/[:action]", damage_tests, [], Metadata)].


init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
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

to_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Body = jsx:decode(Data),
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req, State}.


to_text(Req, State) -> to_json(Req, State).

to_html(Req, State) ->
  Body = damage_utils:load_template("create.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


from_html(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Resp = cowboy_req:set_resp_body(Data, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Body = jsx:decode(Data),
  JsonResult = jsx:encode(Body),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_yaml(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {ok, [Body]} = fast_yaml:decode(Data),
  YamlResult = fast_yaml:encode(Body),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.
