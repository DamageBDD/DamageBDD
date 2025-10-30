-module(damage_doc).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([trails/0]).
-export([init/2, allowed_methods/2, content_types_provided/2, to_html/2]).

-export([info/1]).

-define(TPL(Name), (filename:join("docs/", Name))).

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
render_full_page(Ctx) ->
    %% Assemble from mustache fragments so you can also SSR each piece independently
    %% page_shell.mustache should call {{{topbar}}}, {{{tabs_bar}}}, etc. (triple-stache = HTML safe)
    Top = render_tpl(?TPL("topbar.mustache"), Ctx),
    Foot = render_tpl(?TPL("footer.mustache"), Ctx),
    PageCtx = Ctx#{
        topbar => Top,
        footer => Foot
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
