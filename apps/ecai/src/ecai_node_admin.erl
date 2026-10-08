%% DamageBDD owns the authoritative node administrator list. ECAI may
%% restrict that list but must never grant privileges to other accounts.
-module(ecai_node_admin).

-export([is_node_admin/1, can_manage_code/1, allowed_by_policy/3]).

is_node_admin(Account) ->
    member(Account, application:get_env(damage, node_admins, [])).

can_manage_code(Account) ->
    allowed_by_policy(Account,
        application:get_env(damage, node_admins, []),
        application:get_env(ecai, code_admin_accounts, [])).

%% Empty ECAI scope admits all DamageBDD node admins (only when enabled
%% by the separate code_admin_enabled flag in the caller).
allowed_by_policy(Account, DamageAdmins, EcaiScope) ->
    member(Account, DamageAdmins) andalso in_scope(Account, EcaiScope).

in_scope(_Account, []) -> true;
in_scope(Account, Accounts) -> member(Account, Accounts).

member(Account, Accounts) when is_binary(Account), byte_size(Account) > 0,
                               is_list(Accounts) ->
    lists:any(fun(Entry) -> normalize(Entry) =:= Account end, Accounts);
member(_, _) -> false.

normalize(Value) when is_binary(Value), byte_size(Value) > 0 -> Value;
normalize(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary), byte_size(Binary) > 0 -> Binary;
        _ -> invalid
    catch
        _:_ -> invalid
    end;
normalize(_) -> invalid.
