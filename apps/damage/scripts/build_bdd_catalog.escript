#!/usr/bin/env escript
%%! -noshell
%% Build in the full repository after compile, before stripping release BEAMs.
%% Usage: escript apps/damage/scripts/build_bdd_catalog.escript [profile] [output]
-mode(compile).
-export([main/1]).

main(Args) ->
    {Profile, Output} = case Args of
        [] -> {"default", "apps/damage/priv/bdd_step_catalog.term"};
        [P] -> {P, "apps/damage/priv/bdd_step_catalog.term"};
        [P, O] -> {P, O};
        _ -> io:format(standard_error, "Usage: build_bdd_catalog.escript [profile] [output]~n", []), halt(2)
    end,
    Paths = filelib:wildcard(filename:join(["_build", Profile, "lib", "*", "ebin"])),
    case Paths of
        [] -> io:format(standard_error, "No compiled code for profile ~s. Run rebar3 compile for that profile first.~n", [Profile]), halt(2);
        _ -> ok
    end,
    ok = code:add_paths(Paths),
    try damage_bdd_catalog:write_manifest(Output) of
        ok -> io:format("Wrote ~s. Package it with damage priv and the exact compiled step modules.~n", [Output]);
        {error, Why} -> io:format(standard_error, "Cannot build step manifest: ~p~n", [Why]), halt(1)
    catch
        Class:Reason -> io:format(standard_error, "Manifest build failed: ~p:~p~n", [Class, Reason]), halt(1)
    end.
