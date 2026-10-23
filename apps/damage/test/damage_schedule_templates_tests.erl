-module(damage_schedule_templates_tests).
-include_lib("eunit/include/eunit.hrl").

catalog_test() ->
    Ts = damage_schedule_templates:catalog(),
    Ids = [maps:get(id, T) || T <- Ts],
    ?assertEqual(9, length(Ts)),
    ?assertEqual(Ids -- lists:usort(Ids), []),
    lists:foreach(fun(T) ->
        ?assertEqual(7, maps:get(window_days, T)),
        ?assertMatch({ok, _}, damage_schedule_v2_cron:parse(maps:get(cron_spec, T)))
    end, Ts).

all_templates_render_test() ->
    lists:foreach(fun(T) ->
        Id = maps:get(id, T),
        {ok, Draft} = damage_schedule_templates:render(Id, params(Id)),
        Feature = maps:get(feature, Draft),
        ?assertMatch(<<"Feature:", _/binary>>, Feature),
        ?assert(binary:match(Feature, <<"Then the monitor check must pass">>) =/= nomatch),
        ?assertEqual(Id, maps:get(template_id, Draft)),
        ?assertEqual(7, maps:get(window_days, Draft))
    end, damage_schedule_templates:catalog()).

%% Exercise real deployed parser/catalog signatures, not an invented validator.
all_templates_match_step_catalog_test() ->
    {module, steps_monitor} = code:ensure_loaded(steps_monitor),
    {steps_monitor, Beam, _} = code:get_object_code(steps_monitor),
    {ok, {steps_monitor, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    Steps = damage_bdd_catalog:from_forms(<<"steps_monitor">>, <<0:128>>, Forms),
    Catalog = #{revision => <<"test">>, steps => Steps},
    lists:foreach(fun(T) ->
        Id = maps:get(id, T),
        {ok, #{feature := F}} = damage_schedule_templates:render(Id, params(Id)),
        Validation = damage_bdd_validator:validate(F, Catalog),
        ?assertEqual(true, maps:get(valid, Validation)),
        ?assertEqual(3, maps:get(step_count, Validation))
    end, damage_schedule_templates:catalog()).

consent_and_unknown_fields_test() ->
    P = params(<<"http-uptime">>),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, maps:remove(<<"authorized">>, P))),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, P#{<<"authorized">> => <<"true">>})),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, P#{<<"private_network">> => true})),
    ?assertEqual({error, unknown_schedule_template}, damage_schedule_templates:render(<<"shell">>, P)).

input_validation_test() ->
    P = params(<<"http-uptime">>),
    lists:foreach(fun(Url) ->
        ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, P#{<<"target_url">> => Url}))
    end, [<<"file:///etc/passwd">>, <<"https://u:p@node.example.com/">>,
        <<"https://node.example.com/?secret=x">>, <<"https://node.example.com/#x">>,
        <<"https://node.example.com/\"\nThen injected">>, <<"https://{{secret}}/">>]),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, P#{<<"max_ms">> => 0})),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"http-uptime">>, P#{<<"max_ms">> => <<"3000">>})),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"tls-expiry">>, #{
        <<"authorized">> => true, <<"target_url">> => <<"http://node.example.com/">>})),
    ?assertMatch({error, _}, damage_schedule_templates:render(<<"node-exposure">>, P#{<<"target_url">> => <<"https://node.example.com/subpath">>})).

params(<<"ipfs-content">>) -> #{<<"authorized">> => true,
    <<"target_url">> => <<"https://gateway.example.com/ipfs/QmYwAPJzv5CZsnAzt8auVZRnGiRAxgaXj1uCAYY97HCUwM">>};
params(<<"content-canary">>) -> #{<<"authorized">> => true,
    <<"target_url">> => <<"https://node.example.com/">>, <<"contains">> => <<"Healthy">>};
params(_) -> #{<<"authorized">> => true, <<"target_url">> => <<"https://node.example.com/">>}.
