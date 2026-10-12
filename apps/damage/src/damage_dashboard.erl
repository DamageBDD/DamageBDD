%%====================================================================
%% dealdamage_ui.erl  (Mustache-based)
%%====================================================================
-module(damage_dashboard).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([trails/0]).
-export([init/2, allowed_methods/2, content_types_provided/2, to_html/2, is_authorized/2]).

-define(TPL(Name), (filename:join("ui/dashboard", Name))).

trails() ->
    [
        trails:trail(
            "/",
            ?MODULE,
            #{action => index, node_admin => false},
            #{get => #{tags => ["UI", "HTML"], produces => ["text/html"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) -> {[{{<<"text">>, <<"html">>, '*'}, to_html}], Req, State}.
is_authorized(Req, State0) ->
    Resp = damage_auth:maybe_authenticate(Req, State0),
    Resp.

to_html(Req0, #{action := index} = State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req0),
    AuthCtx = maps:merge(base_context(Req), State),
    Ctx0 = AuthCtx#{tax_only_admin => maps:get(tax_admin, AuthCtx, false) =:= true
                       andalso maps:get(node_admin, AuthCtx, false) =/= true},
    #{component := Comp0} = cowboy_req:match_qs([{component, [], undefined}], Req),
    case Comp0 of
        undefined ->
            {render_full_page(Ctx0), Req, State};
        _ ->
            Comp = try binary_to_existing_atom(Comp0, utf8) catch error:badarg -> unknown end,
            {render_component(Comp, Ctx0), Req, State}
    end.

%% -------------------------- Context --------------------------
base_context(Req) ->
    #{
        request_path => cowboy_req:path(Req),
        node_version => <<"v0.1">>,
        logo_image => logo_image(),
        tax_enabled => application:get_env(damage, tax_enabled, false)
    }.

logo_image() ->
    case application:get_env(damage, logo_image) of
        {ok, Logo} when is_binary(Logo) ->
            Logo;
        {ok, Logo} when is_list(Logo) ->
            list_to_binary(Logo);
        _ ->
            <<"/static/img/logo.png">>
    end.

%% Do not substitute a user wallet as the node identity. A locked node
%% deliberately leaves the default empty instead of silently scanning another account.
history_context(Ctx) ->
    Ctx#{
        run_history_account => maps:get(public_key, Ctx, <<>>),
        run_history_node => history_node_id(),
        run_history_registry => application:get_env(damage, run_history_registry_contract, <<>>)
    }.

history_node_id() ->
    case application:get_env(damage, run_history_node_account, undefined) of
        Account when is_binary(Account), Account =/= <<>> -> Account;
        Account when is_list(Account), Account =/= [] -> list_to_binary(Account);
        _ ->
            try secrets:node_keypair() of
                #{public_key := PublicKey} -> damage_utils:to_bin(PublicKey);
                _ -> <<>>
            catch
                _:_ -> <<>>
            end
    end.

%% -------------------------- Page -----------------------------
render_full_page(Ctx) ->
    %% Assemble from mustache fragments so you can also SSR each piece independently
    %% page_shell.mustache should call {{{topbar}}}, {{{sidebar}}}, etc. (triple-stache = HTML safe)
    Top = render_tpl(?TPL("topbar.mustache"), Ctx),
    Exec = render_tpl(?TPL("execution_tab.mustache"), Ctx),
    Activity = render_tpl(?TPL("activity_tab.mustache"), history_context(Ctx)),
    Anal = render_tpl(?TPL("analytics_tab.mustache"), history_context(Ctx)),
    Sched = render_tpl(?TPL("schedules_tab.mustache"), Ctx),
    Billing = render_tpl(?TPL("billing_tab.mustache"), Ctx),
    Sets = render_tpl(?TPL("settings_tab.mustache"), Ctx),
    InvM = render_tpl(?TPL("invoice_modal.mustache"), Ctx),
    WalletM = render_tpl(?TPL("wallet_modal.mustache"), Ctx),
    %% A guest sees the public onboarding experience immediately, rather than an
    %% auto-open sign-in dialog covering an otherwise empty dashboard.  The
    %% sign-in modal remains available via the guest actions.
    AuthCtx = case maps:get(authenticated, Ctx, false) of
        true -> Ctx;
        _ -> Ctx#{auth_auto_open => <<"false">>, auth_allow_guest => true}
    end,
    AuthM = render_tpl(?TPL("auth_modal.mustache"), AuthCtx),
    GuestLanding = render_tpl(?TPL("guest_landing.mustache"), Ctx),
    LogOutM = render_tpl(?TPL("logout_modal.mustache"), Ctx),
    InstM = render_tpl(?TPL("install_modal.mustache"), Ctx),
    PickM = render_tpl(?TPL("feature_picker_modal.mustache"), Ctx),
    IpfsPickM = render_tpl(?TPL("file_picker_modal.mustache"), Ctx),
    NotifyM = render_tpl(?TPL("notification_modal.mustache"), Ctx),
    Foot = render_tpl(?TPL("footer.mustache"), Ctx),
    NpkM = render_tpl(?TPL("node_details_modal.mustache"), Ctx),
    NodeSetPasswordM = render_tpl(?TPL("node_set_password_modal.mustache"), Ctx),
    NodeUnlockM = render_tpl(?TPL("node_unlock_modal.mustache"), Ctx),
    SwapOptions = render_tpl(?TPL("swap_options_tab.mustache"), Ctx),
    Gallery = render_tpl(?TPL("gallery_tab.mustache"), Ctx),
    EcaiJobDetail = render_tpl(?TPL("ecai_job_detail_modal.mustache"), Ctx),
    NwcModal = render_tpl(?TPL("nwc_modal.mustache"), Ctx),
    NodeWalletModal = render_tpl(?TPL("node_wallet_modal.mustache"), Ctx),
    NodeContextTab = render_tpl(?TPL("node_context_tab.mustache"), Ctx),
    NodeTransactionsTab = render_tpl(?TPL("node_transactions_tab.mustache"), Ctx),
    NodeChannelsTab = render_tpl(?TPL("node_channels_tab.mustache"), Ctx),
    NodeClnAdminTab = render_tpl(?TPL("node_cln_admin.mustache"), Ctx),
    NodeTaxReportsTab = case maps:get(tax_admin, Ctx, false) of
        true -> render_tpl(?TPL("node_tax_reports_tab.mustache"), Ctx);
        _ -> <<>>
    end,

    %% pass the assembled parts into the shell
    PageCtx = Ctx#{
        topbar => Top,
        sidebar => render_tpl(?TPL("sidebar.mustache"), Ctx#{footer => Foot}),
        execution_tab => Exec,
        activity_tab => Activity,
        analytics_tab => Anal,
        schedules_tab => Sched,
        billing_tab => Billing,
        settings_tab => Sets,
        invoice_modal => InvM,
        wallet_modal => WalletM,
        auth_modal => AuthM,
        guest_landing => GuestLanding,
        logout_modal => LogOutM,
        install_modal => InstM,
        feature_picker_modal => PickM,
        file_picker_modal => IpfsPickM,
        notification_modal => NotifyM,
        footer => Foot,
        node_unlock_modal => NodeUnlockM,
        node_set_password_modal => NodeSetPasswordM,
        node_public_key_modal => NpkM,
        swaps_tab => SwapOptions,
        gallery_tab => Gallery,
        ecai_job_detail_modal => EcaiJobDetail,
        nwc_modal => NwcModal,
        node_wallet_modal => NodeWalletModal,
        node_context_tab => NodeContextTab,
        node_transactions_tab => NodeTransactionsTab,
        node_channels_tab => NodeChannelsTab,
        node_cln_admin_tab => NodeClnAdminTab,
        node_tax_reports_tab => NodeTaxReportsTab
    },
    render_tpl(?TPL("page_shell.mustache"), PageCtx).

%% ---------------------- Component switch ---------------------
render_component(page, Ctx) ->
    render_full_page(Ctx);
render_component(topbar, Ctx) ->
    render_tpl(?TPL("topbar.mustache"), Ctx);
render_component(sidebar, Ctx) ->
    Footer = render_tpl(?TPL("footer.mustache"), Ctx),
    render_tpl(?TPL("sidebar.mustache"), Ctx#{footer => Footer});
%% Keep the existing component URL usable; it now returns sidebar navigation.
render_component(tabs, Ctx) ->
    render_component(sidebar, Ctx);
render_component(execution_tab, Ctx) ->
    render_tpl(?TPL("execution_tab.mustache"), Ctx);
render_component(activity_tab, Ctx) ->
    render_tpl(?TPL("activity_tab.mustache"), history_context(Ctx));
render_component(analytics_tab, Ctx) ->
    render_tpl(?TPL("analytics_tab.mustache"), history_context(Ctx));
render_component(schedules_tab, Ctx) ->
    render_tpl(?TPL("schedules_tab.mustache"), Ctx);
render_component(billing_tab, Ctx) ->
    render_tpl(?TPL("billing_tab.mustache"), Ctx);
render_component(settings_tab, Ctx) ->
    render_tpl(?TPL("settings_tab.mustache"), Ctx);
render_component(node_tax_reports_tab, #{tax_admin := true} = Ctx) ->
    render_tpl(?TPL("node_tax_reports_tab.mustache"), Ctx);
render_component(node_tax_reports_tab, _Ctx) ->
    <<>>;
render_component(invoice_modal, Ctx) ->
    render_tpl(?TPL("invoice_modal.mustache"), Ctx);
render_component(login_modal, Ctx) ->
    render_tpl(?TPL("login_modal.mustache"), Ctx);
render_component(signup_modal, Ctx) ->
    render_tpl(?TPL("signup_modal.mustache"), Ctx);
render_component(logout_modal, Ctx) ->
    render_tpl(?TPL("logout_modal.mustache"), Ctx);
render_component(node_public_key_modal, Ctx) ->
    render_tpl(?TPL("node_public_key_modal.mustache"), Ctx);
render_component(install_modal, Ctx) ->
    render_tpl(?TPL("install_modal.mustache"), Ctx);
render_component(feature_picker_modal, Ctx) ->
    render_tpl(?TPL("feature_picker_modal.mustache"), Ctx);
render_component(file_picker_modal, Ctx) ->
    render_tpl(?TPL("file_picker_modal.mustache"), Ctx);
render_component(footer, Ctx) ->
    render_tpl(?TPL("footer.mustache"), Ctx);
render_component(_, _) ->
    <<>>.

%% ---------------------- Rendering helper ---------------------
render_tpl(TemplateRelPath, Context) ->
    try damage_utils:load_template(TemplateRelPath, Context) of
        {error, enoent} ->
            log_missing_template(TemplateRelPath),
            template_error_placeholder(TemplateRelPath);
        {error, Reason} ->
            ?LOG_ERROR(
                "Template render failed template=~p reason=~p",
                [TemplateRelPath, Reason]
            ),
            template_error_placeholder(TemplateRelPath);
        Rendered ->
            Rendered
    catch
        error:{badmatch, {error, enoent}}:Stacktrace ->
            log_missing_template(TemplateRelPath),
            ?LOG_DEBUG(
                "Missing template stacktrace template=~p stacktrace=~p",
                [TemplateRelPath, Stacktrace]
            ),
            template_error_placeholder(TemplateRelPath);
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Template render crashed template=~p class=~p reason=~p stacktrace=~p",
                [TemplateRelPath, Class, Reason, Stacktrace]
            ),
            template_error_placeholder(TemplateRelPath)
    end.

log_missing_template(TemplateRelPath) ->
    ?LOG_ERROR("Template file not found template=~p", [TemplateRelPath]).

template_error_placeholder(_TemplateRelPath) ->
    <<"<!-- template unavailable -->">>.
