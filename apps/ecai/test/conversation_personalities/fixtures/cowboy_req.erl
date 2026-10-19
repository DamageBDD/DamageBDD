%% Test-only Cowboy request boundary; real JSON codec and handler are exercised.
-module(cowboy_req).
-export([binding/2, parse_qs/1, read_body/2, reply/4]).
binding(Key, Req) -> maps:get(Key, maps:get(bindings, Req, #{}), undefined).
parse_qs(Req) -> maps:get(qs, Req, []).
read_body(Req, _) -> {ok, maps:get(body, Req, <<>>), Req}.
reply(Status, Headers, Body, Req) ->
    Req#{response => #{status => Status, headers => Headers, body => Body}}.
