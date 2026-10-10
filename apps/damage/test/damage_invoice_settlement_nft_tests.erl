-module(damage_invoice_settlement_nft_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT, <<"ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ">>).
-define(RECIPIENT, <<"ak_2NgBkrcLxww49XuJAEa4sA3WFb6c3TbcinDptJGuwxyFRtWWwp">>).

attestation_hash_test() ->
    I = invoice(),
    Hash = damage_invoice_settlement_nft:attestation_hash(I),
    ?assertEqual(64, byte_size(Hash)),
    ?assertMatch(match, re:run(Hash, <<"^[0-9a-f]{64}$">>, [{capture, none}])),
    ?assertEqual(Hash, damage_invoice_settlement_nft:attestation_hash(I)),
    ?assertNotEqual(Hash, damage_invoice_settlement_nft:attestation_hash(I#{payment_reference => <<"OTHER">>})).

prepare_is_private_test() ->
    with_config(fun() ->
        I = invoice(),
        {ok, S} = damage_invoice_settlement_nft:prepare(I, ?RECIPIENT),
        ?assertEqual(<<"queued">>, maps:get(status, S)),
        ?assertEqual(?RECIPIENT, maps:get(recipient, S)),
        ?assertEqual(?CONTRACT, maps:get(contract_id, S)),
        ?assertEqual(<<"customer">>, maps:get(reward_class, S)),
        ?assertEqual(false, maps:is_key(customer, S)),
        ?assertEqual(false, maps:is_key(total_minor, S)),
        ?assertEqual(false, maps:is_key(payment_reference, S)),
        ?assertEqual(false, maps:is_key(pdf, S)),
        ?assertMatch({error, _}, damage_invoice_settlement_nft:prepare(I, <<"not-an-account">>))
    end).

status_disabled_without_contract_test() ->
    Prev = application:get_env(damage, enterprise_invoices),
    try
        application:set_env(damage, enterprise_invoices,
            [{enabled,true},{settlement_nft,[{enabled,false},{contract_id,?CONTRACT}]}]),
        ?assertEqual(false, maps:get(enabled, damage_invoice_settlement_nft:status()))
    after
        restore(enterprise_invoices, Prev)
    end.

with_config(Fun) ->
    Prev = application:get_env(damage, enterprise_invoices),
    try
        application:set_env(damage, enterprise_invoices,
            [{enabled,true},{settlement_nft,[{enabled,true},{contract_id,?CONTRACT},{reward_class,<<"customer">>}]}]),
        Fun()
    after
        restore(enterprise_invoices, Prev)
    end.

restore(Key, {ok, Value}) -> application:set_env(damage, Key, Value);
restore(Key, undefined) -> application:unset_env(damage, Key).

invoice() ->
    #{status => <<"paid">>, id => <<"invoice-1">>, number => <<"DBDD-ENT-000001">>,
      plan_id => <<"retainer">>, customer => #{id => <<"customer-1">>},
      pdf_sha256 => <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>,
      paid_on => <<"2026-10-11">>, payment_reference => <<"PRIVATE-REFERENCE">>,
      currency => <<"AUD">>, total_minor => 85000}.
