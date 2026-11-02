%% Test-only entitlement service; never compile into a production application.
-module(ecai_personalities).
-export([fixture/1, reset/0, resolve_personality/2, owned_personalities/1]).
fixture(Config) -> persistent_term:put({?MODULE, conversation_fixture}, Config), ok.
reset() -> persistent_term:erase({?MODULE, conversation_fixture}), ok.
resolve_personality(_, <<"default">>) -> {ok, descriptor(<<"default">>)};
resolve_personality(Owner, <<"purchase:", Id/binary>> = Ref) when byte_size(Id) =:= 64 ->
    Config = persistent_term:get({?MODULE, conversation_fixture}, #{}),
    case lists:member(Ref, maps:get(unavailable, Config, [])) of
        true -> {error, personality_unavailable};
        false ->
            Owned = maps:get(Owner, maps:get(owned, Config, #{}), []),
            case lists:member(Ref, Owned) of
                true -> {ok, descriptor(Ref)};
                false -> {error, personality_not_owned}
            end
    end;
resolve_personality(_, _) -> {error, invalid_personality}.
owned_personalities(Owner) ->
    Config = persistent_term:get({?MODULE, conversation_fixture}, #{}),
    %% Deliberately include a prompt here to check HTTP's public allow-list.
    Owned = maps:get(Owner, maps:get(owned, Config, #{}), []),
    {ok, #{items => [descriptor(R) || R <- [<<"default">> | Owned]]}}.
descriptor(Ref) -> #{ref => Ref, personality_id => Ref, name => <<"Fixture personality">>,
                     version => <<"1">>, package_sha256 => <<"fixture-hash">>,
                     system_prompt => <<"PRIVATE FIXTURE PROMPT, must not enter history">>}.
