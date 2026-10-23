-module(damage_agent_test_adapter).
-export([execute/3,verify/3]).
execute(_Args,Ticket,Options) ->
    case persistent_term:get({?MODULE,observer},undefined) of
        P when is_pid(P) -> P ! {agent_test_effect,maps:get(idempotency_key,Ticket)};
        _ -> ok
    end,
    timer:sleep(proplists:get_value(delay_ms,Options,0)),
    {ok,result()}.
verify(_,_,_) -> {ok,result()}.
result() -> #{<<"observation">> => #{<<"fixture">> => true},
              <<"evidence">> => #{<<"scope">> => <<"test_fixture_only">>}}.
