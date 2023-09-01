%% Feel free to use, reuse and abuse the code in this file.
%% @doc Hello world handler.

-module(hello_h).

-export([init/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([hello_to_html/2]).
-export([hello_to_json/2]).
-export([hello_to_text/2]).
-export([create_paste_form/2]).
-export([create_paste_json/2]).

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      {<<"text/html">>, hello_to_html},
      {<<"application/json">>, hello_to_json},
      {<<"text/plain">>, hello_to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, create_paste_form},
      {{<<"application">>, <<"json">>, '*'}, create_paste_json}
    ],
    Req,
    State
  }.

create_paste_form(Req, State) ->
  {ok, [], Req2} = cowboy_req:read_urlencoded_body(Req),
  logger:error("got it"),
  create_paste(Req2, State).


create_paste_json(Req, State) ->
  {ok, [], Req2} = cowboy_req:read_urlencoded_body(Req),
  create_paste(Req2, State).


create_paste(Req2, State) ->
  case cowboy_req:method(Req2) of
    <<"POST">> -> {{true, <<"{\"status\": \"ok\"">>}, Req2, State};
    _ -> {true, Req2, State}
  end.


hello_to_html(Req, State) ->
  Body =
    <<
      "<html>\n<head>\n\t<meta charset=\"utf-8\">\n\t<title>REST Hello World!</title>\n</head>\n<body>\n\t<p>REST Hello World as HTML!</p>\n</body>\n</html>"
    >>,
  {Body, Req, State}.


hello_to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\"}">>,
  Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  Req =
    cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req, State}.


hello_to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
