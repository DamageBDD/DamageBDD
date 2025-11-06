-module(ecai_dashboard).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([trails/0]).
-export([init/2, allowed_methods/2, content_types_provided/2, to_html/2]).

-define(TPL(Name), (filename:join("ui/dashboard", Name))).

trails() ->
    [
        trails:trail(
            "/",
            ?MODULE,
            #{action => index},
            #{get => #{tags => ["UI", "HTML"], produces => ["text/html"]}}
        ),
        trails:trail(
            "/chat",
            ?MODULE,
            #{action => chat},
            #{get => #{tags => ["UI", "HTML"], produces => ["text/html"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) -> {[{{<<"text">>, <<"html">>, '*'}, to_html}], Req, State}.

to_html(Req, #{action := index} = State) ->
    Ctx0 = base_context(Req),
    #{component := Comp0} = cowboy_req:match_qs([{component, [], undefined}], Req),
    Host = cowboy_req:host(Req),
    %% pick template based on hostname
    Template =
        case Host of
            <<"ecai.damagebdd.com">> -> "ecai_search.mustache";
            <<"ecai.chat">> -> "ecai_chat.mustache";
            _ -> application:get_env(ecai, default_page, "ecai_search.mustache")
        end,
    PageCtx = Ctx0,
    case Comp0 of
        undefined ->
            {render_tpl(?TPL(Template), PageCtx), Req, State};
        _ ->
            Comp = binary_to_atom(Comp0, utf8),
            {render_component(Comp, PageCtx), Req, State}
    end.


%% -------------------------- Context --------------------------
base_context(Req) ->
    %% Add anything you want available to all templates (user, feature list, etc.)
    #{
        request_path => cowboy_req:path(Req),
        node_version => <<"v0.1">>
    }.

render_component(topbar, Ctx) ->
    render_tpl(?TPL("topbar.mustache"), Ctx);
render_component(footer, Ctx) ->
    render_tpl(?TPL("footer.mustache"), Ctx);
render_component(_, _) ->
    <<>>.

%% ---------------------- Rendering helper ---------------------
render_tpl(TemplateRelPath, Context) ->
    %% priv/templates/<TemplateRelPath> :contentReference[oaicite:1]{index=1}
    damage_utils:load_template(ecai, TemplateRelPath, Context).
