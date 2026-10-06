%% Preserve legacy catch result shapes while using try/catch syntax.
%% Keep this helper app-local; no dependency on another app's compatibility module.
-module(nosternity_otp_compat).

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
