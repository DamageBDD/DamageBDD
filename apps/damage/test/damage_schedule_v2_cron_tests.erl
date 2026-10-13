-module(damage_schedule_v2_cron_tests).

-include_lib("eunit/include/eunit.hrl").

parse_hourly_test() ->
    {ok, Parsed} = damage_schedule_v2_cron:parse(<<"0 * * * *">>),
    ?assertEqual([0], maps:get(minute, Parsed)),
    ?assertEqual(lists:seq(0, 23), maps:get(hour, Parsed)).

invalid_cron_test() ->
    ?assertMatch({error, _}, damage_schedule_v2_cron:parse(<<"61 * * * *">>)),
    ?assertMatch({error, _}, damage_schedule_v2_cron:parse(<<"not a cron">>)).

next_hour_test() ->
    After = epoch({{2026, 1, 1}, {0, 1, 0}}),
    Expected = epoch({{2026, 1, 1}, {1, 0, 0}}),
    ?assertEqual({ok, Expected}, damage_schedule_v2_cron:next_after(<<"0 * * * *">>, After)).

weekdays_skip_weekend_test() ->
    %% 2026-01-02 is Friday; the next weekday at 09:30 after Friday 10:00 is Monday.
    After = epoch({{2026, 1, 2}, {10, 0, 0}}),
    Expected = epoch({{2026, 1, 5}, {9, 30, 0}}),
    ?assertEqual(
        {ok, Expected},
        damage_schedule_v2_cron:next_after(<<"30 9 * * 1-5">>, After)
    ).

occurrences_hourly_test() ->
    From = epoch({{2026, 1, 1}, {0, 0, 0}}),
    To = epoch({{2026, 1, 1}, {3, 0, 0}}),
    {ok, Runs} = damage_schedule_v2_cron:occurrences(<<"0 * * * *">>, From, To),
    ?assertEqual(4, length(Runs)),
    ?assertEqual(From, hd(Runs)),
    ?assertEqual(To, lists:last(Runs)).

human_label_test() ->
    ?assertEqual(<<"Every 15 minutes">>, damage_schedule_v2_cron:human(<<"*/15 * * * *">>)),
    ?assertEqual(<<"Daily at 09:30 UTC">>, damage_schedule_v2_cron:human(<<"30 9 * * *">>)).

epoch(DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
