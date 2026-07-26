-module(ecai_index_job_events_tests).

-include_lib("eunit/include/eunit.hrl").

live_publish_and_unsubscribe_test() ->
    WasRunning = is_pid(whereis(ecai_index_job_events)),
    case WasRunning of
        true ->
            ok;
        false ->
            {ok, Pid} = ecai_index_job_events:start_link(),
            unlink(Pid)
    end,
    JobId = <<"ijob-events">>,
    Event = #{seq => 1, type => <<"progress">>},
    try
        ok = ecai_index_job_events:subscribe(JobId, self()),
        ok = ecai_index_job_events:publish(JobId, Event),
        receive
            {ecai_index_job_event, JobId, Event} -> ok
        after 1000 ->
            error(event_timeout)
        end,
        ok = ecai_index_job_events:unsubscribe(JobId, self()),
        ?assertEqual(0, ecai_index_job_events:subscriber_count(JobId))
    after
        case WasRunning of
            true -> ok;
            false -> gen_server:stop(ecai_index_job_events)
        end
    end.
