-module(steps_firecracker).
-license("Apache-2.0").
-damage_roles([node_admin]).
-export([step/6]).

%% erlfmt:ignore-begin
-define(RUN, ["I run a Firecracker script with profile", Profile]).
-define(EXIT, ["the Firecracker exit code should be", Code]).
-define(OUTPUT, ["the Firecracker output should contain", Text]).
%% erlfmt:ignore-end

step(_Config, Context, <<"When">>, _Line, ?RUN, Script) ->
    steps_utils:ensure_admin(Context),
    case damage_firecracker:run(to_binary(Profile), to_binary(Script)) of
        {ok, Result} -> Context#{firecracker_result => Result};
        {error, Reason} -> Context#{fail => {firecracker, Reason}}
    end;
step(_Config, Context, <<"Then">>, _Line, ?EXIT, _Args) ->
    steps_utils:ensure_admin(Context),
    try binary_to_integer(to_binary(Code)) of
        Expected ->
            case maps:get(firecracker_result, Context, undefined) of
                #{exit_code := Expected} -> Context;
                #{exit_code := Actual} -> Context#{fail => {firecracker_exit, Expected, Actual}};
                _ -> Context#{fail => firecracker_result_missing}
            end
    catch error:badarg -> Context#{fail => invalid_firecracker_exit_code}
    end;
step(_Config, Context, <<"Then">>, _Line, ?OUTPUT, _Args) ->
    steps_utils:ensure_admin(Context),
    case maps:get(firecracker_result, Context, undefined) of
        #{output := Output} ->
            case binary:match(Output, to_binary(Text)) of
                nomatch -> Context#{fail => firecracker_output_mismatch};
                _ -> Context
            end;
        _ -> Context#{fail => firecracker_result_missing}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L).
