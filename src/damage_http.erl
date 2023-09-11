-module(damage_http).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([hello_to_html/2]).
-export([hello_to_json/2]).
-export([hello_to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).

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
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_form},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {ok, DataDir} = application:get_env(damage, data_dir),
  ?debugFmt("Got data ~p.", [Data]),
  Config =
    [
      {host, localhost},
      {feature_dirs, ["../../../../features/", "../features/"]}
    ],
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{feature := FeatureData, account := Account} = _FeatureJson ->
        AccountDir = filename:join(DataDir, Account),
        FeatureDir = filename:join(AccountDir, "features"),
        case filelib:ensure_path(FeatureDir) of
          ok ->
            BddFileName =
              filename:join(
                FeatureDir,
                "RenameMeToGeneratedFeatureNamefromData.feature"
              ),
            ?debugFmt("Got bddfilename ~p.", [BddFileName]),
            case file:write_file(BddFileName, FeatureData) of
              ok ->
                Result =
                  damage:execute_file(
                    [{account, Account} | Config],
                    BddFileName
                  ),
                {201, jsx:encode(#{status => <<"ok">>, result => [Result]})};

              Err ->
                {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
            end;

          Err -> {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
        end;

      Err -> {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req, Data) -> {<<"{\"status\":\"not ok\"}">>, Req, Data}.

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
