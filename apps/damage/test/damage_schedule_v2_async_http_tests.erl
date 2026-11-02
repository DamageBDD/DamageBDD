-module(damage_schedule_v2_async_http_tests).
-include_lib("eunit/include/eunit.hrl").

accepted_operation_preserves_running_status_test() ->
    fixture(fun() ->
        ok = meck:expect(damage_schedule_v2, create, fun(<<"ak_owner">>, Json) ->
            ?assertEqual(<<"Feature: fixture">>, maps:get(<<"feature">>, Json)),
            {ok, #{operation_id => <<"sop_fixture">>, status => running, stage => queued}}
        end),
        {stop, Req, _} = damage_schedule_v2_http:from_json(req(), state()),
        ?assertEqual(202, maps:get(reply_status, Req)),
        ?assertEqual(<<"running">>, maps:get(<<"status">>, maps:get(reply_json, Req))),
        ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, maps:get(reply_headers, Req)))
    end).

handler_timeout_is_not_invalid_json_test() ->
    fixture(fun() ->
        ok = meck:expect(damage_schedule_v2, create, fun(_, _) ->
            exit({timeout, {gen_server, call, [fixture]}})
        end),
        {stop, Req, _} = damage_schedule_v2_http:from_json(req(), state()),
        ?assertEqual(504, maps:get(reply_status, Req)),
        ?assertEqual(<<"schedule_operation_outcome_unknown">>,
            maps:get(<<"error">>, maps:get(reply_json, Req)))
    end).

another_owners_operation_is_not_found_test() ->
    fixture(fun() ->
        ok = meck:expect(cowboy_req, binding, fun(operation_id, _) -> <<"sop_other_owner">> end),
        ok = meck:expect(damage_schedule_v2, operation, fun(<<"ak_owner">>, <<"sop_other_owner">>) ->
            {error, not_found}
        end),
        {stop, Req, _} = damage_schedule_v2_http:to_json(#{}, (state())#{action => operation}),
        ?assertEqual(404, maps:get(reply_status, Req))
    end).

empty_operation_listing_is_an_array_test() ->
    fixture(fun() ->
        ok = meck:expect(damage_schedule_v2, operations, fun(<<"ak_owner">>) -> {ok, []} end),
        {stop, Req, _} = damage_schedule_v2_http:to_json(#{}, (state())#{action => operations}),
        ?assertEqual([], maps:get(<<"data">>, maps:get(reply_json, Req)))
    end).

fixture(Fun) ->
    Mods = [damage_schedule_v2, cowboy_req],
    ok = meck:new(Mods, [no_link, non_strict]),
    try
        ok = meck:expect(cowboy_req, read_body, fun(Req) -> {ok, maps:get(body, Req), Req} end),
        ok = meck:expect(cowboy_req, reply, fun(Status, Headers, Body, Req) ->
            Req#{reply_status => Status, reply_headers => Headers,
                reply_json => jsx:decode(Body, [return_maps])}
        end),
        Fun()
    after meck:unload(Mods)
    end.

req() -> #{body => jsx:encode(#{<<"feature">> => <<"Feature: fixture">>})}.
state() -> #{action => schedules, public_key => <<"ak_owner">>}.
