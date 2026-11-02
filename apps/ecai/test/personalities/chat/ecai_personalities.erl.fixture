%% Test entitlement resolver. The production resolver is exercised separately.
-module(ecai_personalities).
-export([resolve_personality/2]).
resolve_personality(_, <<"default">>) ->
    {ok, #{ref => <<"default">>, system_prompt => <<>>}};
resolve_personality(<<"alice">>, <<"purchase:alice-order">> = Ref) ->
    case persistent_term:get(ecai_chat_test_revoked, false) of
        false -> {ok, #{ref => Ref, name => <<"The Skeptic">>, version => <<"1.0.0">>,
                       package_sha256 => <<"trusted-package">>,
                       system_prompt => <<"Ask for evidence. Challenge unsupported claims.">>}};
        true -> {error, personality_not_owned}
    end;
resolve_personality(_, <<"purchase:unavailable">>) -> error(backend_down);
resolve_personality(_, <<"purchase:", _/binary>>) -> {error, personality_not_owned};
resolve_personality(_, _) -> {error, invalid_personality}.
