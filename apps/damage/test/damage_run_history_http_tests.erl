-module(damage_run_history_http_tests).
-include_lib("eunit/include/eunit.hrl").

-define(NODE, "ak_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").
-define(CONTRACT, "ct_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB").

public_contract_scan_test() ->
    Path = iolist_to_binary(["/v3/contracts/calls?contract_id=", ?CONTRACT,
                            "&direction=backward&limit=50"]),
    ?assertMatch({ok, _}, damage_run_history_http:validate_activity_path(Path)).


public_token_transaction_scan_test() ->
    Path = iolist_to_binary(["/v3/transactions?contract=", ?CONTRACT,
                            "&type=contract_call&type=paying_for&direction=backward&limit=50"]),
    ?assertMatch({ok, _}, damage_run_history_http:validate_activity_path(Path)).

middleware_page_path_test() ->
    Path = iolist_to_binary(["/mdw/v3/accounts/", ?NODE,
                            "/activities?owned_only=false&type=transactions&direction=backward&limit=20&cursor=next_123"]),
    {ok, Normalized} = damage_run_history_http:validate_activity_path(Path),
    ?assertEqual(nomatch, binary:match(Normalized, <<"/mdw/">>)),
    ?assertMatch({0, _}, binary:match(Normalized, <<"/v3/">>)).

public_activity_path_restrictions_test() ->
    Denied = [
        <<"https://evil.invalid/v3/transactions">>,
        <<"/v3/../../secrets">>,
        <<"/v3/contracts/logs">>,
        <<"/v3/contracts/calls?contract_id=ct_invalid&limit=50">>,
        <<"/v3/contracts/calls?contract_id=ct_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&next=https%3A%2F%2Fevil.invalid">>,
        <<"/v3/transactions?contract=ct_bad&limit=9999">>,
        <<"/v3/transactions?limit=1000">>,
        <<"/v3/transactions?direction=forward">>,
        <<"/v3/transactions?next=http%3A%2F%2Fevil.invalid">>,
        <<"/v3/transactions#injection">>,
        <<"/v3/transactions/%2e%2e/%2e%2e">>
    ],
    [?assertEqual({error, invalid_path}, damage_run_history_http:validate_activity_path(P))
     || P <- Denied].
