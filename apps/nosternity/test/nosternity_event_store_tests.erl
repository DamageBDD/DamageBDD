-module(nosternity_event_store_tests).

-include_lib("eunit/include/eunit.hrl").

verify_signed_event_test() ->
    Event = signed_event(1, <<"hello aeternity">>),
    ?assertMatch({ok, _}, damage_nostr_event:verify(Event)),
    ?assertMatch({ok, _}, nosternity_event_store:validate_event(Event, 4096)).

reject_modified_event_test() ->
    Event = signed_event(1, <<"hello aeternity">>),
    Tampered = Event#{content => <<"tampered">>},
    ?assertMatch({error, {event_id_mismatch, _, _}}, damage_nostr_event:verify(Tampered)),
    ?assertMatch(
        {error, {event_id_mismatch, _, _}}, nosternity_event_store:validate_event(Tampered, 4096)
    ).

kind_and_author_policy_test() ->
    Event = signed_event(7, <<"+">>),
    Pubkey = maps:get(pubkey, Event),
    ?assert(nosternity_event_store:should_store(Event, #{kinds => #{7 => true}, authors => all})),
    ?assert(
        nosternity_event_store:should_store(Event, #{kinds => all, authors => #{Pubkey => true}})
    ),
    ?assertNot(
        nosternity_event_store:should_store(Event, #{kinds => #{1 => true}, authors => all})
    ),
    ?assertNot(
        nosternity_event_store:should_store(Event, #{
            kinds => all, authors => #{<<"other">> => true}
        })
    ).

size_limit_test() ->
    Event = signed_event(30023, binary:copy(<<"a">>, 1024)),
    ?assertMatch({error, event_too_large}, nosternity_event_store:validate_event(Event, 128)).

signed_event(Kind, Content) ->
    PrivateKey = <<1:256>>,
    {ok, PubkeyBin} = nostrlib_schnorr:new_publickey(PrivateKey),
    Pubkey = damage_nostr_event:lower_hex(PubkeyBin),
    CreatedAt = 1700000000,
    Tags = [],
    Hash = crypto:hash(sha256, jsx:encode([0, Pubkey, CreatedAt, Kind, Tags, Content])),
    EventId = damage_nostr_event:lower_hex(Hash),
    {ok, Signature} = nostrlib_schnorr:sign(Hash, PrivateKey),
    #{
        id => EventId,
        pubkey => Pubkey,
        created_at => CreatedAt,
        kind => Kind,
        tags => Tags,
        content => Content,
        sig => damage_nostr_event:lower_hex(Signature)
    }.
