%% Test-only generation boundary; no models or network calls.
-module(ecai_chat).
-export([get_reply/4, last/0, reset/0]).
get_reply(Id, Owner, Message, Options) ->
    persistent_term:put({?MODULE, conversation_call}, {Id, Owner, Message, Options}),
    {ok, <<"Fixture assistant reply">>}.
last() -> persistent_term:get({?MODULE, conversation_call}, undefined).
reset() -> persistent_term:erase({?MODULE, conversation_call}), ok.
