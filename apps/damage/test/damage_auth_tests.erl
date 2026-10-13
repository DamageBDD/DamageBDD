-module(damage_auth_tests).

-include_lib("eunit/include/eunit.hrl").

auth_success_state_identity_is_reusable_test() ->
    Account = <<"ak_test_account">>,
    State = damage_auth:auth_success_state(#{}, Account, #{}),
    ?assertEqual({ok, Account}, damage_auth:authenticated_account(State)).

public_key_is_canonical_identity_test() ->
    Account = <<"ak_public_key_owner">>,
    ?assertEqual(
        {ok, Account},
        damage_auth:authenticated_account(#{
            authenticated => true,
            public_key => Account
        })
    ).

legacy_identity_keys_remain_compatible_test() ->
    ?assertEqual(
        {ok, <<"ak_legacy_ae">>},
        damage_auth:authenticated_account(#{ae_account => <<"ak_legacy_ae">>})
    ),
    ?assertEqual(
        {ok, <<"ak_legacy_owner">>},
        damage_auth:authenticated_account(#{owner => "ak_legacy_owner"})
    ).

public_key_wins_over_legacy_aliases_test() ->
    ?assertEqual(
        {ok, <<"ak_public">>},
        damage_auth:authenticated_account(#{
            public_key => <<"ak_public">>,
            ae_account => <<"ak_ae">>,
            owner => <<"ak_owner">>
        })
    ).

missing_identity_is_rejected_test() ->
    ?assertEqual(
        {error, unauthenticated},
        damage_auth:authenticated_account(#{authenticated => false})
    ).
