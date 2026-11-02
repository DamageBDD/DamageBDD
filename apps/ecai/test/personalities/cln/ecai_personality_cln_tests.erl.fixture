-module(ecai_personality_cln_tests).
-include_lib("eunit/include/eunit.hrl").

existing_invoice_is_reused_test() ->
    script([{list_invoices_by_label, invoices(invoice())}]),
    {ok, I} = ecai_personality_cln:ensure_invoice(order()),
    ?assertEqual(unpaid, maps:get(status, I)),
    ?assert(damage_cln:exhausted()),
    ?assertEqual(0, creates()).

ambiguous_create_reconciles_same_label_test() ->
    script([{list_invoices_by_label, invoices([])},
            {create_invoice, {raise, timeout}},
            {list_invoices_by_label, invoices(invoice())}]),
    {ok, I} = ecai_personality_cln:ensure_invoice(order()),
    ?assertEqual(<<"ecai-personality-order-test">>, maps:get(label, I)),
    ?assertEqual(1, creates()),
    [{create_invoice, [100000, <<"ECAI personality edition">>, 900,
                       <<"ecai-personality-order-test">>]}] =
        [C || {create_invoice, _} = C <- damage_cln:calls()],
    ?assert(damage_cln:exhausted()),
    %% A retry after coordinator failure observes the existing invoice.
    script([{list_invoices_by_label, invoices(invoice())}]),
    {ok, _} = ecai_personality_cln:ensure_invoice(order()),
    ?assertEqual(0, creates()).

ambiguous_create_never_replaces_label_test() ->
    script([{list_invoices_by_label, invoices([])},
            {create_invoice, {error, timeout}},
            {list_invoices_by_label, invoices([])}]),
    ?assertEqual({error, invoice_creation_uncertain},
                 ecai_personality_cln:ensure_invoice(order())),
    ?assertEqual(1, creates()),
    ?assert(damage_cln:exhausted()).

invalid_preflight_never_creates_test() ->
    script([{list_invoices_by_label, #{<<"error">> => <<"offline">>}}]),
    ?assertEqual({error, cln_rpc_error}, ecai_personality_cln:ensure_invoice(order())),
    ?assertEqual(0, creates()).

msat_encodings_paid_test() ->
    lists:foreach(fun(Value) ->
        Paid = (invoice())#{<<"status">> => <<"paid">>,
                            <<"amount_msat">> => Value,
                            <<"amount_received_msat">> => <<"100001msat">>},
        script([{list_invoices_by_label, invoices(Paid)}]),
        {ok, I} = ecai_personality_cln:lookup_invoice(order()),
        ?assertEqual(paid, maps:get(status, I)),
        ?assertEqual(100000, maps:get(amount_msat, I)),
        ?assertEqual(100001, maps:get(amount_received_msat, I)),
        ?assertEqual(0, creates())
    end, [100000, <<"100000msat">>, #{msat => 100000}, #{<<"msat">> => 100000}]).

incorrect_amount_label_hash_and_underpayment_test() ->
    Cases = [
        {(invoice())#{<<"amount_msat">> => 99000}, order(), invoice_amount_mismatch},
        {(invoice())#{<<"label">> => <<"another-order">>}, order(), invoice_label_mismatch},
        {invoice(), (order())#{payment_hash => binary:copy(<<"b">>, 64)}, invoice_hash_mismatch},
        {invoice(), (order())#{bolt11 => <<"lnbcrt1other">>}, invoice_bolt11_mismatch},
        {(invoice())#{<<"status">> => <<"paid">>, <<"amount_received_msat">> => 99999},
             order(), invoice_underpaid},
        {(invoice())#{<<"status">> => <<"paid">>}, order(), invalid_cln_msat},
        {(invoice())#{<<"status">> => <<"complete">>}, order(), invalid_cln_invoice_status}
    ],
    lists:foreach(fun({Invoice, Order, Why}) ->
        script([{list_invoices_by_label, invoices(Invoice)}]),
        ?assertEqual({error, Why}, ecai_personality_cln:lookup_invoice(Order)),
        ?assertEqual(0, creates())
    end, Cases).

duplicate_invoices_rejected_test() ->
    script([{list_invoices_by_label, invoices([invoice(), invoice()])}]),
    ?assertEqual({error, ambiguous_invoice}, ecai_personality_cln:ensure_invoice(order())),
    ?assertEqual(0, creates()).

lookup_absence_does_not_create_test() ->
    script([{list_invoices_by_label, invoices([])}]),
    ?assertEqual({error, invoice_not_found}, ecai_personality_cln:lookup_invoice(order())),
    ?assertEqual(0, creates()).

treasury_identity_and_network_are_frozen_test() ->
    lists:foreach(fun(Info) ->
        damage_cln:script([{getinfo, Info}]),
        ?assertEqual({error, treasury_identity_or_network_mismatch},
                     ecai_personality_cln:ensure_invoice(order())),
        ?assertEqual(0, creates()),
        ?assert(damage_cln:exhausted())
    end, [#{id => node_id(), network => <<"bitcoin">>},
          #{id => <<"03", (binary:copy(<<"b">>, 64))/binary>>, network => <<"regtest">>}]).

unconfigured_or_unauthorized_mainnet_never_calls_cln_test() ->
    damage_cln:script([]),
    ?assertEqual({error, lightning_not_configured},
        ecai_personality_cln:ensure_invoice(maps:remove(lightning_config, order()))),
    Cfg = #{treasury_node => node_id(), network => <<"bitcoin">>, allow_mainnet => false},
    ?assertEqual({error, mainnet_not_authorized},
        ecai_personality_cln:ensure_invoice((order())#{lightning_config => Cfg})),
    ?assertEqual([], damage_cln:calls()).

config_validation_is_pure_test() ->
    damage_cln:script([]),
    Cfg = maps:get(lightning_config, order()),
    ?assertEqual(ok, ecai_personality_cln:validate_config(Cfg)),
    ?assertEqual({error, lightning_not_configured},
                 ecai_personality_cln:validate_config(#{})),
    ?assertEqual({error, lightning_not_configured},
                 ecai_personality_cln:validate_config(Cfg#{allow_mainnet => <<"false">>})),
    ?assertEqual({error, mainnet_not_authorized},
                 ecai_personality_cln:validate_config(Cfg#{network => <<"bitcoin">>})),
    ?assertEqual(ok, ecai_personality_cln:validate_config(
                     Cfg#{network => <<"bitcoin">>, allow_mainnet => true})),
    ?assertEqual([], damage_cln:calls()).

script(Steps) -> damage_cln:script([{getinfo,
    #{<<"id">> => node_id(), <<"network">> => <<"regtest">>}} | Steps]).
node_id() -> <<"02", (binary:copy(<<"a">>, 64))/binary>>.
order() -> #{label => <<"ecai-personality-order-test">>, price_sats => 100,
    invoice_expiry_seconds => 900,
    lightning_config => #{treasury_node => node_id(), network => <<"regtest">>,
                          allow_mainnet => false}}.
invoice() -> #{<<"label">> => <<"ecai-personality-order-test">>,
    <<"bolt11">> => <<"lnbcrt1fixture">>,
    <<"payment_hash">> => binary:copy(<<"a">>, 64),
    <<"amount_msat">> => 100000, <<"status">> => <<"unpaid">>,
    <<"expires_at">> => 1999999999}.
invoices(M) when is_map(M) -> invoices([M]);
invoices(L) -> #{<<"invoices">> => L}.
creates() -> length([C || {create_invoice, _} = C <- damage_cln:calls()]).
