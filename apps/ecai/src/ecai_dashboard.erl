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
    %Top = render_tpl(?TPL("topbar.mustache"), Ctx),
    %Foot = render_tpl(?TPL("footer.mustache"), Ctx),
    %NpkM = render_tpl(?TPL("node_details_modal.mustache"), Ctx),
    %NodeSetPasswordM = render_tpl(?TPL("node_set_password_modal.mustache"), Ctx),
    %NodeUnlockM = render_tpl(?TPL("node_unlock_modal.mustache"), Ctx),
    %% pass the assembled parts into the shell
    PageCtx = Ctx#{
        %    topbar => Top,
        %    footer => Foot,
        %    node_unlock_modal => NodeUnlockM,
        %    node_set_password_modal => NodeSetPasswordM,
        %    node_public_key_modal => NpkM
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
    damage_utils:load_template(ecai, TemplateRelPath, Context).
