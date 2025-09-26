%%====================================================================
%% dealdamage_ui.erl  (Mustache-based)
%%====================================================================
-module(damage_dashboard).

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
    %% ?component=login_modal (atoms are fine)
    #{component := Comp0} = cowboy_req:match_qs([{component, [], undefined}], Req),
    Ctx0 = base_context(Req),
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
    Tabs = render_tpl(?TPL("tabs_bar.mustache"), Ctx),
    Exec = render_tpl(?TPL("execution_tab.mustache"), Ctx),
    Hist = render_tpl(?TPL("history_tab.mustache"), Ctx),
    Anal = render_tpl(?TPL("analytics_tab.mustache"), Ctx),
    Sched = render_tpl(?TPL("schedules_tab.mustache"), Ctx),
    Sets = render_tpl(?TPL("settings_tab.mustache"), Ctx),
    InvM = render_tpl(?TPL("invoice_modal.mustache"), Ctx),
    LogInM = render_tpl(?TPL("login_modal.mustache"), Ctx),
    SignM = render_tpl(?TPL("signup_modal.mustache"), Ctx),
    LogOutM = render_tpl(?TPL("logout_modal.mustache"), Ctx),
    SchM = render_tpl(?TPL("schedule_modal.mustache"), Ctx),
    NpkM = render_tpl(?TPL("node_details_modal.mustache"), Ctx),
    InstM = render_tpl(?TPL("install_modal.mustache"), Ctx),
    PickM = render_tpl(?TPL("feature_picker_modal.mustache"), Ctx),
    NotifyM = render_tpl(?TPL("notification_modal.mustache"), Ctx),
    Foot = render_tpl(?TPL("footer.mustache"), Ctx),
    %% pass the assembled parts into the shell
    PageCtx = Ctx#{
        topbar => Top,
        tabs_bar => Tabs,
        execution_tab => Exec,
        history_tab => Hist,
        analytics_tab => Anal,
        schedules_tab => Sched,
        settings_tab => Sets,
        invoice_modal => InvM,
        login_modal => LogInM,
        signup_modal => SignM,
        logout_modal => LogOutM,
        schedule_modal => SchM,
        node_public_key_modal => NpkM,
        install_modal => InstM,
        feature_picker_modal => PickM,
        notification_modal => NotifyM,
        footer => Foot
    },
    render_tpl(?TPL("page_shell.mustache"), PageCtx).

%% ---------------------- Component switch ---------------------
render_component(page, Ctx) ->
    render_full_page(Ctx);
render_component(topbar, Ctx) ->
    render_tpl(?TPL("topbar.mustache"), Ctx);
render_component(tabs, Ctx) ->
    render_tpl(?TPL("tabs_bar.mustache"), Ctx);
render_component(execution_tab, Ctx) ->
    render_tpl(?TPL("execution_tab.mustache"), Ctx);
render_component(history_tab, Ctx) ->
    render_tpl(?TPL("history_tab.mustache"), Ctx);
render_component(analytics_tab, Ctx) ->
    render_tpl(?TPL("analytics_tab.mustache"), Ctx);
render_component(schedules_tab, Ctx) ->
    render_tpl(?TPL("schedules_tab.mustache"), Ctx);
render_component(settings_tab, Ctx) ->
    render_tpl(?TPL("settings_tab.mustache"), Ctx);
render_component(invoice_modal, Ctx) ->
    render_tpl(?TPL("invoice_modal.mustache"), Ctx);
render_component(login_modal, Ctx) ->
    render_tpl(?TPL("login_modal.mustache"), Ctx);
render_component(signup_modal, Ctx) ->
    render_tpl(?TPL("signup_modal.mustache"), Ctx);
render_component(logout_modal, Ctx) ->
    render_tpl(?TPL("logout_modal.mustache"), Ctx);
render_component(schedule_modal, Ctx) ->
    render_tpl(?TPL("schedule_modal.mustache"), Ctx);
render_component(node_public_key_modal, Ctx) ->
    render_tpl(?TPL("node_public_key_modal.mustache"), Ctx);
render_component(install_modal, Ctx) ->
    render_tpl(?TPL("install_modal.mustache"), Ctx);
render_component(feature_picker_modal, Ctx) ->
    render_tpl(?TPL("feature_picker_modal.mustache"), Ctx);
render_component(footer, Ctx) ->
    render_tpl(?TPL("footer.mustache"), Ctx);
render_component(_, _) ->
    <<>>.

%% ---------------------- Rendering helper ---------------------
render_tpl(TemplateRelPath, Context) ->
    %% priv/templates/<TemplateRelPath> :contentReference[oaicite:1]{index=1}
    damage_utils:load_template(TemplateRelPath, Context).
