%%--------------------------------------------------------------------
%% Signing timeout guard.
%%
%% The signer MUST fail closed: if the signing backend does not complete in
%% the configured window, no partial signature material is returned to callers.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_signing_guard).

-export([with_timeout/2, classify_elapsed/2]).

-spec with_timeout(fun(() -> term()), pos_integer()) -> term() | {error, signing_timeout}.
with_timeout(Fun, TimeoutMs) when is_function(Fun, 0), is_integer(TimeoutMs), TimeoutMs > 0 ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result =
            try Fun() of
                Value -> {ok, Value}
            catch
                Class:Reason:Stack -> {error, {Class, Reason, Stack}}
            end,
        Parent ! {Ref, Result}
    end),
    receive
        {Ref, {ok, Value}} ->
            erlang:demonitor(MonRef, [flush]),
            Value;
        {Ref, {error, Error}} ->
            erlang:demonitor(MonRef, [flush]),
            {error, Error};
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {signer_exited, Reason}}
    after TimeoutMs ->
        exit(Pid, kill),
        receive
            {'DOWN', MonRef, process, Pid, _} -> ok
        after 0 -> ok
        end,
        {error, signing_timeout}
    end.

-spec classify_elapsed(non_neg_integer(), pos_integer()) -> ok | {error, signing_timeout}.
classify_elapsed(ElapsedMs, TimeoutMs) when is_integer(ElapsedMs), is_integer(TimeoutMs) ->
    case ElapsedMs =< TimeoutMs of
        true -> ok;
        false -> {error, signing_timeout}
    end.
