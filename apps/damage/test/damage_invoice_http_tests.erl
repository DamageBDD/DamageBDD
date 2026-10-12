-module(damage_invoice_http_tests).
-include_lib("eunit/include/eunit.hrl").
bearer_only_test() ->
    ?assertEqual(error, damage_invoice_http:bearer(<<>>)),
    ?assertEqual(error, damage_invoice_http:bearer(<<"Bearer ">>)),
    ?assertEqual(error, damage_invoice_http:bearer(<<"L402 macaroon:preimage">>)),
    ?assertEqual(error, damage_invoice_http:bearer(<<"Nostr token">>)),
    ?assertEqual({ok, <<"test-token">>}, damage_invoice_http:bearer(<<"Bearer test-token">>)).

auth_result_test() ->
    Account = <<"ak_billing_admin">>,
    ?assertEqual(
        {ok, Account},
        damage_invoice_http:auth_result(
            {ok, #{
                public_key => Account,
                auth_type => browser_session,
                auth_mode => custodial
            }}
        )
    ),
    ?assertEqual(
        {error, wallet_session_forbidden},
        damage_invoice_http:auth_result(
            {ok, #{
                public_key => Account,
                auth_type => browser_session,
                auth_mode => wallet
            }}
        )
    ),
    ?assertEqual(
        {ok, Account},
        damage_invoice_http:auth_result({ok, #{public_key => Account}})
    ),
    ?assertEqual(
        {error, invalid_oauth},
        damage_invoice_http:auth_result({error, invalid_oauth})
    ).
private_routes_test() ->
    ?assertEqual(session, damage_invoice_http:route(<<"GET">>, [<<"session">>], #{})),
    ?assertEqual(summary, damage_invoice_http:route(<<"GET">>, [<<"summary">>], #{})),
    ?assertEqual(settings, damage_invoice_http:route(<<"GET">>, [<<"settings">>], #{})),
    ?assertEqual(
        {save_settings, #{<<"revision">> => 0}},
        damage_invoice_http:route(<<"PUT">>, [<<"settings">>], #{<<"revision">> => 0})
    ),
    ?assertEqual(
        {create_customer, #{<<"name">> => <<"Generated ID customer">>}},
        damage_invoice_http:route(<<"POST">>, [<<"customers">>], #{
            <<"name">> => <<"Generated ID customer">>
        })
    ),
    ?assertEqual(
        {action, <<"invoice-1">>, <<"settlement_nft">>, #{<<"revision">> => 3}},
        damage_invoice_http:route(
            <<"POST">>, [<<"invoices">>, <<"invoice-1">>, <<"settlement_nft">>], #{
                <<"revision">> => 3
            }
        )
    ),
    ?assertEqual(
        {get_pdf, <<"invoice-1">>},
        damage_invoice_http:route(<<"GET">>, [<<"invoices">>, <<"invoice-1">>, <<"pdf">>], #{})
    ),
    ?assertThrow(
        not_found,
        damage_invoice_http:route(
            <<"POST">>, [<<"invoices">>, <<"invoice-1">>, <<"pay_wallet">>], #{}
        )
    ),
    ?assertThrow(
        not_found, damage_invoice_http:route(<<"DELETE">>, [<<"invoices">>, <<"invoice-1">>], #{})
    ),
    ?assertThrow(
        {validation, _},
        damage_invoice_http:route(<<"GET">>, [<<"invoices">>, <<"../secret">>], #{})
    ),
    ?assertThrow(
        {validation, _},
        damage_invoice_http:route(<<"PUT">>, [<<"customers">>, <<"a">>], #{<<"id">> => <<"b">>})
    ).
