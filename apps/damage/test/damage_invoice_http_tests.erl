-module(damage_invoice_http_tests).
-include_lib("eunit/include/eunit.hrl").
bearer_only_test() ->
    ?assertEqual(error,damage_invoice_http:bearer(<<>>)),
    ?assertEqual(error,damage_invoice_http:bearer(<<"Bearer ">>)),
    ?assertEqual(error,damage_invoice_http:bearer(<<"L402 macaroon:preimage">>)),
    ?assertEqual(error,damage_invoice_http:bearer(<<"Nostr token">>)),
    ?assertEqual({ok,<<"test-token">>},damage_invoice_http:bearer(<<"Bearer test-token">>)).
private_routes_test() ->
    ?assertEqual(session,damage_invoice_http:route(<<"GET">>,[<<"session">>],#{})),
    ?assertEqual({get_pdf,<<"invoice-1">>},damage_invoice_http:route(<<"GET">>,[<<"invoices">>,<<"invoice-1">>,<<"pdf">>],#{})),
    ?assertThrow(not_found,damage_invoice_http:route(<<"POST">>,[<<"invoices">>,<<"invoice-1">>,<<"pay_wallet">>],#{})),
    ?assertThrow(not_found,damage_invoice_http:route(<<"DELETE">>,[<<"invoices">>,<<"invoice-1">>],#{})),
    ?assertThrow({validation,_},damage_invoice_http:route(<<"GET">>,[<<"invoices">>,<<"../secret">>],#{})),
    ?assertThrow({validation,_},damage_invoice_http:route(<<"PUT">>,[<<"customers">>,<<"a">>],#{<<"id">> => <<"b">>})).
