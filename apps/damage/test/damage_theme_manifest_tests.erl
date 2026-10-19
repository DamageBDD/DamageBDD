-module(damage_theme_manifest_tests).
-include_lib("eunit/include/eunit.hrl").

valid_theme_test() ->
    {ok, Manifest} = damage_theme_manifest:validate(sample()),
    ?assertEqual(<<"test-theme@1.2.3">>, damage_theme_manifest:key(Manifest)),
    ?assertEqual([<<"damage">>, <<"nosternity">>], maps:get(<<"apps">>, Manifest)),
    ?assertEqual(64, byte_size(damage_theme_manifest:package_hash(Manifest))).

stable_digest_test() ->
    {ok, A} = damage_theme_manifest:validate(sample()),
    {ok, B} = damage_theme_manifest:validate(maps:from_list(lists:reverse(maps:to_list(sample())))),
    ?assertEqual(damage_theme_manifest:package_hash(A), damage_theme_manifest:package_hash(B)),
    ?assertNotEqual(damage_theme_manifest:package_hash(A),
                    damage_theme_manifest:package_hash(A#{<<"price_sats">> => 4000})).

malicious_color_rejected_test() ->
    Theme = sample(),
    Tokens = maps:get(<<"tokens">>, Theme),
    Bad = Theme#{<<"tokens">> => Tokens#{<<"accent">> => <<"red; background:url(https://evil.invalid)">>}},
    ?assertMatch({error, invalid_theme_manifest}, damage_theme_manifest:validate(Bad)).

malicious_logo_rejected_test() ->
    lists:foreach(fun(Logo) ->
        ?assertMatch({error, invalid_branding},
            damage_theme_manifest:validate_branding(#{<<"logo">> => Logo}))
    end, [<<"https://tracker.invalid/logo.png">>,
          <<"/static/img/../../private.png">>,
          <<"/static/img/a//b.png">>,
          <<"/static/img/evil.svg">>,
          <<"javascript:alert(1)">>]).

malicious_name_rejected_test() ->
    ?assertMatch({error, invalid_theme_manifest},
        damage_theme_manifest:validate((sample())#{<<"name">> => <<"<script>bad</script>">>})).

unsupported_app_rejected_test() ->
    ?assertMatch({error, invalid_theme_manifest},
        damage_theme_manifest:validate((sample())#{<<"apps">> => [<<"system">>]})).

css_is_data_only_test() ->
    {ok, Manifest} = damage_theme_manifest:validate(sample()),
    Css = damage_theme_manifest:css(<<"damage">>, Manifest),
    ?assertMatch({_, _}, binary:match(Css, <<"--damage-accent:#bada55;">>)),
    ?assertEqual(nomatch, binary:match(Css, <<"url(">>)),
    ?assertEqual(nomatch, binary:match(Css, <<"@import">>)).

invoice_paid_requires_matching_identity_and_amount_test() ->
    Order = order(),
    Paid = paid_invoice(),
    ?assertEqual(paid, damage_theme_purchase:verify_invoice(Order, #{invoices => [Paid]})),
    ?assertMatch({error, mismatched_invoice}, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{label => <<"other">>}]})),
    ?assertMatch({error, mismatched_invoice}, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{payment_hash => <<"other">>}]})),
    ?assertEqual(unpaid, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{amount_received_msat => 2999999}]})),
    ?assertEqual(unpaid, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{status => <<"unpaid">>}]})),
    ?assertMatch({error, mismatched_invoice}, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{amount_msat => 1000}]})),
    ?assertMatch({error, mismatched_invoice}, damage_theme_purchase:verify_invoice(Order,
        #{invoices => [Paid#{bolt11 => <<"lnbc-forged">>}]})).

invoice_rejects_ambiguous_response_test() ->
    ?assertMatch({error, invalid_invoice_response},
        damage_theme_purchase:verify_invoice(order(), #{invoices => [paid_invoice(), paid_invoice()]})).

sample() ->
    #{<<"schema">> => <<"damage-theme/v1">>, <<"id">> => <<"test-theme">>,
      <<"version">> => <<"1.2.3">>, <<"name">> => <<"Test Theme">>,
      <<"description">> => <<"A verified design system">>,
      <<"tokens">> => #{<<"background">> => <<"#111111">>,
          <<"surface">> => <<"#222222">>, <<"text">> => <<"#ffffff">>,
          <<"muted">> => <<"#999999">>, <<"accent">> => <<"#bada55">>,
          <<"border">> => <<"#555555">>},
      <<"apps">> => [<<"nosternity">>, <<"damage">>],
      <<"price_sats">> => 3000, <<"price_damage">> => 500000000}.

order() ->
    #{<<"label">> => <<"theme:test-1">>, <<"payment_hash">> => <<"abc012">>,
      <<"invoice">> => <<"lnbc-test">>,
      <<"amount_msat">> => 3000000, <<"expires_at">> => erlang:system_time(second) + 3600}.

paid_invoice() ->
    #{label => <<"theme:test-1">>, payment_hash => <<"abc012">>,
      bolt11 => <<"lnbc-test">>, amount_msat => 3000000,
      amount_received_msat => 3000000, status => <<"paid">>}.
