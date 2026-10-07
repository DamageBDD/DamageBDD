%% Loopback provider fixture. Only the external model is replaced; tests use
%% the real relay, native ECAI, Cowboy, Gun, damage_gun and inference client.
-module(nosternity_test_llm_http).
-export([init/2]).

init(Req, #{table := Table} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    Number = ets:update_counter(Table, count, 1),
    Request = jsx:decode(Body, [return_maps]),
    ets:insert(Table, {Number, #{path => cowboy_req:path(Req), body => Request}}),
    {Status, Response} = case ets:lookup(Table, mode) of
        [{mode, error}] -> {500, #{error => <<"provider-private-error-and-secret">>}};
        _ -> {200, #{response => <<"Indexed evidence is available [S1].">>, done => true}}
    end,
    Req2 = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Response), Req1),
    {ok, Req2, State}.
