%% Compatibility helpers for removing deprecated bare catch expressions while
%% preserving their documented return values.
-module(erm_otp_compat).

-export([catch_value/1]).

-spec catch_value(fun(() -> term())) -> term().
catch_value(Fun) when is_function(Fun, 0) ->
    try
        Fun()
    catch
        throw:Term -> Term;
        exit:Reason -> {'EXIT', Reason};
        error:Reason:Stack -> {'EXIT', {Reason, Stack}}
    end.
