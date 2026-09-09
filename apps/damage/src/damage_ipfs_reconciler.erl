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
    case damage_ipfs_store:page(Cursor, maps:get(reconcile_batch, C)) of
        {ok, Rows, Next} ->
            Deadline =
                erlang:monotonic_time(millisecond) + maps:get(loop_timeout_ms, C) -
                    maps:get(request_timeout_ms, C) - 2000,
            check(Rows, Next, Cursor, Deadline, 0, 0);
        E ->
            E
    end.
check([], Next, _, _, Checked, Missing) ->
    {ok, #{checked => Checked, missing => Missing}, Next};
check([{Cid, R} | Rest], Next, Last, Deadline, Checked, Missing) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {ok, #{checked => Checked, missing => Missing, partial => true}, Last};
        false ->
            case R of
                #{desired := Desired, status := applied, revision := Rev} ->
                    Expected = Desired =:= pinned,
                    Op =
                        case Desired of
                            pinned -> pin_check;
                            unpinned -> explicit_pin_check
                        end,
                    case damage_ipfs_client:request({Op, Cid}) of
                        {ok, Expected} ->
                            check(Rest, Next, Cid, Deadline, Checked + 1, Missing);
                        {ok, Actual} when is_boolean(Actual) ->
                            _ = damage_ipfs_store:requeue(Cid, Rev),
                            _ = damage_ipfs_pinner:wake(),
                            check(Rest, Next, Cid, Deadline, Checked + 1, Missing + 1);
                        {error, _} = E ->
                            E;
                        _ ->
                            {error, invalid_pin_check}
                    end;
                _ ->
                    check(Rest, Next, Cid, Deadline, Checked, Missing)
            end
    end.
