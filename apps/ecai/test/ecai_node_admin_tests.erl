-module(ecai_node_admin_tests).
-include_lib("eunit/include/eunit.hrl").

empty_scope_allows_configured_damage_admin_test() ->
    Admin = <<"ak_admin">>,
    ?assert(ecai_node_admin:allowed_by_policy(Admin, ["ak_admin"], [])).

non_node_admin_cannot_elevate_test() ->
    ?assertNot(ecai_node_admin:allowed_by_policy(
        <<"ak_guest">>, ["ak_admin"], [<<"ak_guest">>])).

nonempty_ecai_scope_restricts_node_admins_test() ->
    ?assertNot(ecai_node_admin:allowed_by_policy(
        <<"ak_other">>, [<<"ak_other">>], ["ak_admin"])).

binary_and_string_admin_list_test() ->
    ?assert(ecai_node_admin:allowed_by_policy(
        <<"ak_admin">>, [<<"ak_admin">>], ["ak_admin"])).

invalid_scope_fails_closed_test() ->
    ?assertNot(ecai_node_admin:allowed_by_policy(
        <<"ak_admin">>, ["ak_admin"], undefined)),
    ?assertNot(ecai_node_admin:allowed_by_policy(
        <<"ak_admin">>, <<"ak_admin">>, [])).
