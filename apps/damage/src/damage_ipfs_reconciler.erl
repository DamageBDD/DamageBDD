-module(damage_ipfs_reconciler).
-export([start_link/1, reconcile/0, status/0, run/2]).
start_link(C) ->
    damage_ipfs_loop:start_link(
        ?MODULE,
        ?MODULE,
        maps:get(reconcile_interval_ms, C),
        C,
        start
    ).
reconcile() -> damage_ipfs_loop:trigger(?MODULE).
status() -> damage_ipfs_loop:status(?MODULE).
run(C, Cursor) ->
    Deadline =
        erlang:monotonic_time(millisecond) + maps:get(loop_timeout_ms, C) -
            maps:get(request_timeout_ms, C) - 2000,
    case damage_ipfs_store:page(Cursor, maps:get(reconcile_batch, C)) of
        {ok, Rows, Next} ->
            Summary = #{
                checked => 0,
                missing => 0,
                failed => 0,
                deferred => 0,
                backoff => false
            },
            check(Rows, Next, Cursor, Deadline, Summary);
        E ->
            E
    end.
check([], Next, _, _, Summary) ->
    {ok, Summary, Next};
check([{Cid, R} | Rest], Next, Last, Deadline, Summary) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {ok, Summary#{partial => true}, Last};
        false ->
            case R of
                #{desired := Desired, status := applied, revision := Rev} ->
                    case maps:get(verify_next_at, R, 0) > damage_ipfs_config:now_ms() of
                        true ->
                            check(Rest, Next, Cid, Deadline, inc(deferred, Summary));
                        false ->
                            Expected = Desired =:= pinned,
                            Op =
                                case Desired of
                                    pinned -> pin_check;
                                    unpinned -> explicit_pin_check
                                end,
                            Result = damage_ipfs_client:request({Op, Cid}),
                            {StoreResult, Summary1} = record(
                                Result, Expected, Cid, Rev, R, Summary
                            ),
                            case StoreResult of
                                ok ->
                                    check(Rest, Next, Cid, Deadline, Summary1);
                                {error, stale_revision} ->
                                    check(Rest, Next, Cid, Deadline, Summary1);
                                E ->
                                    {error, {verification_store, E}}
                            end
                    end;
                _ ->
                    check(Rest, Next, Cid, Deadline, Summary)
            end
    end.

record({ok, Expected}, Expected, Cid, Rev, R, Summary) ->
    %% Avoid a disk write for every healthy scan. Clear a previous failure
    %% once verification recovers; otherwise leave durable pin state untouched.
    Result =
        case maps:get(verify_attempts, R, 0) of
            0 -> ok;
            _ -> damage_ipfs_store:verification_result(Cid, Rev, ok)
        end,
    {Result, inc(checked, Summary)};
record({ok, Actual}, _, Cid, Rev, _, Summary) when is_boolean(Actual) ->
    Result = damage_ipfs_store:requeue(Cid, Rev),
    case Result of
        ok -> _ = damage_ipfs_pinner:wake();
        _ -> ok
    end,
    {Result, inc(missing, inc(checked, Summary))};
record({error, _} = Error, _, Cid, Rev, _, Summary) ->
    {damage_ipfs_store:verification_result(Cid, Rev, Error), inc(failed, Summary)};
record(_, Expected, Cid, Rev, R, Summary) ->
    record({error, invalid_pin_check}, Expected, Cid, Rev, R, Summary).
inc(Key, Summary) -> Summary#{Key => maps:get(Key, Summary) + 1}.
