-module(nosternity_otp_compat_tests).

-include_lib("eunit/include/eunit.hrl").

normal_values_test() ->
    Values = [ok, 42, #{value => 1}, {ok, note}, {error, timeout}, {'EXIT', returned}],
    lists:foreach(
        fun(Value) ->
            ?assertEqual(Value, nosternity_otp_compat:catch_value(fun() -> Value end))
        end,
        Values
    ).

throw_values_test() ->
    Terms = [42, {ok, note}, {error, timeout}, {'EXIT', thrown}],
    lists:foreach(
        fun(Term) ->
            ?assertEqual(Term, nosternity_otp_compat:catch_value(fun() -> throw(Term) end))
        end,
        Terms
    ).

exit_reason_test() ->
    Reason = {timeout, request},
    ?assertEqual(
        {'EXIT', Reason},
        nosternity_otp_compat:catch_value(fun() -> exit(Reason) end)
    ).

error_stack_test() ->
    {'EXIT', {badarg, Stack}} =
        nosternity_otp_compat:catch_value(fun() -> erlang:error(badarg) end),
    ?assert(is_list(Stack)),
    ?assertMatch([_ | _], Stack).

integer_fallback_test() ->
    Parse = fun(Value, Default) ->
        case nosternity_otp_compat:catch_value(fun() -> binary_to_integer(Value) end) of
            I when is_integer(I) -> I;
            _ -> Default
        end
    end,
    ?assertEqual(25, Parse(<<"25">>, 200)),
    ?assertEqual(0, Parse(<<"0">>, 200)),
    ?assertEqual(-1, Parse(<<"-1">>, 200)),
    ?assertEqual(200, Parse(<<"invalid">>, 200)),
    ?assertEqual(200, Parse(<<>>, 200)).

list_integer_fallback_test() ->
    Parse = fun(Value, Default) ->
        case nosternity_otp_compat:catch_value(fun() -> list_to_integer(Value) end) of
            I when is_integer(I) -> I;
            _ -> Default
        end
    end,
    ?assertEqual(25, Parse("25", 200)),
    ?assertEqual(200, Parse("invalid", 200)),
    ?assertEqual(200, Parse([], 200)).

case_body_exception_propagates_test() ->
    ?assertError(
        consumer_failed,
        case nosternity_otp_compat:catch_value(fun() -> ok end) of
            ok -> erlang:error(consumer_failed)
        end
    ).

unmatched_case_stays_case_clause_test() ->
    ?assertError(
        {case_clause, unexpected},
        case nosternity_otp_compat:catch_value(fun() -> unexpected end) of
            ok -> ok
        end
    ).
