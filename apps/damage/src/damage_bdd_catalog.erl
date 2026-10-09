%% Authoritative, side-effect-free step signatures from deployed BEAMs.
%% No step/6 or step_dry/6 clause is called to discover or validate a step.
-module(damage_bdd_catalog).
-export([snapshot/1, from_forms/3, matches/3, rank/3, write_manifest/1]).

-spec snapshot(map()) -> map().
snapshot(Context) ->
    Modules = try damage_utils:loaded_steps() catch _:_ -> [] end,
    Manifest = read_manifest(),
    Allowed = [M || M <- Modules, steps_utils:step_module_allowed(M, Context)],
    Entries = [module_entry(M, Manifest) || M <- Allowed],
    Steps = lists:append([maps:get(steps, E, []) || E <- Entries]),
    Revision = hex(crypto:hash(sha256, term_to_binary([
        {maps:get(module, E), maps:get(beam_md5, E, <<>>), maps:get(status, E)}
        || E <- Entries
    ]))),
    #{revision => Revision, steps => Steps, modules => Entries,
      step_count => length(Steps), module_count => length(Allowed),
      unavailable_modules => [maps:get(module, E) || E <- Entries,
                               maps:get(status, E) =/= available]}.

module_entry(M, Manifest) ->
    Name = atom_to_binary(M, utf8),
    try
        {M, Beam, _} = code:get_object_code(M),
        {ok, {M, Md5}} = beam_lib:md5(Beam),
        %% get_object_code reads the code path. Do not describe a different
        %% version than the one loaded in the VM after a hot reload.
        Md5 = M:module_info(md5),
        case beam_lib:chunks(Beam, [abstract_code]) of
            {ok, {M, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
                entry(Name, Md5, from_forms(Name, Md5, Forms));
            _ ->
                case maps:get(Name, Manifest, undefined) of
                    #{beam_md5 := Md5, steps := Steps} when is_list(Steps) ->
                        entry(Name, Md5, Steps);
                    _ ->
                        #{module => Name, beam_md5 => hex(Md5),
                          status => missing_debug_info, steps => []}
                end
        end
    catch
        _:_ -> #{module => Name, status => unavailable, steps => []}
    end.

entry(Name, Md5, Steps) ->
    #{module => Name, beam_md5 => hex(Md5), status => available, steps => Steps}.

%% Public for build tooling and pure unit tests. Only trusted compiler forms
%% belong here; HTTP inputs never reach this function.
-spec from_forms(binary(), binary(), list()) -> list().
from_forms(Module, Md5, Forms) ->
    Clauses = lists:append([Cs || {function, _, step, 6, Cs} <- Forms]),
    lists:filtermap(fun(C) -> clause(Module, Md5, C) end, Clauses).

clause(Module, Md5, {clause, Anno, [_, Context, KW, _, Parts0, Body], Guards, _}) ->
    case {keywords(KW), parts(Parts0)} of
        {[], _} -> false;
        {_, error} -> false;
        {_, {ok, []}} -> false;
        {Keywords, {ok, Parts}} ->
            %% A broad catch-all must never validate arbitrary model output.
            HasLiteral = lists:any(fun(P) -> maps:get(kind, P) =:= literal end, Parts),
            Sample = render(Parts, sample),
            RoundTrips = match_parts(Parts, damage_step_tokenizer:tokenize(Sample), #{}),
            case HasLiteral andalso RoundTrips of
                false -> false;
                true ->
                    Line = erl_anno:line(Anno),
                    Id = hex(crypto:hash(sha256, term_to_binary({Module, Md5, Line, Parts}))),
                    {true, #{id => Id, module => Module, source_line => Line,
                             keywords => Keywords, parts => Parts,
                             template => render(Parts, template),
                             body_hint => used_body(Body),
                             runtime_checks => Guards =/= [] orelse not variable(Context)}}
            end
    end;
clause(_, _, _) -> false.

keywords({var, _, _}) -> [<<"Given">>, <<"When">>, <<"Then">>, <<"And">>, <<"But">>];
keywords(Form) ->
    try erl_parse:normalise(Form) of
        K when K =:= <<"Given">>; K =:= <<"When">>; K =:= <<"Then">>;
               K =:= <<"And">>; K =:= <<"But">> -> [K];
        _ -> []
    catch _:_ -> [] end.

parts({match, _, A, B}) ->
    case parts(A) of error -> parts(B); Result -> Result end;
parts({nil, _}) -> {ok, []};
parts({cons, _, Head, Tail}) ->
    case {part(Head), parts(Tail)} of
        {error, _} -> error;
        {_, error} -> error;
        {P, {ok, Ps}} -> {ok, [P | Ps]}
    end;
parts(_) -> error.

part({string, _, S}) ->
    #{kind => literal, value => unicode:characters_to_binary(S), token => S};
part({var, _, Name}) -> #{kind => parameter, name => atom_to_binary(Name, utf8)};
part(_) -> error.

variable({var, _, _}) -> true;
variable(_) -> false.
used_body({var, _, Name}) ->
    case atom_to_list(Name) of [$_ | _] -> false; _ -> true end;
used_body(_) -> true.

render(Parts, Mode) ->
    iolist_to_binary(lists:join(<<" ">>, [render_part(P, Mode) || P <- Parts])).
render_part(#{kind := literal, value := V}, _) -> V;
render_part(#{kind := parameter}, sample) -> <<"\"bdd_sample\"">>;
render_part(#{kind := parameter, name := Name}, template) -> [<<"\"<">>, Name, <<">\"">>].

-spec matches(map(), binary(), [string()]) -> list().
matches(#{steps := Steps}, Keyword, Tokens) ->
    [S || S <- Steps, lists:member(Keyword, maps:get(keywords, S)),
          match_parts(maps:get(parts, S), Tokens, #{})].

match_parts([], [], _) -> true;
match_parts([#{kind := literal, token := T} | Ps], [T | Ts], Bound) ->
    match_parts(Ps, Ts, Bound);
match_parts([#{kind := parameter, name := <<"_">>} | Ps], [_ | Ts], Bound) ->
    match_parts(Ps, Ts, Bound);
match_parts([#{kind := parameter, name := N} | Ps], [T | Ts], Bound) ->
    case maps:find(N, Bound) of
        {ok, T} -> match_parts(Ps, Ts, Bound);
        {ok, _} -> false;
        error -> match_parts(Ps, Ts, maps:put(N, T, Bound))
    end;
match_parts(_, _, _) -> false.

%% Deterministic lexical retrieval; ECAI knowledge cards supply behavioural
%% context later. No claim of learned/semantic ranking is made here.
-spec rank(binary(), list(), pos_integer()) -> list().
rank(Query, Steps, Limit) ->
    Words = words(Query),
    Scored = [{score(Words, S), maps:get(id, S), S} || S <- Steps],
    Ordered = lists:sort(fun({A, I, _}, {B, J, _}) ->
        A > B orelse (A =:= B andalso I < J)
    end, Scored),
    lists:sublist([S || {N, _, S} <- Ordered, N > 0], Limit).

score(Words, Step) ->
    Text = string:lowercase(iolist_to_binary([
        maps:get(module, Step), <<" ">>, maps:get(template, Step)
    ])),
    lists:sum([case binary:match(Text, W) of nomatch -> 0; _ -> 1 end || W <- Words]).
words(Q) ->
    lists:usort([W || W <- re:split(string:lowercase(Q), <<"[^a-z0-9_]+">>,
                                  [{return, binary}]), byte_size(W) > 2,
                     not lists:member(W, [<<"the">>, <<"and">>, <<"with">>, <<"for">>])]).

%% Build this AFTER compile, BEFORE release stripping, and copy it with priv.
%% beam_lib:md5 covers executable chunks and survives removal of debug info.
-spec write_manifest(file:filename()) -> ok | {error, term()}.
write_manifest(Path0) ->
    Path = case Path0 of B when is_binary(B) -> unicode:characters_to_list(B); L -> L end,
    Modules = damage_utils:loaded_steps(),
    Entries = [module_entry(M, #{}) || M <- Modules],
    case [maps:get(module, E) || E <- Entries, maps:get(status, E) =/= available] of
        [] ->
            Manifest = maps:from_list([{maps:get(module, E),
                #{beam_md5 => binary:decode_hex(maps:get(beam_md5, E)),
                  steps => maps:get(steps, E)}} || E <- Entries]),
            case filelib:ensure_dir(Path) of
                ok ->
                    Tmp = Path ++ ".tmp",
                    case file:write_file(Tmp, term_to_binary({damage_bdd_catalog_v1, Manifest})) of
                        ok -> file:rename(Tmp, Path);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Missing -> {error, {missing_debug_info, Missing}}
    end.

read_manifest() ->
    try
        Path = application:get_env(damage, bdd_catalog_manifest,
                                   filename:join(code:priv_dir(damage), "bdd_step_catalog.term")),
        {ok, Bin} = file:read_file(Path),
        {damage_bdd_catalog_v1, Map} = binary_to_term(Bin, [safe]),
        true = is_map(Map),
        Map
    catch _:_ -> #{} end.

hex(B) -> string:lowercase(binary:encode_hex(B)).
