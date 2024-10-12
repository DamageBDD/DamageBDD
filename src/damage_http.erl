-module(damage_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Executing Tests"]).

trails() ->
  [
    trails:trail(
      "/version/",
      damage_http,
      #{action => version},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to execute a test on this DamageBDD server.",
          produces => ["text/html"]
        }
      }
    ),
    trails:trail(
      "/execute_feature/",
      damage_http,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to execute a test on this DamageBDD server.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Execute a test on post",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"feature">>,
              description => <<"Test feature data.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

get_access_token(Req) ->
  case cowboy_req:header(<<"authorization">>, Req) of
    <<"Bearer ", Token/binary>> -> {ok, Token};

    _ ->
      case catch cowboy_req:match_qs([access_token], Req) of
        #{access_token := Token} -> {ok, Token};

        _ ->
          Cookies = cowboy_req:parse_cookies(Req),
          case lists:keyfind(<<"sessionid">>, 1, Cookies) of
            {<<"sessionid">>, Token} -> {ok, Token};
            _ -> {error, missing}
          end
      end
  end.


is_authorized(Req, #{action := version} = State) -> {true, Req, State};

is_authorized(Req, State0) ->
  State =
    maps:put(
      ip,
      damage_utils:get_ip(Req),
      maps:put(useragent, cowboy_req:header(<<"user-agent">>, Req, ""), State0)
    ),
  case get_access_token(Req) of
    {ok, Token} ->
      case oauth2:verify_access_token(Token, []) of
        {ok, {[], Auth}} ->
          #{
            <<"client">> := _Client,
            <<"resource_owner">> := ResourceOwner,
            <<"expiry_time">> := _Expiry,
            <<"scope">> := _Scope
          } = maps:from_list(Auth),
          case damage_ae:get_meta(ResourceOwner) of
            notfound ->
              ?LOG_DEBUG("is_authorized Identity ~p", [ResourceOwner]),
              {{false, <<"Bearer">>}, Req, State};

            User ->
              {
                true,
                Req,
                maps:merge(
                  State,
                  #{
                    ae_account => maps:get(ae_account, User),
                    user => User,
                    username => ResourceOwner
                  }
                )
              }
          end;

        {error, access_denied} -> {{false, <<"Bearer">>}, Req, State};

        Other ->
          logger:error("Unexpected auth ~p", [Other]),
          {{false, <<"Bearer">>}, Req, State}
      end;

    {error, _} -> {{false, <<"Bearer">>}, Req, State}
  end.


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

get_config(
  #{ae_account := AeAccount, concurrency := Concurrency0} = Context,
  Req0
) ->
  Concurrency = damage_utils:get_concurrency_level(Concurrency0),
  Formatters =
    case Concurrency of
      1 ->
        case maps:get(stream, Context, maybe_stream) of
          nostream -> [];

          _ ->
            Req =
              cowboy_req:stream_reply(
                200,
                #{<<"content-type">> => <<"text/plain">>},
                Req0
              ),
            logger:info("execute_bdd req ~p", [Req]),
            [
              {
                text,
                #{
                  output => Req,
                  color => maps:get(color_formatter, Context, false)
                }
              }
            ]
        end;

      _ ->
        ?LOG_DEBUG("execute_bdd concurrenc ~p", [Concurrency]),
        []
    end,
  damage:get_default_config(AeAccount, Concurrency, Formatters).


execute_bdd(Config, Context, #{feature := FeatureData}) ->
  case damage:execute_data(Config, Context, FeatureData) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      Response =
        #{
          status => <<"notok">>,
          failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
          line => Line
        },
      {400, Response};

    {parse_error, LineNo, Message} ->
      ?LOG_DEBUG("failure ~p.", [Message]),
      {
        400,
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
      };

    #{report_hash := _} = Result ->
      {200, maps:merge(Result, #{status => <<"ok">>})}
  end.


check_execute_bdd(
  #{concurrency := Concurrency0} = Context0,
  #{ae_account := AeAccount} = State,
  Req0
) ->
  Context = maps:merge(Context0, State),
  Concurrency = damage_utils:get_concurrency_level(Concurrency0),
  IP = damage_utils:get_ip(Req0),
  case throttle:check(damage_api_rate, IP) of
    {limit_exceeded, _, _} ->
      ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
      {error, 429, Req0};

    _ ->
      case damage_ae:balance(AeAccount) of
        Balance when Balance >= Concurrency ->
          Config = get_config(Context, Req0),
          execute_bdd(
            Config,
            damage_context:get_account_context(
              damage_context:get_global_template_context(Context)
            ),
            Context
          );

        Other ->
          {
            400,
            <<
              "Insufficient balance, please top up balance at `/api/accounts/topup` balance:",
              Other/binary
            >>
          }
      end
  end.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      #{feature := _FeatureData} = FeatureJson ->
        check_execute_bdd(FeatureJson, State, Req)
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  ?LOG_DEBUG("Req ~p.", [Req]),
  _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  Concurrency =
    binary_to_integer(
      cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
    ),
  ColorFormatter =
    case cowboy_req:match_qs([{color, [], <<"true">>}], Req0) of
      #{color := <<"true">>} -> true;
      _Other -> false
    end,
  {_Status, Resp0} =
    check_execute_bdd(
      #{
        feature => Body,
        color_formatter => ColorFormatter,
        concurrency => Concurrency,
        stream => maybe_stream
      },
      State,
      Req0
    ),
  case Concurrency of
    1 -> {stop, Req0, State};

    _ ->
      Res1 = cowboy_req:set_resp_body(Resp0, Req),
      {true, Res1, State}
  end.


to_html(Req, #{action := version} = State) -> to_json(Req, State);

to_html(Req, State) ->
  Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


to_json(Req, #{action := version} = State) ->
  {ok, CommitHash} = file:read_file("commit_hash.txt"),
  {jsx:encode(#{commit_hash => CommitHash}), Req, State};

to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req0, State}.


to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
