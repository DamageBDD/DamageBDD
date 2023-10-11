-module(damage_http).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).

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
    _FeaturePayload,
  UserAgent
) ->
  {ok, DataDir} = application:get_env(damage, data_dir),
  AccountDir = filename:join(DataDir, Account),
  {ok, RunId} = datestring:format("YmdHMS", erlang:localtime()),
  TextReport = filename:join([AccountDir, RunId, "report.txt"]),
  Config =
    [
      {
        formatters,
        [
          {text, #{output => TextReport}},
          {html, #{output => filename:join([AccountDir, RunId, "report.html"])}}
        ]
      },
      {feature_dirs, ["../../../../features/", "../features/"]}
    ],
  RunDir = filename:join(AccountDir, RunId),
  FeatureDir = filename:join(AccountDir, "features"),
  case filelib:ensure_path(RunDir) of
    ok ->
      BddFileName =
        filename:join(FeatureDir, string:join([RunId, ".feature"], "")),
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

            _Ok ->
              %logger:debug("No failure ~p.", [Ok]),
              case UserAgent of
                <<"curl", _/binary>> ->
                  {ok, ReportData} = file:read_file(TextReport),
                  {200, ReportData};

                _Other ->
                  {
                    200,
                    jsx:encode(
                      #{
                        status => <<"ok">>,
                        run_id => list_to_binary(RunId),
                        message => <<"">>
                      }
                    )
                  }
              end
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
        execute_bdd(FeatureJson, cowboy_req:header(<<"user-agent">>, Req, ""));

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


get_ip(Req0) ->
  case cowboy_req:peer(Req0) of
    {{IP, _}, _} -> IP;
    {IP, _} -> IP
  end.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  logger:debug("Req ~p.", [Req]),
  Hostname = cowboy_req:header(<<"x-damage-host">>, Req0, <<"localhost">>),
  Port = cowboy_req:header(<<"x-damage-port">>, Req0, 80),
  UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  {Status, Resp0} =
    case cowboy_req:header(<<"authorization">>, Req0, <<"guest">>) of
      <<"ak_", _Rest>> = Account ->
        execute_bdd(
          #{feature => Body, account => Account, host => Hostname, port => Port},
          UserAgent
        );

      Account ->
        IP = get_ip(Req0),
        case throttle:check(damage_api_rate, IP) of
          {limit_exceeded, _, _} ->
            lager:warning("IP ~p exceeded api limit", [IP]),
            {error, 429, Req};

          _ ->
            execute_bdd(
              #{
                feature => Body,
                account => Account,
                host => Hostname,
                port => Port
              },
              UserAgent
            )
        end
    end,
  logger:debug("Response  ~p.", [Resp0]),
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  {stop, cowboy_req:reply(Status, Resp), State}.


to_html(Req, State) ->
  Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req0, State}.


to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
