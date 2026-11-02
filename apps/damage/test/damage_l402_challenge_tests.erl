-module(damage_l402_challenge_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLES, [damage_l402_tokens, damage_l402_by_hash, damage_l402_by_inv]).

facade_errors_are_propagated_test_() ->
    Errors = [
        {error, {cln_unavailable, {timeout, {gen_server, call, [self(), fixture]}}}},
        {error, {cln_unavailable, noproc}},
        {error, secrets_not_ready},
        {error, node_locked},
        {error, {cln_http_failed, response_timeout}}
    ],
    [?_test(with_fixture(Error, fun() ->
        ?assertEqual(Error, challenge()),
        assert_no_challenge(),
        ?assertEqual(1, meck:num_calls(damage_cln, create_invoice, 4))
    end)) || Error <- Errors].

malformed_invoices_do_not_create_tokens_test_() ->
    Good = valid_invoice(),
    Cases = [
        {undefined, {error, invalid_invoice_response}},
        {{ok, not_a_map}, {error, invalid_invoice_response}},
        {#{}, {error, {invalid_invoice_response, bolt11}}},
        {Good#{bolt11 => <<>>}, {error, {invalid_invoice_response, bolt11}}},
        {Good#{bolt11 => 42}, {error, {invalid_invoice_response, bolt11}}},
        {Good#{bolt11 => [not_iolist]}, {error, {invalid_invoice_response, bolt11}}},
        {Good#{bolt11 => <<"lnbc1fixture\r\nx-injected: yes">>},
            {error, {invalid_invoice_response, bolt11}}},
        {Good#{bolt11 => <<"lnbc1fixture\"">>}, {error, {invalid_invoice_response, bolt11}}},
        {maps:remove(payment_hash, Good), {error, {invalid_invoice_response, payment_hash}}},
        {Good#{payment_hash => binary:copy(<<"g">>, 64)},
            {error, {invalid_invoice_response, payment_hash}}},
        {Good#{payment_hash => <<"abcd">>}, {error, {invalid_invoice_response, payment_hash}}},
        {Good#{payment_hash => #{}}, {error, {invalid_invoice_response, payment_hash}}},
        {Good#{expires_at => 1}, {error, {invalid_invoice_response, expires_at}}},
        {Good#{expires_at => <<"future">>}, {error, {invalid_invoice_response, expires_at}}},
        {#{code => 900, message => <<"backend-secret-fixture">>},
            {error, {invoice_creation_failed, cln_rpc_error}}},
        {Good#{<<"error">> => #{<<"message">> => <<"backend-secret-fixture">>}},
            {error, {invoice_creation_failed, cln_rpc_error}}}
    ],
    [?_test(with_fixture(Reply, fun() ->
        ?assertEqual(Expected, challenge()),
        assert_no_challenge()
    end)) || {Reply, Expected} <- Cases].

success_reply_shapes_test_() ->
    Invoice = valid_invoice(),
    BinaryKeys = maps:from_list([
        {atom_to_binary(Key, utf8), Value} || {Key, Value} <- maps:to_list(Invoice)
    ]),
    ListValues = Invoice#{
        bolt11 => binary_to_list(maps:get(bolt11, Invoice)),
        payment_hash => binary_to_list(maps:get(payment_hash, Invoice))
    },
    [?_test(with_fixture(Reply, fun assert_success/0)) || Reply <- [
        Invoice, {ok, Invoice}, BinaryKeys, {ok, BinaryKeys}, ListValues
    ]].

backend_expiry_is_respected_test() ->
    ExpiresAt = erlang:system_time(second) + 120,
    with_fixture((valid_invoice())#{expires_at => ExpiresAt}, fun() ->
        {_, Meta} = challenge(),
        ?assertEqual(ExpiresAt, maps:get(expires_at, Meta))
    end).

http_outage_returns_503_not_402_test() ->
    Error = {error, {cln_unavailable, {timeout, <<"backend-secret-fixture">>}}},
    with_fixture(Error, fun() ->
        with_http_auth_mock(fun() ->
            State = #{action => status},
            {stop, Req, State} = damage_http:is_authorized(#{}, State),
            ?assertEqual(503, maps:get(test_status, Req)),
            Headers = maps:get(test_headers, Req),
            ?assertEqual(false, maps:is_key(<<"www-authenticate">>, Headers)),
            ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, Headers)),
            ?assertEqual(<<"5">>, maps:get(<<"retry-after">>, Headers)),
            Body = maps:get(test_body, Req),
            Json = jsx:decode(Body, [return_maps]),
            ?assertEqual(<<"L402_UNAVAILABLE">>, maps:get(<<"error">>, Json)),
            ?assertEqual(true, maps:get(<<"retryable">>, Json)),
            ?assertEqual(nomatch, binary:match(Body, <<"backend-secret-fixture">>)),
            ?assertEqual([0, 0, 0], table_sizes()),
            ?assertEqual(1, meck:num_calls(damage_cln, create_invoice, 4))
        end)
    end).

http_locked_secrets_classification_is_preserved_test() ->
    with_fixture({error, secrets_not_ready}, fun() ->
        with_http_auth_mock(fun() ->
            {stop, Req, _} = damage_http:is_authorized(#{}, #{action => status}),
            ?assertEqual(503, maps:get(test_status, Req)),
            Json = jsx:decode(maps:get(test_body, Req), [return_maps]),
            ?assertEqual(<<"NODE_SECRETS_LOCKED">>, maps:get(<<"error">>, Json)),
            ?assertEqual([0, 0, 0], table_sizes())
        end)
    end).

challenge() ->
    damage_l402:challenge_with_body(#{}, <<"/status">>, 1000, <<"{}">>).

valid_invoice() ->
    %% Structural fixture only: never a payable invoice or a real preimage.
    #{bolt11 => <<"lnbc1fixture">>, payment_hash => binary:copy(<<"AB">>, 32)}.

assert_success() ->
    Before = erlang:system_time(second),
    {Req, Meta} = challenge(),
    ?assertEqual(402, maps:get(test_status, Req)),
    Headers = maps:get(test_headers, Req),
    ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, Headers)),
    ?assertMatch(<<"L402 ", _/binary>>, maps:get(<<"www-authenticate">>, Headers)),
    ?assertEqual(binary:copy(<<"ab">>, 32), maps:get(payment_hash_hex, Meta)),
    ?assertEqual(<<"lnbc1fixture">>, maps:get(invoice, Meta)),
    ?assertEqual(false, maps:get(paid, Meta)),
    ?assertEqual(0, maps:get(damage_available, Meta)),
    ?assert(maps:get(expires_at, Meta) >= Before + 600),
    ?assertEqual([1, 1, 1], table_sizes()),
    Mac = maps:get(macaroon, Meta),
    ?assertEqual([{Mac, Meta}], ets:lookup(damage_l402_tokens, Mac)),
    ?assertEqual(1, meck:num_calls(damage_cln, create_invoice, 4)).

assert_no_challenge() ->
    ?assertEqual([0, 0, 0], table_sizes()),
    ?assertEqual(0, meck:num_calls(cowboy_req, reply, 4)).

table_sizes() ->
    [ets:info(Table, size) || Table <- ?TABLES].

with_fixture(Reply, Test) ->
    %% Tests own the tables and never delete a live service's tables.
    [?assertEqual(undefined, ets:info(Table)) || Table <- ?TABLES],
    [ets:new(Table, [named_table, public, set]) || Table <- ?TABLES],
    Keys = [l402_invoice_expiry, l402_uses],
    Saved = [{Key, application:get_env(damage, Key)} || Key <- Keys],
    Mods = [damage_cln, datestring, cowboy_req],
    ok = meck:new(Mods, [no_link]),
    try
        ok = application:set_env(damage, l402_invoice_expiry, 600),
        ok = application:set_env(damage, l402_uses, 1),
        ok = meck:expect(datestring, format, fun(_, _) -> {ok, "20261021000000"} end),
        ok = meck:expect(damage_cln, create_invoice, fun(1000, _, 600, _) -> Reply end),
        ok = meck:expect(cowboy_req, reply, fun(Status, Headers, Body, Req) ->
            Req#{test_status => Status, test_headers => Headers, test_body => Body}
        end),
        Test(),
        [?assert(meck:validate(Mod)) || Mod <- Mods],
        ok
    after
        meck:unload(Mods),
        [ets:delete(Table) || Table <- ?TABLES],
        [restore_env(Key, Value) || {Key, Value} <- Saved]
    end.

with_http_auth_mock(Test) ->
    Mods = [damage_auth, secrets],
    ok = meck:new(Mods, [no_link]),
    try
        ok = meck:expect(secrets, ready, fun() -> true end),
        ok = meck:expect(damage_auth, require_auth, fun(Req, State, Missing, _Invalid) ->
            Missing(Req, State)
        end),
        Test(),
        [?assert(meck:validate(Mod)) || Mod <- Mods],
        ok
    after
        meck:unload(Mods)
    end.

restore_env(Key, {ok, Value}) -> application:set_env(damage, Key, Value);
restore_env(Key, undefined) -> application:unset_env(damage, Key).
