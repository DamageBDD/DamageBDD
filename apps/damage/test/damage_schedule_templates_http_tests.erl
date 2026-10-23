-module(damage_schedule_templates_http_tests).
-include_lib("eunit/include/eunit.hrl").

methods_test() ->
    ?assertMatch({[<<"GET">>], _, _}, damage_schedule_v2_http:allowed_methods(#{}, #{action => templates})),
    ?assertMatch({[<<"POST">>], _, _}, damage_schedule_v2_http:allowed_methods(#{}, #{action => render_template})).

new_routes_use_existing_auth_test() ->
    meck:new(damage_http, [no_link]),
    meck:expect(damage_http, is_authorized, fun(Req, State) ->
        {{false, <<"Bearer">>}, Req, State}
    end),
    try
        lists:foreach(fun(Action) ->
            ?assertMatch({{false, _}, _, _}, damage_schedule_v2_http:is_authorized(#{}, #{action => Action}))
        end, [templates, render_template])
    after meck:unload(damage_http) end.

render_handler_test() ->
    meck:new(cowboy_req, [no_link]),
    meck:expect(cowboy_req, read_body, fun(Req, _Opts) -> {ok, maps:get(raw, Req), Req} end),
    meck:expect(cowboy_req, reply, fun(Status, _Headers, Body, Req) -> Req#{reply_status => Status, reply_body => Body} end),
    try
        State = #{action => render_template, public_key => <<"ak_fixture">>},
        Raw = jsx:encode(#{<<"template_id">> => <<"http-uptime">>, <<"params">> => #{
            <<"target_url">> => <<"https://node.example.com/health">>, <<"authorized">> => true}}),
        {stop, #{reply_status := 200, reply_body := Body}, State} =
            damage_schedule_v2_http:from_json(#{raw => Raw}, State),
        ?assertMatch(#{<<"feature">> := _}, jsx:decode(Body, [return_maps])),
        ?assertMatch({stop, #{reply_status := 400}, _},
            damage_schedule_v2_http:from_json(#{raw => <<"not json">>}, State)),
        ?assertMatch({stop, #{reply_status := 400}, _},
            damage_schedule_v2_http:from_json(#{raw => <<"[]">>}, State)),
        ?assertMatch({stop, #{reply_status := 413}, _},
            damage_schedule_v2_http:from_json(#{raw => binary:copy(<<"x">>, 8193)}, State))
    after meck:unload(cowboy_req) end.
