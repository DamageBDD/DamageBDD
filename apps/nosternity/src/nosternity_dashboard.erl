%% Server-rendered dashboard shell and explicitly allowlisted Mustache fragments.
-module(nosternity_dashboard).
-export([routes/0, init/2, render/1]).
routes() ->
    case nosternity_config:get(dashboard_enabled) of
        false -> [];
        true -> [
            {"/", ?MODULE, #{action => page}},
            {"/dashboard", ?MODULE, #{action => page}},
            {"/dashboard/fragments/:fragment", ?MODULE, #{action => fragment}}
        ] ++ [{"/dashboard/assets/" ++ Name, cowboy_static,
            {priv_file, nosternity, "static/dashboard/" ++ Name}}
            || Name <- ["dashboard.js", "dashboard.css", "qrcode.min.js"]]
    end.
init(Req, #{action := A} = State) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            Part = case A of page -> <<"page">>; fragment -> cowboy_req:binding(fragment, Req) end,
            case render(Part) of
                {ok, HTML} -> {ok, cowboy_req:reply(200, headers(), HTML, Req), State};
                {error, not_found} -> {ok, cowboy_req:reply(404, headers(), <<"Not found">>, Req), State}
            end;
        _ -> {ok, cowboy_req:reply(405, #{<<"allow">> => <<"GET">>}, <<>>, Req), State}
    end.
render(<<"page">>) ->
    Parts = [<<"sidebar">>, <<"header">>, <<"hero">>, <<"feed">>, <<"footer">>, <<"auth">>],
    Context = maps:from_list([{P, element(2, render(P))} || P <- Parts]),
    {ok, template("page", Context)};
render(Part) ->
    case lists:member(Part, [<<"sidebar">>, <<"header">>, <<"hero">>, <<"feed">>,
         <<"footer">>, <<"auth">>, <<"analytics">>, <<"wallet">>, <<"signer">>]) of
        true -> {ok, template(binary_to_list(Part), #{})};
        false -> {error, not_found}
    end.
template(Name, Context) ->
    {ok, Bytes} = file:read_file(filename:join([code:priv_dir(nosternity), "templates", "ui", "dashboard", Name ++ ".mustache"])),
    bbmustache:render(Bytes, Context, [{key_type, binary}]).
headers() -> #{<<"content-type">> => <<"text/html; charset=utf-8">>,
    <<"cache-control">> => <<"no-store">>, <<"referrer-policy">> => <<"no-referrer">>,
    <<"x-content-type-options">> => <<"nosniff">>, <<"x-frame-options">> => <<"DENY">>,
    <<"content-security-policy">> => <<"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' wss:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'">>}.
