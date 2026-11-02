%% Test-only backend. Never register it in production ai_profiles.
-module(damage_ai_test_backend).
-behaviour(damage_ai_backend).
-export([invoke/2]).

invoke(Profile, Request) ->
    case proplists:get_value(observer, Profile, undefined) of
        Pid when is_pid(Pid) -> Pid ! {ai_test_request, self(), Request};
        _ -> ok
    end,
    timer:sleep(proplists:get_value(delay_ms, Profile, 0)),
    case proplists:get_value(test_error, Profile, undefined) of
        undefined ->
            Value = proplists:get_value(reply, Profile, <<"billing">>),
            Base = #{model => <<"fixture-model-v1">>,
                     usage => proplists:get_value(usage, Profile, #{total_tokens => 12})},
            case maps:get(operation, Request) of
                embedding -> {ok, Base#{embedding => Value}};
                chat -> {ok, Base#{text => Value}}
            end;
        Reason -> {error, Reason}
    end.
