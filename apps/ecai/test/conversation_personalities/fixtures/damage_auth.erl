%% Test-only canonical principal helper.
-module(damage_auth).
-export([authenticated_account/1]).
authenticated_account(#{canonical_owner := Owner}) when is_binary(Owner) -> {ok, Owner};
authenticated_account(_) -> {error, unauthenticated}.
