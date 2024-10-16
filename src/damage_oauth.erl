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
  TokenEncrypted = base64:encode(damage_utils:encrypt(Token)),
  case damage_ae:contract_call_admin_account("get_auth_token", [TokenEncrypted]) of
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

    notfound -> {error, <<"Invalid reset password link. Please try again.">>}
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
        notfound ->
          case verify_email(Email, Password, NewPassword) of
            {ok, Message} ->
              damage_ae:set_meta(
                maps:put(
                  password,
                  NewPassword,
                  #{password => NewPassword, email => Email}
                )
              ),
              {ok, Message};

            Error -> Error
          end;

        #{password := Password} = Meta ->
          damage_ae:set_meta(maps:put(password, NewPassword, Meta));

        #{email := Email} = _Meta -> {error, <<"Email already confirmed">>}
      end;

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
      damage_ae:set_token(
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
  Now = date_util:now_to_seconds(os:timestamp()),
  _EmailEncrypted = base64:encode(damage_utils:encrypt(Email)),
  _TokenEncrypted = base64:encode(damage_utils:encrypt(Password)),
  case damage_ae:contract_call_admin_account("get_auth_token", [Password]) of
    #{decodedResult := EncryptedMetaJson} ->
      case
      jsx:decode(
        damage_utils:decrypt(base64:decode(EncryptedMetaJson)),
        [return_maps, {labels, atom}]
      ) of
        #{email := Email, expiry := Expiry} when Expiry - Now > 3600 ->
          {error, <<"Confirm Token Expired.">>};

        #{email := Email} ->
          {_, #{public_key := AeAccount}} =
            damage_ae:maybe_create_wallet(Email, NewPassword),
          #{decodedResult := []} =
            damage_ae:transfer_damage_tokens(
              AeAccount,
              damage:sats_to_damage(4000)
            ),
          damage_ae:revoke_token(Email,Password),
          {ok, <<"Account Verified">>}
      end;

    Err ->
      ?LOG_ERROR("invalid confirm token ~p", [Err]),
      {error, <<"Invalid confirm token.">>}
  end.


add_confirm_token(#{email := ToEmail} = Data0) ->
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
  Expiry = date_util:now_to_seconds(os:timestamp()) + 3600,
  TempPasswordEncrypted = base64:encode(damage_utils:encrypt(TempPassword)),
  TokenEncrypted =
    base64:encode(
      damage_utils:encrypt(jsx:encode(#{email => ToEmail, expiry => Expiry}))
    ),
  [] =
    damage_ae:contract_call_admin_account(
      "add_auth_token",
      [TempPasswordEncrypted, TokenEncrypted]
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
  case catch damage_ae:get_meta(Email) of
    notfound -> add_confirm_token(damage_utils:binary_to_atom_keys(Meta));

    {badmatch, #{status := <<"fail">>}} ->
      add_confirm_token(damage_utils:binary_to_atom_keys(Meta));

    #{password := _Password, email := _Email} = _Found ->
      {
        error,
        <<
          "Account with that email already exists. Please check your email for confirmation link. Don't forget to check spam folder too. If you have forgotten the password please reset password using /accounts/reset_password endpoint or from https://damagebdd.com/account"
        >>
      }
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
      ?LOG_ERROR("authenticate_user error ~p ", [Error]),
      Error;

    notfound ->
      ?LOG_ERROR("authenticate_user error ~p ", [notfound]),
      {error, notfound}
  end.


authenticate_client(_ClientId, _ClientSecret) -> {error, notfound}.

get_client_identity(_ClientId, _Identity) -> {error, notfound}.

associate_access_code(AccessCode, Context, _AppContext) ->
  associate_access_token(AccessCode, Context, _AppContext).

associate_refresh_token(RefreshToken, Context, _) ->
  Context0 = maps:from_list(Context),
  ok = damage_ae:set_auth_token(RefreshToken, Context0),
  {ok, Context0}.

%% @doc Stores a new refresh token token(), associating it with
%%      grantctx() and a device_id.

associate_refresh_token(RefreshToken, Context, DeviceId, _) ->
  damage_ae:set_token(RefreshToken, maps:put(device_id, DeviceId, Context)).

associate_access_token(AccessToken, Context, _) ->
  #{<<"resource_owner">> := Email} = Context0 = maps:from_list(Context),
  DamageAEPid = damage_ae:get_wallet_proc(Email),
  ContextEncrypted = base64:encode(damage_utils:encrypt(jsx:encode(Context0))),
  AccessTokenEncrypted = base64:encode(damage_utils:encrypt(AccessToken)),
  ok =
    gen_server:call(
      DamageAEPid,
      {set_access_token, AccessTokenEncrypted, ContextEncrypted},
      60000
    ),
  {ok, Context0}.


resolve_access_code(AccessCode, _AppContext) ->
  resolve_access_token(AccessCode, _AppContext).

resolve_refresh_token(RefreshToken, _AppContext) ->
  resolve_access_token(RefreshToken, _AppContext).

resolve_access_token(AccessToken, AppContext) ->
  %% The case trickery is just here to make sure that
  %% we don't propagate errors that cannot be legally
  %% returned from this function according to the spec.
  DamageAEPid = damage_ae:get_wallet_proc(admin),
  AccessTokenEncrypted = base64:encode(damage_utils:encrypt(AccessToken)),
  case gen_server:call(DamageAEPid, {get_access_token, AccessTokenEncrypted}) of
    notfound -> {error, notfound};

    Value ->
      Value0 = maps:to_list(Value),
      {ok, {AppContext, Value0}}
  end.


revoke_access_code(AccessCode, _AppContext) ->
  revoke_access_token(AccessCode, _AppContext).

revoke_access_token(AccessToken, _) ->
  AccessTokenEncrypted = base64:encode(damage_utils:encrypt(AccessToken)),
  DamageAEPid = damage_ae:get_wallet_proc(admin),
  ok = gen_server:call(DamageAEPid, {revoke_auth_token, AccessTokenEncrypted}).


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
