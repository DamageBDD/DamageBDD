%% Captures the real serialized model request, without any external network call.
-module(damage_gun).
-export([post/6]).
post(_Host, _Port, "/api/generate", _Headers, Body, _Options) ->
    Request = jsx:decode(Body, [return_maps]),
    ets:insert(ecai_chat_test_calls, {erlang:unique_integer([monotonic, positive]), Request}),
    {ok, #{status => 200, json => #{<<"response">> => <<"fresh model reply">>}, body => <<>>}}.
