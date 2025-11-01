-module(damage_doc).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([trails/0]).
-export([init/2, allowed_methods/2, content_types_provided/2, to_html/2]).

-export([info/1]).
-export([build_context/0]).

-define(TPL(Name), (filename:join("ui/docs", Name))).

trails() ->
    [
        trails:trail(
            "/steps",
            ?MODULE,
            #{action => index},
            #{get => #{tags => ["UI", "HTML"], produces => ["text/html"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) -> {[{{<<"text">>, <<"html">>, '*'}, to_html}], Req, State}.

to_html(Req, #{action := index} = State) ->
    Ctx0 = base_context(Req),
    %% ?component=login_modal (atoms are fine)
    #{component := Comp0} = cowboy_req:match_qs([{component, [], undefined}], Req),
    case Comp0 of
        undefined ->
            {render_full_page(Ctx0), Req, State};
        _ ->
            Comp = binary_to_atom(Comp0, utf8),
            {render_component(Comp, Ctx0), Req, State}
    end.

%% -------------------------- Context --------------------------
base_context(Req) ->
    %% Add anything you want available to all templates (user, feature list, etc.)
    #{
        request_path => cowboy_req:path(Req),
        node_version => <<"v0.1">>
    }.

%% -------------------------- Page -----------------------------
render_full_page(Ctx0) ->
    Top = render_tpl(?TPL("topbar.mustache"), Ctx0),
    Foot = render_tpl(?TPL("footer.mustache"), Ctx0),
    Built = build_context(),
    PageCtx = Ctx0#{
        topbar => Top,
        footer => Foot
    }#{
        groups => maps:get(groups, Built, []),
        title => maps:get(title, Built, <<"Step Reference">>),
        product => maps:get(product, Built, <<"DamageBDD">>),
        description => maps:get(description, Built, <<"Supported Gherkin steps">>),
        version => maps:get(version, Built, <<"dev">>),
        commit_hash => maps:get(commit_hash, Built, <<"-">>),
        generated_at => maps:get(generated_at, Built, <<"-">>),
        intro => maps:get(intro, Built, <<"Browse steps below. Use the search box above.">>)
    },
    render_tpl(?TPL("page_shell.mustache"), PageCtx).

%% ---------------------- Component switch ---------------------
render_component(page, Ctx) ->
    render_full_page(Ctx);
render_component(topbar, Ctx) ->
    render_tpl(?TPL("topbar.mustache"), Ctx);
render_component(footer, Ctx) ->
    render_tpl(?TPL("footer.mustache"), Ctx);
render_component(_, _) ->
    <<>>.

%% ---------------------- Rendering helper ---------------------
render_tpl(TemplateRelPath, Context) ->
    %% priv/templates/<TemplateRelPath> :contentReference[oaicite:1]{index=1}
    damage_utils:load_template(TemplateRelPath, Context).

%% Public API
-spec info({module(), atom(), arity()}) ->
    #{
        module := module(),
        function := atom(),
        arity := arity(),
        exported := boolean(),
        file := file:filename() | undefined,
        docs := binary() | none | undefined,
        spec := term() | none | undefined,
        abstract_clauses := [erl_parse:abstract_clause()] | undefined,
        %% sha256 of function abstract code (or whole module if not available)
        fun_hash := binary(),
        %% sha256 of entire BEAM
        module_hash := binary()
    }
    | {error, term()}.
info({M, F, A}) when is_atom(M), is_atom(F), is_integer(A), A >= 0 ->
    case code:get_object_code(M) of
        {M, BeamBin, File} ->
            %% Pull common chunks; be defensive if chunks are missing.
            {Exports, Attrs, Docs0, Abst0} = get_chunks(BeamBin),
            Exported = lists:member({F, A}, Exports),
            Doc = get_fun_doc(Docs0, F, A),
            StepDoc = get_stepdocs(M),
            Spec = get_fun_spec(Attrs, F, A),
            Forms = get_fun_abstract(Abst0, F, A),
            FunHash = hash_fun_or_module(Forms, BeamBin),
            ModHash = sha256(BeamBin),
            #{
                module => M,
                function => F,
                arity => A,
                exported => Exported,
                file => File,
                docs => Doc,
                step_docs => StepDoc,
                spec => Spec,
                abstract_clauses => Forms,
                fun_hash => FunHash,
                module_hash => ModHash
            };
        error ->
            {error, {not_loaded, M}}
    end.

%% ---- helpers --------------------------------------------------------------

get_chunks(BeamBin) ->
    %% Try to read docs/attributes/abstract code; each may be missing.
    Exports =
        case beam_lib:chunks(BeamBin, [exports]) of
            {ok, {_M, [{exports, Es}]}} -> Es;
            _ -> []
        end,
    Attrs =
        case beam_lib:chunks(BeamBin, [attributes]) of
            {ok, {_, [{attributes, As}]}} -> As;
            _ -> []
        end,
    Docs =
        case beam_lib:chunks(BeamBin, [documentation]) of
            {ok, {_, [{documentation, D}]}} -> D;
            _ -> undefined
        end,
    Abst =
        case beam_lib:chunks(BeamBin, [abstract_code]) of
            {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} -> Forms;
            _ -> undefined
        end,
    {Exports, Attrs, Docs, Abst}.

get_fun_doc(undefined, _F, _A) ->
    undefined;
get_fun_doc(DocsTerm, F, A) ->
    %% EEP-48: 'docs' chunk format
    %% We expect: {docs_v1,_,_,DocMap,_} in newer OTP
    ?LOG_INFO("LOG terms ~p", [DocsTerm]),
    try DocsTerm of
        {docs_v1, _Anno, _Lang, DocMap, _Meta} ->
            case maps:get({function, F, A}, DocMap, undefined) of
                #{doc := DocBin} when is_binary(DocBin) -> DocBin;
                #{doc := none} -> none;
                undefined -> none;
                Other -> Other
            end;
        %% Older/other shapes — return undefined rather than crashing.
        _ ->
            undefined
    catch
        _:_ -> undefined
    end.

get_fun_spec(Attrs, F, A) ->
    %% 'spec' attribute usually looks like {spec, {{F,A}, SpecAst}} or a list thereof.
    case lists:keyfind(spec, 1, Attrs) of
        false ->
            none;
        {spec, SpecList} when is_list(SpecList) ->
            case lists:keyfind({F, A}, 1, SpecList) of
                false -> none;
                {{F, A}, SpecAst} -> SpecAst
            end;
        {spec, {{F, A}, SpecAst}} ->
            SpecAst;
        _ ->
            none
    end.

get_fun_abstract(undefined, _F, _A) ->
    undefined;
get_fun_abstract(Forms, F, A) ->
    %% Filter 'forms' to the specific function clauses
    %% Function form shape: {function, Line, Name, Arity, Clauses}
    case
        [
            Clauses
         || {function, _L, FName, Arity, Clauses} <- Forms,
            FName =:= F,
            Arity =:= A
        ]
    of
        [Clauses] -> Clauses;
        _ -> undefined
    end.

hash_fun_or_module(undefined, BeamBin) ->
    sha256(BeamBin);
hash_fun_or_module(Clauses, _BeamBin) ->
    %% Hash the specific function’s abstract clauses for a stable source-ish hash
    sha256(term_to_binary(Clauses)).

sha256(Bin) when is_binary(Bin) ->
    <<H:256/bits>> = crypto:hash(sha256, Bin),
    H.

%% Helper to read stepdoc entries back from a module’s BEAM:
get_stepdocs(Mod) when is_list(Mod) ->
    get_stepdocs(list_to_atom(Mod));
get_stepdocs(Mod) ->
    case code:get_object_code(Mod) of
        {Mod, Beam, _File} ->
            case beam_lib:chunks(Beam, [attributes]) of
                {ok, {_M, [{attributes, Attrs}]}} ->
                    proplists:get_all_values(stepdoc, Attrs);
                _ ->
                    []
            end;
        error ->
            []
    end.
%% ===== New: build_context/0 =====
build_context() ->
    Mods = list_step_modules(),
    Groups = [group_for_module(M) || M <- Mods],
    #{
        groups => Groups,
        title => <<"Step Reference">>,
        product => <<"DamageBDD">>,
        description => <<"Human-readable Gherkin steps supported by DamageBDD.">>,
        version => <<"0.1.0">>,
        commit_hash => <<"local">>,
        generated_at => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))),
        intro => <<"This page lists all available steps, grouped by module. Type to filter.">>
    }.

list_step_modules() ->
    %% Prefer loaded modules; fallback to code:all_available() scan.
    Ld = [
        M
     || {M, _} <- code:all_loaded(),
        lists:prefix("steps_", atom_to_list(M)),
        not lists:suffix("_SUITE", atom_to_list(M))
    ],
    case Ld of
        %% try available (slow, but robust in releases)
        [] ->
            Avail = code:all_available(),
            [
                list_to_atom(M)
             || {M, _F, _A} <- Avail,
                lists:prefix("steps_", M)
            ];
        _ ->
            lists:usort(Ld)
    end.

group_for_module(M) ->
    Steps = steps_for_module(M),
    #{
        name => list_to_binary(module_name_pretty(M)),
        slug => list_to_binary(slug(module_name_pretty(M))),
        steps => Steps
    }.

module_name_pretty(M) ->
    %% steps_http -> HTTP Steps
    L = atom_to_list(M),
    Stem =
        case lists:prefix("steps_", L) of
            true -> lists:nthtail(6, L);
            false -> L
        end,
    string:titlecase(replace_underscores(Stem) ++ " Steps").

replace_underscores(S) ->
    lists:map(
        fun
            ($_) -> $\s;
            (C) -> C
        end,
        S
    ).

slug(S) ->
    Lower = string:lowercase(S),
    [
        case C of
            $\s -> $-;
            C1 when C1 >= $a, C1 =< $z -> C1;
            C1 when C1 >= $0, C1 =< $9 -> C1;
            _ -> $-
        end
     || C <- Lower
    ].

steps_for_module(M) ->
    %% Pull stepdoc attributes; shape may be a map or proplist. Normalize.
    Docs = get_stepdocs(M),
    Norm = [normalize_stepdoc(M, D) || D <- Docs],
    %% If no -stepdoc attrs, try exported functions for fallback visibility:
    case Norm of
        [] ->
            %% Show exported functions with any EEP-48 doc
            Exports = proplists:get_value(exports, beam_lib:info(code:which(M)), []),
            [step_entry_from_fun(M, F, A, #{}) || {F, A} <- Exports];
        _ ->
            Norm
    end.

normalize_stepdoc(M, D) when is_map(D) ->
    %% Expected keys (any subset): signature, help, example, since, headers, args, keyword, category, function, arity
    F = maps:get(function, D, undefined),
    A = maps:get(arity, D, undefined),
    step_entry_from_fun(M, F, A, D);
normalize_stepdoc(M, D) when is_list(D) ->
    Map = maps:from_list(D),
    normalize_stepdoc(M, Map);
normalize_stepdoc(M, Other) ->
    %% Best-effort: try to parse tuple like {signature, <<"Given ...">>}
    step_entry_from_fun(M, undefined, undefined, #{raw => Other}).

step_entry_from_fun(M, F0, A0, Meta0) ->
    %% Fill function/arity if missing by looking up signature "Keyword I ..." or exported matches.
    {F, A} = ensure_fun_arity(M, F0, A0),
    Info =
        case (F =/= undefined andalso is_integer(A)) of
            true -> info({M, F, A});
            false -> info_guess_any(M)
        end,
    DocBin = get_binary(maps:get(docs, Info, none)),
    %% Render doc_html = paragraphized doc; fallback to plain doc
    DocHtml = paragraphize(DocBin),
    SpecText = pretty_spec(maps:get(spec, Info, none)),
    %% Pull presentation fields from Meta0 or compute
    Signature = get_binary(maps:get(signature, Meta0, guess_signature(M, F, A))),
    Help = get_binary(maps:get(help, Meta0, <<"">>)),
    Example = get_binary(maps:get(example, Meta0, <<"">>)),
    Since = get_binary(maps:get(since, Meta0, <<"">>)),
    Keyword = get_binary(maps:get(keyword, Meta0, guess_keyword(Signature))),
    Category = get_binary(maps:get(category, Meta0, module_name_pretty(M))),
    Headers = listify(maps:get(headers, Meta0, [])),
    Args = mark_last(listify(maps:get(args, Meta0, []))),
    ArgsFlat = iolist_to_binary(
        string:join([binary_to_list(X) || X <- Headers ++ [A1 || {A1, _} <- Args]], ", ")
    ),
    HtmlId = iolist_to_binary(slug(binary_to_list(Signature))),
    #{
        module => atom_to_binary(M, utf8),
        function => atom_to_binary(F, utf8),
        arity => A,
        signature => Signature,
        help => Help,
        example => Example,
        since => Since,
        keyword => Keyword,
        category => Category,
        headers => Headers,
        args => [{AName, Last} || {AName, Last} <- Args],
        args_flat => ArgsFlat,
        html_id => HtmlId,
        doc => DocBin,
        doc_html => DocHtml,
        spec_text => SpecText
    }.

ensure_fun_arity(_M, F, A) when is_atom(F), is_integer(A) -> {F, A};
ensure_fun_arity(M, _F, _A) ->
    %% Fallback: pick the first exported fun that has docs/spec
    case info_guess_any(M) of
        #{function := Fn, arity := Ar} -> {Fn, Ar};
        _ -> {undefined, undefined}
    end.

info_guess_any(M) ->
    case code:get_object_code(M) of
        {M, _Beam, _File} ->
            case lists:keyfind(exports, 1, element(2, beam_lib:info(code:which(M)))) of
                {exports, Es} ->
                    case Es of
                        [{F, A} | _] -> info({M, F, A});
                        _ -> #{}
                    end;
                _ ->
                    #{}
            end;
        error ->
            #{}
    end.

get_binary(none) -> <<>>;
get_binary(undefined) -> <<>>;
get_binary(B) when is_binary(B) -> B;
get_binary(L) when is_list(L) -> list_to_binary(L);
get_binary(T) -> list_to_binary(io_lib:format("~p", [T])).

listify(Bs) when is_list(Bs) ->
    %% Coerce to list of binaries
    [get_binary(B) || B <- Bs];
listify(B) when is_binary(B) -> [B];
listify(_) ->
    [].

mark_last([]) -> [];
mark_last([X]) -> [{X, true}];
mark_last([H | T]) -> [{H, false} | mark_last(T)].

%% Export if you want to unit-test them; otherwise omit from -export().
%% -export([paragraphize/1, safe_html/1, pretty_spec/1]).

paragraphize(<<>>) ->
    <<>>;
paragraphize(Bin) when is_binary(Bin) ->
    %% Split doc on blank lines and wrap each chunk in <p>…</p>
    Lines = binary:split(Bin, <<"\n\n">>, [global]),
    iolist_to_binary([[<<"<p>">>, safe_html(L), <<"</p>\n">>] || L <- Lines]);
paragraphize(List) when is_list(List) ->
    paragraphize(list_to_binary(List));
paragraphize(Other) ->
    %% Last-resort fallback; won't usually hit
    list_to_binary(io_lib:format("<p>~ts</p>\n", [Other])).

safe_html(Bin) when is_binary(Bin) ->
    %% Minimal escaping (& < >). Keep newlines as-is.
    Esc1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    Esc2 = binary:replace(Esc1, <<"<">>, <<"&lt;">>, [global]),
    binary:replace(Esc2, <<">">>, <<"&gt;">>, [global]);
safe_html(List) when is_list(List) ->
    safe_html(list_to_binary(List)).

pretty_spec(none) -> <<>>;
pretty_spec(undefined) -> <<>>;
pretty_spec(SpecAst) -> list_to_binary(io_lib:format("~p", [SpecAst])).

guess_keyword(Sig) when is_binary(Sig) ->
    case Sig of
        <<"Given", _/binary>> -> <<"Given">>;
        <<"When", _/binary>> -> <<"When">>;
        <<"Then", _/binary>> -> <<"Then">>;
        <<"And", _/binary>> -> <<"And">>;
        _ -> <<>>
    end.

guess_signature(M, F, A) when is_atom(F), is_integer(A) ->
    %% Fall back to "Mod:Fun/Arity" if no attribute provides a Gherkin signature
    list_to_binary(io_lib:format("~p:~p/~p", [M, F, A]));
guess_signature(M, _F, _A) ->
    list_to_binary(io_lib:format("~p", [M])).
