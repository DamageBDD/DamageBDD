%%% Same-origin Theme NFT marketplace + node-admin theme studio.
-module(damage_theme_http).
-export([trails/0, init/2]).

-define(JSON, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
    <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>,
    <<"referrer-policy">> => <<"no-referrer">>}).

trails() ->
    [trail("/themes", shop, get),
     trail("/dashboard/node/themes", studio, get),
     trail("/api/themes", catalog, get),
     trail("/api/themes/css", css, get),
     trail("/api/themes/branding", branding, get),
     trail("/api/themes/order", order, get),
     trail("/api/themes/order/settle", settle, post),
     trail("/api/themes/buy/sats", buy_sats, post),
     trail("/api/themes/buy/damage", buy_damage, post),
     trail("/api/admin/themes", admin, both)].

trail(Path, Action, Method) ->
    Get = #{get => #{tags => ["Themes"], produces => ["application/json"]}},
    Post = #{post => #{tags => ["Themes"], produces => ["application/json"]}},
    Meta = case Method of get -> Get; post -> Post; both -> maps:merge(Get, Post) end,
    trails:trail(Path, ?MODULE, #{action => Action}, Meta).

init(Req0, #{action := Action} = State) ->
    Req = case allowed(Action, cowboy_req:method(Req0)) of
        false -> error_reply(405, method_not_allowed, Req0);
        true -> safely(fun() -> dispatch(Action, Req0) end, Req0)
    end,
    {ok, Req, State}.

allowed(admin, Method) -> Method =:= <<"GET">> orelse Method =:= <<"POST">>;
allowed(A, <<"GET">>) -> lists:member(A, [shop, studio, catalog, css, branding, order]);
allowed(A, <<"POST">>) -> lists:member(A, [buy_sats, buy_damage, settle]);
allowed(_, _) -> false.

safely(Fun, Req) ->
    try Fun()
    catch _:_ -> error_reply(503, theme_service_unavailable, Req) end.

dispatch(shop, Req) -> page(Req, <<"shop">>);
dispatch(studio, Req) ->
    case admin_actor(Req) of
        {ok, _} -> page(Req, <<"studio">>);
        _ -> error_reply(403, node_admin_required, Req)
    end;
dispatch(catalog, Req) ->
    case damage_theme:catalog() of
        {ok, T} -> reply_json(200, #{themes => T, nft => damage_theme_nft:status()}, Req);
        _ -> error_reply(503, theme_catalog_unavailable, Req)
    end;
dispatch(css, Req) ->
    App = query(Req, <<"app">>, <<"damage">>),
    case damage_theme:stylesheet(App) of
        {ok, Css} ->
            cowboy_req:reply(200, #{<<"content-type">> => <<"text/css; charset=utf-8">>,
               <<"cache-control">> => <<"no-store">>,
               <<"x-content-type-options">> => <<"nosniff">>}, Css, Req);
        _ -> error_reply(400, unknown_application, Req)
    end;
dispatch(branding, Req) ->
    App = query(Req, <<"app">>, <<"damage">>),
    case damage_theme:is_app(App) of
        true -> reply_json(200, #{branding => damage_theme:branding(App)}, Req);
        false -> error_reply(400, unknown_application, Req)
    end;
dispatch(order, Req) ->
    case customer_actor(Req) of
        {ok, Actor} ->
            result(damage_theme_purchase:order_status(maps:get(public_key, Actor),
                     query(Req, <<"id">>, <<>>)), Req);
        _ -> error_reply(401, authentication_required, Req)
    end;
dispatch(settle, Req) ->
    case customer_actor(Req) of
        {ok, Actor} -> mutation(Req, fun(Json, Req1) ->
            Id = maps:get(<<"order_id">>, Json, <<>>),
            result(damage_theme_purchase:settle_order(maps:get(public_key, Actor), Id), Req1)
        end);
        _ -> error_reply(401, authentication_required, Req)
    end;
dispatch(buy_sats, Req) ->
    case customer_actor(Req) of
        {ok, Actor} -> mutation(Req, fun(Json, Req1) ->
            Key = maps:get(<<"theme_key">>, Json, <<>>),
            result(damage_theme_purchase:new_sats(maps:get(public_key, Actor), Key), Req1)
        end);
        _ -> error_reply(401, authentication_required, Req)
    end;
dispatch(buy_damage, Req) ->
    case customer_actor(Req) of
        {ok, Actor} -> mutation(Req, fun(Json, Req1) ->
            Key = maps:get(<<"theme_key">>, Json, <<>>),
            result(damage_theme_purchase:buy_damage(Actor, Key), Req1)
        end);
        _ -> error_reply(401, authentication_required, Req)
    end;
dispatch(admin, Req) ->
    case admin_actor(Req) of
        {ok, Actor} ->
            case cowboy_req:method(Req) of
                <<"GET">> -> admin_info(Req);
                <<"POST">> -> mutation(Req, fun(Json, Req1) -> admin_action(Actor, Json, Req1) end)
            end;
        _ -> error_reply(403, node_admin_required, Req)
    end.

admin_info(Req) ->
    case damage_theme:catalog() of
        {ok, Themes} ->
            Apps = [<<"damage">>, <<"ecai">>, <<"nosternity">>, <<"erm">>, <<"bop">>],
            Selected = maps:from_list([{A, selected(A)} || A <- Apps]),
            reply_json(200, #{themes => Themes, selected => Selected,
                              nft => damage_theme_nft:status()}, Req);
        _ -> error_reply(503, theme_catalog_unavailable, Req)
    end.
selected(App) ->
    case damage_theme_store:selection(App) of
        {ok, V} -> V;
        _ -> #{}
    end.

admin_action(_Actor, #{<<"action">> := <<"publish">>, <<"manifest">> := M}, Req) ->
    result(damage_theme:publish(M), Req);
admin_action(_Actor, #{<<"action">> := <<"import">>, <<"cid">> := Cid}, Req) ->
    result(damage_theme:import(Cid), Req);
admin_action(Actor, #{<<"action">> := <<"reconcile">>, <<"theme_key">> := K}, Req) ->
    _ = Actor,
    result(damage_theme:reconcile(K), Req);
admin_action(Actor, #{<<"action">> := <<"select">>, <<"app">> := App,
    <<"theme_key">> := Key} = Json, Req) ->
    Brand = maps:get(<<"branding">>, Json, #{}),
    Token = maps:get(<<"token_id">>, Json, 0),
    Licence = #{token_id => Token, owner => maps:get(public_key, Actor)},
    result(damage_theme:select(App, Key, Brand, Licence), Req);
admin_action(_, _, Req) -> error_reply(400, invalid_theme_action, Req).

admin_actor(Req) ->
    case damage_settings_http:node_admin(Req) of
        true -> customer_actor(Req);
        false -> {error, node_admin_required}
    end.

customer_actor(Req) ->
    try damage_auth:authenticate(Req, #{action => themes}) of
        {ok, #{authenticated := true, public_key := Account} = Actor} when is_binary(Account) ->
            {ok, Actor};
        _ -> {error, authentication_required}
    catch _:_ -> {error, authentication_required} end.

mutation(Req0, Fun) ->
    %% Same CSRF/origin policy as the existing node-admin settings API.
    case damage_settings_http:csrf_check(Req0) of
        ok ->
            case cowboy_req:header(<<"content-type">>, Req0, <<>>) of
                <<"application/json", _/binary>> ->
                    case cowboy_req:read_body(Req0, #{length => 32768, period => 5000, timeout => 5000}) of
                        {ok, Raw, Req} when byte_size(Raw) =< 32768 ->
                            Decoded = try {ok, jsx:decode(Raw, [return_maps])}
                                      catch _:_ -> {error, invalid_json} end,
                            case Decoded of
                                {ok, M} when is_map(M), map_size(M) =< 30 -> Fun(M, Req);
                                {ok, _} -> error_reply(400, invalid_json_object, Req);
                                {error, Why} -> error_reply(400, Why, Req)
                            end;
                        {more, _, Req} -> error_reply(413, body_too_large, Req);
                        _ -> error_reply(400, invalid_body, Req0)
                    end;
                _ -> error_reply(415, json_required, Req0)
            end;
        {error, _} -> error_reply(403, csrf_check_failed, Req0)
    end.

page(Req, Mode) ->
    File = filename:join([code:priv_dir(damage), "static", "themes", "index.html"]),
    case file:read_file(File) of
        {ok, Raw} ->
            Html = binary:replace(Raw, <<"__MODE__">>, Mode, [global]),
            cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>,
                <<"x-content-type-options">> => <<"nosniff">>,
                <<"referrer-policy">> => <<"no-referrer">>,
                <<"content-security-policy">> =>
                    <<"default-src 'none'; script-src 'self'; style-src 'self'; ",
                      "connect-src 'self'; img-src 'self'; base-uri 'none'; ",
                      "frame-ancestors 'self'; form-action 'self'">>}, Html, Req);
        _ -> error_reply(503, page_unavailable, Req)
    end.

query(Req, Name, Default) ->
    proplists:get_value(Name, cowboy_req:parse_qs(Req), Default).
result({ok, Result}, Req) -> reply_json(200, #{ok => true, data => Result}, Req);
result({error, Why}, Req) ->
    Status = case Why of
        forbidden -> 403;
        theme_not_found -> 404;
        order_not_found -> 404;
        theme_exists -> 409;
        already_published -> 409;
        _ -> 422
    end,
    error_reply(Status, Why, Req);
result(_, Req) -> error_reply(503, unexpected_service_response, Req).
reply_json(Status, Body, Req) -> cowboy_req:reply(Status, ?JSON, jsx:encode(Body), Req).
error_reply(Status, Why, Req) ->
    %% Do not serialize wallet keys, CLN invoice diagnostics or stacktraces.
    Msg = case Why of
        A when is_atom(A) -> atom_to_binary(A, utf8);
        _ -> <<"operation_failed">>
    end,
    reply_json(Status, #{ok => false, error => Msg}, Req).
