-module(damage_ipfs_pinner).
-export([start_link/1, pin/1, unpin/1, wake/0, status/0, run/2]).
start_link(C) ->
    damage_ipfs_loop:start_link(
        ?MODULE,
        ?MODULE,
        maps:get(pin_poll_ms, C),
        C,
        undefined
    ).
pin(Cid) -> enqueue(Cid, pinned).
unpin(Cid) -> enqueue(Cid, unpinned).
wake() -> damage_ipfs_loop:trigger(?MODULE).
status() -> damage_ipfs_loop:status(?MODULE).
enqueue(Cid, Desired) ->
    case damage_ipfs_store:desire(Cid, Desired) of
        {ok, Receipt} ->
            _ = wake(),
            {ok, Receipt};
        Error ->
            Error
    end.
run(_, D) ->
    case damage_ipfs_store:next_pending() of
        empty ->
            {ok, idle, D};
        {ok, Cid, #{revision := Rev, desired := Desired, attempts := Attempts}} ->
            Op =
                case Desired of
                    pinned -> ensure_pin;
                    unpinned -> unpin
                end,
            Result = damage_ipfs_client:request({Op, Cid}),
            case damage_ipfs_store:complete(Cid, Rev, Result) of
                ok ->
                    case {successful(Result), Attempts} of
                        {false, 0} ->
                            logger:warning("IPFS intent pending retry op=~p cid=~s", [Op, Cid]);
                        {true, N} when N > 0 ->
                            logger:notice("IPFS intent recovered op=~p cid=~s", [Op, Cid]);
                        _ ->
                            ok
                    end,
                    %% Retry timing belongs to the durable record, not this
                    %% loop. One failing CID does not stall other queued pins.
                    {ok, #{cid => Cid, success => successful(Result)}, D};
                {error, stale_revision} ->
                    {ok, superseded, D};
                E ->
                    E
            end;
        E ->
            E
    end.
successful(ok) -> true;
successful({ok, _}) -> true;
successful(_) -> false.
