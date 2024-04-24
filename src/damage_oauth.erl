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

-define(ACCESS_TOKEN_BUCKET, {<<"Default">>, <<"AccessTokens">>}).
-define(REFRESH_TOKEN_BUCKET, {<<"Default">>, <<"RefreshTokens">>}).
-define(CONFIRM_TOKEN_BUCKET, {<<"Default">>, <<"ConfirmTokens">>}).
-define(USER_BUCKET, {<<"Default">>, <<"Users">>}).
-define(CLIENT_BUCKET, {<<"Default">>, <<"Clients">>}).
-define(CONFIRM_TOKEN_EXPIRY, 1440).

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


get_token_expiry(Mins) -> date_util:epoch_hires() + (Mins * 60).

reset_password(#{token := Token}) ->
  case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Token) of
    {ok, #{email := Email, expiry := _Expiry}} ->
      case damage_riak:get(?USER_BUCKET, Email) of
        {ok, User} ->
          damage_riak:put(?USER_BUCKET, Email, maps:put(password, Token, User)),
          damage_riak:delete(?CONFIRM_TOKEN_BUCKET, Token),
          {
            ok,
            damage_utils:load_template(
              "reset_password.mustache",
              #{email => Email, current_password => Token}
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
  case damage_riak:get(?USER_BUCKET, Email) of
    notfound -> {error, <<"Invalid request.">>};

    {ok, #{password := Password} = KycData} ->
      case validate_password(NewPassword) of
        true ->
          damage_riak:put(
            ?USER_BUCKET,
            Email,
            maps:put(password, NewPassword, KycData)
          ),
          damage_riak:delete(?CONFIRM_TOKEN_BUCKET, Password),
          {ok, <<"Password successfuly reset.">>};

        _ ->
          {
            error,
            <<
              "Failed to reset password. Password does not meet complexity requirements of minimum 8 characters with at least one uppercase letter, one lowercase letter, one digit, and one special character"
            >>
          }
      end
  end;

reset_password(#{<<"email">> := Email}) ->
  TempPassword = list_to_binary(uuid:to_string(uuid:uuid4())),
  case damage_riak:get(?USER_BUCKET, Email) of
    notfound -> {error, <<"Invalid request.">>};

    {ok, Found} ->
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
        #{email => Email, expiry => get_token_expiry(?CONFIRM_TOKEN_EXPIRY)}
      ),
      damage_utils:send_email(
        {maps:get(full_name, Found, <<"">>), Email},
        <<"DamageBDD Password Reset">>,
        damage_utils:load_template("reset_password_email.txt.mustache", Ctxt),
        damage_utils:load_template("reset_password_email.html.mustache", Ctxt)
      ),
      %damage_riak:update(?USER_BUCKET, Email, Found),
      {ok, <<"Password Reset successfully.">>}
  end.


add_userdata(
  #{email := ToEmail, ae_contract_address := ContractAddress} = Data0
) ->
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
    #{email => ToEmail, expiry => get_token_expiry(?CONFIRM_TOKEN_EXPIRY)}
  ),
  damage_utils:send_email(
    {maps:get(full_name, Data, <<"">>), ToEmail},
    <<"DamageBDD Account SignUp">>,
    damage_utils:load_template("signup_email.txt.mustache", Ctxt),
    damage_utils:load_template("signup_email.html.mustache", Ctxt)
  ),
  damage_riak:put(
    ?USER_BUCKET,
    ToEmail,
    Data,
    [
      {{binary_index, "enc_email"}, [damage_utils:encrypt(ToEmail)]},
      {{binary_index, "contract"}, [ContractAddress]}
    ]
  ),
  {
    ok,
    <<
      "Account created. Please check email for confirmation link. Don't forget to check spam folder too."
    >>
  }.


add_user(#{business_name := BusinessName} = KycData) ->
  add_user(maps:merge(KycData, #{<<"full_name">> => BusinessName}));

add_user(#{email := ToEmail} = KycData) ->
  case damage_riak:get(?USER_BUCKET, ToEmail) of
    notfound ->
      ?LOG_DEBUG("account not found creating ~p", [ToEmail]),
      case damage_accounts:create_contract() of
        #{status := <<"ok">>, ae_contract_address := ContractAddress} = Data ->
          Data0 =
            maps:merge(
              Data,
              maps:put(contract_address, ContractAddress, KycData)
            ),
          add_userdata(damage_utils:binary_to_atom_keys(Data0));

        #{status := <<"notok">>} -> {error, <<"Account creation failed. .">>}
      end;

    {ok, #{password := Password} = Found} ->
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
          logger:info(" Accoun exists data: ~p ", [Found]),
          {
            error,
            <<
              "Account with that email already exists. Please check your email for confirmation link. Don't forget to check spam folder too. If you have forgotten the password please reset password using /accounts/reset_password endpoint or from https://damagebdd.com/account"
            >>
          }
      end
  end.


delete_user(Username) -> delete(?USER_BUCKET, Username).

add_client(Id, Secret, RedirectUri) ->
  put(
    ?CLIENT_BUCKET,
    Id,
    #{client_id => Id, client_secret => Secret, redirect_uri => RedirectUri}
  ).

add_client(Id, Secret) -> add_client(Id, Secret, undefined).

delete_client(Id) -> delete(?CLIENT_BUCKET, Id).

%%%===================================================================
%%% OAuth2 backend functions
%%%===================================================================

authenticate_user({Username, Password}, _Ctxt) ->
  ?LOG_DEBUG("authenticate_user ~p   ~p ", [Username, Password]),
  case damage_riak:get(?USER_BUCKET, Username) of
    {ok, #{password := UserPw}} ->
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
  case catch damage_riak:get(?CLIENT_BUCKET, ClientId) of
    {ok, #{client_secret := ClientSecret}} -> {ok, {<<"client">>, ClientId}};
    {ok, #{client_secret := _WrongSecret}} -> {error, badsecret};
    _ -> {error, notfound}
  end.


get_client_identity(ClientId, _) ->
  case get(?CLIENT_BUCKET, ClientId) of
    {ok, _} -> {ok, {<<"client">>, ClientId}};
    _ -> {error, notfound}
  end.


associate_access_code(AccessCode, Context, _AppContext) ->
  associate_access_token(AccessCode, Context, _AppContext).

associate_refresh_token(RefreshToken, Context, _) ->
  damage_riak:put(?REFRESH_TOKEN_BUCKET, RefreshToken, Context).

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
  damage_riak:put(?ACCESS_TOKEN_BUCKET, AccessToken, maps:from_list(Context)).

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
  delete(?ACCESS_TOKEN_BUCKET, AccessToken),
  ok.


revoke_refresh_token(_RefreshToken, _) -> ok.

get_redirection_uri(ClientId, _) ->
  case get(?CLIENT_BUCKET, ClientId) of
    {ok, #{redirect_uri := RedirectUri}} -> {ok, RedirectUri};
    Error = {error, notfound} -> Error
  end.


verify_redirection_uri(ClientId, ClientUri, _) ->
  case get(?CLIENT_BUCKET, ClientId) of
    {ok, #{redirect_uri := RedirUri}} when ClientUri =:= RedirUri ->
      {ok, RedirUri};

    _Error -> {error, mismatch}
  end.


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

get(Bucket, Key) ->
  case damage_riak:get(Bucket, Key) of
    [] -> {error, notfound};
    {ok, Value} -> Value
  end.


put(Bucket, Key, Value) ->
  damage_riak:put(Bucket, Key, Value),
  ok.


delete(Bucket, Key) -> damage_riak:delete(Bucket, Key).
