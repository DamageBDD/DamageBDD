-module(damage_http).

%%% @doc
%%% asyncmind top-level HTTP request handler.
%%% @end

-vsn("0.1.0").

-behavior(cowboy_handler).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).

-spec init(Req, State) ->
  Result
  when Req :: cowboy_req:req(),
       State :: any(),
       Result :: {ok, Reply, NewState} | {module(), Reply, NewState, Options},
       Reply :: cowboy_req:req(),
       NewState :: any(),
       Options :: any().
init(Req0, State) ->
  Method = cowboy_req:method(Req0),
  Req = maybe_handle(Method, Req0),
  {ok, Req, State}.


maybe_handle(<<"GET">>, Req) ->
  cowboy_req:reply(400, #{}, <<"Missing body.">>, Req);

maybe_handle(<<"POST">>, Req) ->
  HasBody = cowboy_req:has_body(Req),
  maybe_handle_post(HasBody, Req);

maybe_handle(_, Req) ->
  %% Method not allowed.
  cowboy_req:reply(405, Req).


maybe_handle_post(true, Req0) ->
  {ok, PostVals, Req} = cowboy_req:read_urlencoded_body(Req0),
  FeatureFile = proplists:get_value(<<"feature_file">>, PostVals),
  handle(FeatureFile, Req);

maybe_handle_post(false, Req) ->
  cowboy_req:reply(400, #{}, <<"Missing POST body.">>, Req);

maybe_handle_post(_, Req) ->
  %% Method not allowed.
  cowboy_req:reply(405, Req).


handle(undefined, Req) ->
  cowboy_req:reply(400, #{}, <<"Missing POST data.">>, Req);

handle(Data, Req) ->
  cowboy_req:reply(
    200,
    #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
    Data,
    Req
  ).
