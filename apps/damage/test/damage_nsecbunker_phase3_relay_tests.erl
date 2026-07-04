-module(damage_nsecbunker_phase3_relay_tests).

-include_lib("eunit/include/eunit.hrl").

phase3_response_publish_return_only_test() ->
    Client = <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>,
    Event = #{kind => 24133, pubkey => <<"bunker">>, created_at => erlang:system_time(second), tags => [[<<"p">>, Client]], content => <<"ciphertext">>},
    Config = #{relay_publication_mode => return_only},
    ?assertMatch(
        {ok, #{signing_result := ok, response_event := _, publish_result := {ok, _}}},
        damage_nostr_relay_client:handle_bunker_result({ok, Event}, Config)
    ).

phase3_response_publish_failure_does_not_erase_signing_result_test() ->
    Client = <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>,
    Event = #{kind => 24133, pubkey => <<"bunker">>, created_at => erlang:system_time(second), tags => [[<<"p">>, Client]], content => <<"ciphertext">>},
    Config = #{relay_publication_mode => test_fail},
    ?assertMatch(
        {ok, #{signing_result := ok, response_event := _, publish_result := {error, relay_publish_test_failure}}},
        damage_nostr_relay_client:handle_bunker_result({ok, Event}, Config)
    ).

phase3_bunker_error_is_not_published_test() ->
    Config = #{relay_publication_mode => return_only},
    ?assertEqual(
        {error, client_not_authorized},
        damage_nostr_relay_client:handle_bunker_result({error, client_not_authorized}, Config)
    ).

phase3_filter_contains_kind_24133_and_p_tag_test() ->
    Pubkey = <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>,
    Config = #{bunker_pubkey_hex => Pubkey, relay_publication_mode => return_only},
    {ok, #{filter := Filter}} = damage_nostr_relay_client:subscribe(Config),
    ?assertEqual([24133], maps:get(kinds, Filter)),
    ?assertEqual([Pubkey], maps:get(<<"#p">>, Filter)).

phase3_inbound_requires_kind_24133_test() ->
    Event = #{kind => 1, pubkey => <<"client">>, created_at => erlang:system_time(second), tags => [], content => <<"x">>},
    Config = #{require_inbound_p_tag => false, relay_publication_mode => return_only},
    ?assertMatch({error, {unexpected_nip46_event_kind, 1}}, damage_nostr_relay_client:handle_inbound_event(Event, Config)).

phase3_inbound_requires_p_tag_when_configured_test() ->
    Pubkey = <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>,
    Event = #{kind => 24133, pubkey => <<"client">>, created_at => erlang:system_time(second), tags => [], content => <<"ciphertext">>},
    Config = #{bunker_pubkey_hex => Pubkey, require_inbound_p_tag => true, relay_publication_mode => return_only},
    ?assertEqual({error, inbound_event_not_p_tagged_to_bunker}, damage_nostr_relay_client:handle_inbound_event(Event, Config)).
