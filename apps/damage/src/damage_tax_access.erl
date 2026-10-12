%%%-------------------------------------------------------------------
%%% Tax-specific privileged access. Role membership comes from authenticated
%%% server state AND the current operator-controlled allowlists; never from
%%% client JSON, Gherkin context, or an account address on its own.
%%%-------------------------------------------------------------------
-module(damage_tax_access).
-export([allowed/1]).

-spec allowed(map()) -> boolean().
allowed(#{authenticated := true, public_key := Account} = State) when
    is_binary(Account)
->
    %% L402 and browser wallet sessions may own the same account address,
    %% but cannot administer financial records or change node settings.
    case {maps:get(auth_mode, State, legacy), maps:get(auth_type, State, legacy)} of
        {wallet, _} ->
            false;
        {<<"wallet">>, _} ->
            false;
        {_, l402} ->
            false;
        {_, <<"l402">>} ->
            false;
        _ ->
            (maps:get(node_admin, State, false) =:= true andalso
                damage_auth:is_node_admin_account(Account)) orelse
                (maps:get(tax_admin, State, false) =:= true andalso
                    damage_auth:is_tax_admin_account(Account))
    end;
allowed(_) ->
    false.
