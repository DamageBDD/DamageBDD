-module(damage_nsecbunker_policy_tests).

-include_lib("eunit/include/eunit.hrl").

policy() ->
    (damage_nsecbunker_policy:default_policy())#{
        bunker_pubkey_hex => <<"BUNKER">>,
        authorized_clients => [<<"CLIENT">>],
        contract_sha => <<"CONTRACT">>
    }.

vault_pubkey() -> <<"BUNKER">>.

valid_event(Now) ->
    #{
        kind => 30023,
        created_at => Now,
        tags => [
            [<<"d">>, <<"manifesto">>],
            [<<"title">>, <<"Manifesto">>],
            [<<"published_at">>, integer_to_binary(Now)]
        ],
        content => <<"# Manifesto\n\nMarkdown only.">>
    }.

valid_request(Now) ->
    #{
        requester_pubkey => <<"CLIENT">>,
        request_id => <<"REQ-1">>,
        method => <<"sign_event">>,
        created_at => Now,
        event => valid_event(Now)
    }.

valid_sign_event_test() ->
    Now = 1778000000,
    ?assertMatch(
        {ok, _},
        damage_nsecbunker_policy:authorize(valid_request(Now), policy(), Now, vault_pubkey())
    ).

unauthorized_client_test() ->
    Now = 1778000000,
    Req = (valid_request(Now))#{requester_pubkey => <<"OTHER">>},
    ?assertEqual(
        {error, client_not_authorized},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

method_exact_match_test() ->
    Now = 1778000000,
    Req = (valid_request(Now))#{method => <<"SIGN_EVENT">>},
    ?assertEqual(
        {error, method_not_allowed},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

stale_request_test() ->
    Now = 1778000000,
    Req = (valid_request(Now))#{created_at => Now - 601},
    ?assertEqual(
        {error, request_stale},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

future_event_test() ->
    Now = 1778000000,
    Event = (valid_event(Now))#{created_at => Now + 601},
    Req = (valid_request(Now))#{event => Event},
    ?assertEqual(
        {error, event_from_future},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

kind_not_allowed_test() ->
    Now = 1778000000,
    Event = (valid_event(Now))#{kind => 9735},
    Req = (valid_request(Now))#{event => Event},
    ?assertEqual(
        {error, kind_not_allowed},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

missing_required_tag_test() ->
    Now = 1778000000,
    Event = (valid_event(Now))#{tags => [[<<"d">>, <<"manifesto">>]]},
    Req = (valid_request(Now))#{event => Event},
    ?assertEqual(
        {error, missing_required_tag},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

active_content_test() ->
    Now = 1778000000,
    Event = (valid_event(Now))#{content => <<"# x\n<script>alert(1)</script>">>},
    Req = (valid_request(Now))#{event => Event},
    ?assertEqual(
        {error, active_content_not_allowed},
        damage_nsecbunker_policy:authorize(Req, policy(), Now, vault_pubkey())
    ).

vault_pubkey_mismatch_test() ->
    Now = 1778000000,
    ?assertEqual(
        {error, vault_pubkey_mismatch},
        damage_nsecbunker_policy:authorize(valid_request(Now), policy(), Now, <<"OTHER_BUNKER">>)
    ).
