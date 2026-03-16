#!/usr/bin/env escript
%%! -noshell

-mode(compile).

-export([main/1]).

main(_Args) ->
    Globs = [
        "src/steps_*.erl",
        "apps/*/src/steps_*.erl",
        "test/steps_*.erl",
        "apps/*/test/steps_*.erl"
    ],
    Files = lists:usort(lists:append([filelib:wildcard(G) || G <- Globs])),
    case check_files(Files) of
        ok ->
            io:format("step lint ok~n"),
            halt(0);
        {error, Errors} ->
            lists:foreach(fun print_error/1, Errors),
            halt(1)
    end.

check_files([]) ->
    ok;
check_files(Files) ->
    Errors =
        lists:foldl(
            fun(File, Acc) ->
                case check_file(File) of
                    ok -> Acc;
                    {error, E} -> [E | Acc]
                end
            end,
            [],
            Files
        ),
    case Errors of
        [] -> ok;
        _ -> {error, lists:reverse(Errors)}
    end.

check_file(File) ->
    IncludePaths = include_paths(File),
    case epp:parse_file(File, IncludePaths, []) of
        {ok, Forms} ->
            case find_banned_clause(Forms) of
                none ->
                    ok;
                {found, Fun, Line, Why} ->
                    {error, {catchall_step_banned, File, Fun, Line, Why}}
            end;
        {error, Reason} ->
            {error, {parse_failed, File, Reason}}
    end.

include_paths(File) ->
    Dir = filename:dirname(File),
    AppDir = filename:dirname(Dir),
    lists:usort([
        ".",
        "include",
        "src",
        "test",
        Dir,
        AppDir,
        filename:join(AppDir, "include"),
        filename:join(AppDir, "src"),
        filename:join(AppDir, "test")
    ]).

find_banned_clause(Forms) ->
    lists:foldl(
        fun
            ({function, _FLine, Name, 6, Clauses}, none) when Name =:= step ->
                %; Name =:= step_dry ->
                find_banned_clause_in_fun(Name, Clauses);
            (_Other, Acc) ->
                Acc
        end,
        none,
        Forms
    ).

find_banned_clause_in_fun(Name, Clauses) ->
    lists:foldl(
        fun
            ({clause, Line, Args, _Guards, _Body}, none) ->
                case clause_is_banned(Args) of
                    false -> none;
                    {true, Why} -> {found, Name, Line, Why}
                end;
            (_Clause, Acc) ->
                Acc
        end,
        none,
        Clauses
    ).

%% A banned catch-all is:
%%   1) a fully generic step/6 clause
%%   2) or a clause where both Keyword and Parts are generic
%% This still allows:
%%   - generic Keyword with a specific Parts pattern
%%   - Given/When/Then/And shared clauses with literal text fragments
clause_is_banned([A1, A2, A3, A4, A5, A6]) ->
    case lists:all(fun is_generic_pattern/1, [A1, A2, A3, A4, A5, A6]) of
        true ->
            {true, fully_generic_step_clause};
        false ->
            case is_generic_pattern(A3) andalso parts_pattern_is_generic(A5) of
                true -> {true, generic_keyword_and_parts};
                false -> false
            end
    end;
clause_is_banned(_) ->
    false.

is_generic_pattern({var, _, '_'}) -> true;
is_generic_pattern({var, _, _Name}) -> true;
is_generic_pattern(_) -> false.

parts_pattern_is_generic(Pat) ->
    case is_generic_pattern(Pat) of
        true ->
            true;
        false ->
            case list_pattern_to_elems(Pat) of
                {ok, Elems} ->
                    not lists:any(fun is_literal_fragment/1, Elems);
                error ->
                    false
            end
    end.

list_pattern_to_elems({nil, _}) ->
    {ok, []};
list_pattern_to_elems({cons, _, H, T}) ->
    case list_pattern_to_elems(T) of
        {ok, Rest} -> {ok, [H | Rest]};
        error -> error
    end;
list_pattern_to_elems(_) ->
    error.

is_literal_fragment({string, _, _}) -> true;
is_literal_fragment({char, _, _}) -> true;
is_literal_fragment({integer, _, _}) -> true;
is_literal_fragment({float, _, _}) -> true;
is_literal_fragment({atom, _, _}) -> true;
is_literal_fragment({bin, _, _}) -> true;
is_literal_fragment(_) -> false.

print_error({catchall_step_banned, File, Fun, Line, Why}) ->
    io:format(
        standard_error,
        "~s:~p: banned catch-all in ~p/6 (~p)~n",
        [File, Line, Fun, Why]
    );
print_error({parse_failed, File, Reason}) ->
    io:format(
        standard_error,
        "~s: parse failed: ~p~n",
        [File, Reason]
    ).
