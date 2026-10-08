%%%-------------------------------------------------------------------
%%% ERM Maps API tests using the deterministic gtknode4 backend.
%%%-------------------------------------------------------------------
-module(erm_maps_tests).

-include_lib("eunit/include/eunit.hrl").

maps_app_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_SupPid) ->
        [fun maps_api_contract/0]
    end}.

setup() ->
    cleanup_registered(),
    {ok, SupPid} = gtknode4_sup:start_link(#{
        mode => fake,
        gs => #{test_mode => true, event_log_limit => 100}
    }),
    unlink(SupPid),
    ok = gtknode4:await_ready(1000),
    SupPid.

cleanup(SupPid) ->
    _ = erm_maps:stop(),
    exit(SupPid, kill),
    wait_until_stopped(50),
    ok.

maps_api_contract() ->
    {ok, MapsPid} = erm_maps:start_link(#{
        latitude => -33.8688,
        longitude => 151.2093,
        zoom_level => 11.0,
        width => 800,
        height => 600,
        ready_timeout => 1000
    }),
    unlink(MapsPid),

    Status0 = erm_maps:status(),
    ?assertEqual(<<"osm-mapnik">>, maps:get(source_id, Status0)),
    ?assertEqual(-33.8688, maps:get(latitude, Status0)),
    ?assertEqual(151.2093, maps:get(longitude, Status0)),
    ?assertEqual(11.0, maps:get(zoom_level, Status0)),

    ok = erm_maps:set_view(-37.8136, 144.9631, 10.0),
    Status1 = erm_maps:status(),
    ?assertEqual(-37.8136, maps:get(latitude, Status1)),
    ?assertEqual(144.9631, maps:get(longitude, Status1)),
    ?assertEqual(10.0, maps:get(zoom_level, Status1)),

    ok = erm_maps:zoom_in(),
    ?assertEqual(11.0, maps:get(zoom_level, erm_maps:status())),
    ?assertEqual({error, {invalid_latitude, 91}}, erm_maps:set_center(91, 0)),
    ?assertEqual({error, {invalid_zoom_level, 25}}, erm_maps:set_zoom(25)),
    ok = erm_maps:set_zoom(24),
    ok = erm_maps:zoom_in(),
    ?assertEqual(24.0, maps:get(zoom_level, erm_maps:status())),
    ok = erm_maps:hide(),
    ?assertEqual(false, maps:get(visible, erm_maps:status())),
    ok = erm_maps:show(),
    ?assertEqual(true, maps:get(visible, erm_maps:status())).

cleanup_registered() ->
    _ = erm_maps:stop(),
    case whereis(gtknode4_sup) of
        undefined -> ok;
        Pid ->
            exit(Pid, kill),
            wait_until_stopped(50)
    end.

wait_until_stopped(0) ->
    ok;
wait_until_stopped(Attempts) ->
    case whereis(gtknode4_sup) of
        undefined -> ok;
        _ ->
            timer:sleep(10),
            wait_until_stopped(Attempts - 1)
    end.
