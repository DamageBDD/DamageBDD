%% Render only application-owned templates. Branding values use escaped
%% Mustache fields; the sole unescaped field contains our rendered body.
-module(nosternity_page).
-export([render/3]).

render(Template, PageTitle, Values) ->
    Branding = nosternity_branding:template_vars(),
    Context = maps:merge(Values, Branding),
    Body = template(Template, Context),
    template("page_shell.mustache", Context#{
        title => nosternity_branding:page_title(PageTitle), body => Body
    }).

template(Name, Context) ->
    Path = filename:join([code:priv_dir(nosternity), "templates", Name]),
    {ok, Source} = file:read_file(Path),
    bbmustache:render(Source, Context, [{key_type, atom}]).
