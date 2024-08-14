-module(damage_auth).

-export([init/2, allowed_methods/2]).
-export([content_types_provided/2, content_types_accepted/2]).
-export([from_json/2, from_html/2, to_html/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").

-define(TRAILS_TAG, ["Authentication"]).

%%%===================================================================
%%% Cowboy callbacks
%%%===================================================================

trails() ->
  [
    trails:trail(
      "/auth/",
      damage_auth,
      #{},
      #{
        post
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Get auth token.",
          produces => ["text/html", "application/json"],
          parameters
          =>
          [
            #{
              username => <<"username">>,
              description => <<"Username for account.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              password => <<"password">>,
              description => <<"Account password.">>,
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

content_types_provided(Req, State) ->
  {
    [
      {{<<"text">>, <<"html">>, '*'}, to_html},
      {{<<"application">>, <<"json">>, []}, to_html},
      {{<<"text">>, <<"plain">>, '*'}, to_html}
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

from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{return_maps, false}]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      PostData when is_list(PostData) -> process_post(PostData, Req, State)
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req, State) ->
  {ok, Params, Req0} = cowboy_req:read_urlencoded_body(Req),
  process_post(Params, Req0, State).


process_post(Params, Req, State) ->
  ?LOG_DEBUG(" form data: ~p ", [Params]),
  case
  lists:max(
    [
      proplists:get_value(K, Params)
      || K <- [<<"grant_type">>, <<"response_type">>]
    ]
  ) of
    <<"password">> ->
      {Status, Resp0, Req0} = process_password_grant(Req, Params),
      Resp = cowboy_req:set_resp_body(Resp0, Req0),
      {stop, cowboy_req:reply(Status, Resp), State};

    <<"client_credentials">> -> process_client_credentials_grant(Req, Params);
    <<"token">> -> process_implicit_grant_stage2(Req, Params);
    _ -> {stop, cowboy_req:reply(400, #{}, <<"Bad Request.">>, Req), State}
  end.


to_html(Req, State) ->
  {ResponseType, Req2} = cowboy_req:qs_val(<<"response_type">>, Req),
  {ok, Reply} =
    case ResponseType of
      <<"token">> ->
        {Req3, Params} =
          lists:foldl(
            fun
              (Name, {R, Acc}) ->
                {Val, R2} = cowboy_req:qs_val(Name, R),
                {R2, [{Name, Val} | Acc]}
            end,
            {Req2, []},
            [<<"client_id">>, <<"redirect_uri">>, <<"scope">>, <<"state">>]
          ),
        process_implicit_grant(Req3, Params);

      _ ->
        JSON = jsx:encode([{error, <<"unsupported_response_type">>}]),
        cowboy_req:reply(400, [], JSON, Req2)
    end,
  {stop, Reply, State}.

%%%===================================================================
%%% Grant type handlers
%%%===================================================================

process_password_grant(Req, Params) ->
  ?LOG_DEBUG("Process grant ~p", [Params]),
  Username = proplists:get_value(<<"username">>, Params),
  Password = proplists:get_value(<<"password">>, Params),
  Scope = proplists:get_value(<<"scope">>, Params, <<"">>),
  case oauth2:authorize_password({Username, Password}, Scope, basic) of
    {ok, {<<"user">>, Auth}} -> issue_token({ok, Auth}, Req);

    _ ->
      {
        401,
        jsx:encode(
          #{message => <<"Invalid username or password">>, status => <<"fail">>}
        ),
        Req
      }
  end.


process_client_credentials_grant(Req, Params) ->
  {<<"Basic ", Credentials/binary>>, Req2} =
    cowboy_req:header(<<"authorization">>, Req),
  [Id, Secret] = binary:split(base64:decode(Credentials), <<":">>),
  Scope = proplists:get_value(<<"scope">>, Params),
  Auth = oauth2:authorize_client_credentials(Id, Secret, Scope, []),
  issue_token(Auth, Req2).


process_implicit_grant(Req, Params) ->
  State = proplists:get_value(<<"state">>, Params),
  Scope = proplists:get_value(<<"scope">>, Params, <<>>),
  ClientId = proplists:get_value(<<"client_id">>, Params),
  RedirectUri = proplists:get_value(<<"redirect_uri">>, Params),
  case oauth2:verify_redirection_uri(ClientId, RedirectUri) of
    ok ->
      %% Pass the scope, state and redirect URI to the browser
      %% as hidden form parameters, allowing them to "propagate"
      %% to the next stage.
      Html =
        damage_utils:load_template(
          "auth.mustache",
          [
            {redirect_uri, RedirectUri},
            {client_id, ClientId},
            {state, State},
            {scope, Scope}
          ]
        ),
      cowboy_req:reply(200, [], Html, Req);

    %% TODO: Return an OAuth2 response code here.
    %% The returned Reason might not be valid in an OAuth2 context.
    {error, Reason} ->
      redirect_resp(
        RedirectUri,
        [{<<"error">>, to_binary(Reason)}, {<<"state">>, State}],
        Req
      )
  end.


process_implicit_grant_stage2(Req, Params) ->
  ClientId = proplists:get_value(<<"client_id">>, Params),
  RedirectUri = proplists:get_value(<<"redirect_uri">>, Params),
  Username = proplists:get_value(<<"username">>, Params),
  Password = proplists:get_value(<<"password">>, Params),
  State = proplists:get_value(<<"state">>, Params),
  Scope = proplists:get_value(<<"scope">>, Params),
  case oauth2:verify_redirection_uri(ClientId, RedirectUri) of
    ok ->
      case oauth2:authorize_password(Username, Password, Scope) of
        {ok, Response} ->
          Props =
            [{<<"state">>, State} | oauth2_response:to_proplist(Response)],
          redirect_resp(RedirectUri, Props, Req);

        {error, Reason} ->
          redirect_resp(
            RedirectUri,
            [{<<"error">>, to_binary(Reason)}, {<<"state">>, State}],
            Req
          )
      end;

    {error, _} ->
      %% This should not happen. Redirection URI was
      %% supposedly verified in the previous step, so
      %% someone must have been tampering with the
      %% hidden form values.
      cowboy_req:reply(400, Req)
  end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

issue_token({ok, Auth, Scope}, Req) ->
  ?LOG_DEBUG("issue_token ~p ~p", [Auth, Req]),
  {ok, Response} = oauth2:issue_token(Auth, Scope),
  ?LOG_DEBUG("issue_token response ~p", [Response]),
  emit_response(Response, Req);

issue_token({ok, Auth}, Req) ->
  ?LOG_DEBUG("issue_token ~p ~p", [Auth, Req]),
  {ok, Response} = oauth2:issue_token(Auth, basic),
  ?LOG_DEBUG("issue_token response ~p", [Response]),
  emit_response(Response, Req);

issue_token(Error, Req) -> emit_response(Error, Req).


emit_response(AuthResult, Req) ->
  ?LOG_DEBUG("Authresult ~p", [AuthResult]),
  case AuthResult of
    {error, Reason} -> {400, jsx:encode([{error, to_binary(Reason)}]), Req};

    {
      _User,
      {
        response,
        AccessToken,
        undefined,
        _Expiry,
        _UserName,
        <<"basic">>,
        undefined,
        undefined,
        <<"bearer">>
      } = Response
    } ->
      Response0 = oauth2_response:to_proplist(Response),
      Req0 =
        cowboy_req:set_resp_cookie(
          <<"sessionid">>,
          AccessToken,
          Req,
          #{secure => true, max_age => 3600, path => "/"}
        ),
      ?LOG_DEBUG("Authresult Response~p", [Response0]),
      {200, jsx:encode(proplists:to_map(Response0)), Req0}
  end.


to_binary(Atom) when is_atom(Atom) -> list_to_binary(atom_to_list(Atom)).

redirect_resp(RedirectUri, FragParams, Req) ->
  Frag =
    binary_join(
      [
        <<
          (cowboy_http:urlencode(K))/binary,
          "=",
          (cowboy_http:urlencode(V))/binary
        >>
        || {K, V} <- FragParams
      ],
      <<"&">>
    ),
  Header = [{<<"location">>, <<RedirectUri/binary, "#", Frag/binary>>}],
  cowboy_req:reply(302, Header, <<>>, Req).


binary_join([H], _Sep) -> <<H/binary>>;

binary_join([H | T], Sep) ->
  <<H/binary, Sep/binary, (binary_join(T, Sep))/binary>>;

binary_join([], _Sep) -> <<>>.
