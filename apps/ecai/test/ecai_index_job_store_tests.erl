-module(ecai_index_job_store_tests).

-include_lib("eunit/include/eunit.hrl").

store_round_trip_test() ->
    with_tmp(fun(Dir) ->
        {ok, Store1} = ecai_index_job_store:open(Dir),
        {ok, 1} = ecai_index_job_store:next_sequence(Store1),
        Job = #{id => <<"ijob-test">>, state => queued},
        Event = #{seq => 1, job_id => <<"ijob-test">>, type => <<"state">>},
        ok = ecai_index_job_store:create_job(
            Store1,
            Job,
            Event,
            <<"owner">>,
            <<"key">>
        ),
        ok = ecai_index_job_store:sync(Store1),
        ok = ecai_index_job_store:close(Store1),

        {ok, Store2} = ecai_index_job_store:open(Dir),
        ?assertEqual({ok, Job}, ecai_index_job_store:get_job(Store2, <<"ijob-test">>)),
        ?assertEqual(
            {ok, <<"ijob-test">>},
            ecai_index_job_store:get_idempotency(Store2, <<"owner">>, <<"key">>)
        ),
        ok = ecai_index_job_store:replace_idempotency(
            Store2,
            [{<<"owner">>, <<"new-key">>, <<"ijob-test">>}]
        ),
        ?assertEqual(
            not_found,
            ecai_index_job_store:get_idempotency(Store2, <<"owner">>, <<"key">>)
        ),
        ?assertEqual(
            {ok, <<"ijob-test">>},
            ecai_index_job_store:get_idempotency(
                Store2,
                <<"owner">>,
                <<"new-key">>
            )
        ),
        ?assertEqual(
            {ok, [Event]},
            ecai_index_job_store:events_after(Store2, <<"ijob-test">>, 0, 10)
        ),
        {ok, 2} = ecai_index_job_store:next_sequence(Store2),
        ok = ecai_index_job_store:close(Store2)
    end).

with_tmp(Fun) ->
    Dir = temp_dir(),
    try
        Fun(Dir)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Dir = filename:join(
        Root,
        "ecai-index-job-store-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Child = filename:join(Path, Name),
                    case filelib:is_dir(Child) of
                        true -> remove_tree(Child);
                        false -> _ = file:delete(Child)
                    end
                end,
                Names
            ),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} ->
            ok;
        {error, _Reason} ->
            ok
    end.
