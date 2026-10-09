%% Static validation only. Never invoke the execution engine or step bodies.
-module(damage_bdd_validator).
-export([validate/2, check_ast/2]).

-define(MAX_FEATURE_BYTES, 65536).
-define(MAX_STEPS, 512).

-spec validate(binary(), map()) -> map().
validate(Feature, Catalog) when is_binary(Feature), byte_size(Feature) =< ?MAX_FEATURE_BYTES ->
    case unsupported_structure(Feature) of
        true -> result(Catalog, [], [diagnostic(0, <<"unsupported_structure">>,
            <<"This static checker supports Feature, Background and Scenario. Expand Scenario Outlines and Rules into ordinary scenarios before checking.">>)]);
        false ->
            try egherkin:parse(Feature) of
                {ok, AST} -> check_ast(AST, Catalog);
                AST when is_tuple(AST), tuple_size(AST) =:= 6 -> check_ast(AST, Catalog);
                {failed, Line, _Message} -> result(Catalog, [], [diagnostic(Line,
                    <<"gherkin_syntax">>, <<"Gherkin parsing failed. Check this line, indentation and docstring delimiters.">>)]);
                _ -> result(Catalog, [], [diagnostic(0, <<"gherkin_syntax">>,
                    <<"The Gherkin parser could not read this feature.">>)])
            catch
                error:undef -> result(Catalog, [], [diagnostic(0, <<"parser_unavailable">>,
                    <<"The node Gherkin parser is unavailable.">>)]);
                _:_ -> result(Catalog, [], [diagnostic(0, <<"gherkin_syntax">>,
                    <<"The Gherkin parser rejected this feature.">>)])
            end
    end;
validate(_, Catalog) -> result(Catalog, [], [diagnostic(0, <<"feature_size">>,
    <<"Provide a UTF-8 feature of at most 64 KiB.">>)]).

%% Isolated entrypoint for tests with the same egherkin AST shape as the runner.
check_ast({_Line, _Tags, _Feature, _Description, Background, Scenarios}, Catalog)
  when is_list(Scenarios), Scenarios =/= [] ->
    Steps = collect(Background) ++ collect(Scenarios),
    case length(Steps) of
        0 -> result(Catalog, [], [diagnostic(0, <<"empty_feature">>,
            <<"Add a Scenario containing executable steps.">>)]);
        N when N > ?MAX_STEPS -> result(Catalog, [], [diagnostic(0, <<"step_limit">>,
            <<"A checked feature may contain at most 512 steps.">>)]);
        _ ->
            {Matched, Errors} = lists:foldl(fun(S, {Ms, Es}) ->
                case check_step(S, Catalog) of
                    {ok, M} -> {[M | Ms], Es};
                    {error, E} -> {Ms, [E | Es]}
                end
            end, {[], []}, Steps),
            result(Catalog, lists:reverse(Matched), lists:reverse(Errors))
    end;
check_ast(_, Catalog) -> result(Catalog, [], [diagnostic(0, <<"empty_feature">>,
    <<"Add a Feature and at least one non-empty Scenario.">>)]).

collect({Line, K, Body}) when is_integer(Line),
    (K =:= <<"Given">> orelse K =:= <<"When">> orelse K =:= <<"Then">> orelse
     K =:= <<"And">> orelse K =:= <<"But">>) -> [{Line, K, Body, []}];
collect({Line, K, Body, Args}) when is_integer(Line),
    (K =:= <<"Given">> orelse K =:= <<"When">> orelse K =:= <<"Then">> orelse
     K =:= <<"And">> orelse K =:= <<"But">>) -> [{Line, K, Body, Args}];
collect({datatable, _}) -> [];
collect(L) when is_list(L) -> lists:append([collect(X) || X <- L]);
collect(T) when is_tuple(T) -> collect(tuple_to_list(T));
collect(_) -> [].

check_step({Line, Keyword, Body, Args}, Catalog) ->
    try
        Text = body_text(Body),
        %% The runner tokenizer does not support an unclosed quoted argument.
        true = length(binary:matches(Text, <<"\"">>)) rem 2 =:= 0,
        %% The runner rejects unresolved angle-bracket placeholders as well.
        nomatch = re:run(Text, <<"<[^>]+>">>, [{capture, none}]),
        Tokens = damage_step_tokenizer:tokenize(Text),
        case damage_bdd_catalog:matches(Catalog, Keyword, Tokens) of
            [S | _] ->
                {ok, #{line => Line, keyword => Keyword, step_id => maps:get(id, S),
                       module => maps:get(module, S), source_line => maps:get(source_line, S),
                       required_variables => lists:usort(variables_in({Body, Args}))}};
            [] ->
                {error, (diagnostic(Line, <<"unknown_step">>,
                    <<"No available, authorised step signature matches this line. Use the step library or rewrite it using a listed signature.">>))#{
                        suggestions => [maps:get(template, S) || S <-
                            damage_bdd_catalog:rank(Text, maps:get(steps, Catalog), 3)]}}
        end
    catch
        _:_ -> {error, diagnostic(Line, <<"step_syntax">>,
            <<"Cannot read this step. Check quoted arguments, unresolved <Parameter> markers and docstrings.">>)}
    end.

body_text(B) when is_binary(B) -> B;
body_text(L) when is_list(L) ->
    case lists:all(fun is_integer/1, L) of
        true -> unicode:characters_to_binary(L);
        false ->
            %% egherkin embeds docstrings as {<<"\"\"\"">>, Lines}; they are
            %% arguments, not executable steps or tokens to be matched.
            Text = [B || B <- L, is_binary(B)],
            iolist_to_binary(lists:join(<<" ">>, Text))
    end.

variables(Text) ->
    case re:run(Text, <<"\\{\\{\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\}\\}">>,
                [global, {capture, [1], binary}]) of
        {match, Captures} -> lists:usort(lists:append(Captures));
        nomatch -> []
    end.

variables_in(B) when is_binary(B) -> variables(B);
variables_in(L) when is_list(L) ->
    case lists:all(fun is_integer/1, L) of
        true -> variables(unicode:characters_to_binary(L));
        false -> lists:append([variables_in(X) || X <- L])
    end;
variables_in(T) when is_tuple(T) -> variables_in(tuple_to_list(T));
variables_in(_) -> [].

result(Catalog, Matches, Errors) ->
    #{valid => Errors =:= [], scope => <<"gherkin_syntax_and_step_signatures">>,
      catalog_revision => maps:get(revision, Catalog, <<>>),
      matched_steps => Matches, step_count => length(Matches),
      diagnostics => lists:sublist(Errors, 50),
      required_variables => lists:usort(lists:append([
          maps:get(required_variables, M, []) || M <- Matches])),
      notice => <<"Static checks do not execute steps or validate runtime context, argument values, request bodies, permissions inside step bodies, target availability or expected outcomes. Review before running.">>}.

diagnostic(Line, Code, Message) ->
    #{line => case is_integer(Line) of true -> Line; false -> 0 end,
      code => Code, severity => <<"error">>, message => Message}.

unsupported_structure(Feature) ->
    Lines = binary:split(Feature, <<"\n">>, [global]),
    unsupported_lines(Lines, none).
unsupported_lines([], _) -> false;
unsupported_lines([Line | Rest], Fence) ->
    Trimmed = string:trim(Line),
    case {Trimmed, Fence} of
        {<<"\"\"\"", _/binary>>, none} -> unsupported_lines(Rest, quotes);
        {<<"\"\"\"", _/binary>>, quotes} -> unsupported_lines(Rest, none);
        {<<"```", _/binary>>, none} -> unsupported_lines(Rest, backticks);
        {<<"```", _/binary>>, backticks} -> unsupported_lines(Rest, none);
        {_, none} ->
            case re:run(Trimmed, <<"^(Scenario Outline|Scenario Template|Rule):">>, [{capture, none}]) of
                match -> true;
                nomatch -> unsupported_lines(Rest, none)
            end;
        _ -> unsupported_lines(Rest, Fence)
    end.
