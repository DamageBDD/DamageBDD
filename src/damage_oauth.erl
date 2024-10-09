-module(damage_oauth).

-behavior(oauth2_backend).

%%% API

-export(
  [
    start/0,
    stop/0,
    add_user/1,
    reset_password/1,
    delete_user/1,
    add_client/2,
    add_client/3,
    delete_client/1
  ]
).

%%% Behavior API

-export([authenticate_user/2]).
-export([authenticate_client/2]).
-export([get_client_identity/2]).
-export([associate_access_code/3]).
-export([associate_refresh_token/3]).
-export([associate_refresh_token/4]).
-export([associate_access_token/3]).
-export([resolve_access_code/2]).
-export([resolve_refresh_token/2]).
-export([resolve_access_token/2]).
-export([revoke_access_code/2]).
-export([revoke_access_token/2]).
-export([revoke_refresh_token/2]).
-export([get_redirection_uri/2]).
-export([verify_redirection_uri/3]).
-export([verify_client_scope/3]).
-export([verify_resowner_scope/3]).
-export([verify_scope/3]).
-export([jwt_issuer/0]).
-export([jwt_sign/2]).
-export([jwt_verify/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(ACCESS_TOKEN_BUCKET, {<<"Default">>, <<"AccessTokens">>}).
-define(REFRESH_TOKEN_BUCKET, {<<"Default">>, <<"RefreshTokens">>}).
-define(CONFIRM_TOKEN_EXPIRY, date_util:epoch_hires() + (24 * 60)).

%%%===================================================================
%%% API
%%%===================================================================

start() ->
  add_client(
    <<"flutter_client">>,
    <<"flutter">>,
    <<"https://run.damagebdd.com">>
  ).

stop() -> ok.

validate_password(Password) ->
  %% Password validation logic here
  %% Replace this with your own password validation logic
  %% For example, minimum 8 characters with at least one uppercase letter,
  %% one lowercase letter, one digit, and one special character
  Regex =
    "^(?=.*\\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%^&*()_+\\-=[\\]{};':\"\\\\|,.<>/?]).{8,}$",
  case re:run(Password, Regex) of
    {match, _} -> true;
    _ -> false
  end.


reset_password(#{token := Token}) ->
  case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Token) of
    {ok, #{email := Email, expiry := _Expiry}} ->
      case damage_ae:set_meta(#{email => Email, password => Token}) of
        ok ->
          {
            ok,
            damage_utils:load_template(
              "reset_password.mustache",
              #{
                email => Email,
                current_password => Token,
                current_password_type => <<"hidden">>
              }
            )
          };

        _ -> {error, <<"Invalid reset password link. Please try again.">>}
      end;

    notfound ->
      ?LOG_DEBUG("confirm token not found ~p", [Token]),
      {error, <<"Invalid reset password link. Please try again.">>}
  end;

reset_password(
  #{
    <<"email">> := Email,
    <<"current_password">> := Password,
    <<"new_password_confirmation">> := NewPasswordConfirm,
    <<"new_password">> := NewPassword
  }
) ->
  NewPassword = NewPasswordConfirm,
  case validate_password(NewPassword) of
    true ->
      case damage_ae:get_meta(Email) of
        notfound -> verify_email(Email, Password, NewPassword);

        #{password := Password} = Meta ->
          damage_ae:set_meta(maps:put(password, NewPassword, Meta))
      end;

    {ok, #{email := Email} = _Meta} -> {error, <<"Authentication failed.">>};

    _ ->
      {
        error,
        <<
          "Failed to reset password. Password does not meet complexity requirements of minimum 8 characters with at least one uppercase letter, one lowercase letter, one digit, and one special character"
        >>
      }
  end;

reset_password(#{email := Email}) ->
  TempPassword = list_to_binary(uuid:to_string(uuid:uuid4())),
  case damage_ae:get_meta(Email) of
    notfound -> {error, <<"Invalid request.">>};

    #{email := Email} = Found ->
      {ok, ApiUrl} = application:get_env(damage, api_url),
      ApiUrl0 = list_to_binary(ApiUrl),
      Ctxt =
        maps:put(
          <<"password_reset_url">>,
          <<
            ApiUrl0/binary,
            "/accounts/reset_password?token=",
            TempPassword/binary
          >>,
          Found
        ),
      damage_riak:put(
        ?CONFIRM_TOKEN_BUCKET,
        TempPassword,
        #{email => Email, expiry => ?CONFIRM_TOKEN_EXPIRY}
      ),
      damage_utils:send_email(
        {maps:get(full_name, Found, <<"">>), Email},
        <<"DamageBDD Password Reset">>,
        damage_utils:load_template("reset_password_email.txt.mustache", Ctxt),
        damage_utils:load_template("reset_password_email.html.mustache", Ctxt)
      ),
      {ok, <<"Password Reset successfully.">>}
  end.


verify_email(Email, Password, NewPassword) ->
  Now = os:timestamp(),
  case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Password) of
    {ok, #{email := Email, expiry := Expiry}} when Expiry - Now > 3600 ->
      {notok, <<"Confirm Token Expired.">>};

    {ok, #{email := Email}} ->
      {ok, #{public_key := AeAccount}} =
        damage_ae:maybe_create_wallet(Email, NewPassword),
      #{decodedResult := []} =
        damage_ae:transfer_damage_tokens(
          AeAccount,
          damage_ae:sats_to_damage(4000)
        ),
      damage_riak:delete(?CONFIRM_TOKEN_BUCKET, Password);

    Err ->
      ?LOG_ERROR("invalid confirm token ~p", [Err]),
      {notok, <<"Invalid confirm token.">>}
  end.


add_userdata(#{email := ToEmail} = Data0) ->
  {ok, ApiUrl} = application:get_env(damage, api_url),
  ApiUrl0 = list_to_binary(ApiUrl),
  TempPassword = list_to_binary(uuid:to_string(uuid:uuid4())),
  Data = maps:put(password, TempPassword, Data0),
  Ctxt =
    maps:put(
      <<"password_reset_url">>,
      <<ApiUrl0/binary, "/accounts/confirm?token=", TempPassword/binary>>,
      Data
    ),
  damage_riak:put(
    ?CONFIRM_TOKEN_BUCKET,
    TempPassword,
    #{email => ToEmail, expiry => ?CONFIRM_TOKEN_EXPIRY}
  ),
  damage_utils:send_email(
    {maps:get(full_name, Data, <<"">>), ToEmail},
    <<"DamageBDD Account SignUp">>,
    damage_utils:load_template("signup_email.txt.mustache", Ctxt),
    damage_utils:load_template("signup_email.html.mustache", Ctxt)
  ),
  {
    ok,
    <<
      "Account created. Please check email for confirmation link. Don't forget to check spam folder too."
    >>
  }.


add_user(#{business_name := BusinessName} = Meta) ->
  add_user(maps:merge(Meta, #{<<"full_name">> => BusinessName}));

add_user(#{email := Email} = Meta) when is_atom(Email) ->
  add_user(maps:put(email, atom_to_binary(Email), Meta));

add_user(#{email := Email} = Meta) when is_binary(Email) ->
  case damage_ae:get_meta(Email) of
    notfound ->
      ?LOG_DEBUG("account not found creating ~p", [Email]),
      add_userdata(damage_utils:binary_to_atom_keys(Meta));

    #{password := Password, email := Email} = Found ->
      case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Password) of
        notfound -> add_userdata(Found);

        {ok, #{email := Email, expiry := Expiry}} ->
          case date_util:epoch_hires() of
            Now when Now > Expiry ->
              ok = damage_riak:delete(?CONFIRM_TOKEN_BUCKET, Password),
              ok = delete_user(Email),
              {
                error,
                <<
                  "Confirmation link expired, please signup again to get a new link."
                >>
              };

            _ -> add_userdata(Found)
          end;

        _ ->
          logger:info("Account exists data: ~p ", [Found]),
          {
            error,
            <<
              "Account with that email already exists. Please check your email for confirmation link. Don't forget to check spam folder too. If you have forgotten the password please reset password using /accounts/reset_password endpoint or from https://damagebdd.com/account"
            >>
          }
      end
  end.


delete_user(Username) -> damage_ae:delete_account(Username).

add_client(_Id, _Secret, _RedirectUri) -> {error, notimplemented}.

add_client(Id, Secret) -> add_client(Id, Secret, undefined).

delete_client(_Id) -> {error, notimplemented}.

%%%===================================================================
%%% OAuth2 backend functions
%%%===================================================================

authenticate_user({Username, Password}, _Ctxt) ->
  case damage_ae:get_meta(Username) of
    #{password := UserPw} ->
      case Password of
        UserPw -> {ok, {<<"user">>, Username}};
        _ -> {error, badpass}
      end;

    Error = {error, notfound} ->
      ?LOG_DEBUG("authenticate_user error ~p ", [Error]),
      Error;

    notfound ->
      ?LOG_DEBUG("authenticate_user error ~p ", [notfound]),
      {error, notfound}
  end.


authenticate_client(ClientId, ClientSecret) ->
  ?LOG_DEBUG("authenticate_client ~p   ~p ", [ClientId, ClientSecret]),
  {error, notfound}.


get_client_identity(ClientId, Identity) ->
  ?LOG_DEBUG("get_client_identity ~p   ~p ", [ClientId, Identity]),
  {error, notfound}.


associate_access_code(AccessCode, Context, _AppContext) ->
  associate_access_token(AccessCode, Context, _AppContext).

associate_refresh_token(RefreshToken, Context, _) ->
  ok = damage_riak:put(?REFRESH_TOKEN_BUCKET, RefreshToken, Context),
  {ok, maps:from_list(Context)}.

%% @doc Stores a new refresh token token(), associating it with
%%      grantctx() and a device_id.

associate_refresh_token(RefreshToken, Context, DeviceId, _) ->
  damage_riak:put(
    ?REFRESH_TOKEN_BUCKET,
    RefreshToken,
    Context,
    [{device_id_bin, DeviceId}]
  ).

associate_access_token(AccessToken, Context, _) ->
  #{email := Email} = Context0 = maps:from_list(Context),
  ok = damage_ae:set_token(Email, AccessToken, Context0),
  {ok, Context0}.


resolve_access_code(AccessCode, _AppContext) ->
  resolve_access_token(AccessCode, _AppContext).

resolve_refresh_token(RefreshToken, _AppContext) ->
  resolve_access_token(RefreshToken, _AppContext).

resolve_access_token(AccessToken, AppContext) ->
  %% The case trickery is just here to make sure that
  %% we don't propagate errors that cannot be legally
  %% returned from this function according to the spec.
  case
  damage_riak:get(?ACCESS_TOKEN_BUCKET, AccessToken, [{return_maps, false}]) of
    Error = notfound -> {error, Error};
    {ok, Value} -> {ok, {AppContext, Value}}
  end.


revoke_access_code(AccessCode, _AppContext) ->
  revoke_access_token(AccessCode, _AppContext).

revoke_access_token(AccessToken, _) ->
  damage_riak:delete(?ACCESS_TOKEN_BUCKET, AccessToken),
  ok.


revoke_refresh_token(_RefreshToken, _) -> ok.

get_redirection_uri(ClientId, _) ->
  ?LOG_ERROR("Not implemented get_redirection_uri ~p", [ClientId]),
  {error, notimplemented}.


verify_redirection_uri(ClientId, ClientUri, _) ->
  ?LOG_ERROR(
    "Not implemented verify_redirection_uri ~p ClientUri",
    [ClientId, ClientUri]
  ),
  {error, notimplemented}.


verify_client_scope(_ClientId, Scope, _) -> {ok, Scope}.

verify_resowner_scope(_ResOwner, Scope, Context) -> {ok, {Context, Scope}}.

verify_scope(Scope, Scope, _) -> {ok, Scope};
verify_scope(_, _, _) -> {error, invalid_scope}.

%% @doc Sign the grant context with a private key and produce a JWT.
%%      The grant context is a proplist carrying information about the identity
%%      with which the token is associated, when it expires, etc.

-spec jwt_sign(oauth2_backend:grantctx(), oauth2_backend:appctx()) ->
  {ok, oauth2_backend:token()}.
jwt_sign(GrantCtx, AppCtx) ->
  logger:info("jwt sign ~p ~p", [GrantCtx, AppCtx]),
  {ok, <<"Token">>}.

%% @doc Verifies a JWT, returning the corresponding grant context if
%%      verification succeeds.

-spec jwt_verify(oauth2_backend:token()) ->
  {ok, oauth2_backend:grantctx()} | {error, badjwt}.
jwt_verify(Token) -> {ok, Token}.

%% @doc A case-sensitive string or URI that uniquely identifies the issuer.

-spec jwt_issuer() -> binary().
jwt_issuer() -> <<"https://run.DamageBDD.com">>.

%%%===================================================================
%%% Internal functions
%%%===================================================================
