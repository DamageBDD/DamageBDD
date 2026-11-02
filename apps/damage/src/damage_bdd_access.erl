%% Browser authoring and agent management are authenticated control-plane APIs.
%% They must not mint invoices or turn a paid L402 identity into custody authority.
-module(damage_bdd_access).
-license("Apache-2.0").
-export([is_authorized/2, credential_allowed/1]).

is_authorized(Req, State) ->
    case credential_allowed(damage_access_token:get_access_token(Req)) of
        true -> damage_auth:require_auth(Req, State,
            fun deny/2, fun(R, _Reason, S) -> deny(R, S) end);
        false -> deny(Req, State)
    end.
credential_allowed({access_token, Token}) -> is_binary(Token) andalso byte_size(Token) > 0;
credential_allowed(_) -> false.
deny(Req, State) -> {{false, <<"Bearer">>}, Req, State}.
