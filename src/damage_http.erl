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
      {{<<"text">>, <<"html">>, '*'}, hello_to_html},
      {{<<"application">>, <<"json">>, []}, hello_to_json},
      {{<<"text">>, <<"plain">>, '*'}, hello_to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

execute_bdd(
  #{feature := FeatureData, account := Account, host := Hostname, port := Port} =
    _FeaturePayload
) ->
  {ok, DataDir} = application:get_env(damage, data_dir),
  AccountDir = filename:join(DataDir, Account),
  Config =
    [
      {
        formatters,
        [
          {text, #{output => filename:join(AccountDir, "report.txt")}},
          {html, #{output => filename:join(AccountDir, "report.html")}}
        ]
      },
      {feature_dirs, ["../../../../features/", "../features/"]}
    ],
  FeatureDir = filename:join(AccountDir, "features"),
  case filelib:ensure_path(FeatureDir) of
    ok ->
      BddFileName =
        filename:join(
          FeatureDir,
          "RenameMeToGeneratedFeatureNamefromData.feature"
        ),
      case file:write_file(BddFileName, FeatureData) of
        ok ->
          case
          damage:execute_file(
            [
              {account, binary_to_list(Account)},
              {host, binary_to_list(Hostname)},
              {port, Port} | Config
            ],
            BddFileName
          ) of
            [
              #{
                fail := _FailReason,
                failing_step := {_KeyWord, Line, Step, _Args}
              }
              | _
            ] ->
              Response =
                #{
                  status => <<"notok">>,
                  failing_step
                  =>
                  list_to_binary(damage_utils:lists_concat(Step, " ")),
                  line => Line
                },
              {400, jsx:encode(Response)};

            {parse_error, LineNo, Message} ->
              logger:debug("failure ~p.", [Message]),
              {
                400,
                jsx:encode(
                  #{
                    status => <<"notok">>,
                    message => list_to_binary(Message),
                    line => LineNo,
                    hint
                    =>
                    <<
                      "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
                    >>
                  }
                )
              };

            Ok ->
              logger:debug("No failure ~p.", [Ok]),
              {200, jsx:encode(#{status => <<"ok">>, message => <<"">>})}
          end;

        Err ->
          logger:error("Write file failed ~p.", [Err]),
          {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
      end;

    Err ->
      logger:error("Data dir creation faild ~p.", [Err]),
      {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
  end.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{
        feature := _FeatureData,
        account := _Account,
        host := _Hostname,
        port := _Port
      } = FeatureJson ->
        execute_bdd(FeatureJson);

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  logger:debug("Req ~p.", [Req]),
  Hostname = cowboy_req:header(<<"x-damage-host">>, Req0, <<"localhost">>),
  Port = cowboy_req:header(<<"x-damage-port">>, Req0, 80),
  Account = cowboy_req:header(<<"authorization">>, Req0, <<"guest">>),
  {Status, Resp0} =
    execute_bdd(
      #{feature => Body, account => Account, host => Hostname, port => Port}
    ),
  logger:debug("Response  ~p.", [Resp0]),
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  {stop, cowboy_req:reply(Status, Resp), State}.


load_template(FilePath) ->
  PrivDir = application:priv_dir(damage),
  FilePath = filename:join([PrivDir, "dealdamage.html"]),
  {ok, {_, TemplateString}} = file:consult(FilePath),
  mustache:render(TemplateString, #{}).


hello_to_html(Req, State) ->
  Body = load_template("template.mustache"),
  {Body, Req, State}.


hello_to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req0, State}.


hello_to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
