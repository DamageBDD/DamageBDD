-module(ecai_dashboard).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([trails/0]).
-export([init/2, allowed_methods/2, content_types_provided/2, to_html/2]).

-define(DASH_TPL(Name), (filename:join("ui/dashboard", Name))).
-define(INDEXER_TPL(Name), (filename:join("ui/indexer", Name))).
-define(ADV_INDEXER_TPL(Name), (filename:join(["ui", "indexer", "advanced", Name]))).

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
        ),
        trails:trail(
            "/indexer",
            ?MODULE,
            #{action => indexer},
            #{get => #{tags => ["UI", "HTML", "ECAI Indexer"], produces => ["text/html"]}}
        ),
        trails:trail(
            "/indexer/advanced",
            ?MODULE,
            #{action => indexer_advanced},
            #{get => #{tags => ["UI", "HTML", "ECAI Indexer"], produces => ["text/html"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) -> {[{{<<"text">>, <<"html">>, '*'}, to_html}], Req, State}.

to_html(Req, #{action := index} = State) ->
    Ctx = base_context(Req),
    #{component := Component} = cowboy_req:match_qs([{component, [], undefined}], Req),
    case Component of
        undefined ->
            Host = cowboy_req:host(Req),
            Template =
                case Host of
                    <<"ecai.damagebdd.com">> -> "ecai_search.mustache";
                    <<"ecai.chat">> -> "ecai_chat.mustache";
                    _ -> application:get_env(ecai, default_page, "ecai_search.mustache")
                end,
            {render_tpl(?DASH_TPL(Template), Ctx), Req, State};
        _ ->
            {render_dashboard_component(Component, Ctx), Req, State}
    end;
to_html(Req, #{action := chat} = State) ->
    Ctx = base_context(Req),
    {render_tpl(?DASH_TPL("ecai_chat.mustache"), Ctx), Req, State};
to_html(Req, #{action := indexer} = State) ->
    Ctx = base_context(Req),
    #{component := Component} = cowboy_req:match_qs([{component, [], undefined}], Req),
    case Component of
        undefined -> {render_indexer_page(Ctx), Req, State};
        _ -> {render_indexer_component(Component, Ctx), Req, State}
    end;
to_html(Req, #{action := indexer_advanced} = State) ->
    Ctx = base_context(Req),
    #{component := Component} = cowboy_req:match_qs([{component, [], undefined}], Req),
    case Component of
        undefined -> {render_advanced_indexer_page(Ctx), Req, State};
        _ -> {render_advanced_indexer_component(Component, Ctx), Req, State}
    end.

%% -------------------------- Context --------------------------
base_context(Req) ->
    #{
        request_path => cowboy_req:path(Req),
        node_version => <<"v0.1">>,
        indexer_path => <<"/indexer">>,
        advanced_indexer_path => <<"/indexer/advanced">>
    }.

%% ---------------------- Dashboard pieces --------------------
render_dashboard_component(<<"topbar">>, Ctx) ->
    render_tpl(?DASH_TPL("topbar.mustache"), Ctx);
render_dashboard_component(<<"footer">>, Ctx) ->
    render_tpl(?DASH_TPL("footer.mustache"), Ctx);
render_dashboard_component(_, _) ->
    <<>>.

%% -------------------- Simple indexer page --------------------
render_indexer_page(Ctx) ->
    Header = render_tpl(?INDEXER_TPL("header.mustache"), Ctx),
    Presets = render_tpl(?INDEXER_TPL("presets.mustache"), Ctx),
    Jobs = render_tpl(?INDEXER_TPL("jobs.mustache"), Ctx),
    LoginDialog = render_tpl(?INDEXER_TPL("login_dialog.mustache"), Ctx),
    PageCtx = Ctx#{
        indexer_header => Header,
        presets => Presets,
        jobs => Jobs,
        login_dialog => LoginDialog
    },
    render_tpl(?INDEXER_TPL("page_shell.mustache"), PageCtx).

render_indexer_component(<<"header">>, Ctx) ->
    render_tpl(?INDEXER_TPL("header.mustache"), Ctx);
render_indexer_component(<<"presets">>, Ctx) ->
    render_tpl(?INDEXER_TPL("presets.mustache"), Ctx);
render_indexer_component(<<"jobs">>, Ctx) ->
    render_tpl(?INDEXER_TPL("jobs.mustache"), Ctx);
render_indexer_component(<<"login_dialog">>, Ctx) ->
    render_tpl(?INDEXER_TPL("login_dialog.mustache"), Ctx);
render_indexer_component(<<"page">>, Ctx) ->
    render_indexer_page(Ctx);
render_indexer_component(_, _) ->
    <<>>.

%% ------------------- Advanced indexer page -------------------
render_advanced_indexer_page(Ctx) ->
    Header = render_tpl(?ADV_INDEXER_TPL("header.mustache"), Ctx),
    QueueStatus = render_tpl(?ADV_INDEXER_TPL("queue_status.mustache"), Ctx),
    NewJob = render_tpl(?ADV_INDEXER_TPL("new_wikimedia_job.mustache"), Ctx),
    Search = render_tpl(?ADV_INDEXER_TPL("search.mustache"), Ctx),
    Jobs = render_tpl(?ADV_INDEXER_TPL("jobs.mustache"), Ctx),
    SelectedJob = render_tpl(?ADV_INDEXER_TPL("selected_job.mustache"), Ctx),
    Artifact = render_tpl(?ADV_INDEXER_TPL("artifact.mustache"), Ctx),
    OperatorOutput = render_tpl(?ADV_INDEXER_TPL("operator_output.mustache"), Ctx),
    LoginDialog = render_tpl(?INDEXER_TPL("login_dialog.mustache"), Ctx),
    PageCtx = Ctx#{
        indexer_header => Header,
        queue_status => QueueStatus,
        new_wikimedia_job => NewJob,
        search => Search,
        jobs => Jobs,
        selected_job => SelectedJob,
        artifact => Artifact,
        operator_output => OperatorOutput,
        login_dialog => LoginDialog
    },
    render_tpl(?ADV_INDEXER_TPL("page_shell.mustache"), PageCtx).

render_advanced_indexer_component(<<"header">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("header.mustache"), Ctx);
render_advanced_indexer_component(<<"queue_status">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("queue_status.mustache"), Ctx);
render_advanced_indexer_component(<<"new_job">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("new_wikimedia_job.mustache"), Ctx);
render_advanced_indexer_component(<<"search">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("search.mustache"), Ctx);
render_advanced_indexer_component(<<"jobs">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("jobs.mustache"), Ctx);
render_advanced_indexer_component(<<"selected_job">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("selected_job.mustache"), Ctx);
render_advanced_indexer_component(<<"artifact">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("artifact.mustache"), Ctx);
render_advanced_indexer_component(<<"operator_output">>, Ctx) ->
    render_tpl(?ADV_INDEXER_TPL("operator_output.mustache"), Ctx);
render_advanced_indexer_component(<<"login_dialog">>, Ctx) ->
    render_tpl(?INDEXER_TPL("login_dialog.mustache"), Ctx);
render_advanced_indexer_component(<<"page">>, Ctx) ->
    render_advanced_indexer_page(Ctx);
render_advanced_indexer_component(_, _) ->
    <<>>.

%% ---------------------- Rendering helper ---------------------
render_tpl(TemplateRelPath, Context) ->
    try damage_utils:load_template(ecai, TemplateRelPath, Context) of
        {error, enoent} ->
            ?LOG_ERROR("ECAI template file not found template=~p", [TemplateRelPath]),
            <<"<!-- template unavailable -->">>;
        {error, Reason} ->
            ?LOG_ERROR("ECAI template render failed template=~p reason=~p", [
                TemplateRelPath, Reason
            ]),
            <<"<!-- template unavailable -->">>;
        Rendered ->
            Rendered
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "ECAI template render crashed template=~p class=~p reason=~p stacktrace=~p",
                [TemplateRelPath, Class, Reason, Stacktrace]
            ),
            <<"<!-- template unavailable -->">>
    end.
